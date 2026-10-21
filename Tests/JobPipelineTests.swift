import XCTest
@testable import KairoBody

final class JobPipelineTests: XCTestCase {
    private func turn(at date: Date = Date()) -> PendingTurn {
        PendingTurn.new(sessionID: "session_1", text: "hello", attachmentIDs: [],
                        outputDestination: nil, at: date)
    }

    func testSubmissionRetriesTheIdenticalRequestThenSucceeds() async throws {
        var attempts = 0
        var bodies: [String] = []
        let tracker = JobTracker(request: { path, method, body in
            XCTAssertEqual(path, "api/sessions/session_1/jobs")
            XCTAssertEqual(method, "POST")
            attempts += 1
            if let body,
               let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
                bodies.append(String(decoding: data, as: UTF8.self))
            }
            if attempts < 3 { throw HTTPStatusError(status: 503) }
            return ["id": "job_7"]
        }, sleep: { _ in })
        let jobID = try await tracker.submit(turn())
        XCTAssertEqual(jobID, "job_7")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(Set(bodies).count, 1, "every retry must resend byte-identically")
    }

    func testRejectedSubmissionIsNotRetried() async throws {
        var attempts = 0
        let tracker = JobTracker(request: { _, _, _ in
            attempts += 1
            throw HTTPStatusError(status: 401)
        }, sleep: { _ in })
        do {
            _ = try await tracker.submit(turn())
            XCTFail("401 must surface")
        } catch let status as HTTPStatusError {
            XCTAssertEqual(status.status, 401)
        }
        XCTAssertEqual(attempts, 1)
    }

    func testOutageRecoversTheSameJobByIdempotencyKey() async throws {
        var posts = 0
        var gets = 0
        let tracker = JobTracker(request: { path, method, _ in
            if method == "POST" {
                posts += 1
                XCTAssertEqual(path, "api/sessions/session_1/jobs")
                throw URLError(.timedOut)
            }
            gets += 1
            XCTAssertTrue(path.contains("idempotency_key=ipad-body:"))
            return [["id": "job_original"]]
        }, sleep: { _ in })
        let jobID = try await tracker.submit(turn())
        XCTAssertEqual(jobID, "job_original")
        XCTAssertEqual(posts, JobTracker.submitAttempts)
        XCTAssertEqual(gets, 1)
    }

    func testUnconfirmedSubmissionKeepsTheTurnForResend() async {
        let tracker = JobTracker(request: { _, _, _ in throw URLError(.notConnectedToInternet) },
                                 sleep: { _ in })
        do {
            _ = try await tracker.submit(turn())
            XCTFail("expected SubmissionUnconfirmed")
        } catch let error as SubmissionUnconfirmed {
            // Resending the stored turn is safe whether or not the server took it.
            XCTAssertFalse(error.turn.idempotencyKey.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testWaitObservesProgressThenSettles() async throws {
        var polls = 0
        var seen: [[String: Any]] = []
        let tracker = JobTracker(
            request: { path, _, _ in
                XCTAssertEqual(path, "api/jobs/job_9?compact=1")
                polls += 1
                if polls < 3 { return ["status": "running"] }
                return ["status": "completed", "settled_status": "completed", "settled_text": "done"]
            },
            sleep: { _ in })
        let wait = try await tracker.waitForSettlement(jobID: "job_9", since: Date()) { job in
            seen.append(job)
        }
        switch wait {
        case .settled(let job): XCTAssertEqual(job["settled_text"] as? String, "done")
        case .stillRunning: XCTFail("should have settled")
        }
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(seen.count, 3, "the settling read must also reach the progress sink")
    }

    func testDeadlineWhileWorkingIsReportedNotFailed() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var reads = 0
        let tracker = JobTracker(
            request: { _, _, _ in reads += 1; return ["status": "running"] },
            now: { base.addingTimeInterval(TimeInterval(reads * 301)) },
            sleep: { _ in })
        let wait = try await tracker.waitForSettlement(jobID: "job_9", since: base) { _ in }
        switch wait {
        case .settled: XCTFail("must not claim settlement")
        case .stillRunning(let last): XCTAssertNotNil(last?["status"])
        }
        // The loop polls first and checks the deadline after, so a read always
        // happens even when resuming long past the window.
        XCTAssertEqual(reads, 2)
    }

    func testTransientPollFailuresBackOffButKeepWaiting() async throws {
        var requests = 0
        var delays: [Double] = []
        let tracker = JobTracker(
            request: { _, _, _ in
                requests += 1
                if requests <= 2 { throw URLError(.timedOut) }
                return ["settled_status": "completed", "settled_text": "late"]
            },
            sleep: { seconds in delays.append(seconds) })
        let wait = try await tracker.waitForSettlement(jobID: "j", since: Date()) { _ in }
        if case .settled(let job) = wait { XCTAssertEqual(job["settled_text"] as? String, "late") }
        else { XCTFail("should settle") }
        XCTAssertEqual(delays, [1, 2], "backoff grows after successive failures; ordinary cadence is 2 s")
    }

    func testPendingTurnStoreSurvivesRelaunchAndIgnoresCorruption() throws {
        let suiteName = "JobPipelineTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = PendingTurnStore(defaults: suite)
        var turn = turn(at: Date(timeIntervalSince1970: 1_500_000))
        store.save(turn)
        var reloaded = store.load()
        XCTAssertEqual(reloaded, turn)
        turn.jobID = "job_11"
        store.save(turn)
        reloaded = store.load()
        XCTAssertEqual(reloaded?.jobID, "job_11")
        // A relaunch would call recoverPendingTurn with exactly this turn.
        store.clear()
        XCTAssertNil(store.load())
        suite.set(Data("corrupt".utf8), forKey: PendingTurnStore.key)
        XCTAssertNil(store.load())
        XCTAssertNil(suite.data(forKey: PendingTurnStore.key), "corruption must be purged")
    }

    func testOutputDestinationCarriesThroughTheRequestBody() {
        var turn = turn()
        turn.outputDestination = "ipad_speech"
        let body = turn.requestBody()
        XCTAssertEqual(body["output_destination"] as? String, "ipad_speech")
        let metadata = body["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["client"] as? String, "ipad_body")
    }
}
