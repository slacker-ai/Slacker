import Foundation

/// User-visible state for a workspace's Socket Mode connection.
enum SocketModeConnectionState: Equatable, Sendable {
    case setupRequired
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// A routed Events API delivery from a Socket Mode envelope.
struct SocketModeEvent: Equatable, Sendable {
    let envelopeID: String
    let teamID: String
    let eventID: String?
    let event: SlackSocketEvent
}

/// The subset of Slack event fields needed to choose a targeted reconciliation.
struct SlackSocketEvent: Decodable, Equatable, Sendable {
    let type: String
    let subtype: String?
    let channel: String?
    let ts: String?
    let threadTS: String?
    let deletedTS: String?
    let message: SlackSocketMessage?
    let previousMessage: SlackSocketMessage?
    let item: SlackSocketItem?

    enum CodingKeys: String, CodingKey {
        case type, subtype, channel, ts, message, item
        case threadTS = "thread_ts"
        case deletedTS = "deleted_ts"
        case previousMessage = "previous_message"
    }

    init(
        type: String,
        subtype: String? = nil,
        channel: String? = nil,
        ts: String? = nil,
        threadTS: String? = nil,
        deletedTS: String? = nil,
        message: SlackSocketMessage? = nil,
        previousMessage: SlackSocketMessage? = nil,
        item: SlackSocketItem? = nil
    ) {
        self.type = type
        self.subtype = subtype
        self.channel = channel
        self.ts = ts
        self.threadTS = threadTS
        self.deletedTS = deletedTS
        self.message = message
        self.previousMessage = previousMessage
        self.item = item
    }

    var channelID: String? { channel ?? item?.channel }
}

struct SlackSocketMessage: Decodable, Equatable, Sendable {
    let ts: String?
    let threadTS: String?

    enum CodingKeys: String, CodingKey {
        case ts
        case threadTS = "thread_ts"
    }

    init(ts: String?, threadTS: String? = nil) {
        self.ts = ts
        self.threadTS = threadTS
    }
}

struct SlackSocketItem: Decodable, Equatable, Sendable {
    let type: String?
    let channel: String?
    let ts: String?

    init(type: String? = nil, channel: String? = nil, ts: String? = nil) {
        self.type = type
        self.channel = channel
        self.ts = ts
    }
}

/// Decode only the control fields first so an envelope can still be acknowledged when
/// its payload is malformed or introduces fields this version does not understand.
struct SocketModeEnvelopeHeader: Decodable {
    let envelopeID: String?
    let type: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case type, reason
        case envelopeID = "envelope_id"
    }
}

struct SocketModeEventsEnvelope: Decodable {
    let payload: Payload

    struct Payload: Decodable {
        let teamID: String?
        let eventID: String?
        let event: SlackSocketEvent
        let authorizations: [Authorization]?

        enum CodingKeys: String, CodingKey {
            case event, authorizations
            case teamID = "team_id"
            case eventID = "event_id"
        }

        var routedTeamID: String? {
            teamID ?? authorizations?.compactMap(\.teamID).first
        }
    }

    struct Authorization: Decodable {
        let teamID: String?

        enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
        }
    }
}
