import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import KairoBody

/// A scripted Agent API. Each call pops the next scripted outcome for its route.
private final class ScriptedAgent {
    enum Outcome { case json(Any), fail(Error) }
    var posts: [Outcome] = []
    var recoveries: [Outcome] = []
    var polls: [Outcome] = []
    var repeatingPoll: Outcome?
    private(set) var calls: [(method: String, path: String, body: String?)] = []
    var clock = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [Double] = []

    func request(_ path: String, _ method: String, _ body: [String: Any]?) async throws -> Any {
        let encoded = try body.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        calls.append((method, path, encoded))
        let outcome: Outcome
        if method == "POST" {
            outcome = posts.isEmpty ? .fail(URLError(.timedOut)) : posts.removeFirst()
        } else if path.contains("idempotency_key=") {
            outcome = recoveries.isEmpty ? .json([[String: Any]]()) : recoveries.removeFirst()
        } else if !polls.isEmpty {
            outcome = polls.removeFirst()
        } else {
            outcome = repeatingPoll ?? .fail(URLError(.timedOut))
        }
        switch outcome {
        case .json(let value): return value
        case .fail(let error): throw error
        }
    }

    func tracker() -> JobTracker {
        JobTracker(request: { [unowned self] in try await self.request($0, $1, $2) },
                   now: { [unowned self] in self.clock },
                   sleep: { [unowned self] seconds in self.sleeps.append(seconds); self.clock += seconds })
    }
}

private func turn(at date: Date = Date(timeIntervalSince1970: 1_000_000)) -> PendingTurn {
    PendingTurn(sessionID: "session-1", text: "Are you there?",
                idempotencyKey: "ipad-body:3f2c1d7e-0000-4000-8000-000000000001",
                attachmentIDs: [], outputDestination: nil, submittedAt: date, jobID: nil)
}

private let running: [String: Any] = ["id": "job-1", "status": "running"]
private let settled: [String: Any] = ["id": "job-1", "status": "completed",
                                      "settled_status": "completed", "settled_text": "Yes."]

