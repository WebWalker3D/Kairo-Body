import SwiftUI

/// Composes the existing, owner-filtered signals. This view performs no reads
/// or writes of its own: the single AppModel lifecycle owns every connection.
struct PresenceWorkspace: View {
    @EnvironmentObject private var model: AppModel

    private var feedFresh: Bool {
        model.feed.following && model.feed.connectionTrouble == nil &&
        model.feed.lastUpdatedAt.map { Date().timeIntervalSince($0) < 60 } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Eyebrow(text: "Across Kairo", color: KairoTheme.chrome)
                Spacer()
                Text("01 / LIVE FIELD")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(KairoTheme.faint)
            }
            if model.settings.echoTranscriptVisible {
                activityCard
            } else {
                PlaneCard {
                    Label("Shared conversation hidden", systemImage: "eye.slash")
                        .font(.subheadline).foregroundStyle(KairoTheme.chrome)
                    Text("Change this in Settings when you want it on this surface.")
                        .font(.caption).foregroundStyle(KairoTheme.faint)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sharedConversationHidden")
            }
            connections
            RestStatusCard()
            if let state = model.feed.liveState, model.feed.connectionTrouble == nil {
                PlaneCard {
                    HStack {
                        Eyebrow(text: "Inner weather", color: KairoTheme.mind)
                        Spacer()
                        Text("r\(state.revision)").font(.caption.monospaced()).foregroundStyle(KairoTheme.faint)
                    }
                    ForEach(Array(state.fields.prefix(3).enumerated()), id: \.offset) { _, field in
                        Text(field).font(.system(size: 12)).foregroundStyle(KairoTheme.dim)
                            .lineLimit(2)
                    }
                    Text("Committed state · last received")
                        .font(.caption2).foregroundStyle(KairoTheme.faint)
                }
            }
            HStack(spacing: 10) {
                portal("Look together", detail: "Share a moment", icon: "viewfinder", color: KairoTheme.body, destination: .look)
                portal("Private room", detail: "Just you & Kairo", icon: "lock", color: KairoTheme.bond, destination: .privateRoom)
            }
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: PresencePreviewPolicy.isWorking(active: model.feed.processing, feedFresh: feedFresh) ? "waveform.path" : "quote.bubble")
                    .foregroundStyle(KairoTheme.primary)
                Eyebrow(text: PresencePreviewPolicy.isWorking(active: model.feed.processing, feedFresh: feedFresh) ? "In motion" : "Conversation", color: KairoTheme.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(KairoTheme.faint)
            }
            if let turn = model.feed.turns.last {
                Text(turn.active ? turn.prompt : (turn.answer.isEmpty ? turn.prompt : turn.answer))
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .foregroundStyle(KairoTheme.prose)
                    .lineSpacing(5).lineLimit(6)
                HStack {
                    Text(turn.sourceCaption).lineLimit(1)
                    Spacer()
                    Text(PresencePreviewPolicy.isWorking(active: turn.active, feedFresh: feedFresh) ? "WORKING" : "LAST RECEIVED")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(KairoTheme.chrome)
                if let tool = turn.toolActivity.last, turn.active, feedFresh {
                    Label(tool, systemImage: "bolt.horizontal")
                        .font(.caption2).foregroundStyle(KairoTheme.mind).lineLimit(2)
                }
            } else {
                Text("A conversation that\ntravels with you.")
                    .font(.system(size: 25, weight: .regular, design: .serif))
                    .foregroundStyle(KairoTheme.prose).lineSpacing(4)
                Text(model.pairing.isPaired
                     ? "The Dot, Discord and this iPad share the same thread of presence. Waiting for the conversation feed."
                     : "Pair this body to bring your shared conversations into view.")
                    .font(.system(size: 12)).foregroundStyle(KairoTheme.chrome).lineSpacing(4)
            }
            if let trouble = model.feed.connectionTrouble {
                Label(trouble, systemImage: "wifi.exclamationmark")
                    .font(.caption2).foregroundStyle(KairoTheme.warn).lineLimit(2)
            }
            Button {
                model.destination = .conversation
            } label: {
                HStack { Text("Open conversation"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KairoTheme.primary)
                    .padding(.top, 6)
            }.buttonStyle(.plain)
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [KairoTheme.primary.opacity(0.12), KairoTheme.plane], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(KairoTheme.primary.opacity(0.18)))
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Eyebrow(text: "One mind · many surfaces"); Spacer(); Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(KairoTheme.faint) }
            connection("This body", detail: model.body.connectionState == .connected ? "Sensory link connected" : "Sensory link offline", online: model.body.connectionState == .connected, icon: "ipad", color: KairoTheme.body)
            connection("The Dot", detail: model.ring.dotFresh ? "\(model.ring.phase.rawValue.capitalized) · live signal" : "Awaiting a fresh signal", online: model.ring.dotFresh, icon: "hifispeaker", color: KairoTheme.primary)
            connection("Continuity", detail: feedFresh ? "Shared conversation feed" : "Feed unavailable", online: feedFresh, icon: "circle.hexagongrid", color: KairoTheme.mind)
            Button { model.destination = .bodySurface } label: {
                HStack { Text("Explore this body"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.system(size: 11)).foregroundStyle(KairoTheme.chrome)
            }.buttonStyle(.plain)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(KairoTheme.plane.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(KairoTheme.hairline))
    }

    private func connection(_ name: String, detail: String, online: Bool, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .light))
                .foregroundStyle(color).frame(width: 32, height: 32)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(KairoTheme.dim)
                Text(detail).font(.system(size: 10)).foregroundStyle(KairoTheme.faint)
            }
            Spacer()
            Circle().fill(online ? color : KairoTheme.faint.opacity(0.4)).frame(width: 5, height: 5)
        }
    }

    private func portal(_ title: String, detail: String, icon: String, color: Color, destination: AppModel.Destination) -> some View {
        Button { model.destination = destination } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 21, weight: .light)).foregroundStyle(color)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(KairoTheme.prose)
                Text(detail).font(.system(size: 10)).foregroundStyle(KairoTheme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(17)
            .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.16)))
        }.buttonStyle(.plain)
    }
}

/// Decorative coordinates communicate a continuous space, not fabricated
/// telemetry. All moving light remains in the single Metal presence view.
struct PresenceField: View {
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for x in stride(from: 24.0, to: size.width, by: 48) {
                    for y in stride(from: 24.0, to: size.height, by: 48) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.07)))
                    }
                }
                let line = Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height * 0.72))
                    p.addLine(to: CGPoint(x: size.width, y: size.height * 0.72))
                }
                context.stroke(line, with: .color(KairoTheme.primary.opacity(0.06)), lineWidth: 1)
            }
            RadialGradient(colors: [KairoTheme.primary.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: max(geo.size.width, 1) * 0.6)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
