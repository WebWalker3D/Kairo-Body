import Foundation

struct PendingApproval: Equatable {
    let observationID = UUID()
    let jobID: String
    let requestID: Int
    let description: String
    let scope: String
    let truncated: Bool
}

/// Explicit once-only owner decisions. The observer itself uses agent authentication.
@MainActor
final class ApprovalClient: ObservableObject {
    @Published private(set) var approval: PendingApproval?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var status = ""
    private let ownerProof: () -> String
    private let now: () -> Date
    private let request: (String, String, [String: Any]?) async throws -> [String: Any]

    init(ownerProof: @escaping () -> String = { AppConfig.ownerProof },
         now: @escaping () -> Date = Date.init,
         request: @escaping (String, String, [String: Any]?) async throws -> [String: Any] = { path, method, body in
             try await KairoHTTP().agentObject(path, method: method, body: body, timeout: 12)
         }) {
        self.ownerProof = ownerProof; self.now = now; self.request = request
    }

    func refresh(jobID: String) async {}
    func stop() {}
    func decide(_ item: PendingApproval, allow: Bool) async {}
}
