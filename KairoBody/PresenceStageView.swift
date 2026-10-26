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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if wide {
                        HStack(alignment: .top, spacing: 34) {
                            presence(side: max(260, min(geometry.size.width - 430, geometry.size.height - 360, 610)))
                                .frame(maxWidth: .infinity)
                            PresenceWorkspace().frame(width: 320).padding(.top, 18)
                        }
                    } else {
                        presence(side: min(geometry.size.width - 48, 570))
                        PresenceWorkspace().frame(maxWidth: 620).frame(maxWidth: .infinity)
                    }
                    if let invitation = model.invitations.invitation {
                        InvitationCard(invitation: invitation)
                    }
                }
                .padding(.horizontal, wide ? 36 : 24)
                .padding(.top, 26)
                .padding(.bottom, 110)
                .frame(maxWidth: 1440).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { KairoTheme.background; PresenceField() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 25, weight: .ultraLight)).foregroundStyle(KairoTheme.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("K A I R O").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(KairoTheme.prose)
                    Text("A CONTINUOUS PRESENCE").font(.system(size: 8, weight: .medium, design: .monospaced))
                        .tracking(2).foregroundStyle(KairoTheme.faint)
                }
            }
            Spacer()
            StatusChip(label: model.body.connectionState == .connected ? "BODY CONNECTED" : "BODY OFFLINE",
                       color: model.body.connectionState == .connected ? KairoTheme.body : KairoTheme.faint)
        }
    }

    private func presence(side: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "Presence / 01", color: KairoTheme.chrome)
                Spacer()
                Text(model.ring.presentationFresh ? "COMMITTED AFFECT" : "AWAITING STATE")
                    .font(.system(size: 8, design: .monospaced)).tracking(1)
                    .foregroundStyle(KairoTheme.faint)
            }.padding(.top, 20)
            ringStage(side: max(180, side))
                .padding(.vertical, -24)
            Text(bodyHeadline.capitalized)
                .font(.system(size: 42, weight: .regular, design: .serif))
                .foregroundStyle(KairoTheme.prose)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            HStack(spacing: 9) {
                Circle().fill(KairoTheme.primary.opacity(0.6)).frame(width: 4, height: 4)
                Text(model.ring.presentationFresh ? model.ring.mood.capitalized : "Waiting for Kairo’s state")
                Text("·")
                Text("Touch to connect")
            }
            .font(.system(size: 11)).foregroundStyle(KairoTheme.chrome)
            .padding(.top, 12).padding(.bottom, 26)
            quickActions
            Button { model.destination = .conversation } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").foregroundStyle(KairoTheme.primary)
                    Text(model.voice.isCapturing ? "Listening…" : "Say something to Kairo")
                        .font(.system(size: 13)).foregroundStyle(KairoTheme.chrome)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(KairoTheme.primary)
                }.padding(18)
                .background(KairoTheme.plane.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(KairoTheme.hairline))
            }.buttonStyle(.plain).padding(.top, 25).frame(maxWidth: 420)
        }
    }

    private func ringStage(side: CGFloat) -> some View {
        ZStack {
            KairoRingMetalView(state: model.renderState(), framesPerSecond: reduceMotion ? 10 : 30,
                               reduceMotion: reduceMotion)
            if model.settings.cameraMode, let session = model.body.frontCameraSession {
                FrontCameraPreview(session: session)
                    .frame(width: side * 0.30, height: side * 0.30)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(KairoTheme.body.opacity(0.3)))
            }
            if let point = contactPoint {
                Circle().stroke(KairoTheme.primary.opacity(0.7), lineWidth: 1)
                    .frame(width: 68, height: 68).position(point).allowsHitTesting(false)
                Circle().fill(KairoTheme.primary.opacity(0.12))
                    .frame(width: 100, height: 100).blur(radius: 12).position(point).allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .gesture(contactGesture(in: side))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kairo presence. \(bodyHeadline)")
        .accessibilityHint("Touch sends a contact observation to Kairo")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                let theta = reduceMotion ? 0 : 2 * Double.pi * elapsed / Self.orbitSeconds
                let orbitX = size.width * 0.23
                let orbitY = size.height * 0.17
                let cards = cardsFor(now: context.date)
                ZStack {
                    Color.black.ignoresSafeArea()
                    KairoRingMetalView(state: model.ambientRingState(now: context.date),
                                       framesPerSecond: 10, reduceMotion: reduceMotion)
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
