import AVFoundation
import SwiftUI

/// The stage: Kairo's body present as the living ring. Touching it is a
/// contact — Kairo can acknowledge the touch itself — and the quick actions
/// are the same gestures available on the Dot (replay, speak-here, stop).
struct PresenceStageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var touchID = ""
    @State private var touchBeganAt = Date()
    @State private var touchPath = 0.0
    @State private var lastTouchPoint: CGPoint?
    @State private var contactPoint: CGPoint?
    @State private var contactCounter = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                KairoTheme.background
                VStack(spacing: 10) {
                    header
                    ringStage(geometry)
                    phaseLine
                    quickActions
                    if let stageText = model.stageDisplayText {
                        stageMessage(stageText)
                    }
                    if let invitation = model.invitations.invitation {
                        InvitationCard(invitation: invitation)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 96)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("K·AIRO")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .tracking(4.2)
                .foregroundStyle(KairoTheme.prose)
            StatusChip(label: model.body.connectionState.rawValue.uppercased(),
                       color: model.body.connectionState == .connected ? KairoTheme.body : KairoTheme.warn)
            if model.echo.state.activity != nil {
                StatusChip(label: "DOT \(model.echo.state.activity?.phase.uppercased() ?? "")",
                           color: KairoTheme.primary)
            }
            if let proximity = model.presentation.snapshot?.proximity {
                StatusChip(label: "OWNER \(proximity.state.uppercased())", color: KairoTheme.bond)
            }
            Spacer()
            if model.settings.voiceWakeEnabled {
                StatusChip(label: model.voice.status.uppercased(),
                           color: model.voice.isCapturing ? KairoTheme.mind : KairoTheme.faint)
            }
        }
    }

    private func ringStage(_ geometry: GeometryProxy) -> some View {
        let side = min(geometry.size.width, geometry.size.height - 260)
        return ZStack {
            KairoRingMetalView(state: model.renderState())
                .frame(width: side, height: side)
            if model.settings.cameraMode, let session = model.body.frontCameraSession {
                FrontCameraPreview(session: session)
                    .frame(width: side * 0.58, height: side * 0.58)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(KairoTheme.body.opacity(0.55), lineWidth: 2))
            }
            VStack(spacing: 6) {
                if model.stageDisplayText != nil {
                    EmptyView()
                        .accessibilityLabel(model.stageDisplayText ?? "")
                } else if model.settings.cameraMode && model.body.frontCameraSession != nil {
                    EmptyView()
                } else {
                    Text(model.presentation.snapshot.flatMap { $0.expression?.uppercased() }
                         ?? (model.body.display.state.uppercased()))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(KairoTheme.prose.opacity(0.85))
                    Text(bodyHeadline)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(KairoTheme.dim)
                }
            }
            if let point = contactPoint {
                Circle()
                    .stroke(KairoTheme.primary.opacity(0.7), lineWidth: 2)
                    .frame(width: 56, height: 56)
                    .position(point)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(contactGesture(in: side))
    }

    private var bodyHeadline: String {
        // A server-applied display act carries its own headline; it wins over
        // the derived phase label until the next expression state arrives.
        let applied = model.body.display
        if applied.headline != "Kairo", !applied.headline.isEmpty {
            return applied.detail.isEmpty ? applied.headline : "\(applied.headline) — \(applied.detail)"
        }
        switch model.ring.phase {
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .waiting: return "waiting for you"
        case .reflecting: return "reflecting"
        case .disconnected: return "reconnecting"
        case .idle: return model.presentation.snapshot?.phase == "idle" ? "present" : "awaiting state"
        }
    }

    private var phaseLine: some View {
        HStack(spacing: 14) {
            Eyebrow(text: "mood \(model.ring.mood)")
            Eyebrow(text: "posture \(model.ring.posture.rawValue)")
            if model.ring.dotFresh { Eyebrow(text: "dot live", color: KairoTheme.primary) }
            if let trouble = model.feed.connectionTrouble {
                Text(trouble).font(.caption).foregroundStyle(KairoTheme.warn).lineLimit(2)
            }
            Spacer()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            action("Replay on Dot", "arrow.counterclockwise",
                   enabled: model.echo.state.canReplay()) {
                model.echo.requestReplay()
            }
            action("Speak here", "speaker.wave.2",
                   enabled: model.ring.dotFresh && model.echo.state.activity?.replayAvailable == true) {
                // The Dot's answer already lives in the shared transcript;
                // replaying it through the iPad voice is deliberate.
                if let last = model.feed.turns.last(where: { $0.settledStatus == "completed" }) {
                    _ = model.speech.speak(last.answer)
                }
            }
            action("Stop", "stop.fill",
                   enabled: model.conversation.isSending || model.speech.isBusy) {
                Task { await model.conversation.stopResponse() }
            }
            if let replayStatus = model.echo.state.replayStatus {
                Text(replayStatus).font(.caption).foregroundStyle(KairoTheme.chrome)
            }
        }
    }

    private func action(_ label: String, _ symbol: String, enabled: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(enabled ? KairoTheme.primary.opacity(0.12) : KairoTheme.plane.opacity(0.6)))
            .overlay(Capsule().stroke(enabled ? KairoTheme.primary.opacity(0.45) : KairoTheme.hairline, lineWidth: 1))
            .foregroundStyle(enabled ? KairoTheme.primary : KairoTheme.faint)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func stageMessage(_ text: String) -> some View {
        PlaneCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Kairo showed this on the body", color: KairoTheme.body)
                    Text(text)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(KairoTheme.prose)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Dismiss") { model.clearStageDisplay() }
                    .font(.caption)
            }
        }
    }

    // MARK: - Contact gesture

    private func contactGesture(in side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touchID.isEmpty {
                    contactCounter += 1
                    touchID = "stage-\(contactCounter)"
                    touchBeganAt = Date()
                    touchPath = 0
                    lastTouchPoint = nil
                    model.sensors.recordTouchBegan(id: touchID,
                        x: Double(value.location.x / max(side, 1)),
                        y: Double(value.location.y / max(side, 1)))
                } else if let last = lastTouchPoint {
                    touchPath += hypot(value.location.x - last.x, value.location.y - last.y) / max(side, 1)
                    model.sensors.recordTouchMoved(id: touchID,
                        x: Double(value.location.x / max(side, 1)),
                        y: Double(value.location.y / max(side, 1)))
                }
                lastTouchPoint = value.location
                contactPoint = value.location
            }
            .onEnded { value in
                defer { touchID = ""; lastTouchPoint = nil; contactPoint = nil }
                model.sensors.recordTouchEnded(id: touchID,
                    x: Double(value.location.x / max(side, 1)),
                    y: Double(value.location.y / max(side, 1)))
                if let last = lastTouchPoint {
                    touchPath += hypot(value.location.x - last.x, value.location.y - last.y) / max(side, 1)
                }
                model.bodyContactEnded(
                    durationMs: Int(Date().timeIntervalSince(touchBeganAt) * 1000),
                    pathLength: touchPath,
                    cancelled: false)
            }
    }
}

