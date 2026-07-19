import Foundation
import GRDB

/// A persisted Slack message (root or thread reply) — the local mirror (§4, §6).
struct Message: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    /// Composite identity `channelID:ts`, so re-ingesting the same message is idempotent (§3).
    var id: String
    var channelID: String
    /// Parent thread `ts` if this is a reply; nil for a standalone/root message.
    var threadTS: String?
    var userID: String?
    var text: String
    /// Slack message timestamp (string, e.g. "1718200000.001500"); also the in-channel ordering key.
    var ts: String
    /// Raw reactions JSON array (`[{"name":...,"count":...}]`), or nil.
    var reactionsJSON: String?
    /// Local time when this message was first observed. Unlike Slack's server timestamp,
    /// this is directly comparable to an item's local `lastEvaluatedAt` boundary.
    var firstObservedAt: Date?
    /// Local time when a persisted message's text last changed.
    var contentEditedAt: Date?
    /// Local time when an open-loop reaction (eyes/hourglass/etc.) was newly observed.
    var openReactionObservedAt: Date?
    /// Local time when a resolved/done reaction was newly observed on this message.
    var resolvedReactionObservedAt: Date?
    /// Local time when the final resolved/done reaction was removed from this message.
    var resolvedReactionRemovedAt: Date?
    var ingestedAt: Date

    static func makeID(channelID: String, ts: String) -> String { "\(channelID):\(ts)" }

    /// Numeric form of `ts` for time math (Slack ts is `seconds.micros`).
    var timestamp: Double { Double(ts) ?? 0 }

    init(
        channelID: String,
        ts: String,
        threadTS: String?,
        userID: String?,
        text: String,
        reactionsJSON: String?,
        firstObservedAt: Date? = nil,
        contentEditedAt: Date? = nil,
        openReactionObservedAt: Date? = nil,
        resolvedReactionObservedAt: Date? = nil,
        resolvedReactionRemovedAt: Date? = nil,
        ingestedAt: Date
    ) {
        self.id = Message.makeID(channelID: channelID, ts: ts)
        self.channelID = channelID
        self.ts = ts
        self.threadTS = threadTS
        self.userID = userID
        self.text = text
        self.reactionsJSON = reactionsJSON
        self.firstObservedAt = firstObservedAt
        self.contentEditedAt = contentEditedAt
        self.openReactionObservedAt = openReactionObservedAt
        self.resolvedReactionObservedAt = resolvedReactionObservedAt
        self.resolvedReactionRemovedAt = resolvedReactionRemovedAt
        self.ingestedAt = ingestedAt
    }
}
