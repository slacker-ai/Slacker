import Foundation

/// Drives ingestion on a periodic loop off the main actor (§6.2), and backfills the
/// gap on launch/wake (§6.3). Detection/staleness operate on message `ts`, so a
/// closed laptop over a weekend still yields a correct Monday state.
actor Poller {
    private let ingestion: IngestionService
    private let intervalSeconds: @Sendable () -> Int
    /// Runs after a successful ingestion cycle (e.g. detection). Optional.
    private let onCycleComplete: (@Sendable () async throws -> Void)?
    /// Injectable sleep so tests can drive the loop without real delays.
    private let sleep: @Sendable (_ seconds: Double) async throws -> Void

    private var loopTask: Task<Void, Never>?
    private(set) var lastError: String?
    private(set) var lastPollStartedAt: Date?

    init(
        ingestion: IngestionService,
        intervalSeconds: @escaping @Sendable () -> Int = { 180 },
        onCycleComplete: (@Sendable () async throws -> Void)? = nil,
        sleep: @escaping @Sendable (_ seconds: Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.ingestion = ingestion
        self.intervalSeconds = intervalSeconds
        self.onCycleComplete = onCycleComplete
        self.sleep = sleep
    }

    /// Start the periodic poll loop (no-op if already running). Polls immediately,
    /// which also performs the launch/wake backfill via each channel's `lastPolledTS`.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                let interval = Double(self.intervalSeconds())
                try? await self.sleep(interval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Run a single poll cycle. Safe to call directly (e.g. on system wake).
    func pollOnce() async {
        lastPollStartedAt = Date()
        Log.info("Poll cycle started.")
        do {
            try await ingestion.pollAllWorkspaces()
            try await onCycleComplete?()
            lastError = nil
            Log.info("Poll cycle finished.")
        } catch {
            // Network loss must never crash; record and retry next cycle (§3).
            lastError = String(describing: error)
            Log.error("Poll cycle failed: \(error)")
        }
    }
}
