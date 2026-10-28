import XCTest
import UIKit
@testable import KairoBody

private final class LookHTTP: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class PresenceLookTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "PresenceLookTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        LookHTTP.respond = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
    }
    private func client(tracker: JobTracker) -> ConversationClient {
        let settings = AppSettings(defaults: defaults)
        settings.followEcho = false
        settings.sharedSessionID = "session_look_fixture"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LookHTTP.self]
        return ConversationClient(settings: settings, speech: SpeechService(),
            http: KairoHTTP(session: URLSession(configuration: config), credentials: { ("fixture", "fixture") }),
            tracker: tracker, pendingStore: PendingTurnStore(defaults: defaults))
    }
    private func acceptVision(_ request: URLRequest) throws -> (Int, [String: Any]) {
        switch request.url!.path {
        case "/api/sessions/session_look_fixture": return (200, ["workspace_id": "workspace_fixture"])
        case "/api/workspaces/workspace_fixture/observations":
            return (200, ["id": "observation_frame", "session_id": "session_look_fixture"])
        case "/api/observations/observation_frame/vision":
            return (200, ["frame_observation_id": "observation_frame", "description_observation_id": "observation_description"])
        default: XCTFail("Unexpected visual request: \(request.url!.path)"); return (500, [:])
        }
    }

    // Catches eager upload on selection and sending the question without its image.
    func testPhotoStaysLocalUntilSendAndUsesSameConversation() async throws {
        var visualRequests = 0
        LookHTTP.respond = { [self] request in visualRequests += 1; return try acceptVision(request) }
        var submissions: [[String: Any]] = []
        let client = client(tracker: JobTracker(request: { path, method, body in
            if method == "POST" {
                XCTAssertEqual(path, "api/sessions/session_look_fixture/jobs")
                submissions.append(body!); return ["id": "job_look_fixture"]
            }
            return ["settled_status": "completed", "settled_text": "I see your photo"]
        }))
        client.outputDestination = .silent
        let draft = SharedImageDraft()
        try draft.select(photo(), source: .frontCamera, observedAt: Date(timeIntervalSince1970: 123))
        XCTAssertEqual(visualRequests, 0)
        client.draft = "What do you see?"
        await client.send(client.draft, imageDraft: draft)
        XCTAssertEqual(visualRequests, 3)
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?["attachment_ids"] as? [String], ["observation_description"])
        XCTAssertEqual(submissions.first?["prompt"] as? String, "What do you see?")
        XCTAssertEqual(client.reply, "I see your photo")
        XCTAssertNil(draft.photo)
    }

    // Catches losing a local photo/question when vision fails before job creation.
    func testFailedUploadRetainsPhotoAndQuestion() async throws {
        LookHTTP.respond = { _ in (503, [:]) }
        var posts = 0
        let client = client(tracker: JobTracker(request: { _, _, _ in posts += 1; return [:] }))
        client.outputDestination = .silent
        let draft = SharedImageDraft()
        try draft.select(photo(), source: .selectedImage)
        let id = draft.photo?.id
        client.draft = "Please look"
        await client.send(client.draft, imageDraft: draft)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(draft.photo?.id, id)
        XCTAssertEqual(client.draft, "Please look")
        XCTAssertNotNil(client.error)
        XCTAssertFalse(client.hasPendingTurn)
    }

    // Catches a late completion clearing a newly chosen photo.
    func testConsumingAnOlderPhotoPreservesReplacement() throws {
        let draft = SharedImageDraft()
        try draft.select(photo(), source: .frontCamera)
        let old = try XCTUnwrap(draft.photo)
        try draft.select(photo(), source: .selectedImage)
        let replacement = draft.photo?.id
        draft.remove(ifMatching: old.id)
        XCTAssertEqual(draft.photo?.id, replacement)
    }

    // Catches image loss or a fresh attachment/idempotency identity on retry.
    func testUnconfirmedSubmissionRetainsDurableAttachment() async throws {
        LookHTTP.respond = { [self] in try acceptVision($0) }
        let store = PendingTurnStore(defaults: defaults)
        let client = client(tracker: JobTracker(request: { _, _, _ in throw URLError(.notConnectedToInternet) }, sleep: { _ in }))
        client.outputDestination = .silent
        let draft = SharedImageDraft()
        try draft.select(photo(), source: .frontCamera)
        await client.send("Look", imageDraft: draft)
        let pending = try XCTUnwrap(store.load())
        XCTAssertEqual(pending.attachmentIDs, ["observation_description"])
        XCTAssertEqual(pending.sessionID, "session_look_fixture")
        XCTAssertTrue(client.hasPendingTurn)
        XCTAssertNil(draft.photo, "The durable pending turn owns the attachment now")
        await client.send("Duplicate", imageDraft: draft)
        XCTAssertEqual(store.load()?.idempotencyKey, pending.idempotencyKey)
    }
    func testCameraReservationRejectsCompetingCaptureAndBackgroundStart() async throws {
        let body = BodyClient(settings: AppSettings(defaults: defaults), sensors: SensorManager(),
                              speech: SpeechService(), camera: CameraCaptureService())
        let first = try await body.reserveSharedCamera()
        do {
            _ = try await body.reserveSharedCamera()
            XCTFail("A second camera owner must be rejected")
        } catch { XCTAssertEqual(error as? CameraCaptureService.CameraError, .notReady) }
        body.releaseSharedCamera(first)
        let second = try await body.reserveSharedCamera()
        body.releaseSharedCamera(first)
        do {
            _ = try await body.reserveSharedCamera()
            XCTFail("A stale release must not release a new reservation")
        } catch { XCTAssertEqual(error as? CameraCaptureService.CameraError, .notReady) }
        body.releaseSharedCamera(second)
        body.setForeground(false)
        do {
            _ = try await body.reserveSharedCamera()
            XCTFail("Background camera access must be rejected")
        } catch { XCTAssertEqual(error as? CameraCaptureService.CameraError, .notReady) }
    }

    func testStoppedMotionDetectorRejectsAnOlderStartTicket() async {
        let detector = FrontCameraMotionDetector()
        let ticket = detector.startTicket()
        await detector.stop()
        let started = await detector.start(ticket: ticket)
        XCTAssertFalse(started, "Stopped camera ownership cannot be resurrected by a delayed start")
    }

}
