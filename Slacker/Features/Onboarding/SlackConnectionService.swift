import Foundation
import GRDB

/// Bridges the Slack API, Keychain, and local DB for connecting workspaces (§5).
/// UI-free so it can be unit-tested with a stub transport + in-memory database.
struct SlackConnectionService {
    let client: SlackClient
    let database: AppDatabase
    /// Injectable Keychain writers so tests don't touch the real Keychain.
    var storeToken: (_ token: String, _ workspaceID: String) throws -> Void = {
        try KeychainStore.setToken($0, workspaceID: $1)
    }
    var deleteToken: (_ workspaceID: String) throws -> Void = { try KeychainStore.deleteToken(workspaceID: $0) }
    var storeAPIKey: (String) throws -> Void = { try KeychainStore.set($0, for: .llmAPIKey) }
    var now: () -> Date = { Date() }

    struct Connection: Equatable {
        let team: String
        let user: String
        let teamID: String
        let userID: String
    }

    /// LLM choice captured during onboarding.
    struct LLMConfig: Equatable {
        var provider: LLMProvider
        var model: String
        var baseURL: String
        var cliPath: String
        var apiKey: String
    }

    /// Validate the token (`auth.test`), store it under the workspace, and cache the user.
    func connect(token: String) async throws -> Connection {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SlackClientError.api("not_authed") }

        let auth = try await client.authTest(token: trimmed)
        guard let userID = auth.userId, let teamID = auth.teamId, !teamID.isEmpty else {
            throw SlackClientError.decoding
        }

        // Store the token under this workspace only after a successful validation.
        try storeToken(trimmed, teamID)

        let apiUser = try await client.usersInfo(token: trimmed, userID: userID)
        try await database.dbWriter.write { db in
            try CachedUser(from: apiUser).save(db)
        }

        return Connection(
            team: auth.team ?? teamID,
            user: auth.user ?? apiUser.bestDisplayName,
            teamID: teamID,
            userID: userID
        )
    }

    /// Create/update the workspace record for a validated connection.
    func upsertWorkspace(_ connection: Connection, variant: ManifestVariant) throws {
        try database.dbWriter.write { db in
            if var existing = try Workspace.fetchOne(db, key: connection.teamID) {
                existing.name = connection.team
                existing.authUserID = connection.userID
                existing.manifestVariant = variant
                try existing.update(db)
            } else {
                try Workspace(
                    id: connection.teamID,
                    name: connection.team,
                    authUserID: connection.userID,
                    manifestVariant: variant,
                    createdAt: now()
                ).insert(db)
            }
        }
    }

    /// Fetch the workspace's channels and upsert them (tagged with `workspaceID`),
    /// preserving existing watch/sensitivity choices. Returns that workspace's channels.
    func refreshChannels(token: String, variant: ManifestVariant, workspaceID: String) async throws -> [Channel] {
        // Also refresh the workspace's display name (repairs migrated/ID-named rows).
        let teamName = (try? await client.authTest(token: token))?.team
        let conversations = try await client.listConversations(
            token: token,
            includePrivate: variant == .publicAndPrivate
        )

        try await database.dbWriter.write { db in
            if let teamName, !teamName.isEmpty, var workspace = try Workspace.fetchOne(db, key: workspaceID) {
                workspace.name = teamName
                try workspace.update(db)
            }
            for conv in conversations {
                if var existing = try Channel.fetchOne(db, key: conv.id) {
                    existing.name = conv.name ?? conv.id
                    existing.isPrivate = conv.isPrivate ?? false
                    existing.workspaceID = workspaceID
                    try existing.update(db)
                } else {
                    try Channel(
                        id: conv.id,
                        workspaceID: workspaceID,
                        name: conv.name ?? conv.id,
                        isPrivate: conv.isPrivate ?? false
                    ).insert(db)
                }
            }
        }

        return try await database.dbWriter.read { db in
            try Channel
                .filter(Column("workspaceID") == workspaceID)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    /// Toggle whether a channel is watched.
    func setWatched(_ isWatched: Bool, channelID: String) throws {
        _ = try database.dbWriter.write { db in
            try Channel
                .filter(key: channelID)
                .updateAll(db, Column("isWatched").set(to: isWatched))
        }
    }

    /// Remove a workspace: delete its token + record (channels/messages/items cascade).
    func removeWorkspace(_ workspaceID: String) throws {
        try? deleteToken(workspaceID)
        _ = try database.dbWriter.write { db in
            // Channels cascade-delete their messages/items/summaries via FK.
            try Channel.filter(Column("workspaceID") == workspaceID).deleteAll(db)
            try Workspace.deleteOne(db, key: workspaceID)
        }
    }

    /// Mark onboarding complete and persist the (global) LLM choice. The LLM API key
    /// goes to the Keychain, never the DB.
    func completeOnboarding(llm: LLMConfig? = nil) throws {
        try database.dbWriter.write { db in
            var settings = try AppSettings.loadOrCreate(db)
            if let llm {
                settings.llmProvider = llm.provider
                settings.llmModel = llm.model.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.llmBaseURL = llm.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.cliPathOverride = llm.cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            settings.onboardingCompleted = true
            try settings.update(db)
        }
        if let llm {
            let key = llm.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { try storeAPIKey(key) }
        }
    }
}
