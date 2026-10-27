import SwiftUI

/// The stage's read-only view of work across Kairo, plus this device's durable
/// submission status. Observing an answer here never claims delivery or speaks it.
struct ResponseActivityView: View {
    @EnvironmentObject private var model: AppModel
    var showShared = true
    @State private var confirmForget = false

    private var localVisible: Bool {
        model.conversation.isSending || model.conversation.pendingRecovery != nil || model.conversation.error != nil
    }
    private var sharedTurn: ConversationTurn? {
        guard showShared, model.settings.echoTranscriptVisible else { return nil }
        return model.feed.turns.last
    }
    private var feedFresh: Bool {
        model.feed.following && model.feed.connectionTrouble == nil &&
        model.feed.lastUpdatedAt.map { Date().timeIntervalSince($0) < 30 } == true
    }

    var body: some View {
        if localVisible || sharedTurn != nil || model.surfaceDelivery.error != nil {
            VStack(alignment: .leading, spacing: 10) {
                if localVisible {
                    activity(title: model.conversation.error == nil ? model.conversation.status : "Response interrupted",
                             detail: model.conversation.error ?? localDetail,
                             source: "THIS IPAD", active: model.conversation.isSending,
                             blocked: model.conversation.error != nil || model.conversation.pendingRecovery != nil,
                             since: model.conversation.submittedAt)
                    if !model.conversation.submittedText.isEmpty {
                        Text(model.conversation.submittedText).lineLimit(2)
                            .font(.system(size: 14)).foregroundStyle(KairoTheme.prose)
                    }
                    if model.conversation.pendingRecovery != nil {
                        HStack {
                            Button("Check original request") { Task { await model.conversation.recoverPendingTurn() } }
                                .disabled(model.conversation.isSending)
                            Spacer()
                            Button("Stop request") { Task { await model.conversation.stopResponse() } }
                        }.font(.caption.weight(.semibold))
                        Button("Stop tracking…") { confirmForget = true }
                            .font(.caption).foregroundStyle(KairoTheme.chrome)
                            .disabled(model.conversation.isSending)
                    }
                } else if let turn = sharedTurn {
                    let blocked = turn.status == "waiting_permission" || turn.settledStatus == "failed"
                    activity(title: feedFresh ? ResponseActivity.headline(status: turn.status, settled: turn.settledStatus) : "Reconnecting to conversation",
                             detail: feedFresh ? (turn.settledStatus == nil
                                 ? ResponseActivity.detail(status: turn.status, progress: turn.progress, tools: turn.toolActivity)
                                 : (turn.settledStatus == "completed" ? "Observed in the shared conversation" : "Kairo did not produce a completed answer."))
                                 : (model.feed.connectionTrouble ?? "Showing the last observed state; current progress is unknown."),
                             source: turn.sourceCaption.uppercased(), active: turn.active && feedFresh && !blocked,
                             blocked: blocked || !feedFresh,
                             since: turn.active ? BodyJSON.date(turn.createdAt) : nil)
                    if turn.status == "waiting_permission", feedFresh {
                        ApprovalReviewView(jobID: turn.id)
                    }
                    Text(turn.answer.isEmpty ? turn.prompt : turn.answer)
                        .font(.system(size: 15)).foregroundStyle(KairoTheme.prose).lineSpacing(3).lineLimit(3)
                    Button {
                        model.destination = .conversation
                    } label: {
                        HStack { Text(turn.active ? "View conversation" : "Read full conversation"); Spacer(); Image(systemName: "arrow.up.right") }
                    }.font(.caption.weight(.semibold))
                }
                if model.surfaceDelivery.hasUnconfirmedReceipts {
                    Button("Retry delivery receipt") { Task { await model.surfaceDelivery.retryReceipts() } }
                        .font(.caption)
                }
                if let error = model.surfaceDelivery.error {
                    Label(error, systemImage: "speaker.badge.exclamationmark")
                        .font(.caption).foregroundStyle(KairoTheme.warn)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(KairoTheme.hairline))
            .accessibilityIdentifier("responseActivity")
            .confirmationDialog("Stop tracking this request?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Stop tracking", role: .destructive) { model.conversation.clearRecoveredTurn() }
                Button("Keep tracking", role: .cancel) {}
            } message: {
                Text("This removes local recovery. It does not cancel Kairo's work, which may still finish on another surface.")
            }
        }
    }

    private var localDetail: String {
        if let progress = model.conversation.promptProgress {
            return ResponseActivity.detail(status: "running", progress: progress, tools: [])
        }
        return model.conversation.isSending ? "Your question is retained while this request is in progress." : "Check the existing request without creating a second one."
    }

    private func activity(title: String, detail: String, source: String, active: Bool,
                          blocked: Bool, since: Date?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                if active {
                    ProgressView().controlSize(.small).tint(KairoTheme.primary)
                } else {
                    Image(systemName: blocked ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(blocked ? KairoTheme.warn : KairoTheme.body)
                }
                Text(title.isEmpty ? "Sending your message…" : title)
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(KairoTheme.prose)
                Spacer(minLength: 4)
                if let since {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ResponseActivity.elapsed(since: since, now: context.date))
                            .monospacedDigit().font(.caption).foregroundStyle(KairoTheme.chrome)
                    }
                }
            }
            Text(source).font(.system(size: 9, design: .monospaced)).tracking(1)
                .foregroundStyle(KairoTheme.chrome).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(blocked ? KairoTheme.warn : KairoTheme.chrome)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }
}
