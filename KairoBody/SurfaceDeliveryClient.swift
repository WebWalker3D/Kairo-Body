import Foundation
import Observation

/// Executes one already-settled, atomically claimed answer on this iPad.
/// Never queues on reconnect: an answer that left the foreground reports
/// failure so Kairo can choose another surface honestly.
@MainActor
@Observable
final class SurfaceDeliveryClient {
    typealias Request = (String, [String: Any]?) async throws -> [String: Any]
    private(set) var busy = false
    private(set) var error: String?
    var display: (String) async -> Bool = { _ in false }
    var speak: (String, @escaping (ActionPhase, String) -> Void) -> Bool = { _, _ in false }
    var stopSpeech: () -> Void = {}
    private let request: Request
    private var seen = Set<String>()
    private struct Receipt: Equatable {
        let job: String
        let target: String
        let success: Bool
        let detail: String
        let owner: String
        var key: String { target + ":" + job }
    }
    private var pendingReceipts: [String: Receipt] = [:]
    var hasUnconfirmedReceipts: Bool { !pendingReceipts.isEmpty }
    private var reporting = Set<String>()
    private var active: (job: String, target: String)?
    private var generation = UUID()
    private var foreground = true
    private var displayVisible = true
    private var presenceTask: Task<Void, Never>?

    init(request: @escaping Request) {
        self.request = request
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value { stop() }
        else { Task { await retryReceipts() } }
    }

    func setDisplayVisible(_ value: Bool) {
        displayVisible = value
    }

    func prepare(_ destination: String) async throws {
        guard foreground else { throw CancellationError() }
        let run = generation
        presenceTask?.cancel(); presenceTask = nil
        let targets: [String]
        if destination == "kairo" {
            let response = try await request("api/ipad/destinations", nil)
            guard foreground, generation == run else { throw CancellationError() }
            targets = (response["destinations"] as? [String] ?? []).filter { ["ipad_display", "ipad_speech"].contains($0) }
        } else {
            targets = ["ipad_display", "ipad_speech"].contains(destination) ? [destination] : []
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            guard foreground, generation == run else { throw CancellationError() }
            if target == "ipad_display" && !displayVisible { continue }
            _ = try await request("api/surfaces/\(target)/presence", ["available": true, "instance_id": "foreground-ipad"])
        }
        guard foreground, generation == run else { throw CancellationError() }
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.foreground, self.generation == run else { return }
                do {
                    for target in targets {
                        guard self.foreground, self.generation == run else { return }
                        if target == "ipad_display" && !self.displayVisible { continue }
                        _ = try await self.request("api/surfaces/\(target)/presence", ["available": true, "instance_id": "foreground-ipad"])
                    }
                } catch { self.stop(); return }
            }
        }
    }

    func deliver(jobID: String, destination: String) async {
        guard foreground else { return }
        if !["ipad_display", "ipad_speech"].contains(destination) {
            presenceTask?.cancel(); presenceTask = nil
            return
        }
        guard !seen.contains(jobID), WireID.valid(jobID) else { return }
        guard !busy else {
            error = "Another answer is still playing or being delivered. This answer remains in Conversation."
            return
        }
        busy = true; error = nil
        let run = generation
        do {
            let payload = try await request("api/surfaces/\(destination)/deliveries/\(jobID)/claim", [:])
            guard generation == run else {
                try? await report(jobID, destination, success: false, detail: "device left foreground during claim")
                return
            }
            seen.insert(jobID)
            active = (jobID, destination)
            guard payload["job_id"] as? String == jobID, payload["target"] as? String == destination,
                  payload["kind"] as? String == "text", let text = payload["text"] as? String,
                  !text.isEmpty, text.count <= 4_000 else {
                await finish(success: false, detail: "unsupported or invalid delivery", run: run); return
            }
            if destination == "ipad_display" {
                guard displayVisible, foreground else {
                    await finish(success: false, detail: "body display is obscured", run: run); return
                }
                let applied = await display(text)
                guard generation == run else { return }
                let visible = applied && displayVisible && foreground
                await finish(success: visible,
                    detail: visible ? "answer applied to visible display" : "display did not acknowledge visible output", run: run)
            } else {
                let started = speak(text) { [weak self] phase, detail in
                    guard phase == .completed || phase == .failed || phase == .stopped || phase == .expired else { return }
                    Task { @MainActor in await self?.finish(success: phase == .completed, detail: detail, run: run) }
                }
                if !started { await finish(success: false, detail: "speech was not started", run: run) }
            }
        } catch {
            if generation == run { self.error = error.localizedDescription; busy = false; active = nil }
        }
    }

    func stop() {
        presenceTask?.cancel(); presenceTask = nil
        let previous = active
        active = nil; generation = UUID(); busy = false
        stopSpeech()
        if let previous {
            Task { try? await report(previous.job, previous.target, success: false, detail: "delivery interrupted") }
        }
    }

    private func finish(success: Bool, detail: String, run: UUID) async {
        guard generation == run, let item = active else { return }
        active = nil
        do { try await report(item.job, item.target, success: success, detail: detail) }
        catch { if generation == run { self.error = error.localizedDescription } }
        if generation == run { busy = false; presenceTask?.cancel(); presenceTask = nil }
    }

    /// Resends only an already-observed outcome, never a claim or output act.
    func retryReceipts() async {
        guard foreground else { return }
        error = nil
        for item in Array(pendingReceipts.values) {
            do { try await sendReceipt(item) }
            catch { self.error = "The delivery outcome receipt is still unconfirmed. " + error.localizedDescription }
        }
    }

    private func report(_ job: String, _ target: String, success: Bool, detail: String) async throws {
        let item = Receipt(job: job, target: target, success: success,
                           detail: String(detail.prefix(500)), owner: AppConfig.ownerProof)
        pendingReceipts[item.key] = item
        try await sendReceipt(item)
    }

    private func sendReceipt(_ item: Receipt) async throws {
        guard !reporting.contains(item.key) else { return }
        guard item.owner == AppConfig.ownerProof else {
            pendingReceipts.removeValue(forKey: item.key)
            return
        }
        reporting.insert(item.key)
        defer { reporting.remove(item.key) }
        for attempt in 0..<3 {
            guard item.owner == AppConfig.ownerProof else {
                pendingReceipts.removeValue(forKey: item.key)
                return
            }
            do {
                _ = try await request("api/surfaces/\(item.target)/deliveries/\(item.job)/result",
                    ["status": item.success ? "delivered" : "failed",
                     "receipt": item.success ? item.detail : "", "error": item.success ? "" : item.detail])
                if pendingReceipts[item.key] == item { pendingReceipts.removeValue(forKey: item.key) }
                return
            } catch {
                guard RequestFailure.kind(of: error) == .transient, attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
    }
}
