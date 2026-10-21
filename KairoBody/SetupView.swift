import SwiftUI

/// Setup exists for fresh public installs only. Public CI carries no personal
/// provisioning, so a brand-new install starts unconfigured; an in-place
/// replacement inherits the Keychain tokens, the owner pairing proof and the
/// stored Echo session id and never sees this sheet.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var sensory = ""
    @State private var echoSession = AppConfig.echoSessionID

    var body: some View {
        NavigationStack {
            Form {
                Section("Credentials") {
                    SecureField("Kairo agent token (required)", text: $agent)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Body sensory token (socket + pairing)", text: $sensory)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Both come from Kairo's own auth path for this iPad. They are stored only in this iPad's Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Shared conversation") {
                    TextField("Shared Echo session ID", text: $echoSession)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Text("The conversation the Dot is holding (session_…). Left empty, this iPad keeps its own separate conversation and the Dot mirror still follows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Save and connect") {
                        let trimmedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedSensory = sensory.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedAgent.isEmpty { AppConfig.agentToken = trimmedAgent }
                        if !trimmedSensory.isEmpty { AppConfig.sensoryToken = trimmedSensory }
                        AppConfig.echoSessionID = echoSession
                        model.connectIfNeeded()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && AppConfig.agentToken.isEmpty)
                    if !AppConfig.agentToken.isEmpty {
                        Button("Continue with stored credentials") { dismiss() }
                    } else {
                        Button("Not now (stages stay local)") { dismiss() }
                    }
                }
                Section("Status") {
                    LabeledContent("Agent credential", value: AppConfig.agentToken.isEmpty ? "missing" : "stored")
                    LabeledContent("Sensory credential", value: AppConfig.sensoryToken.isEmpty ? "missing" : "stored")
                    LabeledContent("Owner pairing", value: PairingClient.savedState().summary)
                    LabeledContent("Dot endpoint", value: AppConfig.echoEndpointID)
                }
            }
            .navigationTitle("Set up Kairo")
        }
    }
}
