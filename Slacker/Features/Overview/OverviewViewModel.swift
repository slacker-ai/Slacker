import Foundation
import Observation
import GRDB

/// Backs the Overview tab (§8.3): one row per watched channel — today's summary,
/// open-item count, last activity. Channel-scoped only; never per-person (§8.6).
@MainActor
@Observable
final class OverviewViewModel {
    struct ChannelOverview: Identifiable, Equatable {
        let id: String
        let name: String
        let isPrivate: Bool
        let summary: String?
        let openCount: Int
        let lastActivityTS: String?

        func lastActivityText(now: Date = Date()) -> String {
            guard let ts = lastActivityTS, let value = Double(ts) else { return "no activity" }
            let hours = Int((now.timeIntervalSince1970 - value) / 3600)
            if hours < 1 { return "active just now" }
            if hours < 24 { return "active \(hours)h ago" }
            return "active \(hours / 24)d ago"
        }
    }

    private let database: AppDatabase
    private let now: () -> Date
    var channels: [ChannelOverview] = []
    var activeChannels: [ChannelOverview] {
        channels.filter { channel in
            channel.summary?.isEmpty == false || channel.openCount > 0 || channel.lastActivityTS != nil
        }
    }

    init(database: AppDatabase, now: @escaping () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    func reload() async {
        let today = dayString(now())
        channels = (try? await database.dbWriter.read { db in
            let watched = try Channel.filter(Column("isWatched") == true).order(Column("name")).fetchAll(db)
            return try watched.map { channel in
                let summary = try Summary.fetchOne(db, key: Summary.makeID(channelID: channel.id, date: today))
                let openCount = try Item
                    .filter(Column("channelID") == channel.id)
                    .filter([ItemState.surfaced.rawValue, ItemState.review.rawValue].contains(Column("state")))
                    .fetchCount(db)
                let lastTS = try Message
                    .filter(Column("channelID") == channel.id)
                    .select(max(Column("ts")), as: String.self)
                    .fetchOne(db)
                return ChannelOverview(
                    id: channel.id,
                    name: channel.name,
                    isPrivate: channel.isPrivate,
                    summary: summary?.text,
                    openCount: openCount,
                    lastActivityTS: lastTS
                )
            }
        }) ?? []
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
