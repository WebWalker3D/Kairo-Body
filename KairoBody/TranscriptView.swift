import SwiftUI

/// The shared conversation across every Kairo surface — the Dot's turns,
/// Discord, the phone, this iPad — from the owner-scoped feed. Replying here
/// writes into the same conversation Kairo is holding with the Dot.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ResponseActivityView(showShared: false).padding(.horizontal, 18).padding(.bottom, 8)
            if let trouble = model.feed.connectionTrouble {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(KairoTheme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 6)
                    .background(KairoTheme.warn.opacity(0.08))
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
        .padding(.bottom, 96)
        .background(KairoTheme.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Conversations")
                .font(.system(size: 30, weight: .regular, design: .rounded))
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
            Button("Check original request") { Task { await model.conversation.recoverPendingTurn() } }
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
                    if !model.conversation.reply.isEmpty,
                       !model.feed.turns.contains(where: { $0.id == model.conversation.responseJobID }) {
                        PlaneCard {
                            Eyebrow(text: "This iPad", color: KairoTheme.body)
                            Text(model.conversation.submittedText).font(.subheadline).foregroundStyle(KairoTheme.chrome)
                            Text(model.conversation.reply).textSelection(.enabled).foregroundStyle(KairoTheme.prose)
                        }
                    }
                    if model.feed.turns.isEmpty && model.conversation.reply.isEmpty {
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
                Picker("Output", selection: Binding(get: { model.conversation.outputDestination }, set: { model.conversation.outputDestination = $0 })) {
                    ForEach(ConversationClient.OutputDestination.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .tint(KairoTheme.chrome)
                .frame(width: 130)
                .accessibilityLabel("Output: \(model.conversation.outputDestination.rawValue)")
                .accessibilityIdentifier("conversationOutput")
                TextField(model.settings.followEcho
                          ? "Continue with Kairo…"
                          : "Say something to Kairo",
                          text: Binding(get: { model.conversation.draft }, set: { model.conversation.draft = $0 }), axis: .vertical)
                    .focused($composerFocused)
                    .accessibilityIdentifier("conversationComposer")
                    .lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(KairoTheme.plane))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(KairoTheme.hairline))
                    .foregroundStyle(KairoTheme.prose)
                Button {
                    let text = model.conversation.draft
                    composerFocused = false
                    Task { await model.conversation.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.conversation.draft.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? KairoTheme.faint : KairoTheme.primary)
                .disabled(model.conversation.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).count > 16_000 || !model.conversation.canSubmit)
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
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(KairoTheme.faint)
            }
            Text(turn.prompt)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(KairoTheme.prose)
            if turn.active {
                HStack(spacing: 8) {
                    Circle().fill(KairoTheme.mind).frame(width: 7, height: 7)
                    Text(ResponseActivity.headline(status: turn.status, settled: turn.settledStatus))
                        .font(.caption).foregroundStyle(KairoTheme.mind)
                }
            }
            if turn.status == "waiting_permission" { ApprovalReviewView(jobID: turn.id) }
            if !turn.toolActivity.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(turn.toolActivity.suffix(4), id: \.self) { activity in
                        Text(activity).font(.footnote).foregroundStyle(KairoTheme.chrome)
                    }
                }
            }
            if let settled = turn.settledStatus, settled != "completed" {
                Label(ResponseActivity.headline(status: turn.status, settled: settled), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(KairoTheme.warn)
            }
            if !turn.answer.isEmpty {
                Divider().overlay(KairoTheme.hairline)
                Text(turn.answer)
                    .font(.system(size: 17, design: .rounded))
                    .lineSpacing(6)
                    .foregroundStyle(KairoTheme.prose.opacity(0.92))
                    .textSelection(.enabled)
            }
            if let usage = turn.usage.caption {
                Text(usage).font(.system(size: 13, design: .monospaced)).foregroundStyle(KairoTheme.faint)
            }
        }
    }
}
