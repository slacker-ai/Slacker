import Foundation
import GRDB

/// Pulls messages + threads for watched channels into the local mirror (§6).
/// UI-free and timer-free so it can be unit-tested; `Poller` drives it on a schedule.
struct IngestionService {
    /// First sync for a newly watched channel is intentionally bounded. After that,
    /// `Channel.lastPolledTS` drives exact incremental backfill across restarts.
    static let initialHistoryLookbackDays = 3

    let client: SlackClient
    let database: AppDatabase
    /// Injectable clock so `ingestedAt` is deterministic in tests.
    var now: () -> Date = { Date() }
    /// Resolves a workspace's Slack token (Keychain by default; injected in tests).
    var tokenProvider: (_ workspaceID: String) -> String? = {
        (try? KeychainStore.getToken(workspaceID: $0)) ?? nil
    }

    /// Poll every connected workspace once (one full cycle), each with its own token.
    func pollAllWorkspaces() async throws {
        let workspaces = try await database.dbWriter.read { db in
            try Workspace.fetchAll(db)
        }
        guard !workspaces.isEmpty else {
            Log.info("Ingestion: no workspaces connected.")
            return
        }
        for workspace in workspaces {
            guard let token = tokenProvider(workspace.id), !token.isEmpty else {
                Log.error("Ingestion[\(workspace.name)]: no token available; skipping.")
                continue
            }
            try await pollWorkspace(workspaceID: workspace.id, token: token)
        }
    }

    /// Poll one workspace's watched channels, then re-fetch its open threads.
    func pollWorkspace(workspaceID: String, token: String) async throws {
        let channels = try await database.dbWriter.read { db in
            try Channel
                .filter(Column("workspaceID") == workspaceID && Column("isWatched") == true)
                .fetchAll(db)
        }
        Log.info("Ingestion[\(workspaceID)]: \(channels.count) watched channel(s): \(channels.map(\.name).joined(separator: ", "))")
        for channel in channels {
            try await pollChannel(channel, token: token)
        }

        // Re-fetch the threads of active/terminal items so resolving replies/reactions on
        // older threads are captured, resolved threads can reopen, and dismissed threads
        // can return if the connected user is newly mentioned.
        try await refreshOpenItemThreads(workspaceID: workspaceID, token: token)
    }

    /// States whose threads we keep watching for resolution/reopen signals.
    private static let refreshableItemStates: [ItemState] = [.open, .surfaced, .review, .resolved, .dismissed]

    private func refreshOpenItemThreads(workspaceID: String, token: String) async throws {
        let openItems = try await database.dbWriter.read { db in
            // Open items in this workspace's channels only.
            let channelIDs = try Channel
                .filter(Column("workspaceID") == workspaceID)
                .fetchAll(db).map(\.id)
            return try Item
                .filter(IngestionService.refreshableItemStates.map(\.rawValue).contains(Column("state")))
                .filter(channelIDs.contains(Column("channelID")))
                .fetchAll(db)
        }
        // Unique (channel, threadRoot) pairs.
        let threads = Set(openItems.map { "\($0.channelID)\t\($0.rootMessageTS)" })
        guard !threads.isEmpty else { return }
        Log.info("Refreshing \(threads.count) active thread(s) for resolution/reopen.")

        for key in threads {
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (channelID, rootTS) = (parts[0], parts[1])

            // conversations.replies returns the root (with current reactions) + all replies.
            let thread: [SlackMessage]
            do {
                thread = try await client.conversationsReplies(
                    token: token, channelID: channelID, threadTS: rootTS
                )
            } catch SlackClientError.api("thread_not_found") {
                Log.info("Ingestion: tracked thread not found; dropping local item(s) for channel=\(channelID) rootTS=\(rootTS).")
                try await dropItemsForMissingThread(channelID: channelID, rootTS: rootTS)
                continue
            }
            guard !thread.isEmpty else { continue }

            try await resolveUnknownUsers(in: thread, token: token)
            let records = try await records(from: thread, channelID: channelID)
            try await database.dbWriter.write { db in
                for record in records { try record.save(db) }  // idempotent upsert
            }
        }
    }

    private func dropItemsForMissingThread(channelID: String, rootTS: String) async throws {
        try await database.dbWriter.write { db in
            try Item
                .filter(Column("channelID") == channelID && Column("rootMessageTS") == rootTS)
                .deleteAll(db)
        }
    }

