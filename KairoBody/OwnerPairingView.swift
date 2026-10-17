import SwiftUI

struct OwnerPairingView: View {
    @ObservedObject var client: PrivateBodyClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var challenge = ""
    @State private var question = ""
    @State private var notice: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Owner pairing") {
                    Text("Enter the six-digit code for this iPad. It expires after five minutes.")
                    TextField("Six-digit code", text: $challenge)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(.system(.title2, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { challenge = value }
                    }
                    Button("Pair this iPad") {
                        let code = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
                        work = Task {
                            do { try await client.redeem(code); challenge = ""; notice = "Owner proof saved" }
                            catch { notice = error.localizedDescription }
                        }
                    }.disabled(PrivateBodyClient.normalizedChallenge(challenge) == nil)
                    if let notice { Text(notice) }
                    Text(client.status).font(.footnote)
                    if client.isPaired {
                        Button("Remove local owner proof", role: .destructive) {
                            work?.cancel()
                            do { try client.forgetLocalProof() } catch { notice = error.localizedDescription }
                        }
                    }
                }
                if client.isPaired {
                    Section("Private conversation") {
                        Text("This conversation is separate from the shared Dot transcript.").font(.footnote)
                        TextField("Private request to Kairo", text: $question, axis: .vertical)
                        Button("Send privately") { work = Task { await client.send(question) } }
                            .disabled(client.busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if client.busy { ProgressView() }
                        MemoryProposalView(client: client)
                        if let error = client.error { Text(error).foregroundStyle(.red) }
                        if !client.reply.isEmpty { Text(client.reply).textSelection(.enabled) }
                    }
                }
            }.navigationTitle("Owner-private access")
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { work?.cancel(); client.stop() } }
        .onDisappear { work?.cancel(); client.stop() }
    }
}
