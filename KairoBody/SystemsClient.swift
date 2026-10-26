import Foundation

/// Deliberately narrow projection. Private dream text and appraisal never
/// become stored properties, logs, UI, or conversation context on this surface.
struct RestProjection {
    enum State: String { case awake, sleeping, dreaming }
    let state: State
    let observedAt: Date

    init?(object: [String: Any], now: Date = Date()) {
        guard object["schema_version"] as? Int == 1,
              object["read_only"] as? Bool == true,
              let observedAt = BodyJSON.date(object["observed_at"]),
              let memory = object["memory"] as? [String: Any],
              memory["available"] as? Bool == true, memory["read_only"] as? Bool == true,
              memory["foreground_lease_acquired"] as? Bool == false,
              memory["semantic_recall_performed"] as? Bool == false,
              let temporal = memory["temporal"] as? [String: Any],
              let rest = temporal["rest_state"] as? [String: Any],
              let value = rest["current_state"] as? String, let state = State(rawValue: value) else { return nil }
        self.state = state; self.observedAt = observedAt
        guard isFresh(at: now) else { return nil }
    }

    func isFresh(at now: Date = Date()) -> Bool {
        observedAt <= now.addingTimeInterval(5) && now.timeIntervalSince(observedAt) <= 60
    }
}

struct SystemCapability: Identifiable {
    let id: String
    let name: String
    let detail: String
    let enabled: Bool
    let prerequisites: [String]

    init?(object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty, id.count <= 200,
              let name = object["name"] as? String, !name.isEmpty,
              let enabled = boundedInteger(object["enabled"], range: 0...1) else { return nil }
        self.id = id; self.name = String(name.prefix(500)); self.enabled = enabled == 1
        detail = String((object["description"] as? String ?? "").prefix(4096))
        prerequisites = (object["prerequisites_json"] as? [Any] ?? [])
            .compactMap { $0 as? String }.prefix(8).map { String($0.prefix(200)) }
    }
}

@MainActor
final class SystemsClient: ObservableObject {
    @Published private(set) var rest: RestProjection?
    @Published private(set) var capabilities: [SystemCapability] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var unavailable = true
    private var loop: Task<Void, Never>?
    private var generation = UUID()
    private let request: (String) async throws -> Any

    init(request: @escaping (String) async throws -> Any = { path in
        try await KairoHTTP().agent(path, timeout: 10)
    }) { self.request = request }

    var freshRest: RestProjection? { rest.flatMap { $0.isFresh() ? $0 : nil } }

    func start(paired: Bool, foreground: Bool) {
        stop()
        guard paired, foreground else { return }
        let run = generation
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, run == self.generation else { return }
                await self.refresh(run: run)
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    func stop() {
        generation = UUID(); loop?.cancel(); loop = nil
        rest = nil; capabilities = []; updatedAt = nil; unavailable = true
    }

    private func refresh(run: UUID) async {
        do {
            let object = try await request("api/kairo-state")
            guard run == generation, !Task.isCancelled else { return }
            rest = (object as? [String: Any]).flatMap { RestProjection(object: $0) }
        } catch {
            guard run == generation else { return }
            rest = nil
            if RequestFailure.kind(of: error) == .authorizationLost { stop(); return }
        }
        do {
            let response = try await request("api/capabilities")
            guard run == generation, !Task.isCancelled else { return }
            guard let rows = response as? [[String: Any]] else { throw MalformedResponse() }
            var seen = Set<String>()
            capabilities = rows.prefix(256).compactMap(SystemCapability.init(object:)).filter { seen.insert($0.id).inserted }
            updatedAt = Date(); unavailable = false
        } catch {
            guard run == generation else { return }
            capabilities = []; updatedAt = nil; unavailable = true
            if RequestFailure.kind(of: error) == .authorizationLost { stop() }
        }
    }
}
