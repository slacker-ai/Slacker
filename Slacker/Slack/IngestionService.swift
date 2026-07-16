import Foundation
import GRDB

protocol SlackIngestionServing: Sendable {
    func reconcileAllWorkspaces() async throws -> [String: Set<String>]
    func reconcileWorkspace(workspaceID: String) async throws -> [String: Set<String>]
    @discardableResult
    func reconcileChannel(workspaceID: String, channelID: String) async throws -> Set<String>
    func refreshThread(workspaceID: String, channelID: String, threadTS: String) async throws
    @discardableResult
    func refreshThreadContainingMessage(
        workspaceID: String,
        channelID: String,
        messageTS: String
    ) async throws -> String?
    func recoverTrackedItemThreads(workspaceID: String?) async throws -> [[String: Set<String>]]
    func removeLocalMessage(channelID: String, messageTS: String) async throws -> String?
}

/// Pulls messages + threads for watched channels into the local mirror (§6).
/// It has no timer: the sync coordinator invokes targeted reconciliation for lifecycle
/// boundaries and Socket Mode events.
struct IngestionService: SlackIngestionServing, @unchecked Sendable {
    /// First sync for a newly watched channel starts at local midnight. After that,
    /// `Channel.lastPolledTS` drives exact incremental backfill across restarts.
    /// Keep enough parallel HTTP work to hide network latency without hammering Slack's
    /// per-method rate limits.
    private static let maxConcurrentSlackRequests = 3
    /// Recovery deliberately yields small units of changed roots so downstream work stays
    /// bounded even when a user returns after a long offline period.
    private static let trackedThreadBatchSize = 12

    let client: SlackClient
    let database: AppDatabase
    private let requestLimiter: SlackRequestLimiter
    /// Injectable clock so `ingestedAt` is deterministic in tests.
    var now: () -> Date
    /// Resolves a workspace's Slack token (Keychain by default; injected in tests).
    var tokenProvider: (_ workspaceID: String) -> String?

    init(
        client: SlackClient,
        database: AppDatabase,
        now: @escaping () -> Date = { Date() },
        tokenProvider: @escaping (_ workspaceID: String) -> String? = {
            (try? KeychainStore.getToken(workspaceID: $0)) ?? nil
        }
    ) {
        self.client = client
        self.database = database
        self.requestLimiter = SlackRequestLimiter(limit: Self.maxConcurrentSlackRequests)
        self.now = now
        self.tokenProvider = tokenProvider
    }

    /// Reconcile every connected workspace once, each with its own user token.
    func reconcileAllWorkspaces() async throws -> [String: Set<String>] {
        let workspaces = try await database.dbWriter.read { db in
            try Workspace.fetchAll(db)
        }
        guard !workspaces.isEmpty else {
            Log.info("Ingestion: no workspaces connected.")
            return [:]
        }
        var rootsByChannel: [String: Set<String>] = [:]
        for workspace in workspaces {
            guard let token = tokenProvider(workspace.id), !token.isEmpty else {
                Log.error("Ingestion[\(workspace.name)]: no token available; skipping.")
                continue
            }
            merge(
                try await pollWorkspace(workspaceID: workspace.id, token: token),
                into: &rootsByChannel
            )
        }
        return rootsByChannel
    }

    func reconcileWorkspace(workspaceID: String) async throws -> [String: Set<String>] {
        guard let token = tokenProvider(workspaceID), !token.isEmpty else {
            Log.error("Ingestion[\(workspaceID)]: no user token available; skipping.")
            return [:]
        }
        return try await pollWorkspace(workspaceID: workspaceID, token: token)
    }

    @discardableResult
    func reconcileChannel(workspaceID: String, channelID: String) async throws -> Set<String> {
        guard let token = tokenProvider(workspaceID), !token.isEmpty else { return [] }
        guard let channel = try await watchedChannel(channelID, workspaceID: workspaceID) else { return [] }
        return try await pollChannel(channel, token: token)
    }

