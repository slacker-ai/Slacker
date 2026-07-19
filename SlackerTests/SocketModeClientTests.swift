import XCTest
@testable import Slacker

final class SocketModeClientTests: XCTestCase {
    private let socketURL = URL(string: "wss://example.slack.com/link/?ticket=temporary")!

    func testAcknowledgesBeforeRoutingAndTransitionsToConnected() async throws {
        let socket = FakeSocketModeWebSocket()
        let connected = expectation(description: "connected")
        let routed = expectation(description: "event routed")

        let client = SocketModeClient(
            openConnection: { _ in self.socketURL },
            makeWebSocket: { _ in socket },
            onEvent: { event in
                XCTAssertEqual(socket.sentCount, 1, "ack must be sent before application work")
                XCTAssertEqual(event.teamID, "T1")
                XCTAssertEqual(event.event.channelID, "C1")
                routed.fulfill()
            },
            onStateChange: { state in
                if state == .connected { connected.fulfill() }
            },
            jitter: { 0 }
        )

        await client.start(appToken: "xapp-secret")
        socket.enqueue(text: #"{"type":"hello","num_connections":1}"#)
        socket.enqueue(text: eventEnvelope(envelopeID: "env-1", eventID: "Ev1"))

        await fulfillment(of: [connected, routed], timeout: 2)
        let ack = try XCTUnwrap(socket.sentTexts.first)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: Data(ack.utf8)) as? [String: String],
            ["envelope_id": "env-1"]
        )
        await client.stop()
    }

    func testDuplicateEventIsAcknowledgedButRoutedOnce() async {
        let twoAcks = expectation(description: "both envelopes acknowledged")
        twoAcks.expectedFulfillmentCount = 2
        let socket = FakeSocketModeWebSocket(onSend: { _ in twoAcks.fulfill() })
        let routed = expectation(description: "event routed once")

        let client = SocketModeClient(
            openConnection: { _ in self.socketURL },
            makeWebSocket: { _ in socket },
            onEvent: { _ in routed.fulfill() },
            jitter: { 0 }
        )

        await client.start(appToken: "xapp-secret")
        socket.enqueue(text: eventEnvelope(envelopeID: "env-1", eventID: "same-event"))
        socket.enqueue(text: eventEnvelope(envelopeID: "env-2", eventID: "same-event"))

        await fulfillment(of: [twoAcks, routed], timeout: 2)
        XCTAssertEqual(socket.sentCount, 2)
        await client.stop()
    }

    func testMalformedEventPayloadIsStillAcknowledgedAndIgnored() async {
        let acked = expectation(description: "malformed payload acknowledged")
        let socket = FakeSocketModeWebSocket(onSend: { _ in acked.fulfill() })
        let routed = expectation(description: "must not route")
        routed.isInverted = true

        let client = SocketModeClient(
            openConnection: { _ in self.socketURL },
            makeWebSocket: { _ in socket },
            onEvent: { _ in routed.fulfill() },
            jitter: { 0 }
        )

        await client.start(appToken: "xapp-secret")
        socket.enqueue(text: #"{"envelope_id":"bad-1","type":"events_api","payload":{"team_id":"T1"}}"#)

        await fulfillment(of: [acked, routed], timeout: 0.2)
        XCTAssertEqual(socket.sentCount, 1)
        await client.stop()
    }

    func testDisconnectRefreshReplacesConnectionWithoutBackoff() async {
        let first = FakeSocketModeWebSocket()
        let second = FakeSocketModeWebSocket()
        let sequence = SocketSequence([first, second])
        let replacementCreated = expectation(description: "replacement socket created")

        let client = SocketModeClient(
            openConnection: { _ in self.socketURL },
            makeWebSocket: { _ in
                let result = sequence.next()
                if result === second { replacementCreated.fulfill() }
                return result
            },
            onEvent: { _ in },
            jitter: { 0 },
            sleep: { _ in XCTFail("Slack-requested refresh must not back off") }
        )

        await client.start(appToken: "xapp-secret")
        first.enqueue(text: #"{"type":"hello"}"#)
        first.enqueue(text: #"{"type":"disconnect","reason":"refresh_requested"}"#)

        await fulfillment(of: [replacementCreated], timeout: 2)
        XCTAssertTrue(first.wasCancelled)
        await client.stop()
    }

    func testCancellationStopsSocketAndPreventsRetry() async {
        let socket = FakeSocketModeWebSocket()
        let opens = Counter()
        let client = SocketModeClient(
            openConnection: { _ in
                _ = opens.next()
                return self.socketURL
            },
            makeWebSocket: { _ in socket },
            onEvent: { _ in },
            jitter: { 0 }
        )

        await client.start(appToken: "xapp-secret")
        socket.enqueue(text: #"{"type":"hello"}"#)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await client.stop()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(socket.wasCancelled)
        XCTAssertEqual(opens.next(), 1, "next() returns the number of opens already recorded")
    }

    func testRetryBackoffIsExponentialAndBounded() async {
        let attempts = Counter()
        let delays = LockedValues<Double>()
        let socket = FakeSocketModeWebSocket()
        let connectedAttempt = expectation(description: "third open succeeds")

        let client = SocketModeClient(
            openConnection: { _ in
                let attempt = attempts.next()
                if attempt < 2 { throw SlackClientError.http(503) }
                connectedAttempt.fulfill()
                return self.socketURL
            },
            makeWebSocket: { _ in socket },
            onEvent: { _ in },
            baseBackoffSeconds: 2,
            maxBackoffSeconds: 3,
            jitter: { 0 },
            sleep: { delays.append($0) }
        )

        await client.start(appToken: "xapp-secret")
        await fulfillment(of: [connectedAttempt], timeout: 2)
        XCTAssertEqual(delays.values, [2, 3])
        await client.stop()
    }

    private func eventEnvelope(envelopeID: String, eventID: String) -> String {
        #"{"envelope_id":"\#(envelopeID)","type":"events_api","payload":{"team_id":"T1","event_id":"\#(eventID)","event":{"type":"message","channel":"C1","ts":"100.0","text":"hello"}}}"#
    }
}

private enum FakeSocketError: Error { case cancelled }

private final class FakeSocketModeWebSocket: SocketModeWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<SocketModeWebSocketFrame, Error>] = []
    private var waiter: CheckedContinuation<SocketModeWebSocketFrame, Error>?
    private var sent: [String] = []
    private var cancelled = false
    private let onSend: @Sendable (String) -> Void

    init(onSend: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onSend = onSend
    }

    func resume() {}

    func send(text: String) async throws {
        lock.lock()
        sent.append(text)
        lock.unlock()
        onSend(text)
    }

    func receive() async throws -> SocketModeWebSocketFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queued.isEmpty {
                let result = queued.removeFirst()
                lock.unlock()
                continuation.resume(with: result)
            } else if cancelled {
                lock.unlock()
                continuation.resume(throwing: FakeSocketError.cancelled)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(throwing: FakeSocketError.cancelled)
    }

    func enqueue(text: String) {
        enqueue(.success(.text(text)))
    }

    private func enqueue(_ result: Result<SocketModeWebSocketFrame, Error>) {
        lock.lock()
        if let continuation = waiter {
            waiter = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            queued.append(result)
            lock.unlock()
        }
    }

    var sentTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    var sentCount: Int { sentTexts.count }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeSocketModeWebSocket]

    init(_ sockets: [FakeSocketModeWebSocket]) { self.sockets = sockets }

    func next() -> FakeSocketModeWebSocket {
        lock.lock(); defer { lock.unlock() }
        return sockets.isEmpty ? FakeSocketModeWebSocket() : sockets.removeFirst()
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
