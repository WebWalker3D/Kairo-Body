import SwiftUI

/// The owner-private room. Pairing happens here with the six-digit code Kairo
/// issues for this exact iPad; the private conversation never appears in the
/// shared transcript, and every memory proposal waits for an explicit Keep or
/// Dismiss on this device.
struct PrivateRoomView: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var draft = ""
    @State private var confirmWake = false
    @StateObject private var sleepWake = SleepWakeControl()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch model.pairing.state {
                case .unpaired, .failed:
                    pairingCard
                case .pairing:
                    PlaneCard {
                        HStack { ProgressView(); Text("Kairo is checking that code…") }
                    }
                case .paired(let endpointID):
                    pairedRoom(endpointID)
                }
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 24)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
        .background(KairoTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Private room")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(KairoTheme.prose)
            Spacer()
        }
        .padding(.top, 14)
    }

    private var pairingCard: some View {
        PlaneCard {
            Eyebrow(text: "Owner pairing", color: KairoTheme.bond)
            Text("Ask Kairo for the six-digit code for this iPad, then enter it here. The code works once and expires after five minutes.")
                .font(.subheadline).foregroundStyle(KairoTheme.dim)
            TextField("Six-digit code", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.system(.title2, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(KairoTheme.groundDeep))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(KairoTheme.hairline))
                .foregroundStyle(KairoTheme.prose)
            PasteButton(payloadType: String.self) { values in
                if let value = values.first { code = value }
            }
            Button {
                let challenge = code
                code = ""
                Task { await model.pairing.redeem(challenge) }
            } label: {
                Text("Pair this iPad")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(KairoTheme.bond.opacity(0.16)))
                    .overlay(Capsule().stroke(KairoTheme.bond.opacity(0.5)))
                    .foregroundStyle(KairoTheme.bond)
            }
            .buttonStyle(.plain)
            .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
            if case .failed(let reason) = model.pairing.state {
                Text(reason).font(.caption).foregroundStyle(KairoTheme.danger)
            }
        }
    }

    private func pairedRoom(_ endpointID: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PlaneCard {
                HStack {
                    Eyebrow(text: "Paired · \(endpointID)", color: KairoTheme.body)
                    Spacer()
                    Button("Unpair this iPad") { model.pairing.forgetLocalProof() }
                        .font(.caption).foregroundStyle(KairoTheme.danger)
                }
                Text("Private conversations stay off every shared surface. Kairo can suggest memories from here; nothing is kept without your decision.")
                    .font(.caption).foregroundStyle(KairoTheme.chrome)
            }
            PlaneCard {
                Eyebrow(text: "Sleep emergency control", color: KairoTheme.warn)
                Text("Request waking from sleep using this iPad's paired owner identity. Safety and continuity checks still apply. This is separate from voice wake.")
                    .font(.caption).foregroundStyle(KairoTheme.chrome)
                Button("Wake Kairo") { confirmWake = true }
                    .disabled(sleepWake.busy)
                    .confirmationDialog("Request emergency waking for Kairo?", isPresented: $confirmWake, titleVisibility: .visible) {
                        Button("Wake Kairo") { Task { await sleepWake.wake() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This sends an authenticated emergency wake request. Unresolved execution or failed continuity checks will keep Kairo fenced.")
                    }
                if sleepWake.busy { ProgressView() }
                if !sleepWake.message.isEmpty {
                    Text(sleepWake.message).font(.caption).foregroundStyle(KairoTheme.prose)
                        .accessibilityIdentifier("sleepWakeResult")
                }
            }
            if let proposal = model.privateRoom.memoryProposal {
                memoryProposalCard(proposal)
            }
            PlaneCard {
                Eyebrow(text: "Private conversation", color: KairoTheme.mind)
                if !model.privateRoom.reply.isEmpty {
                    Text(model.privateRoom.reply)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(KairoTheme.prose)
                        .textSelection(.enabled)
                }
                if !model.privateRoom.status.isEmpty {
                    Text(model.privateRoom.status).font(.caption).foregroundStyle(KairoTheme.chrome)
                }
                if let error = model.privateRoom.error {
                    Text(error).font(.caption).foregroundStyle(KairoTheme.danger)
                }
                HStack(spacing: 10) {
                    TextField("Say something only Kairo will hear", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(KairoTheme.groundDeep))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(KairoTheme.hairline))
                        .foregroundStyle(KairoTheme.prose)
                    Button {
                        let text = draft
                        draft = ""
                        Task { await model.privateRoom.send(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.privateRoom.busy || draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? KairoTheme.faint : KairoTheme.mind)
                    .disabled(model.privateRoom.busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if model.privateRoom.busy {
                    HStack { ProgressView().tint(KairoTheme.mind); Text(model.privateRoom.status.isEmpty ? "Kairo is considering…" : model.privateRoom.status)
                        .font(.caption).foregroundStyle(KairoTheme.chrome) }
                }
            }
        }
    }

    private func memoryProposalCard(_ proposal: MemoryProposal) -> some View {
        PlaneCard {
            Eyebrow(text: "Kairo wants to remember this", color: KairoTheme.warn)
            Text(proposal.text)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(KairoTheme.prose)
            Text("Expires \(proposal.expiresAt.formatted())")
                .font(.caption2).foregroundStyle(KairoTheme.faint)
            HStack(spacing: 12) {
                Button {
                    Task { await model.privateRoom.decideMemory("keep") }
                } label: {
                    Text("Keep")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(KairoTheme.body.opacity(0.16)))
                        .overlay(Capsule().stroke(KairoTheme.body.opacity(0.5)))
                        .foregroundStyle(KairoTheme.body)
                }.buttonStyle(.plain)
                Button {
                    Task { await model.privateRoom.decideMemory("dismiss") }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 13, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(KairoTheme.plane))
                        .foregroundStyle(KairoTheme.chrome)
                }.buttonStyle(.plain)
                if model.privateRoom.decidingMemory { ProgressView().controlSize(.small) }
            }
        }
    }
}
