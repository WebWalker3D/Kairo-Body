import Foundation

/// One fixed Kairo deployment plus credentials that live in the Keychain.
/// Public CI builds carry no personal provisioning: tokens and the shared
/// Echo session id come from on-device setup. Replacing the previously
/// installed body app inherits the stored bearer, agent token and owner
/// pairing proof (same Keychain service/accounts) and the stored Echo
/// session (same UserDefaults key), so a replacement never shows setup.
enum AppConfig {
    // Connection identity is fixed by the deployment, never entered on device.
    // The paths are public-topology facts: connect.kairo.icu routes /api/* and
    // /ws/body to the agent API, but the sensory socket and pairing redemption
    // live in the memory service, which nginx exposes under the /memory/
    // prefix (prefix stripped). The previously installed body app connected to
    // wss://connect.kairo.icu/memory/v1/body/ws; the bare /v1/body/ws path
    // falls through to the agent API and is rejected with 401.
    static let agentOrigin = "https://connect.kairo.icu"
    static let bodySocketURL = "wss://connect.kairo.icu/memory/v1/body/ws"
    static let bodyPairingRedeemURL = "https://connect.kairo.icu/memory/v1/body/pairing/redeem"
    static let dotObserverURL = "wss://connect.kairo.icu/ws/body"
    static let bodyID = "ipad-pro-2017"

    // Keychain layout is identical to the previously installed body app so an
    // in-place replacement inherits its bearer, agent token and owner proof.
    static let keychainService = "icu.kairo.body"
    static let bearerAccount = "bearer-token"
    static let agentAccount = "agent-token"
    static let ownerService = "icu.kairo.body.owner"
    static let ownerAccount = "paired-owner-proof"

    static func infoValue(_ key: String) -> String {
        ((Bundle.main.infoDictionary?[key] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Optional local dev/personal-build override: Info.plist values seed the
    /// Keychain only when this device has none (a replacement install keeps
    /// its live pairing and tokens).
    static func provisionOnFirstLaunch() {
        KeychainStore.seed(infoValue("KairoSensoryToken"), service: keychainService, account: bearerAccount)
        KeychainStore.seed(infoValue("KairoAgentToken"), service: keychainService, account: agentAccount)
    }

    /// Everything the appliance can do requires the Agent token; the sensory
    /// bearer only adds the body socket and pairing. Public installs start
    /// unprovisioned and show setup until a token exists.
    static var hasMinimumProvisioning: Bool { !agentToken.isEmpty }

    static var sensoryToken: String {
        get { KeychainStore.read(service: keychainService, account: bearerAccount) ?? "" }
        set { KeychainStore.set(newValue, service: keychainService, account: bearerAccount) }
    }

    static var agentToken: String {
        get { KeychainStore.read(service: keychainService, account: agentAccount) ?? "" }
        set { KeychainStore.set(newValue, service: keychainService, account: agentAccount) }
    }

    static var ownerProof: String {
        KeychainStore.read(service: ownerService, account: ownerAccount) ?? ""
    }

    static func saveOwnerProof(_ value: String) throws {
        try KeychainStore.setChecked(value, service: ownerService, account: ownerAccount)
    }

    static func clearOwnerProof() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: ownerService,
                                    kSecAttrAccount as String: ownerAccount]
        SecItemDelete(query as CFDictionary)
    }

    /// The shared conversation session, entered at setup (same UserDefaults
    /// key the previous body app used, so replacements inherit it). Empty
    /// until configured; the app then holds its own separate conversation.
    static var echoSessionID: String {
        get {
            let saved = (UserDefaults.standard.string(forKey: "echoSessionID") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return saved.isEmpty ? infoValue("KairoEchoSessionID") : saved
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "echoSessionID")
        }
    }

    /// The physical Dot's endpoint. This identifier is a fixed part of
    /// Kairo's embodied deployment (it ships in every installed body app);
    /// an Info.plist override exists only for development experiments.
    static let echoEndpointID: String = {
        let configured = infoValue("KairoEchoEndpointID")
        return configured.isEmpty ? "echomuse-rs03qr" : configured
    }()
}

/// Device-local appliance preferences. Connection, credentials, endpoint and
/// session identity are deliberately absent: they are fixed by the build.
final class AppSettings: ObservableObject {
    private enum Keys {
        static let sendLocation = "sendLocation"
        static let allowRemoteCamera = "allowRemoteCamera"
        static let cameraMode = "cameraMode"
        static let keepAwake = "keepAwake"
        static let dimWhenStill = "dimWhenStill"
        static let screensaverMinutes = "screensaverMinutes"
        static let followEcho = "followEcho"
        static let invitationsEnabled = "invitationsEnabled"
        static let voiceWakeEnabled = "voiceWakeEnabled"
        static let echoTranscriptVisible = "echoTranscriptVisible"
        static let sharedSessionID = "sharedSessionID"
    }

    @Published var sendLocation: Bool { didSet { defaults.set(sendLocation, forKey: Keys.sendLocation) } }
    @Published var allowRemoteCamera: Bool { didSet { defaults.set(allowRemoteCamera, forKey: Keys.allowRemoteCamera) } }
    @Published var cameraMode: Bool { didSet { defaults.set(cameraMode, forKey: Keys.cameraMode) } }
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    @Published var dimWhenStill: Bool { didSet { defaults.set(dimWhenStill, forKey: Keys.dimWhenStill) } }
    @Published var screensaverMinutes: Int { didSet { defaults.set(screensaverMinutes, forKey: Keys.screensaverMinutes) } }
    @Published var followEcho: Bool { didSet { defaults.set(followEcho, forKey: Keys.followEcho) } }
    @Published var invitationsEnabled: Bool { didSet { defaults.set(invitationsEnabled, forKey: Keys.invitationsEnabled) } }
    @Published var voiceWakeEnabled: Bool { didSet { defaults.set(voiceWakeEnabled, forKey: Keys.voiceWakeEnabled) } }
    @Published var echoTranscriptVisible: Bool { didSet { defaults.set(echoTranscriptVisible, forKey: Keys.echoTranscriptVisible) } }
    /// The iPad's own shared conversation session. It is created once and
    /// reused; the Dot's configured session is never written from here.
    @Published var sharedSessionID: String { didSet { defaults.set(sharedSessionID, forKey: Keys.sharedSessionID) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sendLocation = defaults.object(forKey: Keys.sendLocation) as? Bool ?? true
        allowRemoteCamera = defaults.object(forKey: Keys.allowRemoteCamera) as? Bool ?? true
        cameraMode = defaults.object(forKey: Keys.cameraMode) as? Bool ?? false
        keepAwake = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true
        dimWhenStill = defaults.object(forKey: Keys.dimWhenStill) as? Bool ?? true
        let saved = defaults.object(forKey: Keys.screensaverMinutes) as? Int ?? 30
        screensaverMinutes = [30, 60].contains(saved) ? saved : 30
        followEcho = defaults.object(forKey: Keys.followEcho) as? Bool ?? true
        invitationsEnabled = defaults.object(forKey: Keys.invitationsEnabled) as? Bool ?? false
        voiceWakeEnabled = defaults.object(forKey: Keys.voiceWakeEnabled) as? Bool ?? false
        echoTranscriptVisible = defaults.object(forKey: Keys.echoTranscriptVisible) as? Bool ?? true
        sharedSessionID = defaults.string(forKey: Keys.sharedSessionID) ?? ""
    }
}