    /// Fetch new top-level messages since `lastPolledTS`, pull their threads, resolve
    /// users, persist idempotently, and advance the channel's polling boundary.
    func pollChannel(_ channel: Channel, token: String) async throws {
        let oldest = channel.lastPolledTS ?? initialHistoryOldestTS()
        let history = try await client.conversationsHistory(
            token: token,
            channelID: channel.id,
            oldest: oldest
        )

        // Collect thread replies for any root that has them (§6.2).
        var allMessages = history
        for message in history where message.hasReplies {
            let replies = try await client.conversationsReplies(
                token: token,
                channelID: channel.id,
                threadTS: message.ts
            )
            allMessages.append(contentsOf: replies)
        }

        guard !allMessages.isEmpty else {
            Log.info("Ingestion[#\(channel.name)]: no new messages since \(oldest ?? "start").")
            return
        }
        Log.info("Ingestion[#\(channel.name)]: \(history.count) new top-level, \(allMessages.count) total (incl. replies).")

        try await resolveUnknownUsers(in: allMessages, token: token)

        // Newest top-level ts becomes the next polling boundary.
        let newestRootTS = history.map(\.ts).max()
        let records = try await records(from: allMessages, channelID: channel.id)

        try await database.dbWriter.write { db in
            // Idempotent: PK is channelID:ts, so save() upserts (no duplicates) (§3).
            for record in records {
                try record.save(db)
            }
            if let newestRootTS {
                try Channel
                    .filter(key: channel.id)
                    .updateAll(db, Column("lastPolledTS").set(to: newestRootTS))
            }
        }
    }

    // MARK: - Helpers

    private func initialHistoryOldestTS() -> String {
        let oldest = now().addingTimeInterval(Double(-Self.initialHistoryLookbackDays * 24 * 60 * 60))
        return String(format: "%.6f", oldest.timeIntervalSince1970)
    }

    private func records(from messages: [SlackMessage], channelID: String) async throws -> [Message] {
        var records = messages.map { record(from: $0, channelID: channelID) }
        let ids = records.map(\.id)
        guard !ids.isEmpty else { return records }

        let existingByID = try await database.dbWriter.read { db in
            let existing = try Message
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        }

        for index in records.indices {
            let existing = existingByID[records[index].id]
            records[index].resolvedReactionObservedAt = resolvedReactionObservedAt(
                existing: existing,
                incoming: records[index]
            )
        }
        return records
    }

    private func record(from message: SlackMessage, channelID: String) -> Message {
        var reactionsJSON: String?
        if let reactions = message.reactions, !reactions.isEmpty,
           let data = try? JSONEncoder().encode(reactions) {
            reactionsJSON = String(data: data, encoding: .utf8)
        }
        return Message(
            channelID: channelID,
            ts: message.ts,
            threadTS: message.threadTS,
            userID: message.user,
            text: message.text ?? "",
            reactionsJSON: reactionsJSON,
            ingestedAt: now()
        )
    }

    private func resolvedReactionObservedAt(existing: Message?, incoming: Message) -> Date? {
        let oldResolvedCount = resolvedReactionCount(existing?.reactionsJSON)
        let newResolvedCount = resolvedReactionCount(incoming.reactionsJSON)
        if newResolvedCount > oldResolvedCount {
            return now()
        }
        return existing?.resolvedReactionObservedAt
    }

    private func resolvedReactionCount(_ json: String?) -> Int {
        guard let json, let data = json.data(using: .utf8),
              let reactions = try? JSONDecoder().decode([SlackReaction].self, from: data) else {
            return 0
        }
        return reactions.reduce(0) { count, reaction in
            let normalizedName = reaction.name
                .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            return EmojiSignalDetector.resolvedReactionNames.contains(normalizedName)
                ? count + reaction.count
                : count
        }
    }

    /// Fetch + cache any user ids we haven't seen yet (grounding, §7).
    private func resolveUnknownUsers(in messages: [SlackMessage], token: String) async throws {
        let ids = Set(messages.compactMap(\.user))
        guard !ids.isEmpty else { return }

        let known = try await database.dbWriter.read { db in
            try CachedUser.filter(keys: ids).fetchAll(db)
        }
        let knownIDs = Set(known.map(\.id))
        let unknownIDs = ids.subtracting(knownIDs)

        for id in unknownIDs {
            // A single failed lookup must not abort the whole poll.
            guard let apiUser = try? await client.usersInfo(token: token, userID: id) else { continue }
            try await database.dbWriter.write { db in
                try CachedUser(from: apiUser).save(db)
            }
        }
    }
}
