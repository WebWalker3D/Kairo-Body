import Foundation

/// Pairing: the six-digit code for this exact iPad endpoint redeems once for a
/// durable owner proof. The code is endpoint-scoped and single-use; the proof
/// is what authorizes private sessions, the shared transcript, presentation
/// and surface delivery. The sensory bearer never carries owner scope itself.
@MainActor
final class PairingClient: ObservableObject {
    enum State: Equatable {
        case unpaired
        case pairing
        case paired(endpointID: String)
        case failed(String)

        var summary: String {
            switch self {
            case .unpaired: return "not paired"
            case .pairing: return "pairing…"
            case .paired(let endpoint): return "paired · \(endpoint)"
            case .failed: return "last attempt failed"
            }
        }
    }

    @Published private(set) var state: State
    private var redeemTask: Task<Void, Never>?
    /// Bumped whenever an attempt is replaced or forgotten, so a late network
    /// result from the old attempt can never overwrite the current state.
    private var pairingGeneration = 0

    private let defaults: UserDefaults
    private let sensoryAvailable: () -> Bool
    private let saveProof: (String) throws -> Void
    private let clearProof: () throws -> Void
    private let request: (String) async throws -> [String: Any]

    init(defaults: UserDefaults = .standard,
         readProof: () -> String = { AppConfig.ownerProof },
         sensoryAvailable: @escaping () -> Bool = { !AppConfig.sensoryToken.isEmpty },
         saveProof: @escaping (String) throws -> Void = { try AppConfig.saveOwnerProof($0) },
         clearProof: @escaping () throws -> Void = { try AppConfig.clearOwnerProof() },
         request: @escaping (String) async throws -> [String: Any] = { challenge in
             try await KairoHTTP().sensory(url: URL(string: AppConfig.bodyPairingRedeemURL)!,
                                           body: ["challenge": challenge])
         }) {
        self.defaults = defaults
        self.sensoryAvailable = sensoryAvailable
        self.saveProof = saveProof
        self.clearProof = clearProof
        self.request = request
        state = Self.validCredential(readProof())
            ? .paired(endpointID: defaults.string(forKey: "pairedEndpointID") ?? "this iPad") : .unpaired
    }

    static func savedState() -> State {
        guard let proof = KeychainStore.read(service: AppConfig.ownerService,
                                             account: AppConfig.ownerAccount),
              validCredential(proof) else { return .unpaired }
        let endpoint = UserDefaults.standard.string(forKey: "pairedEndpointID") ?? "this iPad"
        return .paired(endpointID: endpoint)
    }

    static func validCredential(_ value: String) -> Bool {
        value.hasPrefix("kbp_") && (36...160).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func normalizedChallenge(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter { !$0.isWhitespace && $0 != "-" }
        if digits.count == 6 && digits.allSatisfy({ $0.isASCII && $0.isNumber }) { return digits }
        return nil
    }

    var isPaired: Bool {
        if case .paired = state { return true }
        return false
    }

    func redeem(_ challenge: String) async {
        guard let challenge = Self.normalizedChallenge(challenge) else {
            state = .failed("Enter the six-digit code from Kairo's pairing request."); return
        }
        guard sensoryAvailable() else {
            state = .failed("This copy of Kairo has no body credential."); return
        }
        redeemTask?.cancel()
        pairingGeneration += 1
        state = .pairing
        let attempt = pairingGeneration
        redeemTask = Task { [weak self] in
            do {
                guard let self else { return }
                let data = try await self.request(challenge)
                guard let credential = data["credential"] as? String, Self.validCredential(credential),
                      let endpoint = data["endpoint_id"] as? String, !endpoint.isEmpty else {
                    throw MalformedResponse()
                }
                try self.saveProof(credential)
                guard attempt == self.pairingGeneration, !Task.isCancelled else { return }
                self.defaults.set(endpoint, forKey: "pairedEndpointID")
                self.state = .paired(endpointID: endpoint)
            } catch {
                // A replaced or forgotten attempt must never land a stale state.
                guard let self, attempt == self.pairingGeneration,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                let kind = RequestFailure.kind(of: error)
                let message: String
                switch kind {
                case .authorizationLost: message = "That code is not valid for this iPad, or it has expired."
                case .transient: message = "Kairo could not be reached. Try the code again."
                case .rejected: message = "Kairo refused this pairing request."
                }
                self.state = .failed(message)
            }
        }
    }

    func forgetLocalProof() {
        redeemTask?.cancel()
        pairingGeneration += 1
        do { try clearProof() } catch {}
        defaults.removeObject(forKey: "pairedEndpointID")
        state = .unpaired
    }
}