    func refreshThread(
        workspaceID: String,
        channelID: String,
        threadTS: String
    ) async throws {
        guard let token = tokenProvider(workspaceID), !token.isEmpty else { return }
        guard try await watchedChannel(channelID, workspaceID: workspaceID) != nil else { return }
        _ = try await fetchAndPersistThread(channelID: channelID, threadTS: threadTS, token: token)
    }

    @discardableResult
    func refreshThreadContainingMessage(
        workspaceID: String,
        channelID: String,
        messageTS: String
    ) async throws -> String? {
        let rootTS = try await database.dbWriter.read { db in
            try Message.fetchOne(db, key: Message.makeID(channelID: channelID, ts: messageTS))
                .map { $0.threadTS ?? $0.ts }
        }
        if let rootTS {
            try await refreshThread(
                workspaceID: workspaceID,
                channelID: channelID,
                threadTS: rootTS
            )
            return rootTS
        } else {
            // A reaction can race the initial message delivery. Reconcile the channel so
            // the message exists before a later retry/event targets its thread.
            _ = try await reconcileChannel(workspaceID: workspaceID, channelID: channelID)
            return try await database.dbWriter.read { db in
                try Message.fetchOne(db, key: Message.makeID(channelID: channelID, ts: messageTS))
                    .map { $0.threadTS ?? $0.ts }
            }
        }
    }

    /// Remove a deleted Slack message from the local mirror. Deleting a root also drops
    /// its replies and item; deleting a reply returns its root for a targeted refresh.
    func removeLocalMessage(channelID: String, messageTS: String) async throws -> String? {
        try await database.dbWriter.write { db in
            guard let message = try Message.fetchOne(
                db,
                key: Message.makeID(channelID: channelID, ts: messageTS)
            ) else { return nil }

            let rootTS = message.threadTS ?? message.ts
            if rootTS == messageTS {
                try Message
                    .filter(Column("channelID") == channelID)
                    .filter(Column("ts") == messageTS || Column("threadTS") == messageTS)
                    .deleteAll(db)
                try Item
                    .filter(Column("channelID") == channelID && Column("rootMessageTS") == messageTS)
                    .deleteAll(db)
                return nil
            }

            _ = try Message.deleteOne(db, key: message.id)
            return rootTS
        }
    }

    /// Poll one workspace's watched channels from their durable cursors. Tracked threads
    /// are recovered separately in background batches at lifecycle boundaries.
    @discardableResult
    func pollWorkspace(workspaceID: String, token: String) async throws -> [String: Set<String>] {
        let channels = try await database.dbWriter.read { db in
            try Channel
                .filter(Column("workspaceID") == workspaceID && Column("isWatched") == true)
                .fetchAll(db)
        }
        Log.info("Ingestion[\(workspaceID)]: \(channels.count) watched channel(s): \(channels.map(\.name).joined(separator: ", "))")
        let channelResults = try await concurrentMap(
            channels,
            limit: Self.maxConcurrentSlackRequests
        ) { channel in
            (channel.id, try await pollChannel(channel, token: token))
        }
        return Dictionary(uniqueKeysWithValues: channelResults.filter { !$0.1.isEmpty })
    }

