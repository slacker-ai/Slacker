import XCTest
import GRDB
@testable import Slacker

final class SlackConnectionServiceTests: XCTestCase {

    private func makeService(
        transport: StubTransport,
        database: AppDatabase,
        onStore: @escaping (_ token: String, _ workspaceID: String) -> Void = { _, _ in }
    ) -> SlackConnectionService {
        let client = SlackClient(transport: transport, sleep: { _ in })
        return SlackConnectionService(
            client: client,
            database: database,
            storeToken: { token, workspaceID in onStore(token, workspaceID) }
        )
    }

    func testConnectStoresTokenUnderWorkspaceAndCachesUser() async throws {
        let db = try AppDatabase.makeInMemory()
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("auth.test") {
                return (jsonData(#"{"ok":true,"team":"Acme","user":"daanish","team_id":"T1","user_id":"U1"}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"""
            {"ok":true,"user":{"id":"U1","name":"daanish","real_name":"Daanish H",
              "profile":{"display_name":"daanish","real_name":"Daanish H"}}}
            """#), makeHTTPResponse(200))
        }

        var storedToken: String?
        var storedWorkspace: String?
        let service = makeService(transport: transport, database: db) { token, ws in
            storedToken = token; storedWorkspace = ws
        }

        let connection = try await service.connect(token: "  xoxp-token  ")

        XCTAssertEqual(connection.team, "Acme")
        XCTAssertEqual(connection.teamID, "T1")
        XCTAssertEqual(storedToken, "xoxp-token", "token is trimmed before storing")
        XCTAssertEqual(storedWorkspace, "T1", "token is keyed by workspace")

        let cached = try await db.dbWriter.read { try CachedUser.fetchOne($0, key: "U1") }
        XCTAssertEqual(cached?.displayName, "daanish")
    }

    func testConnectRejectsEmptyTokenWithoutStoring() async {
        let db = try! AppDatabase.makeInMemory()
        let transport = StubTransport { _ in (jsonData(#"{"ok":true}"#), makeHTTPResponse(200)) }
        var stored = false
        let service = makeService(transport: transport, database: db) { _, _ in stored = true }

        do {
            _ = try await service.connect(token: "   ")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? SlackClientError, .api("not_authed"))
            XCTAssertFalse(stored, "must not store an empty token")
            XCTAssertEqual(transport.requestCount, 0, "must not hit the network for an empty token")
        }
    }

    func testUpsertWorkspaceCreatesRow() async throws {
        let db = try AppDatabase.makeInMemory()
        let service = makeService(transport: StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }, database: db)
        let connection = SlackConnectionService.Connection(team: "Acme", user: "d", teamID: "T1", userID: "U1")

        try service.upsertWorkspace(connection, variant: .publicOnly)

        let ws = try await db.dbWriter.read { try Workspace.fetchOne($0, key: "T1") }
        XCTAssertEqual(ws?.name, "Acme")
        XCTAssertEqual(ws?.manifestVariant, .publicOnly)
        XCTAssertEqual(ws?.authUserID, "U1")
    }

    func testRefreshChannelsTagsWorkspaceAndPreservesWatchState() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "old-name", isPrivate: false, isWatched: true).insert(dbc)
        }
        let transport = StubTransport { _ in
            (jsonData(#"""
            {"ok":true,"channels":[
              {"id":"C1","name":"general","is_private":false,"is_member":true},
              {"id":"C2","name":"random","is_private":false,"is_member":true}
            ],"response_metadata":{"next_cursor":""}}
            """#), makeHTTPResponse(200))
        }
        let service = makeService(transport: transport, database: db)

        let channels = try await service.refreshChannels(token: "t", variant: .publicOnly, workspaceID: "T1")

        XCTAssertEqual(channels.map(\.id), ["C1", "C2"])
        let c1 = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1") }
        XCTAssertEqual(c1?.name, "general", "name refreshed")
        XCTAssertEqual(c1?.workspaceID, "T1")
        XCTAssertEqual(c1?.isWatched, true, "existing watch state preserved across refresh")
    }

    func testRefreshChannelsRepairsWorkspaceName() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            // A workspace whose name is still the placeholder ID (e.g. from migration).
            try Workspace(id: "T1", name: "T1", authUserID: "U1", manifestVariant: .publicOnly,
                          createdAt: Date(timeIntervalSince1970: 1)).insert(dbc)
        }
        let transport = StubTransport { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("auth.test") {
                return (jsonData(#"{"ok":true,"team":"Acme Corp","team_id":"T1","user_id":"U1"}"#),
                        makeHTTPResponse(200))
            }
            return (jsonData(#"{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}"#),
                    makeHTTPResponse(200))
        }
        let service = makeService(transport: transport, database: db)

        _ = try await service.refreshChannels(token: "t", variant: .publicOnly, workspaceID: "T1")

        let name = try await db.dbWriter.read { try Workspace.fetchOne($0, key: "T1")?.name }
        XCTAssertEqual(name, "Acme Corp", "refresh pulls the human workspace name from auth.test")
    }

    func testRemoveWorkspaceDeletesTokenAndChannels() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            try Workspace(id: "T1", name: "Acme", authUserID: "U1", manifestVariant: .publicOnly,
                          createdAt: Date(timeIntervalSince1970: 1)).insert(dbc)
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false, isWatched: true).insert(dbc)
        }
        var deletedWorkspace: String?
        var service = makeService(transport: StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }, database: db)
        service.deleteToken = { deletedWorkspace = $0 }

        try service.removeWorkspace("T1")

        XCTAssertEqual(deletedWorkspace, "T1", "the workspace token is deleted")
        let wsCount = try await db.dbWriter.read { try Workspace.fetchCount($0) }
        let chCount = try await db.dbWriter.read { try Channel.fetchCount($0) }
        XCTAssertEqual(wsCount, 0)
        XCTAssertEqual(chCount, 0, "the workspace's channels are removed too")
    }

    func testCompleteOnboardingPersistsLLMChoiceNoKeyForLocal() async throws {
        let db = try AppDatabase.makeInMemory()
        var storedKey: String?
        let service = SlackConnectionService(
            client: SlackClient(transport: StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }, sleep: { _ in }),
            database: db, storeToken: { _, _ in }, storeAPIKey: { storedKey = $0 }
        )
        let llm = SlackConnectionService.LLMConfig(
            provider: .ollama, model: "llama3", baseURL: "http://localhost:11434", cliPath: "", apiKey: ""
        )

        try service.completeOnboarding(llm: llm)

        let settings = try await db.dbWriter.read { try AppSettings.fetchOne($0, key: 1) }
        XCTAssertEqual(settings?.llmProvider, .ollama)
        XCTAssertEqual(settings?.llmModel, "llama3")
        XCTAssertEqual(settings?.onboardingCompleted, true)
        XCTAssertNil(storedKey, "local LLM has no key to store")
    }

    func testCompleteOnboardingStoresAPIKeyForCloudProvider() async throws {
        let db = try AppDatabase.makeInMemory()
        var storedKey: String?
        let service = SlackConnectionService(
            client: SlackClient(transport: StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }, sleep: { _ in }),
            database: db, storeToken: { _, _ in }, storeAPIKey: { storedKey = $0 }
        )
        let llm = SlackConnectionService.LLMConfig(
            provider: .anthropic, model: "claude-opus-4-8", baseURL: "", cliPath: "", apiKey: "  sk-secret  "
        )

        try service.completeOnboarding(llm: llm)

        XCTAssertEqual(storedKey, "sk-secret", "API key is trimmed and sent to the Keychain")
        let provider = try await db.dbWriter.read { try AppSettings.fetchOne($0, key: 1)?.llmProvider }
        XCTAssertEqual(provider, .anthropic)
    }

    func testSetWatchedPersists() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.dbWriter.write { dbc in
            try Channel(id: "C1", workspaceID: "T1", name: "general", isPrivate: false).insert(dbc)
        }
        let service = makeService(transport: StubTransport { _ in (jsonData("{}"), makeHTTPResponse(200)) }, database: db)

        try service.setWatched(true, channelID: "C1")

        let watched = try await db.dbWriter.read { try Channel.fetchOne($0, key: "C1")?.isWatched }
        XCTAssertEqual(watched, true)
    }
}
