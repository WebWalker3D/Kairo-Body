import Foundation
import XCTest
@testable import KairoBody

/// A socket whose pings can go unanswered, like a half-open TCP connection.
private final class FakeBodySocket: BodySocket, @unchecked Sendable {
    private let lock = NSLock()
    private let answeredPings: Int
    private var _pings = 0
    private var _cancelled = false
    private var pendingReceive: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    init(answeredPings: Int) { self.answeredPings = answeredPings }

    var pings: Int { lock.lock(); defer { lock.unlock() }; return _pings }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if cancelled { throw URLError(.networkConnectionLost) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if _cancelled {
                lock.unlock()
                continuation.resume(throwing: URLError(.cancelled))
            } else {
                pendingReceive = continuation
                lock.unlock()
            }
        }
    }
    func sendPing() async throws {
        lock.lock(); _pings += 1; let answered = _pings <= answeredPings; lock.unlock()
        if answered { return }
        // Dead link: the completion never fires.
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock(); _cancelled = true; lock.unlock()
        failReceive(URLError(.cancelled))
    }
    /// A late error delivered by the OS after the socket was already replaced.
    func failReceive(_ error: Error) {
        lock.lock()
        let pending = pendingReceive
        pendingReceive = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }
}

@MainActor
final class BodyLinkTests: XCTestCase {
    private var saved: (String, Bool, Bool) = ("", false, false)

    override func setUp() async throws {
        let settings = AppSettings()
        saved = (settings.websocketURL, settings.dimWhenStill, settings.cameraMode)
        settings.websocketURL = "wss://body.invalid/v1/body/ws"
        settings.dimWhenStill = false
        settings.cameraMode = false
    }

    override func tearDown() async throws {
        let settings = AppSettings()
        settings.websocketURL = saved.0
        settings.dimWhenStill = saved.1
        settings.cameraMode = saved.2
    }

    private func client(sockets: @escaping () -> FakeBodySocket, counter: @escaping (FakeBodySocket) -> Void) -> BodyClient {
        let settings = AppSettings()
        return BodyClient(settings: settings, sensors: SensorManager(),
                          speech: SpeechService(settings: settings), camera: CameraCaptureService(),
                          makeSocket: { _ in let socket = sockets(); counter(socket); return socket },
                          timing: BodyLinkTiming(livenessInterval: 0.2, livenessDeadline: 0.1,
                                                 openingDeadline: 0.5, reconnectDelay: { _ in 0.05 }))
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Double = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testDeadSocketIsDetectedAndReplacedByExactlyOneConnection() async {
        var created: [FakeBodySocket] = []
        // First socket answers its opening ping, then stops answering.
        let body = client(sockets: { FakeBodySocket(answeredPings: created.isEmpty ? 1 : .max) },
                          counter: { created.append($0) })
        body.start()
        await waitUntil { created.count == 2 && body.connectionState == .connected }
        XCTAssertEqual(created.count, 2, "one heartbeat timeout produces one replacement")
        XCTAssertTrue(created[0].cancelled)
        XCTAssertEqual(body.connectionState, .connected)
        // Late errors from the dead socket must not start another connection loop.
        created[0].failReceive(URLError(.networkConnectionLost))
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(created.count, 2)
        XCTAssertFalse(created[1].cancelled)
        body.stop()
    }

    func testHealthySocketIsProbedButNeverReplaced() async {
        var created: [FakeBodySocket] = []
        let body = client(sockets: { FakeBodySocket(answeredPings: .max) }, counter: { created.append($0) })
        body.start()
        await waitUntil { (created.first?.pings ?? 0) >= 3 }
        XCTAssertGreaterThanOrEqual(created.first?.pings ?? 0, 3, "heartbeats run every interval while active")
        XCTAssertEqual(created.count, 1)
        body.stop()
    }

    func testForegroundReturnProbesImmediatelyAndStopCancelsHeartbeats() async {
        var created: [FakeBodySocket] = []
        let settings = AppSettings()
        let body = BodyClient(settings: settings, sensors: SensorManager(),
                              speech: SpeechService(settings: settings), camera: CameraCaptureService(),
                              makeSocket: { _ in let socket = FakeBodySocket(answeredPings: .max); created.append(socket); return socket },
                              timing: BodyLinkTiming(livenessInterval: 60, livenessDeadline: 0.1,
                                                     openingDeadline: 0.5, reconnectDelay: { _ in 0.05 }))
        body.start()
        await waitUntil { body.connectionState == .connected }
        let afterOpen = created[0].pings
        body.setForeground(false)
        body.setForeground(true)
        await waitUntil { created[0].pings > afterOpen }
        XCTAssertEqual(created[0].pings, afterOpen + 1, "returning to the foreground checks the link at once")
        body.stop()
        let afterStop = created[0].pings
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(created[0].pings, afterStop)
        XCTAssertEqual(created.count, 1)
    }
}
