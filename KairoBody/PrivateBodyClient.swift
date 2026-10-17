import Foundation

@MainActor
final class PrivateBodyClient: ObservableObject {
    @Published private(set) var privateSessionID: String?
    @Published private(set) var isPaired: Bool
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var reply = ""
    @Published private(set) var busy = false
    @Published private(set) var memoryProposal: MemoryProposal?
    @Published private(set) var decidingMemory = false
    private var currentJobID: String?
    private let settings: AppSettings
    private let session: URLSession
    private let readCredential: () -> String
    private let writeCredential: (String) throws -> Void
    private var generation = UUID()
    private static let service = "icu.kairo.body.owner"
    private static let account = "paired-owner-proof"

    static func ownerCredential() -> String { KeychainStore.read(service: service, account: account) ?? "" }

    init(settings: AppSettings, session: URLSession = .shared,
         readCredential: (() -> String)? = nil, writeCredential: ((String) throws -> Void)? = nil) {
        self.settings = settings
        self.session = session
        self.readCredential = readCredential ?? { KeychainStore.read(service: Self.service, account: Self.account) ?? "" }
        self.writeCredential = writeCredential ?? { try KeychainStore.writeChecked($0, service: Self.service, account: Self.account) }
        isPaired = Self.validCredential(self.readCredential())
    }
    static func validCredential(_ value: String) -> Bool {
        value.hasPrefix("kbp_") && (36...160).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    static func normalizedChallenge(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { !$0.isWhitespace && $0 != "-" }
        if digits.count == 6 && digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return digits }
        // Keep pasted pre-update operator challenges compatible during rollout.
        if trimmed.hasPrefix("kbc_"), (36...160).contains(trimmed.count),
           trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return trimmed
        }
        return nil
    }
    func redeem(_ challenge: String) async throws {
        guard let challenge = Self.normalizedChallenge(challenge),
              !settings.bearerToken.isEmpty,
              var url = URL(string: settings.websocketURL), url.host == "connect.kairo.icu",
              url.path.hasSuffix("/ws"), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PrivateBodyError.unpaired
        }
        components.scheme = "https"
        guard let https = components.url else { throw PrivateBodyError.invalidResponse }
        url = https.deletingLastPathComponent().appendingPathComponent("pairing").appendingPathComponent("redeem")
        let data = try await perform(url, bearer: settings.bearerToken, body: ["challenge": challenge], ownerProof: nil)
        guard let credential = data["credential"] as? String, Self.validCredential(credential),
              let endpoint = data["endpoint_id"] as? String, !endpoint.isEmpty else { throw PrivateBodyError.invalidResponse }
        try writeCredential(credential)
        guard readCredential() == credential else { throw PrivateBodyError.keychainFailed }
        generation = UUID()
        privateSessionID = nil
        isPaired = true
        status = "Owner proof saved. Private access is checked by the server."
    }
    func openSession() async throws -> String {
        guard !settings.agentToken.isEmpty, Self.validCredential(readCredential()) else { throw PrivateBodyError.unpaired }
        let run = generation
        let opened = try await request("api/ipad/private/session", body: settings.agentWorkspaceID.isEmpty ? [:] : ["workspace_id": settings.agentWorkspaceID])
        guard generation == run, let id = opened["id"] as? String, !id.isEmpty,
              id != settings.echoSessionID,
              (opened["metadata_json"] as? [String: Any])?["client"] as? String == "ipad_private" else {
            throw PrivateBodyError.invalidResponse
        }
        privateSessionID = id
        return id
    }
    func forgetLocalProof() throws {
        try writeCredential("")
        generation = UUID(); privateSessionID = nil; isPaired = false
        reply = ""; memoryProposal = nil; currentJobID = nil; error = nil; status = "Local owner proof removed"
    }
    func stop() { generation = UUID(); busy = false; reply = ""; memoryProposal = nil; currentJobID = nil; decidingMemory = false }
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, trimmed.count <= 4_000 else { return }
        busy = true; error = nil
        let run = generation
        defer { if generation == run { busy = false } }
        do {
            let id: String
            if let current = privateSessionID { id = current } else { id = try await openSession() }
            guard generation == run else { return }
            let job = try await request("api/sessions/\(id)/jobs", body: ["prompt": trimmed,
                "idempotency_key": "ipad-private:\(UUID().uuidString.lowercased())", "metadata": ["client": "ipad_private", "source": "ipad_private"]])
            guard let jobID = job["id"] as? String else { throw PrivateBodyError.invalidResponse }
            currentJobID = jobID
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard generation == run else { return }
                let current = try await request("api/jobs/\(jobID)?compact=1")
                if current["status"] as? String == "waiting_permission" {
                    let pending = try await request("api/jobs/\(jobID)/ipad-memory")
                    guard generation == run else { return }
                    memoryProposal = (pending["proposals"] as? [[String: Any]])?.compactMap(MemoryProposal.init(json:)).first
                }
                if current["settled_status"] as? String == "completed", let answer = current["settled_text"] as? String {
                    memoryProposal = nil; currentJobID = nil
                    reply = answer; status = "Private reply"; return
                }
                if let terminal = current["settled_status"] as? String { throw PrivateBodyError.server(terminal) }
                status = "Kairo is considering your private request…"
                try await Task.sleep(for: .seconds(2))
            }
            throw PrivateBodyError.server("Private reply is still pending")
        } catch { if generation == run { self.error = error.localizedDescription } }
    }
    func decideMemory(_ decision: String) async {
        guard !decidingMemory, let proposal = memoryProposal, let jobID = currentJobID,
              proposal.expiresAt > Date(), decision == "keep" || decision == "dismiss" else { return }
        let run = generation
        decidingMemory = true
        defer { if generation == run { decidingMemory = false } }
        do {
            let result = try await request("api/jobs/\(jobID)/ipad-memory", body: [
                "approval_id": proposal.id, "proposal_hash": proposal.hash, "decision": decision])
            guard generation == run else { return }
            guard result["accepted"] as? Bool == true else { throw PrivateBodyError.invalidResponse }
            memoryProposal = nil
            status = decision == "keep" ? "Permission given. Kairo still chooses whether to adopt." : "Proposal dismissed."
        } catch { if generation == run { self.error = error.localizedDescription } }
    }

    func fetchPresentation() async -> GlobalBodyPresentation? {
        let run = generation
        let proof = readCredential()
        guard Self.validCredential(proof) else { return nil }
        do {
            let object = try await request("api/ipad/presentation", timeout: 8)
            guard !Task.isCancelled, generation == run, readCredential() == proof else { return nil }
            return GlobalBodyPresentation(object: object)
        } catch { return nil }
    }

    func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard Self.validCredential(readCredential()), let base = URL(string: settings.agentURL),
              base.scheme == "https", base.host == "connect.kairo.icu", base.user == nil,
              base.password == nil, base.path.isEmpty || base.path == "/" else { throw PrivateBodyError.unpaired }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base
        for piece in parts[0].split(separator: "/") { url.appendPathComponent(String(piece)) }
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = parts[1]
            guard let queryURL = components.url else { throw PrivateBodyError.invalidResponse }
            url = queryURL
        }
        return try await perform(url, bearer: settings.agentToken, body: body, ownerProof: readCredential(), timeout: timeout)
    }
    private func perform(_ url: URL, bearer: String, body: [String: Any]?, ownerProof: String?, timeout: TimeInterval = 30) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let ownerProof { request.setValue(ownerProof, forHTTPHeaderField: "X-Kairo-Device") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.data(for: request)
        guard bytes.count <= 256_000, let http = response as? HTTPURLResponse else { throw PrivateBodyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { privateSessionID = nil; status = "Owner proof unavailable or revoked" }
            throw PrivateBodyError.server("Private access failed (\(http.statusCode))")
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PrivateBodyError.invalidResponse }
        return object
    }
}

enum PrivateBodyError: LocalizedError {
    case unpaired, invalidResponse, keychainFailed, server(String)
    var errorDescription: String? {
        switch self {
        case .unpaired: return "Pair this iPad with an owner code before opening private access."
        case .invalidResponse: return "Private pairing returned an invalid response."
        case .keychainFailed: return "Could not save the owner proof securely."
        case .server(let reason): return reason
        }
    }
}
