import Foundation
import GRDB

/// A daily per-channel catch-up summary (§4, §8.3). One row per channel per day.
struct Summary: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary"

    /// Composite identity `channelID:date` (date as `yyyy-MM-dd`) — one per channel per day.
    var id: String
    var channelID: String
    var date: String
    var text: String
    var generatedAt: Date

    static func makeID(channelID: String, date: String) -> String { "\(channelID):\(date)" }

    init(channelID: String, date: String, text: String, generatedAt: Date) {
        self.id = Summary.makeID(channelID: channelID, date: date)
        self.channelID = channelID
        self.date = date
        self.text = text
        self.generatedAt = generatedAt
    }
}
