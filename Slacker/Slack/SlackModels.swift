import Foundation

/// Codable models for the Slack Web API responses we consume (§5, §6).
/// Only the fields Slacker actually uses are modeled; Slack returns many more.

/// Common envelope: every Slack Web API response has `ok` and, on failure, `error`.
protocol SlackAPIResponse: Decodable {
    var ok: Bool { get }
    var error: String? { get }
}

/// `auth.test` — validates a token and identifies the workspace + user.
struct AuthTestResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let url: String?
    let team: String?
    let user: String?
    let teamId: String?
    let userId: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, url, team, user
        case teamId = "team_id"
        case userId = "user_id"
    }
}

/// A Slack conversation (channel) as returned by `conversations.list`.
struct SlackConversation: Decodable, Equatable {
    let id: String
    let name: String?
    let isPrivate: Bool?
    let isMember: Bool?
    let isArchived: Bool?
    let isChannel: Bool?
    let isGroup: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrivate = "is_private"
        case isMember = "is_member"
        case isArchived = "is_archived"
        case isChannel = "is_channel"
        case isGroup = "is_group"
    }
}

/// Cursor-based pagination metadata.
struct SlackResponseMetadata: Decodable {
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }
}

struct ConversationsListResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let channels: [SlackConversation]?
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok, error, channels
        case responseMetadata = "response_metadata"
    }
}

/// A Slack user as returned by `users.info`.
struct SlackUser: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let realName: String?
    let profile: Profile?

    struct Profile: Decodable, Equatable, Sendable {
        let displayName: String?
        let realName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case realName = "real_name"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, profile
        case realName = "real_name"
    }

    /// Best available human-facing name for grounding (§7).
    var bestDisplayName: String {
        if let d = profile?.displayName, !d.isEmpty { return d }
        if let r = realName, !r.isEmpty { return r }
        if let p = profile?.realName, !p.isEmpty { return p }
        return name ?? id
    }
}

struct UsersInfoResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let user: SlackUser?
}

/// A reaction on a message (`conversations.history` / `.replies`).
struct SlackReaction: Codable, Equatable, Sendable {
    let name: String
    let count: Int
}

/// A message from `conversations.history` or `conversations.replies`.
struct SlackMessage: Decodable, Equatable, Sendable {
    let ts: String
    let user: String?
    let text: String?
    let threadTS: String?
    let replyCount: Int?
    let latestReply: String?
    let subtype: String?
    let reactions: [SlackReaction]?

    enum CodingKeys: String, CodingKey {
        case ts, user, text, subtype, reactions
        case threadTS = "thread_ts"
        case replyCount = "reply_count"
        case latestReply = "latest_reply"
    }

    /// True when this message heads a thread with replies and needs a `replies` fetch (§6.2).
    var hasReplies: Bool { (replyCount ?? 0) > 0 }

    var isMembershipNotification: Bool {
        SlackSystemMessageFilter.isMembershipNotification(subtype: subtype, text: text)
    }
}

/// Membership changes are Slack-generated channel history, not user-authored work. Keep
/// them out of the local mirror so their rendered `<@user>` text cannot become a mention.
enum SlackSystemMessageFilter {
    private static let membershipSubtypes: Set<String> = [
        "channel_join", "channel_leave", "group_join", "group_leave",
    ]
    private static let membershipTextFragments = [
        " has joined the channel", " has left the channel",
        " has joined the group", " has left the group",
    ]

    static func isMembershipNotification(subtype: String?, text: String?) -> Bool {
        if let subtype, membershipSubtypes.contains(subtype) { return true }

        // Older local rows predate subtype persistence. Slack renders these notices with
        // a leading user mention, so this fallback cleans them without matching ordinary
        // human sentences that merely discuss someone joining or leaving.
        guard let text else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("<@")
            && membershipTextFragments.contains(where: normalized.hasSuffix)
    }
}

struct ConversationsHistoryResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let messages: [SlackMessage]?
    let hasMore: Bool?
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok, error, messages
        case hasMore = "has_more"
        case responseMetadata = "response_metadata"
    }
}

struct ConversationsRepliesResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let messages: [SlackMessage]?
    let responseMetadata: SlackResponseMetadata?

    enum CodingKeys: String, CodingKey {
        case ok, error, messages
        case responseMetadata = "response_metadata"
    }
}

/// `apps.connections.open` — returns a short-lived WebSocket URL for Socket Mode.
/// The URL is intentionally kept in memory only and must never be logged.
struct AppsConnectionsOpenResponse: SlackAPIResponse {
    let ok: Bool
    let error: String?
    let url: String?
}
