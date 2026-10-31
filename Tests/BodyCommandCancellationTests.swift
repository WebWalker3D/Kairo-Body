import XCTest
@testable import KairoBody

@MainActor
final class BodyCommandCancellationTests: XCTestCase {
    func testStopWhileAcceptedEventIsSendingDoesNotApplyDisplayCommand() async throws {
        let previousToken = AppConfig.sensoryToken
        AppConfig.sensoryToken = "body-command-cancellation-fixture"
        defer { AppConfig.sensoryToken = previousToken }
        XCTAssertFalse(AppConfig.sensoryToken.isEmpty)

        let suite = "BodyCommandCancellationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.sendLocation = false
        settings.cameraMode = false
        settings.dimWhenStill = false
        settings.keepAwake = false

        let accepted = expectation(description: "accepted event is suspended")
        let applied = expectation(description: "stopped command must not apply display")
        applied.isInverted = true
        let socket = SuspendedAcceptedEventSocket(accepted: accepted)
        let body = BodyClient(settings: settings, sensors: SensorManager(),
                              speech: SpeechService(), camera: CameraCaptureService(),
                              makeSocket: { _ in socket })
        defer { body.stop(); socket.releaseAcceptedEvent() }
        body.setDisplayVisible(true)
        body.applyDisplay = { _ in applied.fulfill(); return true }
        let initialHeadline = body.display.headline
        try socket.enqueue([
            "type": "hello_ack", "protocolVersion": "kairo-body/1",
            "bodyID": AppConfig.bodyID, "sessionID": body.sessionID,
            "endpointID": "fixture-endpoint",
            "capabilities": ["body_capabilities_v1", "body_action_events_v1"]
        ])
        try socket.enqueue([
            "type": "command", "id": "cancelled-display-fixture", "command": "display",
            "args": ["headline": "This command was stopped", "detail": "fixture"]
        ])

        body.start()
        await fulfillment(of: [accepted], timeout: 2)
        body.stop()
        socket.releaseAcceptedEvent()
        // An inverted expectation observes the actual display callback, rather
        // than guessing how many executor yields the suspended send needs.
        await fulfillment(of: [applied], timeout: 0.2)
        XCTAssertEqual(body.display.headline, initialHeadline)
        XCTAssertEqual(body.connectionState, .stopped)
    }
}

private final class SuspendedAcceptedEventSocket: BodySocket, @unchecked Sendable {
    private let lock = NSLock()
    private let accepted: XCTestExpectation
    private var messages: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var acceptedSend: CheckedContinuation<Void, Never>?
    private var cancelled = false

    init(accepted: XCTestExpectation) { self.accepted = accepted }
    func resume() {}
    func sendPing() async throws {}

    func enqueue(_ object: [String: Any]) throws {
        let message = URLSessionWebSocketTask.Message.data(try JSONSerialization.data(withJSONObject: object))
        lock.lock()
        let waiting = receiver
        receiver = nil
        if waiting == nil { messages.append(message) }
        lock.unlock()
        waiting?.resume(returning: message)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "action_event",
              object["phase"] as? String == "accepted" else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            acceptedSend = continuation
            lock.unlock()
            accepted.fulfill()
        }
    }

    func releaseAcceptedEvent() {
        lock.lock()
        let waiting = acceptedSend
        acceptedSend = nil
        lock.unlock()
        waiting?.resume()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else if !messages.isEmpty {
                let message = messages.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else {
                receiver = continuation
                lock.unlock()
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        let waiting = receiver
        receiver = nil
        lock.unlock()
        waiting?.resume(throwing: URLError(.cancelled))
    }
}
