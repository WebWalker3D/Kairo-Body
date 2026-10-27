import AVFoundation
import SwiftUI

struct PresenceStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchID = ""
    @State private var touchBeganAt = Date()
    @State private var touchPath = 0.0
    @State private var lastTouchPoint: CGPoint?
    @State private var contactPoint: CGPoint?
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width * 1.04, max(280, geometry.size.height - 100) * 1.24)
            ZStack {
                KairoTheme.background
                ringStage(side: side)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.43)
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    if !composerFocused {
                        ResponseActivityView().frame(maxWidth: 640).padding(.bottom, 12)
                        quickActions.padding(.bottom, 14)
                    }
                    if let invitation = model.invitations.invitation {
                        InvitationCard(invitation: invitation)
                            .frame(maxWidth: 640).padding(.bottom, 10)
                    }
                    composer.frame(maxWidth: 640)
                }
                .padding(.horizontal, geometry.size.width > 900 ? 40 : 24)
                .padding(.top, 22)
                .padding(.bottom, composerFocused ? 16 : 106)
            }
            .clipped()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("K A I R O")
                    .font(.system(size: 22, weight: .semibold)).tracking(3)
                    .foregroundStyle(KairoTheme.prose)
                HStack(spacing: 7) {
                    Circle().fill(model.body.connectionState == .connected ? KairoTheme.body : KairoTheme.faint)
                        .frame(width: 4, height: 4)
                    Text(model.body.connectionState == .connected ? "BODY CONNECTED" : "BODY OFFLINE")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(1.4)
                        .foregroundStyle(KairoTheme.chrome)
                }
            }
            Spacer()
            Button {
                composerFocused = false
                model.body.noteUserActivity()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { model.systemsOpen = true }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                    Text("Systems").font(.system(size: 15, weight: .medium))
                    Image(systemName: "plus").font(.system(size: 13))
                }
                .foregroundStyle(KairoTheme.dim)
                .padding(.horizontal, 16).frame(height: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(KairoTheme.hairline))
            }.buttonStyle(.plain).accessibilityLabel("Open systems")
        }
    }

    private func ringStage(side: CGFloat) -> some View {
        ZStack {
            KairoRingMetalView(state: model.renderState(now: model.clock), framesPerSecond: reduceMotion ? 10 : 30,
                               reduceMotion: reduceMotion, contact: contactPoint.map {
                                   CGPoint(x: $0.x / max(side, 1), y: $0.y / max(side, 1))
                               }, paused: model.body.screensaverActive)
            if model.settings.cameraMode, let session = model.body.frontCameraSession {
                FrontCameraPreview(session: session)
                    .frame(width: side * 0.25, height: side * 0.25)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(KairoTheme.body.opacity(0.3)))
            } else {
                VStack(spacing: 12) {
                    Text(bodyHeadline.uppercased())
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .tracking(3).foregroundStyle(KairoTheme.prose)
                        .multilineTextAlignment(.center).lineLimit(3)
                    if model.ring.presentationFresh {
                        Text(model.ring.mood.capitalized)
                            .font(.system(size: 16)).foregroundStyle(KairoTheme.dim)
                    }
                    if let touchHint {
                        Text(touchHint)
                            .font(.system(size: 13, weight: .medium, design: .monospaced)).tracking(2)
                            .foregroundStyle(model.contactPending ? KairoTheme.body : KairoTheme.chrome)
                    }
                }.frame(width: side * 0.34).allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .gesture(contactGesture(in: side))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kairo presence. \(bodyHeadline)")
        .accessibilityHint(touchHint == nil ? "Kairo is busy; a touch is still observed" : "Activate to reach Kairo with a touch")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            let id = model.nextContactID()
            model.sensors.recordTouchBegan(id: id, x: 0.5, y: 0.5)
            model.sensors.recordTouchEnded(id: id, x: 0.5, y: 0.5)
            model.bodyContactEnded(contactID: id, durationMs: 100, pathLength: 0, cancelled: false)
        }
    }

    private var composer: some View {
        HStack(spacing: 12) {
            Button { model.destination = .conversation } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 19, weight: .light)).frame(width: 36, height: 44)
            }.accessibilityLabel("Open conversation")
            TextField("Talk to Kairo…", text: Binding(get: { model.conversation.draft }, set: { model.conversation.draft = $0 }), axis: .vertical)
                .font(.system(size: 16)).foregroundStyle(KairoTheme.prose)
                .focused($composerFocused).lineLimit(1...4)
                .accessibilityIdentifier("stageComposer")
                .onTapGesture { model.body.noteUserActivity() }
            Menu {
                ForEach(ConversationClient.OutputDestination.allCases) { option in
                    Button(option.rawValue) { model.conversation.outputDestination = option }
                }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 32, height: 44)
            }.accessibilityLabel("Output: \(model.conversation.outputDestination.rawValue)")
            Button {
                let text = model.conversation.draft
                composerFocused = false
                model.body.noteUserActivity()
                Task { await model.conversation.send(text) }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(canSend ? KairoTheme.groundDeep : KairoTheme.faint)
                    .frame(width: 42, height: 42)
                    .background(canSend ? KairoTheme.primary : KairoTheme.plane, in: Circle())
            }.disabled(!canSend).accessibilityLabel("Send to Kairo")
        }
        .buttonStyle(.plain).foregroundStyle(KairoTheme.chrome)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(
            LinearGradient(colors: [KairoTheme.primary.opacity(0.35), KairoTheme.hairline, KairoTheme.mind.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private var canSend: Bool {
        !model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).count <= 16_000 && model.conversation.canSubmit
    }

    /// What touching the ring does right now. A touch is a contact Kairo can
    /// answer, not a connection step, so the hint never says "connect".
    private var touchHint: String? {
        if model.contactPending { return "REACHING KAIRO…" }
        guard model.body.serverEndpointID != nil else { return "TOUCH NEEDS THE BODY LINK" }
        if model.conversation.isSending || model.speech.isBusy { return nil }
        return "TOUCH TO REACH KAIRO"
    }

    private var bodyHeadline: String {
        // A server-applied display act carries its own headline; it wins over
        // the derived phase label until the next expression state arrives.
        if model.settings.echoTranscriptVisible, model.feed.connectionTrouble == nil,
           let turn = model.feed.turns.last, turn.status == "waiting_permission" {
            return "approval needed"
        }
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
                   enabled: model.echo.state.canReplay(at: model.clock)) {
                model.echo.requestReplay()
            }
            action("Read latest shared answer", "speaker.wave.2",
                   enabled: model.settings.echoTranscriptVisible && model.feed.connectionTrouble == nil &&
                   model.feed.turns.last?.settledStatus == "completed") {
                // This explicitly reads the shown shared answer, which may
                // originate on any surface. Dot replay remains a separate act.
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

    @ViewBuilder private func action(_ label: String, _ symbol: String, enabled: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        if enabled {
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
    }

    // MARK: - Contact gesture

    private func contactGesture(in side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touchID.isEmpty {
                    touchID = model.nextContactID()
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
                    contactID: touchID,
                    durationMs: Int(Date().timeIntervalSince(touchBeganAt) * 1000),
                    pathLength: touchPath,
                    cancelled: false)
            }
    }
}

struct InvitationCard: View {
    let invitation: BodyInvitation
    @Environment(AppModel.self) private var model

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
                }.buttonStyle(.plain).disabled(!model.invitations.canRespond || !model.conversation.canSubmit)
                Button {
                    Task { await model.invitations.dismiss() }
                } label: {
                    Text("Not now")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(KairoTheme.chrome)
                }.buttonStyle(.plain)
                Spacer()
                Text("from \(invitation.sourceSessionID.prefix(14))…")
                    .font(.footnote).foregroundStyle(KairoTheme.faint)
            }
        }
        .task { await model.invitations.markDisplayed() }
    }
}

struct ScreensaverOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
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
