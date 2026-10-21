import SwiftUI

/// Settings are appliance preferences plus a read-only identity panel. A
/// public build carries no personal provisioning, so fresh installs set
/// credentials once under Credential setup; a replacement install inherits
/// everything and these rows simply report what the device already holds.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            SettingsForm(settings: model.settings, voice: model.voice, pairing: model.pairing)
                .navigationTitle("Settings")
                .scrollContentBackground(.hidden)
                .background(KairoTheme.background)
        }
    }
}

/// The toggles bind through observed objects (a `let` reference on the model
/// cannot carry `$model.settings.x`), and the change handlers live where the
/// observation does.
private struct SettingsForm: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var voice: VoiceInputService
    @ObservedObject var pairing: PairingClient
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            presenceSection
            voiceSection
            sensesSection
            displaySection
            provisioningSection
            aboutSection
        }
        .onChange(of: settings.followEcho) { _, _ in model.settingsChanged() }
        .onChange(of: settings.invitationsEnabled) { _, _ in model.settingsChanged() }
        .onChange(of: settings.voiceWakeEnabled) { _, _ in model.settingsChanged() }
        .onChange(of: settings.sendLocation) { _, _ in model.settingsChanged() }
        .onChange(of: settings.allowRemoteCamera) { _, _ in model.settingsChanged() }
        .onChange(of: settings.cameraMode) { _, _ in model.settingsChanged() }
        .onChange(of: settings.keepAwake) { _, _ in model.settingsChanged() }
        .onChange(of: settings.dimWhenStill) { _, _ in model.settingsChanged() }
        .onChange(of: settings.screensaverMinutes) { _, _ in model.settingsChanged() }
    }

    private var presenceSection: some View {
        Section("Presence") {
            Toggle("Follow the Dot", isOn: $settings.followEcho)
            Toggle("Show the shared conversation", isOn: $settings.echoTranscriptVisible)
            Toggle("Accept conversation invitations", isOn: $settings.invitationsEnabled)
            Text(followEchoCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Toggle("Wake on “Kairo”", isOn: $settings.voiceWakeEnabled)
            Text(voice.status).font(.caption).foregroundStyle(.secondary)
            if let heard = voice.lastCommand, !heard.isEmpty {
                Text("Last heard: \(heard)").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { voice.clearTranscript() }
                    .font(.caption)
            }
        }
    }

    private var sensesSection: some View {
        Section("Senses") {
            Toggle("Share location observations", isOn: $settings.sendLocation)
            Toggle("Allow remote front-camera captures", isOn: $settings.allowRemoteCamera)
            Toggle("Camera mode (live front view)", isOn: $settings.cameraMode)
            Text("The rear camera is always blocked by body policy. Motion video is never sent; captures are one-shot, resized ≤1280 px.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Toggle("Keep the display awake", isOn: $settings.keepAwake)
            Toggle("Dim when still", isOn: $settings.dimWhenStill)
            Picker("Screensaver after stillness", selection: $settings.screensaverMinutes) {
                Text("30 minutes").tag(30)
                Text("60 minutes").tag(60)
            }
            .disabled(!settings.dimWhenStill)
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
            if !pairing.isPaired {
                Button("Pair this iPad") { model.destination = .privateRoom }
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
        guard settings.followEcho else {
            return "Off: this iPad keeps its own separate conversation."
        }
        return EchoBinding.configuredSessionID.isEmpty
            ? "On — no shared Echo session is configured yet, so this iPad holds its own conversation until one is set under Credential setup."
            : "On: this iPad speaks inside the Dot's own conversation. Kairo's replies stay quiet here unless you choose “Speak here”."
    }

    private var pairingSummary: String {
        switch pairing.state {
        case .paired(let endpoint): return "paired · \(endpoint)"
        case .pairing: return "pairing…"
        case .failed: return "last attempt failed"
        case .unpaired: return "not paired"
        }
    }
}