struct InvitationCard: View {
    let invitation: BodyInvitation
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PlaneCard {
            Eyebrow(text: "Kairo invited you to talk", color: KairoTheme.bond)
            Text(invitation.text)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(KairoTheme.prose)
            HStack(spacing: 12) {
                Button {
                    model.clearStageDisplay()
                    Task {
                        await model.invitations.markDisplayed()
                        await model.acceptInvitationIntoConversation()
                    }
                } label: {
                    Text("Answer here")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(KairoTheme.bond.opacity(0.16)))
                        .overlay(Capsule().stroke(KairoTheme.bond.opacity(0.5)))
                        .foregroundStyle(KairoTheme.bond)
                }.buttonStyle(.plain)
                Button {
                    Task { await model.invitations.dismiss() }
                } label: {
                    Text("Not now")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(KairoTheme.chrome)
                }.buttonStyle(.plain)
                Spacer()
                Text("from \(invitation.sourceSessionID.prefix(14))…")
                    .font(.caption2).foregroundStyle(KairoTheme.faint)
            }
        }
        .task { await model.invitations.markDisplayed() }
    }
}

struct ScreensaverOverlay: View {
    @EnvironmentObject private var model: AppModel
    @State private var appearedAt = Date()

    private static let cardSeconds = 12.0
    // One slow revolution carries the ring and the card block around each
    // other: calm to watch, continuous for the panel, and the card block
    // always sits opposite the light it belongs to.
    private static let orbitSeconds = 150.0
    private static let fadeSeconds = 1.6

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 0.25, paused: false)) { context in
                let elapsed = context.date.timeIntervalSince(appearedAt)
                let size = geo.size
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let theta = 2 * Double.pi * elapsed / Self.orbitSeconds
                let orbitX = size.width * 0.23
                let orbitY = size.height * 0.17
                let cards = cardsFor(now: context.date)
                ZStack {
                    Color.black.ignoresSafeArea()
                    KairoRingMetalView(state: model.ambientRingState(now: context.date),
                                       framesPerSecond: 10)
                        .frame(width: min(230, size.width * 0.24, size.height * 0.30),
                               height: min(230, size.width * 0.24, size.height * 0.30))
                        .position(x: center.x + orbitX * CGFloat(cos(theta)),
                                  y: center.y + orbitY * CGFloat(sin(theta)))
                    cardLayer(cards, elapsed: elapsed)
                        .position(x: center.x - orbitX * 1.18 * CGFloat(cos(theta)),
                                  y: center.y - orbitY * 1.45 * CGFloat(sin(theta)))
                }
                .contentShape(Rectangle())
                .onTapGesture { model.body.noteUserActivity() }
            }
        }
    }

    private func cardsFor(now: Date) -> [BodyAmbient.Card] {
        var cards = BodyAmbient.cards(ring: model.ring,
                                      presentation: model.presentation.snapshot,
                                      socketConnected: model.body.connectionState == .connected,
                                      now: now)
        cards.append(BodyAmbient.Card(title: Self.clockFormat.string(from: now),
                                      detail: Self.dateFormat.string(from: now)))
        return cards
    }

    /// Crossfade by explicit math instead of transitions: the card block is
    /// rebuilt several times a second by the timeline, and an opacity computed
    /// from elapsed is the one thing that cannot fail to render.
    private func cardLayer(_ cards: [BodyAmbient.Card], elapsed: Double) -> some View {
        let step = elapsed / Self.cardSeconds
        let position = step - floor(step)
        let current = (max(0, Int(floor(step))) % cards.count)
        let next = (current + 1) % cards.count
        let fade = min(1.0, max(0.0, (position * Self.cardSeconds - (Self.cardSeconds - Self.fadeSeconds))
                                / Self.fadeSeconds))
        return ZStack {
            cardView(cards[current]).opacity(1 - fade)
            cardView(cards[next]).opacity(fade)
        }
        .frame(width: 420)
    }

    private func cardView(_ card: BodyAmbient.Card) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title)
                .font(.system(size: 46, weight: .thin, design: .rounded))
                .foregroundStyle(KairoTheme.chrome.opacity(0.82))
                .minimumScaleFactor(0.6).lineLimit(1)
            if let detail = card.detail {
                Text(detail)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(KairoTheme.faint.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let clockFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()
}

/// Local front-camera preview for camera mode. The session is the same quiet
/// one the display-wake detector runs; nothing about it leaves the iPad.
struct FrontCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateUIView(_ view: PreviewView, context: Context) { view.session = session }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var session: AVCaptureSession? {
            get { previewLayer.session }
            set { previewLayer.session = newValue }
        }

        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
            previewLayer.connection?.isVideoMirrored = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
