import Foundation
import Observation
import GRDB

/// Backs the main UI (§8.2–§8.4): loads surfaced + review items as display rows,
/// stays live via GRDB observation, and applies triage actions that also feed the
/// calibration flywheel (§7.5).
@MainActor
@Observable
final class MainViewModel {
    private let database: AppDatabase
    private let calibration: CalibrationService
    private let now: () -> Date

    var teamID: String = ""
    var missedFollowups: [ItemRow] = []
    var staleItems: [ItemRow] = []
    var mentions: [ItemRow] = []
    var reviewItems: [ItemRow] = []

    var surfacedCount: Int { missedFollowups.count + staleItems.count + mentions.count }

    @ObservationIgnored private var observationTask: Task<Void, Never>?
    /// Triggers an immediate poll+detect cycle (wired by `AppRoot`).
    @ObservationIgnored var onRefresh: (() async -> Void)?
    /// Per-triage learning hook (§7.5): each triage verdict proposes a phrase/guidance
    /// change for human approval. Wired by `AppRoot`; runs in the background so triage
    /// stays instant.
    @ObservationIgnored var onTriageLabeled: ((_ channelID: String, _ messageTS: String, _ verdict: UserVerdict, _ source: LabelSource) async -> Void)?
    var isRefreshing = false

    init(database: AppDatabase, now: @escaping () -> Date = { Date() }) {
        self.database = database
        self.calibration = CalibrationService(database: database)
        self.now = now
        self.teamID = (try? database.dbWriter.read { try AppSettings.fetchOne($0, key: 1)?.teamID }) ?? "" ?? ""
    }

    /// Begin observing item changes; reloads rows whenever the poller writes.
    func start() {
        guard observationTask == nil else { return }
        let reader = database.dbWriter
        observationTask = Task { [weak self] in
            await self?.reload()
            // Cheap trigger: any change to the item table → reload the display rows.
            let observation = ValueObservation.tracking { db in try Item.fetchCount(db) }
            do {
                for try await _ in observation.values(in: reader) {
                    await self?.reload()
                }
            } catch {
                // Observation ended; nothing to surface.
            }
        }
    }

    /// Run an immediate poll cycle now (the "Refresh" button).
    func refreshNow() async {
        guard let onRefresh, !isRefreshing else { return }
        isRefreshing = true
        await onRefresh()
        isRefreshing = false
    }

    func reload() async {
        let surfaced = await fetchRows(states: [.surfaced])
        missedFollowups = surfaced.filter { $0.type == .missedFollowup }
        staleItems = surfaced.filter { $0.type == .stale }
        mentions = surfaced.filter { $0.type == .mention }
        reviewItems = await fetchRows(states: [.review])
    }

    // MARK: - Triage actions

    func resolve(_ row: ItemRow) async {
        await apply(row, newState: .resolved, verdict: .matters, source: .markResolved)
    }

    func dismiss(_ row: ItemRow) async {
        await apply(row, newState: .dismissed, verdict: .ignore, source: .dismissal)
    }

    /// Review queue: "This matters" → promote to surfaced.
    func promote(_ row: ItemRow) async {
        await apply(row, newState: .surfaced, verdict: .matters, source: .reviewTriage)
    }

    /// Review queue: "Ignore" → dismiss.
    func ignore(_ row: ItemRow) async {
        await apply(row, newState: .dismissed, verdict: .ignore, source: .reviewTriage)
    }

    // MARK: - Internals

    private func apply(_ row: ItemRow, newState: ItemState, verdict: UserVerdict, source: LabelSource) async {
        let timestamp = now()
        await update(row) { item in
            item.state = newState
            item.lastEvaluatedAt = timestamp
        }
        try? await calibration.record(
            verdict: verdict, source: source,
            channelID: row.channelID, messageTS: row.item.rootMessageTS, itemID: row.item.id
        )
        // Learn from this triage immediately (§7.5). Fire-and-forget so the click stays
        // instant; the proposal lands as `proposed` for approval in Settings.
        if let onTriageLabeled {
            let channelID = row.channelID
            let messageTS = row.item.rootMessageTS
            Task { await onTriageLabeled(channelID, messageTS, verdict, source) }
        }
        await reload()
    }

    private func update(_ row: ItemRow, _ mutate: @escaping (inout Item) -> Void) async {
        try? await database.dbWriter.write { db in
            guard var item = try Item.fetchOne(db, key: row.item.id) else { return }
            mutate(&item)
            try item.update(db)
        }
        await reload()
    }

    private func fetchRows(states: [ItemState]) async -> [ItemRow] {
        let rows = (try? await database.dbWriter.read { db -> [ItemRow] in
            let items = try Item
                .filter(states.map(\.rawValue).contains(Column("state")))
                .order(Column("confidence").desc)
                .fetchAll(db)

            return try items.map { item in
                let root = try Message.fetchOne(db, key: Message.makeID(channelID: item.channelID, ts: item.rootMessageTS))
                let channel = try Channel.fetchOne(db, key: item.channelID)
                let author = try root?.userID.flatMap { try CachedUser.fetchOne(db, key: $0) }
                let responseCount = try Message
                    .filter(Column("channelID") == item.channelID && Column("threadTS") == item.rootMessageTS)
                    .filter(Column("ts") != item.rootMessageTS)
                    .fetchCount(db)
                return ItemRow(
                    item: item,
                    channelName: channel?.name ?? item.channelID,
                    channelID: item.channelID,
                    teamID: channel?.workspaceID ?? "",
                    snippet: root?.text ?? "",
                    authorName: author?.displayName ?? author?.realName,
                    responseCount: responseCount,
                    threadSummary: item.threadSummary
                )
            }
        }) ?? []
        return rows
    }
}
