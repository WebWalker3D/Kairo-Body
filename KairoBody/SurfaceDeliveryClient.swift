import Foundation

/// Executes one already-settled, atomically claimed answer on this iPad.
/// Never queues on reconnect: an answer that left the foreground reports
/// failure so Kairo can choose another surface honestly.
@MainActor
final class SurfaceDeliveryClient: ObservableObject {
    typealias Request = (String, [String: Any]?) async throws -> [String: Any]
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    var display: (String) -> Void = { _ in }
    var speak: (String, @escaping (ActionPhase, String) -> Void) -> Bool = { _, _ in false }
    var stopSpeech: () -> Void = {}
    private let request: Request
    private var seen = Set<String>()
    private var active: (job: String, target: String)?
    private var generation = UUID()
    private var foreground = true
    private var displayVisible = false
    private var presenceTask: Task<Void, Never>?

    init(request: @escaping Request) {
        self.request = request
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value { stop() }
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
        guard destination != "silent", ["ipad_display", "ipad_speech"].contains(destination),
              !busy, !seen.contains(jobID), !jobID.isEmpty, WireID.valid(jobID) else { return }
        busy = true; error = nil; seen.insert(jobID)
        let run = generation
        do {
            let payload = try await request("api/surfaces/\(destination)/deliveries/\(jobID)/claim", [:])
            guard generation == run else {
                try? await report(jobID, destination, success: false, detail: "device left foreground during claim")
                return
            }
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
                display(text)
                await Task.yield()
                await finish(success: displayVisible && foreground,
                    detail: displayVisible && foreground ? "answer applied to visible display" : "display became obscured", run: run)
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

    private func report(_ job: String, _ target: String, success: Bool, detail: String) async throws {
        _ = try await request("api/surfaces/\(target)/deliveries/\(job)/result",
            ["status": success ? "delivered" : "failed", "receipt": success ? String(detail.prefix(500)) : "",
             "error": success ? "" : String(detail.prefix(500))])
    }
}