    /// At launch, wake, and reconnect, compare full snapshots for tracked item threads.
    /// Only changed roots are returned, grouped into small batches for targeted analysis.
    func recoverTrackedItemThreads(workspaceID: String?) async throws -> [[String: Set<String>]] {
        let workspaces = try await database.dbWriter.read { db -> [Workspace] in
            if let workspaceID {
                return try Workspace.filter(key: workspaceID).fetchAll(db)
            }
            return try Workspace.fetchAll(db)
        }
        var changedBatches: [[String: Set<String>]] = []

        for workspace in workspaces {
            guard let token = tokenProvider(workspace.id), !token.isEmpty else { continue }
            let targets = try await trackedThreadTargets(workspaceID: workspace.id)
            guard !targets.isEmpty else { continue }
            let batchCount = Int(ceil(Double(targets.count) / Double(Self.trackedThreadBatchSize)))
            Log.info("Gap recovery[\(workspace.name)]: checking \(targets.count) tracked thread(s) in \(batchCount) batch(es).")

            for offset in stride(from: 0, to: targets.count, by: Self.trackedThreadBatchSize) {
                let end = min(offset + Self.trackedThreadBatchSize, targets.count)
                let batch = Array(targets[offset..<end])
                let results = try await concurrentMap(
                    batch,
                    limit: Self.maxConcurrentSlackRequests
                ) { target -> (String, String, Bool) in
                    do {
                        let changed = try await fetchAndPersistThread(
                            channelID: target.channelID,
                            threadTS: target.rootTS,
                            token: token
                        )
                        return (target.channelID, target.rootTS, changed)
                    } catch {
                        let message = SecretRedaction.redact(String(describing: error))
                        Log.error("Gap recovery thread failed: \(message)")
                        return (target.channelID, target.rootTS, false)
                    }
                }

                var changedRoots: [String: Set<String>] = [:]
                for (channelID, rootTS, changed) in results where changed {
                    changedRoots[channelID, default: []].insert(rootTS)
                }
                if !changedRoots.isEmpty { changedBatches.append(changedRoots) }
            }
        }
        return changedBatches
    }

    private struct TrackedThreadTarget: Hashable, Sendable {
        let channelID: String
        let rootTS: String
    }

    private func trackedThreadTargets(workspaceID: String) async throws -> [TrackedThreadTarget] {
        try await database.dbWriter.read { db in
            let channelIDs = try Channel
                .filter(Column("workspaceID") == workspaceID && Column("isWatched") == true)
                .fetchAll(db)
                .map(\.id)
            guard !channelIDs.isEmpty else { return [] }
            let states = [
                ItemState.open, .surfaced, .review, .resolved, .dismissed
            ].map(\.rawValue)
            let items = try Item
                .filter(states.contains(Column("state")))
                .filter(channelIDs.contains(Column("channelID")))
                .fetchAll(db)
            return Array(Set(items.map {
                TrackedThreadTarget(channelID: $0.channelID, rootTS: $0.rootMessageTS)
            })).sorted {
                ($0.channelID, Double($0.rootTS) ?? 0) < ($1.channelID, Double($1.rootTS) ?? 0)
            }
        }
    }

    private func dropItemsForMissingThread(channelID: String, rootTS: String) async throws -> Bool {
        try await database.dbWriter.write { db in
            let removedMessages = try Message
                .filter(Column("channelID") == channelID)
                .filter(Column("ts") == rootTS || Column("threadTS") == rootTS)
                .deleteAll(db)
            let removedItems = try Item
                .filter(Column("channelID") == channelID && Column("rootMessageTS") == rootTS)
                .deleteAll(db)
            return removedMessages > 0 || removedItems > 0
        }
    }