final class JobSubmissionTests: XCTestCase {
    func testLostResponseIsRetriedWithTheIdenticalRequestAndKey() async throws {
        let agent = ScriptedAgent()
        // The server admitted the first POST, but its response never arrived.
        agent.posts = [.fail(URLError(.networkConnectionLost)), .json(["id": "job-1"])]
        let job = try await agent.tracker().submit(turn())
        XCTAssertEqual(job, "job-1")
        let posts = agent.calls.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].path, "api/sessions/session-1/jobs")
        XCTAssertEqual(posts[0].body, posts[1].body, "a retry must be byte-identical so the server deduplicates it")
        XCTAssertTrue(posts[0].body?.contains("ipad-body:3f2c1d7e-0000-4000-8000-000000000001") == true)
    }

    func testEveryResponseLostRecoversTheJobByItsKey() async throws {
        let agent = ScriptedAgent()
        agent.posts = Array(repeating: .fail(URLError(.timedOut)), count: JobTracker.submitAttempts)
        agent.recoveries = [.json([["id": "job-1", "status": "running"]])]
        let job = try await agent.tracker().submit(turn())
        XCTAssertEqual(job, "job-1")
        XCTAssertEqual(agent.calls.filter { $0.method == "POST" }.count, JobTracker.submitAttempts)
        XCTAssertEqual(agent.calls.last?.path,
                       "api/sessions/session-1/jobs?idempotency_key=ipad-body:3f2c1d7e-0000-4000-8000-000000000001")
    }

    func testUnconfirmedSubmissionKeepsTheMessageForAnIdenticalRetry() async {
        let agent = ScriptedAgent()
        agent.posts = Array(repeating: .fail(URLError(.notConnectedToInternet)), count: JobTracker.submitAttempts)
        agent.recoveries = [.fail(URLError(.notConnectedToInternet))]
        do {
            _ = try await agent.tracker().submit(turn())
            XCTFail("expected an unconfirmed submission")
        } catch let error as SubmissionUnconfirmed {
            XCTAssertEqual(error.turn, turn())
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRejectedSubmissionIsNotRetried() async {
        let agent = ScriptedAgent()
        agent.posts = [.fail(HTTPStatusError(status: 400))]
        do {
            _ = try await agent.tracker().submit(turn())
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? HTTPStatusError, HTTPStatusError(status: 400))
        }
        XCTAssertEqual(agent.calls.count, 1)
    }

    func testReloadedTurnEncodesByteIdenticalRequest() throws {
        var pending = turn()
        pending.outputDestination = "dot"
        let reloaded = try JSONDecoder().decode(PendingTurn.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(try PendingTurn.encode(pending.requestBody()),
                       try PendingTurn.encode(reloaded.requestBody()))
    }

    func testRequestBodyIsTheMessageKeyAndProvenanceOnly() throws {
        var pending = turn()
        pending.outputDestination = "kairo"
        let body = pending.requestBody()
        XCTAssertEqual(body["prompt"] as? String, "Are you there?")
        XCTAssertEqual(body["idempotency_key"] as? String, pending.idempotencyKey)
        XCTAssertEqual(body["output_destination"] as? String, "kairo")
        XCTAssertEqual((body["metadata"] as? [String: String]) ?? [:],
                       ["source": "ipad_body", "client": "ipad_body"])
    }
}

final class JobTrackingTests: XCTestCase {
    func testFailedStatusChecksDoNotAbandonARunningJob() async throws {
        let agent = ScriptedAgent()
        agent.polls = [.json(running), .fail(HTTPStatusError(status: 502)), .fail(URLError(.timedOut)),
                       .fail(MalformedResponse()), .json(settled)]
        var observed = 0
        let result = try await agent.tracker().waitForSettlement(jobID: "job-1", since: agent.clock) { _ in observed += 1 }
        guard case .settled(let job) = result else { return XCTFail("expected settlement, got \(result)") }
        XCTAssertEqual(job["settled_text"] as? String, "Yes.")
        XCTAssertEqual(observed, 2, "the running read and the settling read are both observed")
        XCTAssertEqual(agent.calls.count, 5)
        // Bounded backoff after each failure, not a fixed attempt budget.
        XCTAssertEqual(agent.sleeps, [2, 1, 2, 4])
    }

    func testDeadlineIsSixHundredSecondsOfElapsedTimeNotAnAttemptCount() async throws {
        let agent = ScriptedAgent()
        agent.repeatingPoll = .json(running)
        let started = agent.clock
        let result = try await agent.tracker().waitForSettlement(jobID: "job-1", since: started) { _ in }
        guard case .stillRunning(let last) = result else { return XCTFail("expected still running") }
        XCTAssertEqual(last?["status"] as? String, "running")
        let elapsed = agent.clock.timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 598)
        XCTAssertLessThanOrEqual(elapsed, 600)
        XCTAssertGreaterThan(agent.calls.count, 120, "the old fixed 120-attempt limit no longer applies")
    }

    func testOutageLongerThanTheDeadlineReportsStillRunningNotFailure() async throws {
        let agent = ScriptedAgent()
        agent.polls = [.json(running)]
        agent.repeatingPoll = .fail(URLError(.networkConnectionLost))
        let result = try await agent.tracker().waitForSettlement(jobID: "job-1", since: agent.clock) { _ in }
        guard case .stillRunning = result else { return XCTFail("expected still running") }
        XCTAssertTrue(agent.sleeps.allSatisfy { $0 <= 15 })
    }

    func testAFinalResultIsRecoverableAfterTheDeadline() async throws {
        let agent = ScriptedAgent()
        agent.repeatingPoll = .json(running)
        let tracker = agent.tracker()
        _ = try await tracker.waitForSettlement(jobID: "job-1", since: agent.clock) { _ in }
        agent.repeatingPoll = .json(settled)
        let later = try await tracker.waitForSettlement(jobID: "job-1", since: agent.clock) { _ in }
        guard case .settled = later else { return XCTFail("expected the recovered result") }
    }

    func testResumingPastTheDeadlineStillChecksOnce() async throws {
        let agent = ScriptedAgent()
        agent.repeatingPoll = .json(settled)
        let longAgo = agent.clock.addingTimeInterval(-3_600)
        let result = try await agent.tracker().waitForSettlement(jobID: "job-1", since: longAgo) { _ in }
        guard case .settled = result else { return XCTFail("expected one check to find the result") }
        XCTAssertEqual(agent.calls.count, 1)
    }

    func testAuthorizationLossStopsTracking() async {
        let agent = ScriptedAgent()
        agent.polls = [.fail(HTTPStatusError(status: 403))]
        do {
            _ = try await agent.tracker().waitForSettlement(jobID: "job-1", since: agent.clock) { _ in }
            XCTFail("expected authorization loss")
        } catch {
            XCTAssertEqual(RequestFailure.kind(of: error), .authorizationLost)
        }
    }
}

final class PendingTurnStoreTests: XCTestCase {
    func testPendingTurnSurvivesRelaunchUntilCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-turn-tests-\(UUID().uuidString)"))
        var pending = turn()
        pending.jobID = "job-1"
        PendingTurnStore(defaults: defaults).save(pending)
        XCTAssertEqual(PendingTurnStore(defaults: defaults).load(), pending)
        PendingTurnStore(defaults: defaults).clear()
        XCTAssertNil(PendingTurnStore(defaults: defaults).load())
    }

    func testCorruptStoredTurnIsDiscarded() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-turn-tests-\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: PendingTurnStore.key)
        XCTAssertNil(PendingTurnStore(defaults: defaults).load())
    }
}
