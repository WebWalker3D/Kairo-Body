import SwiftUI

/// Settings are appliance preferences plus a read-only identity panel. A
/// public build carries no personal provisioning, so fresh installs set
/// credentials once under Credential setup; a replacement install inherits
/// everything and these rows simply report what the device already holds.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                presenceSection
                voiceSection
                sensesSection
                displaySection
                provisioningSection
                aboutSection
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(KairoTheme.background)
            .onChange(of: model.settings.followEcho) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.invitationsEnabled) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.voiceWakeEnabled) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.sendLocation) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.allowRemoteCamera) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.cameraMode) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.keepAwake) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.dimWhenStill) { _, _ in model.settingsChanged() }
            .onChange(of: model.settings.screensaverMinutes) { _, _ in model.settingsChanged() }
        }
    }

    private var presenceSection: some View {
        Section("Presence") {
            Toggle("Follow the Dot", isOn: $model.settings.followEcho)
            Toggle("Show the shared conversation", isOn: $model.settings.echoTranscriptVisible)
            Toggle("Accept conversation invitations", isOn: $model.settings.invitationsEnabled)
            Text(followEchoCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Toggle("Wake on “Kairo”", isOn: $model.settings.voiceWakeEnabled)
            Text(model.voice.status).font(.caption).foregroundStyle(.secondary)
            if let heard = model.voice.lastCommand, !heard.isEmpty {
                Text("Last heard: \(heard)").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { model.voice.clearTranscript() }
                    .font(.caption)
            }
        }
    }

    private var sensesSection: some View {
        Section("Senses") {
            Toggle("Share location observations", isOn: $model.settings.sendLocation)
            Toggle("Allow remote front-camera captures", isOn: $model.settings.allowRemoteCamera)
            Toggle("Camera mode (live front view)", isOn: $model.settings.cameraMode)
            Text("The rear camera is always blocked by body policy. Motion video is never sent; captures are one-shot, resized ≤1280 px.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Keep the display awake", isOn: $model.settings.keepAwake)
            Toggle("Dim when still", isOn: $model.settings.dimWhenStill)
            Picker("Screensaver after stillness", selection: $model.settings.screensaverMinutes) {
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            .disabled(!model.settings.dimWhenStill)
            Text("Kairo's actual work — on any surface, including the Dot — keeps the screen alive. A bare heartbeat never does.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var provisioningSection: some View {
        Section("Provisioning") {
            LabeledContent("Deployment", value: AppConfig.agentOrigin.replacingOccurrences(of: "https://", with: ""))
            LabeledContent("Body endpoint", value: AppConfig.bodyID)
            LabeledContent("Dot", value: EchoBinding.endpointID)
            LabeledContent("Shared Echo session", value: echoSessionSummary)
            LabeledContent("Sensory credential", value: AppConfig.sensoryToken.isEmpty ? "missing" : "stored")
            LabeledContent("Agent credential", value: AppConfig.agentToken.isEmpty ? "missing" : "stored")
            LabeledContent("Owner pairing", value: pairingSummary)
            NavigationLink("Credential setup") { SetupView() }
            if !model.pairing.isPaired {
                NavigationLink("Pair this iPad") { model.destination = .privateRoom }
                    .tint(KairoTheme.bond)
            }
            Text("Public builds carry no personal provisioning: enter Kairo's credentials for this iPad once here. Replacing an installed body app keeps everything this device already stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
            LabeledContent("Body protocol", value: "kairo-body/1")
            Button("Reset shared conversation session", role: .destructive) {
                model.conversation.clearChat()
            }
        }
    }

    private var echoSessionSummary: String {
        EchoBinding.configuredSessionID.isEmpty
            ? "not configured — this iPad holds its own conversation"
            : EchoBinding.configuredSessionID
    }

    private var followEchoCaption: String {
        guard model.settings.followEcho else {
            return "Off: this iPad keeps its own separate conversation."
        }
        return EchoBinding.configuredSessionID.isEmpty
            ? "On — no shared Echo session is configured yet, so this iPad holds its own conversation until one is set under Credential setup."
            : "On: this iPad speaks inside the Dot's own conversation. Kairo's replies stay quiet here unless you choose “Speak here”."
    }

    private var pairingSummary: String {
        switch model.pairing.state {
        case .paired(let endpoint): return "paired · \(endpoint)"
        case .pairing: return "pairing…"
        case .failed: return "last attempt failed"
        case .unpaired: return "not paired"
        }
    }
}