    /// Fetch new top-level messages since `lastPolledTS`, pull their threads, resolve
    /// users, persist idempotently, and advance the channel's reconciliation boundary.
    @discardableResult
    func pollChannel(_ channel: Channel, token: String) async throws -> Set<String> {
        let oldest = channel.lastPolledTS ?? initialHistoryOldestTS()
        let history = try await requestLimiter.run {
            try await client.conversationsHistory(
                token: token,
                channelID: channel.id,
                oldest: oldest
            )
        }

        // Collect thread replies for any root that has them (§6.2).
        var allMessages = history
        for message in history where message.hasReplies {
            let replies = try await requestLimiter.run {
                try await client.conversationsReplies(
                    token: token,
                    channelID: channel.id,
                    threadTS: message.ts
                )
            }
            allMessages.append(contentsOf: replies)
        }

        guard !allMessages.isEmpty else {
            Log.info("Ingestion[#\(channel.name)]: no new messages since \(oldest).")
            return []
        }
        Log.info("Ingestion[#\(channel.name)]: \(history.count) new top-level, \(allMessages.count) total (incl. replies).")

        let ignoredMembershipMessages = allMessages.filter(\.isMembershipNotification)
        let persistableMessages = allMessages.filter { !$0.isMembershipNotification }
        if !ignoredMembershipMessages.isEmpty {
            Log.info("Ingestion[#\(channel.name)]: ignored \(ignoredMembershipMessages.count) Slack membership notification(s).")
        }
        try await resolveUnknownUsers(in: persistableMessages, token: token)

        // Newest top-level ts becomes the next HTTP reconciliation boundary.
        let newestRootTS = history.map(\.ts).max()
        let records = try await records(from: persistableMessages, channelID: channel.id)
        let changedRoots = try await persistSnapshot(
            records: records,
            ignoredMembershipMessages: ignoredMembershipMessages,
            channelID: channel.id,
            rootTSs: Set(history.map(\.ts))
        )

        if let newestRootTS {
            _ = try await database.dbWriter.write { db in
                try Channel
                    .filter(key: channel.id)
                    .updateAll(db, Column("lastPolledTS").set(to: newestRootTS))
            }
        }
        return changedRoots
    }

    // MARK: - Helpers

    private func watchedChannel(_ channelID: String, workspaceID: String) async throws -> Channel? {
        try await database.dbWriter.read { db in
            try Channel
                .filter(key: channelID)
                .filter(Column("workspaceID") == workspaceID && Column("isWatched") == true)
                .fetchOne(db)
        }
    }

    private func fetchAndPersistThread(
        channelID: String,
        threadTS: String,
        token: String
    ) async throws -> Bool {
        let thread: [SlackMessage]
        do {
            thread = try await requestLimiter.run {
                try await client.conversationsReplies(
                    token: token,
                    channelID: channelID,
                    threadTS: threadTS
                )
            }
        } catch SlackClientError.api("thread_not_found") {
            Log.info("Ingestion: tracked thread no longer exists; removing its local mirror.")
            return try await dropItemsForMissingThread(channelID: channelID, rootTS: threadTS)
        }
        guard !thread.isEmpty else { return false }

        let ignoredMembershipMessages = thread.filter(\.isMembershipNotification)
        let persistableMessages = thread.filter { !$0.isMembershipNotification }
        try await resolveUnknownUsers(in: persistableMessages, token: token)
        let records = try await records(from: persistableMessages, channelID: channelID)
        return try await persistSnapshot(
            records: records,
            ignoredMembershipMessages: ignoredMembershipMessages,
            channelID: channelID,
            rootTSs: [threadTS]
        ).contains(threadTS)
    }

    /// Replace only the supplied thread snapshots and report roots whose stable Slack
    /// content changed. Local bookkeeping timestamps do not create false positives.
    private func persistSnapshot(
        records: [Message],
        ignoredMembershipMessages: [SlackMessage],
        channelID: String,
        rootTSs: Set<String>
    ) async throws -> Set<String> {
        guard !rootTSs.isEmpty else { return [] }
        let existing = try await database.dbWriter.read { db in
            try Message
                .filter(Column("channelID") == channelID)
                .filter(rootTSs.contains(Column("ts")) || rootTSs.contains(Column("threadTS")))
                .fetchAll(db)
        }
        let incomingIDs = Set(records.map(\.id))
        let existingByRoot = Dictionary(grouping: existing, by: messageRootTS)
        let incomingByRoot = Dictionary(grouping: records, by: messageRootTS)
        var changedRoots = Set<String>()

        for rootTS in rootTSs {
            let oldByID = Dictionary(uniqueKeysWithValues:
                (existingByRoot[rootTS] ?? []).map { ($0.id, $0) }
            )
            let newByID = Dictionary(uniqueKeysWithValues:
                (incomingByRoot[rootTS] ?? []).map { ($0.id, $0) }
            )
            if oldByID.keys != newByID.keys
                || newByID.contains(where: { id, message in
                    guard let old = oldByID[id] else { return true }
                    return !sameSlackContent(old, message)
                }) {
                changedRoots.insert(rootTS)
            }
        }

        try await database.dbWriter.write { db in
            _ = try Message
                .filter(Column("channelID") == channelID)
                .filter(rootTSs.contains(Column("ts")) || rootTSs.contains(Column("threadTS")))
                .filter(!incomingIDs.contains(Column("id")))
                .deleteAll(db)
            try removeMembershipNotifications(
                ignoredMembershipMessages,
                channelID: channelID,
                db: db
            )
            for record in records { try record.save(db) }
        }
        return changedRoots
    }

