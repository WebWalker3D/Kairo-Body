import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanningAgentToken = false
    @State private var showingOwnerPairing = false
    @State private var agentTokenImported = false

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Foreground invitations from Kairo", isOn: $model.settings.invitationsEnabled)
                Section("Kairo server") {
                    TextField("wss://host.example/api/body/v1/ws", text: $model.settings.websocketURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Body ID", text: $model.settings.bodyID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token", text: $model.tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Conversation") {
                    TextField("Agent URL", text: $model.settings.agentURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Agent API token", text: $model.agentTokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Scan Agent token QR") {
                        Task {
                            await model.client.suspendFrontMotion()
                            scanningAgentToken = true
                        }
                    }
                    if agentTokenImported {
                        Text("Agent token imported into Keychain")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                    TextField("Workspace ID (optional if only one)", text: $model.settings.agentWorkspaceID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Uses Kairo's existing Agent Platform conversation. The agent token is stored in Keychain and is separate from the body bearer token.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Listen for “Kairo”", isOn: $model.settings.voiceWakeEnabled)
                    Text("While the app is open, saying “Kairo” followed by a request sends recognized text through this conversation. Listening pauses while Kairo responds. Speech recognition may use Apple's service if this iPad cannot recognize speech on device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Echo Dot") {
                    Toggle("Follow Dot playback", isOn: $model.settings.followEcho)
                    TextField("Shared Echo session ID", text: $model.settings.echoSessionID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("All conversations appear while this paired iPad is open. This setting controls Dot playback activity and replay. Dot replies play on the Dot; replay uses its recent response and creates no new conversation turn.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Owner-private access") {
                    Button("Pair iPad and open private conversation") { showingOwnerPairing = true }
                }
                Section("Body permissions") {
                    Toggle("Send location", isOn: $model.settings.sendLocation)
                        .onChange(of: model.settings.sendLocation) { _, enabled in
                            model.sensors.setLocationEnabled(enabled)
                            Task { await model.client.sendCapabilities() }
                        }
                    Toggle("Allow remote camera capture", isOn: $model.settings.allowRemoteCamera)
                        .onChange(of: model.settings.allowRemoteCamera) { _, _ in
                            Task { await model.client.sendCapabilities() }
                        }
                    Toggle("Camera Mode · front preview", isOn: $model.settings.cameraMode)
                        .onChange(of: model.settings.cameraMode) { _, _ in
                            model.client.updateMotionDimming()
                        }
                    Toggle("Keep display awake while body is running", isOn: $model.settings.keepAwake)
                    Toggle("Screen saver when still", isOn: $model.settings.dimWhenStill)
                    Picker("Screen off after", selection: $model.settings.screensaverMinutes) {
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .disabled(!model.settings.dimWhenStill)
                    Text("Camera Mode shows a local front-camera preview beside Kairo. After one idle minute, show the dark clock and presence graphic; then set brightness to zero. The idle timer restarts after Kairo finishes responding. Front camera motion stays on this iPad. Moving the iPad or touching the screen wakes it. The app remains open and unlocked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Senses and readiness") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let facts = model.sensors.capabilities(settings: model.settings)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Front camera: \(facts.cameraPermission)")
                            Text("Rear camera: blocked by body")
                            Text("Location permission: \(facts.locationPermission)")
                            Text("Latest local location: \(facts.locationObservedAt ?? "no fix")")
                            if let confirmed = model.client.capabilitiesConfirmedAt,
                               context.date.timeIntervalSince(confirmed) < 45 {
                                Text("Server confirmed readiness \(Int(context.date.timeIntervalSince(confirmed)))s ago")
                            } else {
                                Text("Server readiness confirmation unavailable")
                            }
                        }.font(.footnote)
                    }
                    Text("Permission and readiness do not establish a fresh observation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("MVP behavior") {
                    LabeledContent("Frame cadence", value: "about 17 seconds")
                    LabeledContent("Protocol", value: "kairo-body/1")
                    Text("Location and remote camera are intentionally opt-in. The app stays foregrounded for the MVP; no background sensor mode is requested.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Kairo Body")
            .fullScreenCover(isPresented: $scanningAgentToken, onDismiss: {
                model.client.resumeFrontMotion()
            }) {
                ZStack(alignment: .topTrailing) {
                    AgentTokenQRScanner { token in
                        model.agentTokenDraft = token
                        model.saveToken()
                        agentTokenImported = true
                        scanningAgentToken = false
                    }
                    Button("Cancel") { scanningAgentToken = false }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingOwnerPairing) { OwnerPairingView(client: model.privateBody) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveToken()
                        model.client.updateMotionDimming()
                        dismiss()
                    }
                }
            }
        }
    }
}
