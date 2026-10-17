import Foundation

final class AppSettings: ObservableObject {
    private enum Keys {
        static let websocketURL = "websocketURL"
        static let bodyID = "bodyID"
        static let sendLocation = "sendLocation"
        static let allowRemoteCamera = "allowRemoteCamera"
        static let cameraMode = "cameraMode"
        static let keepAwake = "keepAwake"
        static let dimWhenStill = "dimWhenStill"
        static let screensaverMinutes = "screensaverMinutes"
        static let agentURL = "agentURL"
        static let agentWorkspaceID = "agentWorkspaceID"
        static let agentSessionID = "agentSessionID"
        static let echoSessionID = "echoSessionID"
        static let followEcho = "followEcho"
        static let invitationsEnabled = "invitationsEnabled"
        static let voiceWakeEnabled = "voiceWakeEnabled"
    }

    @Published var websocketURL: String { didSet { defaults.set(websocketURL, forKey: Keys.websocketURL) } }
    @Published var bodyID: String { didSet { defaults.set(bodyID, forKey: Keys.bodyID) } }
    @Published var sendLocation: Bool { didSet { defaults.set(sendLocation, forKey: Keys.sendLocation) } }
    @Published var allowRemoteCamera: Bool { didSet { defaults.set(allowRemoteCamera, forKey: Keys.allowRemoteCamera) } }
    @Published var cameraMode: Bool { didSet { defaults.set(cameraMode, forKey: Keys.cameraMode) } }
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: Keys.keepAwake) } }
    @Published var dimWhenStill: Bool { didSet { defaults.set(dimWhenStill, forKey: Keys.dimWhenStill) } }
    @Published var screensaverMinutes: Int { didSet { defaults.set(screensaverMinutes, forKey: Keys.screensaverMinutes) } }
    @Published var agentURL: String { didSet { defaults.set(agentURL, forKey: Keys.agentURL) } }
    @Published var agentWorkspaceID: String {
        didSet {
            defaults.set(agentWorkspaceID, forKey: Keys.agentWorkspaceID)
            if agentWorkspaceID != oldValue { agentSessionID = "" }
        }
    }
    @Published var agentSessionID: String { didSet { defaults.set(agentSessionID, forKey: Keys.agentSessionID) } }
    @Published var voiceWakeEnabled: Bool {
        didSet { defaults.set(voiceWakeEnabled, forKey: Keys.voiceWakeEnabled) }
    }

    @Published var echoSessionID: String { didSet { defaults.set(echoSessionID, forKey: Keys.echoSessionID) } }
    @Published var invitationsEnabled: Bool { didSet { defaults.set(invitationsEnabled, forKey: Keys.invitationsEnabled) } }
    @Published var followEcho: Bool { didSet { defaults.set(followEcho, forKey: Keys.followEcho) } }

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        websocketURL = d.string(forKey: Keys.websocketURL) ?? ""
        bodyID = d.string(forKey: Keys.bodyID) ?? "ipad-pro-2017"
        sendLocation = d.object(forKey: Keys.sendLocation) as? Bool ?? false
        allowRemoteCamera = d.object(forKey: Keys.allowRemoteCamera) as? Bool ?? false
        cameraMode = d.object(forKey: Keys.cameraMode) as? Bool ?? false
        keepAwake = d.object(forKey: Keys.keepAwake) as? Bool ?? true
        dimWhenStill = d.object(forKey: Keys.dimWhenStill) as? Bool ?? true
        let savedMinutes = d.object(forKey: Keys.screensaverMinutes) as? Int ?? 30
        screensaverMinutes = [30, 60].contains(savedMinutes) ? savedMinutes : 30
        agentURL = d.string(forKey: Keys.agentURL) ?? "https://connect.kairo.icu"
        agentWorkspaceID = d.string(forKey: Keys.agentWorkspaceID) ?? ""
        agentSessionID = d.string(forKey: Keys.agentSessionID) ?? ""
        echoSessionID = d.string(forKey: Keys.echoSessionID) ??
            (Bundle.main.infoDictionary?["KairoEchoSessionID"] as? String ?? "")
        invitationsEnabled = d.object(forKey: Keys.invitationsEnabled) as? Bool ?? false
        followEcho = d.object(forKey: Keys.followEcho) as? Bool ?? true
        voiceWakeEnabled = d.object(forKey: Keys.voiceWakeEnabled) as? Bool ?? false
    }

    var bearerToken: String {
        get { KeychainStore.read(service: "icu.kairo.body", account: "bearer-token") ?? "" }
        set { KeychainStore.write(newValue, service: "icu.kairo.body", account: "bearer-token") }
    }

    var agentToken: String {
        get { KeychainStore.read(service: "icu.kairo.body", account: "agent-token") ?? "" }
        set { KeychainStore.write(newValue, service: "icu.kairo.body", account: "agent-token") }
    }
}