    private func messageRootTS(_ message: Message) -> String {
        message.threadTS ?? message.ts
    }

    private func sameSlackContent(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.channelID == rhs.channelID
            && lhs.ts == rhs.ts
            && lhs.threadTS == rhs.threadTS
            && lhs.userID == rhs.userID
            && lhs.text == rhs.text
            && lhs.reactionsJSON == rhs.reactionsJSON
    }

    private func initialHistoryOldestTS() -> String {
        let oldest = Calendar.autoupdatingCurrent.startOfDay(for: now())
        return String(format: "%.6f", oldest.timeIntervalSince1970)
    }

    private func records(from messages: [SlackMessage], channelID: String) async throws -> [Message] {
        var recordsByID: [String: Message] = [:]
        for message in messages {
            let record = record(from: message, channelID: channelID)
            recordsByID[record.id] = record
        }
        var records = recordsByID.values.sorted { $0.ts < $1.ts }
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
            records[index].firstObservedAt = existing?.firstObservedAt
                ?? records[index].firstObservedAt
            records[index].ingestedAt = existing?.ingestedAt
                ?? records[index].ingestedAt
            records[index].contentEditedAt = contentEditedAt(
                existing: existing,
                incoming: records[index]
            )
            records[index].openReactionObservedAt = openReactionObservedAt(
                existing: existing,
                incoming: records[index]
            )
            records[index].resolvedReactionObservedAt = resolvedReactionObservedAt(
                existing: existing,
                incoming: records[index]
            )
            records[index].resolvedReactionRemovedAt = resolvedReactionRemovedAt(
                existing: existing,
                incoming: records[index]
            )
        }
        return records
    }

    private func record(from message: SlackMessage, channelID: String) -> Message {
        let observedAt = now()
        var reactionsJSON: String?
        if let reactions = message.reactions, !reactions.isEmpty,
           let data = try? JSONEncoder().encode(reactions) {
            reactionsJSON = String(data: data, encoding: .utf8)
        }
        return Message(
            channelID: channelID,
            ts: message.ts,
            threadTS: message.threadTS == message.ts ? nil : message.threadTS,
            userID: message.user,
            text: message.text ?? "",
            reactionsJSON: reactionsJSON,
            firstObservedAt: observedAt,
            ingestedAt: observedAt
        )
    }

    /// Remove membership notices written by older builds, including the false item and
    /// calibration label they may have produced before subtype filtering existed.
    private func removeMembershipNotifications(
        _ messages: [SlackMessage],
        channelID: String,
        db: Database
    ) throws {
        guard !messages.isEmpty else { return }
        let messageTSs = Set(messages.map(\.ts))
        let rootTSs = Set(messages.compactMap { message -> String? in
            guard message.threadTS == nil || message.threadTS == message.ts else { return nil }
            return message.ts
        })

        var messageRequest = Message
            .filter(Column("channelID") == channelID)
            .filter(messageTSs.contains(Column("ts")))
        if !rootTSs.isEmpty {
            messageRequest = Message
                .filter(Column("channelID") == channelID)
                .filter(messageTSs.contains(Column("ts")) || rootTSs.contains(Column("threadTS")))
            _ = try Item
                .filter(Column("channelID") == channelID)
                .filter(rootTSs.contains(Column("rootMessageTS")))
                .deleteAll(db)
            _ = try TriageLabel
                .filter(Column("channelID") == channelID)
                .filter(rootTSs.contains(Column("messageTS")))
                .deleteAll(db)
        }
        _ = try messageRequest.deleteAll(db)
    }

    private func contentEditedAt(existing: Message?, incoming: Message) -> Date? {
        guard let existing else { return nil }
        return existing.text == incoming.text ? existing.contentEditedAt : now()
    }

    private func openReactionObservedAt(existing: Message?, incoming: Message) -> Date? {
        let oldOpenCount = reactionCount(
            existing?.reactionsJSON,
            names: EmojiSignalDetector.openReactionNames
        )
        let newOpenCount = reactionCount(
            incoming.reactionsJSON,
            names: EmojiSignalDetector.openReactionNames
        )
        if newOpenCount > oldOpenCount {
            return now()
        }
        return existing?.openReactionObservedAt
    }

    private func resolvedReactionObservedAt(existing: Message?, incoming: Message) -> Date? {
        let oldResolvedCount = reactionCount(
            existing?.reactionsJSON,
            names: EmojiSignalDetector.resolvedReactionNames
        )
        let newResolvedCount = reactionCount(
            incoming.reactionsJSON,
            names: EmojiSignalDetector.resolvedReactionNames
        )
        if newResolvedCount > oldResolvedCount {
            return now()
        }
        return existing?.resolvedReactionObservedAt
    }

    private func resolvedReactionRemovedAt(existing: Message?, incoming: Message) -> Date? {
        guard let existing else { return nil }
        let oldResolvedCount = reactionCount(
            existing.reactionsJSON,
            names: EmojiSignalDetector.resolvedReactionNames
        )
        let newResolvedCount = reactionCount(
            incoming.reactionsJSON,
            names: EmojiSignalDetector.resolvedReactionNames
        )
        if oldResolvedCount > 0, newResolvedCount == 0 {
            return now()
        }
        return existing.resolvedReactionRemovedAt
    }

    private func reactionCount(_ json: String?, names: Set<String>) -> Int {
        guard let json, let data = json.data(using: .utf8),
              let reactions = try? JSONDecoder().decode([SlackReaction].self, from: data) else {
            return 0
        }
        return reactions.reduce(0) { count, reaction in
            let normalizedName = reaction.name
                .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            return names.contains(normalizedName)
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
            guard let apiUser = try? await requestLimiter.run({
                try await client.usersInfo(token: token, userID: id)
            }) else { continue }
            try await database.dbWriter.write { db in
                try CachedUser(from: apiUser).save(db)
            }
        }
    }

    private func merge(
        _ source: [String: Set<String>],
        into destination: inout [String: Set<String>]
    ) {
        for (channelID, roots) in source {
            destination[channelID, default: []].formUnion(roots)
        }
    }

    private func concurrentMap<Element: Sendable, Output: Sendable>(
        _ elements: [Element],
        limit: Int,
        operation: @escaping @Sendable (Element) async throws -> Output
    ) async throws -> [Output] {
        guard !elements.isEmpty else { return [] }
        let concurrency = max(1, min(limit, elements.count))

        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                let element = elements[nextIndex]
                nextIndex += 1
                group.addTask { (index, try await operation(element)) }
            }

            var results = [Output?](repeating: nil, count: elements.count)
            while let (index, result) = try await group.next() {
                results[index] = result
                guard nextIndex < elements.count else { continue }
                let nextResultIndex = nextIndex
                let element = elements[nextIndex]
                nextIndex += 1
                group.addTask { (nextResultIndex, try await operation(element)) }
            }
            return results.compactMap { $0 }
        }
    }
}

/// One limiter is shared by every ingestion path, including lifecycle recovery and live
/// Socket Mode batches, so actor reentrancy cannot create an unbounded Slack request burst.
private actor SlackRequestLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func run<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
