import Foundation
import GRDB

/// Generates the daily per-channel catch-up summary (§8.3). Creates the first summary
/// for a channel/day, then regenerates only when new activity arrives after the configured
/// summary interval. Ambient context only — never the headline (the attention list leads).
struct SummaryService {
    let database: AppDatabase
    let llm: LLMClient?
    var now: () -> Date = { Date() }
    var calendar: Calendar = .current
    var minimumRefreshIntervalSeconds: () -> TimeInterval = { 6 * 60 * 60 }

    private let system = """
    Summarize this Slack channel's day for a manager catching up. 2-3 sentences, plain \
    text, no preamble. Focus on decisions made, open questions, and notable activity. \
    Do not single out individuals' performance.
    """

    /// Generate or refresh today's summary for each watched channel when the interval allows.
    func generateDailySummaries() async throws {
        guard let llm else {
            Log.info("Summary skipped: no LLM configured (set a provider + key in Settings).")
            return
        }

        let channels = try await database.dbWriter.read { db in
            try Channel.filter(Column("isWatched") == true).fetchAll(db)
        }
        let today = dayString(now())
        let startOfDay = calendar.startOfDay(for: now()).timeIntervalSince1970

        for channel in channels {
            let summaryID = Summary.makeID(channelID: channel.id, date: today)
            let existing = try await database.dbWriter.read { db in
                try Summary.fetchOne(db, key: summaryID)
            }

            let todaysMessages = try await messagesToday(channelID: channel.id, startOfDay: startOfDay)
            guard !todaysMessages.isEmpty else { continue }

            // Regenerate only when there's new activity since the last summary — first
            // time there's no summary; afterwards refresh when newer messages arrived
            // and the configured summary interval has elapsed.
            if let existing,
               let newest = todaysMessages.last?.timestamp,
               newest <= existing.generatedAt.timeIntervalSince1970 {
                continue
            }
            if let existing,
               now().timeIntervalSince(existing.generatedAt) < minimumRefreshIntervalSeconds() {
                continue
            }

            let transcript: String = todaysMessages
                .compactMap { message in
                    let text = SlackTextSanitizer.stripFencedBlocks(message.text)
                    guard !text.isEmpty else { return nil }
                    return "[\(message.userID ?? "unknown")] \(text)"
                }
                .joined(separator: "\n")
            guard !transcript.isEmpty else { continue }

            // A summary failure must not break the cycle — skip and try next time.
            Log.info("LLM summary used[#\(channel.name) date=\(today)]: \(todaysMessages.count) message(s).")
            let text: String
            do {
                text = try await llm.complete(LLMRequest(system: system, user: transcript))
            } catch {
                Log.info("LLM summary[#\(channel.name) date=\(today)]: call failed (\(error)); will retry next cycle.")
                continue
            }

            let summary = Summary(channelID: channel.id, date: today, text: text, generatedAt: now())
            try await database.dbWriter.write { db in
                try summary.save(db)
            }
            Log.info("LLM summary[#\(channel.name) date=\(today)]: saved.")
        }
    }

    private func messagesToday(channelID: String, startOfDay: Double) async throws -> [Message] {
        try await database.dbWriter.read { db in
            try Message
                .filter(Column("channelID") == channelID)
                .order(Column("ts"))
                .fetchAll(db)
                .filter { $0.timestamp >= startOfDay }
        }
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
