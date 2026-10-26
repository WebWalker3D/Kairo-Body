import SwiftUI

/// The shared conversation across every Kairo surface — the Dot's turns,
/// Discord, the phone, this iPad — from the owner-scoped feed. Replying here
/// writes into the same conversation Kairo is holding with the Dot.
struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""
    @State private var destination = ConversationClient.OutputDestination.automatic
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if let trouble = model.feed.connectionTrouble {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(KairoTheme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(KairoTheme.warn.opacity(0.08))
            }
            if let recovery = model.conversation.pendingRecovery {
                recoveryBanner(recovery)
            }
            if model.settings.echoTranscriptVisible {
                turnsList
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash").font(.title2)
                    Text("Shared conversation hidden")
                    Text("You can show it again in Settings.").font(.caption)
                }
                .foregroundStyle(KairoTheme.chrome)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let invitation = model.invitations.invitation {
                InvitationCard(invitation: invitation)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
            composer
        }
        .padding(.bottom, 84)
        .background(KairoTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Conversations")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(KairoTheme.prose)
            if model.feed.following { StatusChip(label: "LIVE", color: KairoTheme.body) }
            if model.feed.processing { StatusChip(label: "KAIRO WORKING", color: KairoTheme.mind) }
            Spacer()
            if model.echo.state.canReplay() {
                Button { model.echo.requestReplay() } label: {
                    Label("Replay Dot", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }.buttonStyle(.plain).foregroundStyle(KairoTheme.primary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func recoveryBanner(_ recovery: ConversationClient.PendingRecovery) -> some View {
        HStack(spacing: 10) {
            switch recovery {
            case .unconfirmed:
                Text("Kairo may not have received your last message. It is safe to send it again.")
            case .stillWorking(let jobID):
                Text("Your message is still in Kairo's hands (\(jobID.prefix(18))…). Its answer will appear here.")
            }
            Spacer()
            Button("Dismiss") { model.conversation.clearRecoveredTurn() }
                .font(.caption).foregroundStyle(KairoTheme.chrome)
        }
        .font(.caption)
        .foregroundStyle(KairoTheme.warn)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(KairoTheme.warn.opacity(0.08))
    }

    private var turnsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.feed.turns) { turn in
                        TurnCard(turn: turn)
                            .id(turn.id)
                    }
                    if model.feed.turns.isEmpty {
                        Text(model.feed.following
                             ? "Kairo's conversation across the Dot, Discord and this iPad will appear here."
                             : "Owner pairing brings the shared conversation onto this iPad.")
                            .font(.subheadline)
                            .foregroundStyle(KairoTheme.faint)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.feed.turns.count) { _, count in
                if let last = model.feed.turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                _ = count
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if model.conversation.isSending {
                HStack(spacing: 10) {
                    ProgressView().tint(KairoTheme.primary)
                    if let progress = model.conversation.promptProgress {
                        Text("Kairo is reading \(progress.processed) of \(progress.total ?? 0) tokens…")
                            .font(.caption).foregroundStyle(KairoTheme.chrome)
                    } else {
                        Text(model.conversation.status).font(.caption).foregroundStyle(KairoTheme.chrome)
                    }
                    Spacer()
                    Button("Stop") { Task { await model.conversation.stopResponse() } }
                        .font(.caption).foregroundStyle(KairoTheme.danger)
                }
            }
            HStack(spacing: 10) {
                Picker("Output", selection: $destination) {
                    ForEach(ConversationClient.OutputDestination.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(KairoTheme.chrome)
                .frame(width: 130)
                .onChange(of: destination) { _, value in
                    model.conversation.outputDestination = value
                }
                TextField(model.settings.followEcho
                          ? "Continue with Kairo…"
                          : "Say something to Kairo",
                          text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(KairoTheme.plane))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(KairoTheme.hairline))
                    .foregroundStyle(KairoTheme.prose)
                Button {
                    let text = draft
                    draft = ""
                    composerFocused = false
                    Task { await model.conversation.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? KairoTheme.faint : KairoTheme.primary)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.conversation.isSending)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(KairoTheme.groundDeep.opacity(0.9))
    }
}

struct TurnCard: View {
    let turn: ConversationTurn

    private var surfaceColor: Color {
        if turn.sourceCaption.hasPrefix("dot") { return KairoTheme.primary }
        if turn.sourceCaption.hasPrefix("discord") { return KairoTheme.mind }
        if turn.sourceCaption.hasPrefix("ipad") { return KairoTheme.body }
        return KairoTheme.chrome
    }

    var body: some View {
        PlaneCard {
            HStack(spacing: 8) {
                Eyebrow(text: turn.sourceCaption, color: surfaceColor)
                Spacer()
                Text(turn.createdAt)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(KairoTheme.faint)
            }
            Text(turn.prompt)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(KairoTheme.prose)
            if turn.active {
                HStack(spacing: 8) {
                    Circle().fill(KairoTheme.mind).frame(width: 7, height: 7)
                    Text(turn.status == "waiting_permission"
                         ? "Kairo is waiting on an owner decision"
                         : "Kairo is working…")
                        .font(.caption).foregroundStyle(KairoTheme.mind)
                }
            }
            if !turn.toolActivity.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(turn.toolActivity.suffix(4), id: \.self) { activity in
                        Text(activity).font(.caption2).foregroundStyle(KairoTheme.chrome)
                    }
                }
            }
            if !turn.answer.isEmpty {
                Divider().overlay(KairoTheme.hairline)
                Text(turn.answer)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(6)
                    .foregroundStyle(KairoTheme.prose.opacity(0.92))
                    .textSelection(.enabled)
            }
            if let usage = turn.usage.caption {
                Text(usage).font(.system(size: 10, design: .monospaced)).foregroundStyle(KairoTheme.faint)
            }
        }
    }
}
