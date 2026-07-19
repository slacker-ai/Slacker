import Foundation

enum SocketModeWebSocketFrame: Sendable {
    case text(String)
    case data(Data)
}

/// Small seam around `URLSessionWebSocketTask` so Socket Mode behavior is testable
/// without opening a real network connection.
protocol SocketModeWebSocket: AnyObject, Sendable {
    func resume()
    func send(text: String) async throws
    func receive() async throws -> SocketModeWebSocketFrame
    func cancel()
}

final class URLSessionSocketModeWebSocket: SocketModeWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
    }

    func resume() { task.resume() }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> SocketModeWebSocketFrame {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: throw SocketModeClientError.unsupportedFrame
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

enum SocketModeClientError: Error {
    case unsupportedFrame
    case connectionEnded
}

/// Native Socket Mode transport. It acknowledges deliveries before invoking application
/// work, de-duplicates retries, and replaces expired connections with bounded backoff.
actor SocketModeClient {
    typealias OpenConnection = @Sendable (_ appToken: String) async throws -> URL
    typealias MakeWebSocket = @Sendable (_ url: URL) -> any SocketModeWebSocket
    typealias EventHandler = @Sendable (SocketModeEvent) async -> Void
    typealias StateHandler = @Sendable (SocketModeConnectionState) async -> Void
    typealias Sleep = @Sendable (_ seconds: Double) async throws -> Void

    private enum ReceiveResult { case reconnectImmediately }

    private let openConnection: OpenConnection
    private let makeWebSocket: MakeWebSocket
    private let onEvent: EventHandler
    private let onStateChange: StateHandler
    private let sleep: Sleep
    private let jitter: @Sendable () -> Double
    private let baseBackoffSeconds: Double
    private let maxBackoffSeconds: Double

    private var runTask: Task<Void, Never>?
    private var currentSocket: (any SocketModeWebSocket)?
    private var isStopping = false
    private(set) var state: SocketModeConnectionState = .disconnected

    private var seenEnvelopeIDs = Set<String>()
    private var envelopeIDOrder: [String] = []
    private var seenEventIDs = Set<String>()
    private var eventIDOrder: [String] = []
    private let duplicateWindowSize = 1_000

    init(
        openConnection: @escaping OpenConnection,
        makeWebSocket: @escaping MakeWebSocket = { URLSessionSocketModeWebSocket(url: $0) },
        onEvent: @escaping EventHandler,
        onStateChange: @escaping StateHandler = { _ in },
        baseBackoffSeconds: Double = 1,
        maxBackoffSeconds: Double = 30,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.5) },
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.openConnection = openConnection
        self.makeWebSocket = makeWebSocket
        self.onEvent = onEvent
        self.onStateChange = onStateChange
        self.baseBackoffSeconds = baseBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.jitter = jitter
        self.sleep = sleep
    }

    func start(appToken: String) {
        guard runTask == nil else { return }
        isStopping = false
        runTask = Task { [weak self] in
            await self?.run(appToken: appToken)
        }
    }

    func stop() async {
        isStopping = true
        currentSocket?.cancel()
        currentSocket = nil
        runTask?.cancel()
        runTask = nil
        await publish(.disconnected)
    }

    private func run(appToken: String) async {
        var failedAttempts = 0

        while !Task.isCancelled && !isStopping {
            await publish(.connecting)
            do {
                let url = try await openConnection(appToken)
                try Task.checkCancellation()

                let socket = makeWebSocket(url)
                currentSocket = socket
                socket.resume()

                _ = try await receiveLoop(socket: socket)
                socket.cancel()
                currentSocket = nil
                failedAttempts = 0

                guard !Task.isCancelled && !isStopping else { break }
                await publish(.disconnected)
                // Slack disconnect/refresh messages ask clients to replace the URL now.
                continue
            } catch is CancellationError {
                break
            } catch {
                currentSocket?.cancel()
                currentSocket = nil
                guard !Task.isCancelled && !isStopping else { break }

                if state == .connected {
                    // A confirmed connection earns a fresh retry budget if it later drops.
                    failedAttempts = 0
                }
                failedAttempts += 1
                await publish(.failed(Self.safeErrorMessage(for: error)))
                let exponent = pow(2, Double(max(failedAttempts - 1, 0)))
                let delay = min(
                    maxBackoffSeconds,
                    baseBackoffSeconds * exponent + max(0, jitter())
                )
                do {
                    try await sleep(delay)
                } catch {
                    break
                }
            }
        }

        currentSocket?.cancel()
        currentSocket = nil
        runTask = nil
        await publish(.disconnected)
    }

    private func receiveLoop(socket: any SocketModeWebSocket) async throws -> ReceiveResult {
        while !Task.isCancelled && !isStopping {
            let frame = try await socket.receive()
            let data: Data
            switch frame {
            case .text(let text): data = Data(text.utf8)
            case .data(let value): data = value
            }

            guard let header = try? JSONDecoder().decode(SocketModeEnvelopeHeader.self, from: data) else {
                Log.error("Socket Mode received a malformed envelope; ignoring it.")
                continue
            }

            // Slack expects the envelope acknowledgement before any application work.
            if let envelopeID = header.envelopeID {
                try await acknowledge(envelopeID, on: socket)
                guard rememberEnvelope(envelopeID) else { continue }
            }

            switch header.type {
            case "hello":
                await publish(.connected)

            case "disconnect":
                return .reconnectImmediately

            case "events_api":
                guard let envelopeID = header.envelopeID,
                      let envelope = try? JSONDecoder().decode(SocketModeEventsEnvelope.self, from: data),
                      let teamID = envelope.payload.routedTeamID else {
                    Log.error("Socket Mode received an invalid Events API payload; ignoring it.")
                    continue
                }
                if let eventID = envelope.payload.eventID, !rememberEvent(eventID) {
                    continue
                }
                await onEvent(SocketModeEvent(
                    envelopeID: envelopeID,
                    teamID: teamID,
                    eventID: envelope.payload.eventID,
                    event: envelope.payload.event
                ))

            default:
                // Slash commands and interactive payloads are not enabled in Slacker's
                // manifests. Unknown future envelope types are safely acknowledged above.
                continue
            }
        }
        throw CancellationError()
    }

    private func acknowledge(_ envelopeID: String, on socket: any SocketModeWebSocket) async throws {
        let data = try JSONEncoder().encode(Acknowledgement(envelopeID: envelopeID))
        guard let text = String(data: data, encoding: .utf8) else {
            throw SocketModeClientError.unsupportedFrame
        }
        try await socket.send(text: text)
    }

    private func rememberEnvelope(_ id: String) -> Bool {
        remember(id, seen: &seenEnvelopeIDs, order: &envelopeIDOrder)
    }

    private func rememberEvent(_ id: String) -> Bool {
        remember(id, seen: &seenEventIDs, order: &eventIDOrder)
    }

    private func remember(_ id: String, seen: inout Set<String>, order: inout [String]) -> Bool {
        guard seen.insert(id).inserted else { return false }
        order.append(id)
        if order.count > duplicateWindowSize {
            seen.remove(order.removeFirst())
        }
        return true
    }

    private func publish(_ newState: SocketModeConnectionState) async {
        guard state != newState else { return }
        state = newState
        await onStateChange(newState)
    }

    private static func safeErrorMessage(for error: Error) -> String {
        if case SlackClientError.api(let code) = error {
            return "Slack rejected the Socket Mode connection (\(SecretRedaction.redact(code))). Retrying…"
        }
        return "Socket Mode connection failed. Retrying…"
    }

    private struct Acknowledgement: Encodable {
        let envelopeID: String

        enum CodingKeys: String, CodingKey {
            case envelopeID = "envelope_id"
        }
    }
}
