import SwiftUI

struct EchoPanel: View {
    @ObservedObject var conversation: EchoConversationClient
    @ObservedObject var playback: EchoActivityClient
    @AppStorage("showSharedConversationText") private var showConversationText = true

    private var phase: String? { playback.state.activity?.phase }
    private var caption: String {
        switch phase {
        case "listening": return "Echo Dot listening"
        case "speech_detected": return "Echo Dot heard you"
        case "thinking": return "Kairo thinking on the Dot"
        case "speaking": return "Kairo speaking on the Dot"
        case "replaying": return "Replaying on the Dot"
        case "idle": return "Echo Dot ready"
        case "disconnected": return "Echo Dot disconnected"
        default: return playback.connected ? "Waiting for fresh Dot activity" : playback.notice
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Kairo · all conversations", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)
            Text("Read-only observer · does not speak or submit turns").font(.caption).foregroundStyle(.secondary)
            if let error = conversation.error {
                Text(error).font(.caption).foregroundStyle(.pink)
            } else if let trouble = conversation.connectionTrouble {
                Label(trouble, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel("Connection trouble: \(trouble)")
            }
            Toggle("Show conversation text", isOn: $showConversationText)
                .font(.caption)
                .accessibilityHint("Shows or hides message text; source, session, tools, tokens and speed stay visible")
            transcript
            progress
            playbackControls
            if let state = conversation.state {
                DisclosureGroup("Kairo's current state · revision \(state.revision)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Current committed state across Kairo; not attributed to a single turn.")
                            .foregroundStyle(.secondary)
                        ForEach(Array(state.fields.enumerated()), id: \.offset) { field in
                            Text(field.element).textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var transcript: some View {
        if conversation.turns.isEmpty {
            Text("Conversations from every authorized surface will appear here.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    // A plain stack: twenty bounded turns. A lazy stack with
                    // long, variable-height text and scroll-to-bottom drew blank.
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: conversation.turns.last?.id, initial: true) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: conversation.turns.last?.answer) { _, _ in
                    if let id = conversation.turns.last?.id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func turnView(_ turn: EchoTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.sourceCaption).font(.caption2).foregroundStyle(.secondary)
            Text("Session · " + turn.sessionID).font(.caption2.monospaced()).foregroundStyle(.secondary)
            if showConversationText {
                Text(Self.bounded(turn.prompt, 600)).lineLimit(8).textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                if showConversationText {
                    Text(Self.bounded(turn.answer, 1_200)).lineLimit(14)
                        .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                }
                Text("Accepted response · " + turn.sourceCaption).font(.caption2).foregroundStyle(.secondary)
            } else if turn.active {
                Label("Kairo is thinking…", systemImage: "ellipsis")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Turn \(turn.settledStatus ?? turn.status)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let progress = turn.progress {
                Text("\(progress.processed.formatted())\(progress.total.map { " / \($0.formatted())" } ?? "") context tokens" +
                    (progress.cached.map { " · \($0.formatted()) cached" } ?? ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let usage = turn.usage.caption {
                Text(usage).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(Array(turn.toolActivity.enumerated()), id: \.offset) { tool in
                Text(tool.element).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func bounded(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    @ViewBuilder private var progress: some View {
        if let progress = conversation.progress {
            HStack {
                Text("\(progress.processed.formatted())\(progress.total.map { " / \($0.formatted())" } ?? "") context tokens")
                if let cached = progress.cached { Text("· \(cached.formatted()) cached") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let usage = conversation.usage.caption {
            Text(usage).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            if ["speaking", "replaying"].contains(phase ?? ""),
               let levels = playback.state.activity?.levels, !levels.isEmpty {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(Array(levels.enumerated()), id: \.offset) { sample in
                        Capsule().fill(.teal.opacity(0.7))
                            .frame(width: 5, height: max(3, CGFloat(sample.element) * 24))
                    }
                }
                .frame(height: 24)
                .accessibilityLabel("Echo Dot speaker output")
            }
            if playback.connected {
                Button("Replay on Dot", systemImage: "arrow.counterclockwise") { playback.requestReplay() }
                    .buttonStyle(.bordered)
                    .disabled(!playback.connected || !playback.state.canReplay())
            }
            if let status = playback.state.replayStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
