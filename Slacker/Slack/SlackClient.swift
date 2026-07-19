import Foundation

enum SlackClientError: Error, Equatable {
    /// Slack returned `ok: false` with this error code (e.g. `invalid_auth`, `not_authed`).
    case api(String)
    /// HTTP-level failure (non-2xx that isn't a handled 429).
    case http(Int)
    case nonHTTPResponse
    case decoding
    /// Exhausted retries against rate limiting.
    case rateLimited
}

/// Thin client over the Slack Web API for the calls Slacker needs (§5, §6).
///
/// - Token is passed per-request as a Bearer header; it is never logged.
/// - Honors HTTP 429 `Retry-After` with bounded retries (§3 resilience).
/// - Pagination is handled internally for `conversations.list`.
struct SlackClient: Sendable {
    private let transport: HTTPTransport
    private let baseURL: URL
    private let maxRetries: Int
    /// Injectable sleep so tests don't actually wait on backoff.
    private let sleep: @Sendable (_ seconds: Double) async -> Void

    init(
        transport: HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://slack.com/api")!,
        maxRetries: Int = 3,
        sleep: @escaping @Sendable (_ seconds: Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    // MARK: - Public API

    /// Validate a token and identify the workspace + user (`auth.test`).
    func authTest(token: String) async throws -> AuthTestResponse {
        try await call("auth.test", token: token, queryItems: [])
    }

    /// Exchange an app-level token for Slack's short-lived Socket Mode URL.
    /// The returned URL must be connected immediately and never persisted or logged.
    func openSocketModeConnection(appToken: String) async throws -> URL {
        let response: AppsConnectionsOpenResponse = try await call(
            "apps.connections.open",
            token: appToken,
            queryItems: [],
            httpMethod: "POST"
        )
        guard let value = response.url,
              let url = URL(string: value),
              url.scheme?.lowercased() == "wss",
              let host = url.host?.lowercased(),
              host == "slack.com" || host.hasSuffix(".slack.com") else {
            throw SlackClientError.decoding
        }
        return url
    }

    /// Fetch a single user's profile (`users.info`).
    func usersInfo(token: String, userID: String) async throws -> SlackUser {
        let response: UsersInfoResponse = try await call(
            "users.info",
            token: token,
            queryItems: [URLQueryItem(name: "user", value: userID)]
        )
        guard let user = response.user else { throw SlackClientError.decoding }
        return user
    }

    /// List the channels the user is a member of, following cursor pagination.
    /// `includePrivate` adds `private_channel` (only for the default manifest variant).
    func listConversations(token: String, includePrivate: Bool) async throws -> [SlackConversation] {
        var types = ["public_channel"]
        if includePrivate { types.append("private_channel") }

        var all: [SlackConversation] = []
        var cursor: String?

        repeat {
            var items = [
                URLQueryItem(name: "types", value: types.joined(separator: ",")),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor, !cursor.isEmpty {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }

            let page: ConversationsListResponse = try await call(
                "conversations.list", token: token, queryItems: items
            )
            all.append(contentsOf: page.channels ?? [])
            cursor = page.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false

        // Only channels the user is actually in (user-token scoping; §6c).
        return all.filter { $0.isMember ?? false }
    }

    /// Fetch top-level messages newer than `oldest` (exclusive), following pagination (§6.2).
    /// Returns messages oldest-first.
    func conversationsHistory(
        token: String,
        channelID: String,
        oldest: String?
    ) async throws -> [SlackMessage] {
        var all: [SlackMessage] = []
        var cursor: String?

        repeat {
            var items = [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let oldest, !oldest.isEmpty {
                items.append(URLQueryItem(name: "oldest", value: oldest))
                // `oldest` is inclusive by default; exclude the boundary message we already have.
                items.append(URLQueryItem(name: "inclusive", value: "false"))
            }
            if let cursor, !cursor.isEmpty {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }

            let page: ConversationsHistoryResponse = try await call(
                "conversations.history", token: token, queryItems: items
            )
            all.append(contentsOf: page.messages ?? [])
            cursor = page.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false

        // Slack returns newest-first; normalize to oldest-first for stable persistence.
        return all.sorted { ($0.ts) < ($1.ts) }
    }

    /// Fetch a full thread (root + all replies), following pagination (§6.2).
    func conversationsReplies(
        token: String,
        channelID: String,
        threadTS: String
    ) async throws -> [SlackMessage] {
        var all: [SlackMessage] = []
        var cursor: String?

        repeat {
            var items = [
                URLQueryItem(name: "channel", value: channelID),
                URLQueryItem(name: "ts", value: threadTS),
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor, !cursor.isEmpty {
                items.append(URLQueryItem(name: "cursor", value: cursor))
            }

            let page: ConversationsRepliesResponse = try await call(
                "conversations.replies", token: token, queryItems: items
            )
            all.append(contentsOf: page.messages ?? [])
            cursor = page.responseMetadata?.nextCursor
        } while cursor?.isEmpty == false

        return all.sorted { ($0.ts) < ($1.ts) }
    }

    // MARK: - Request plumbing

    private func call<T: SlackAPIResponse>(
        _ method: String,
        token: String,
        queryItems: [URLQueryItem],
        httpMethod: String = "GET"
    ) async throws -> T {
        let request = makeRequest(
            method: method,
            token: token,
            queryItems: queryItems,
            httpMethod: httpMethod
        )

        var attempt = 0
        while true {
            let (data, http) = try await transport.send(request)

            if http.statusCode == 429 {
                guard attempt < maxRetries else { throw SlackClientError.rateLimited }
                let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                await sleep(retryAfter)
                attempt += 1
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                throw SlackClientError.http(http.statusCode)
            }

            let decoded: T
            do {
                decoded = try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw SlackClientError.decoding
            }

            guard decoded.ok else {
                throw SlackClientError.api(decoded.error ?? "unknown_error")
            }
            return decoded
        }
    }

    private func makeRequest(
        method: String,
        token: String,
        queryItems: [URLQueryItem],
        httpMethod: String
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(method),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = httpMethod
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
