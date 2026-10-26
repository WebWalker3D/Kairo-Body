import AVFoundation
import Combine
import Foundation
import UIKit

/// The composition root. It owns every client, keeps exactly one body
/// transport, one Dot observer, one transcript feed, one presentation poll and
/// one invitation loop alive, and publishes the single derived ring state the
/// whole app renders.
@MainActor
final class AppModel: ObservableObject {
    let systems = SystemsClient()
    let settings = AppSettings()
    let sensors = SensorManager()
    let pairing = PairingClient()
    let feed = TranscriptFeedClient()
    let presentation = PresentationClient()
    let invitations = InvitationClient()
    let privateRoom = PrivateRoomClient()
    let echo = DotObserverClient()
    let voice = VoiceInputService()
    let visual = SharedVisualContext()

    let speech: SpeechService
    let body: BodyClient
    let conversation: ConversationClient
    let surfaceDelivery: SurfaceDeliveryClient

    @Published var destination: Destination = .stage
    @Published private(set) var ring = RingMirrorState()
    @Published private(set) var isForeground = true
    @Published var exportedArtifact: URL?
    @Published private(set) var stageDisplayText: String?
    @Published private(set) var lastContactAt: Date?
    @Published private(set) var stageDisplayID = UUID()
    private var acknowledgedDisplayID: UUID?
    private var rootSurfaceVisible = false
    private let surfaceUnobscured: @MainActor () -> Bool
    private var ringTask: Task<Void, Never>?
    private var invitationTask: Task<Void, Never>?
    private var contactCounter = 0
    private var kairoProcessingCache: (value: Bool, at: Date)?
    private var nextProcessingReadAt = Date.distantPast

    enum Destination: String, CaseIterable, Identifiable {
        case stage = "Stage"
        case conversation = "Conversation"
        case look = "Look"
        case privateRoom = "Private"
        case bodySurface = "Body"
        case settings = "Settings"
        var id: String { rawValue }
    }

    init(deliveryRequest: SurfaceDeliveryClient.Request? = nil,
         surfaceUnobscured: @escaping @MainActor () -> Bool = { SurfaceVisibility.isUnobscured() }) {
        self.surfaceUnobscured = surfaceUnobscured
        AppConfig.provisionOnFirstLaunch()
        let http = KairoHTTP()
        camera = CameraCaptureService()
        speech = SpeechService(http: http)
        body = BodyClient(settings: settings, sensors: sensors, speech: speech, camera: camera)
        conversation = ConversationClient(settings: settings, speech: speech, http: http)
        surfaceDelivery = SurfaceDeliveryClient(request: deliveryRequest ?? { path, body in
            try await http.agentObject(path, method: body == nil ? "GET" : "POST", body: body)
        })
        body.applyDisplay = { [weak self] state in
            await self?.applyStageDisplay(state.surfaceText) ?? false
        }
        surfaceDelivery.display = { [weak self] text in await self?.applyStageDisplay(text) ?? false }
        surfaceDelivery.speak = { [weak self] text, event in self?.speech.speak(text, onEvent: event) ?? false }
        surfaceDelivery.stopSpeech = { [weak self] in self?.speech.stop() }
        conversation.prepareOutput = { [weak self] destination in
            try await self?.surfaceDelivery.prepare(destination)
        }
        conversation.deliverOutput = { [weak self] job, destination in
            await self?.surfaceDelivery.deliver(jobID: job, destination: destination)
        }
        conversation.stopOutput = { [weak self] in self?.surfaceDelivery.stop() }
        forwardChangePublishers()
    }

    private let camera: CameraCaptureService

    /// Every client is separately observable, but every view observes the
    /// model. Forwarding each child's change publisher keeps one observation
    /// point without rebuilding the tree from a dozen @ObservedObjects.
    private var forwardCancellables: [AnyCancellable] = []

    private func forwardChangePublishers() {
        // Each child is generic-forwarded: an ObservableObject's publisher is
        // an associated type, so it cannot be reached through `any`.
        forChild(settings); forChild(sensors); forChild(pairing); forChild(feed)
        forChild(presentation); forChild(invitations); forChild(privateRoom)
        forChild(echo); forChild(voice); forChild(visual)
        forChild(body); forChild(conversation); forChild(surfaceDelivery); forChild(systems)
    }

    private func forChild<_Source: ObservableObject>(_ source: _Source) {
        forwardCancellables.append(source.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
    }

    func wireVoiceCallbacks() {
        voice.onCommand = { [weak self] command in
            guard let self else { return }
            Task { await self.conversation.send(command) }
        }
        voice.onWake = { [weak self] in self?.body.noteUserActivity() }
    }

    // MARK: - Lifecycle

    func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        body.setForeground(foreground)
        updateSurfaceVisibility()
        systems.start(paired: pairing.isPaired, foreground: foreground)
        surfaceDelivery.setForeground(foreground)
        echo.follow(token: AppConfig.agentToken, foreground: foreground && settings.followEcho)
        feed.followAllSurfaces(foreground: foreground)
        presentation.start(paired: pairing.isPaired, foreground: foreground)
        voice.configure(enabled: settings.voiceWakeEnabled, foreground: foreground,
                        conversationBusy: conversation.isSending)
        Task { await invitations.refresh(foreground: foreground && settings.invitationsEnabled && pairing.isPaired) }
        if foreground {
            startLoops()
            Task { await conversation.recoverPendingTurn() }
        } else {
            ringTask?.cancel(); ringTask = nil
            invitationTask?.cancel(); invitationTask = nil
            privateRoom.stop()
        }
    }

    func connectIfNeeded() {
        guard AppConfig.sensoryToken.isEmpty == false || AppConfig.agentToken.isEmpty == false else { return }
        body.start()
        systems.start(paired: pairing.isPaired, foreground: isForeground)
        updateSurfaceVisibility()
        echo.follow(token: AppConfig.agentToken, foreground: isForeground && settings.followEcho)
        feed.followAllSurfaces(foreground: isForeground)
        presentation.start(paired: pairing.isPaired, foreground: isForeground)
        voice.configure(enabled: settings.voiceWakeEnabled, foreground: isForeground,
                        conversationBusy: conversation.isSending)
        startLoops()
        Task { await conversation.recoverPendingTurn() }
    }

    func settingsChanged() {
        body.updateMotionDimming()
        sensors.setLocationEnabled(settings.sendLocation)
        echo.follow(token: AppConfig.agentToken, foreground: isForeground && settings.followEcho)
        voice.configure(enabled: settings.voiceWakeEnabled, foreground: isForeground,
                        conversationBusy: conversation.isSending)
        updateInvitations()
    }

    private func updateInvitations() {
        if settings.invitationsEnabled && pairing.isPaired {
            invitationTask?.cancel()
            invitationTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isForeground else { return }
                    await self.invitations.refresh(foreground: true)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        } else {
            invitationTask?.cancel(); invitationTask = nil
            invitations.stop()
        }
    }

    private func startLoops() {
        ringTask?.cancel()
        ringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.ring = self.currentRingState()
                // A screensavered stage is not a usable display surface; the
                // delivery presence and claim paths must report that honestly.
                updateSurfaceVisibility()
                // The server-side "is Kairo working anywhere" read is cached
                // for eight seconds by refreshProcessing itself; asking every
                // tick is how kairoBusy can hold the display at all.
                await self.refreshProcessing()
                body.setResponseActive(self.awakeBecauseKairoIsActive())
                // The physical Dot stream ticks at one second; the mirror can
                // afford the same cadence.
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if settings.invitationsEnabled && pairing.isPaired && invitationTask == nil {
            invitationTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.isForeground else { return }
                    await self.invitations.refresh(foreground: true)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    // MARK: - Derived ring state

    func currentRingState(now: Date = Date()) -> RingMirrorState {
        RingMirror.compose(
            dot: echo.state,
            presentation: presentation.snapshot,
            remote: RemoteActs(thinking: feed.processing,
                               answeredAgo: feed.lastAnsweredAt.map { max(0, now.timeIntervalSince($0)) }),
            local: LocalActs(speaking: speech.isBusy,
                             capturing: voice.isCapturing,
                             sending: conversation.isSending),
            now: now)
    }

    func renderState(now: Date = Date()) -> RingRenderState {
        let mirror = currentRingState(now: now)
        let palette = ExpressionPalette.forState(mirror.mood)
        let colors = palette.rgb
        var state = RingRenderState()
        state.moodPrimary = colors.primary
        state.moodAccent = colors.accent
        let levels = RingMirror.resample(mirror.levels, to: RingMirror.emitterCount)
        state.emitterLevels = levels.map(Float.init)
        state.breath = palette.energy * 0.5
        state.energy = Float(max(mirror.intensity, Double(palette.energy) * (mirror.phase == .idle ? 0.25 : 0.7)))
        state.intensity = body.connectionState == .connected || mirror.dotFresh ? 0.95 : 0.55
        state.sleeping = body.screensaverActive
        // The verbs: speaking/thinking/listening animate the ring even when
        // this iPad is the body speaking and the Dot's waveform is stale -
        // the phase itself is the observed fact, as 1.0.x treated it.
        state.activity = RingMirror.activity(for: mirror.phase)
        state.activityLevel = state.activity == .idle ? 0 : Float(max(mirror.intensity, 0.6))
        state.motion = palette.motionMode
        return state
    }

    /// The dozing body stays alive: the ring keeps breathing in Kairo's real
    /// mood colours with damped motion, so the screensaver reads as presence,
    /// not a wallpaper that stopped working.
    func ambientRingState(now: Date = Date()) -> RingRenderState {
        var state = renderState(now: now)
        state.emitterLevels = state.emitterLevels.map { max(0.04, $0 * 0.55) }
        state.energy *= 0.6
        state.breath = max(0.2, state.breath)
        state.intensity = min(max(state.intensity, 0.35), 0.6)
        state.activityLevel *= 0.45
        state.sleeping = false
        return state
    }

    /// Kairo being actually busy anywhere keeps the appliance awake; the Dot's
    /// fresh live phase counts, a bare heartbeat never does.
    private func awakeBecauseKairoIsActive() -> Bool {
        MotionDimmingPolicy.keepsAwake(
            localSending: conversation.isSending,
            localSpeaking: speech.isBusy,
            capturing: voice.isCapturing,
            dotPhase: echo.state.activity?.phase,
            dotActivityFresh: echo.state.activity.map { $0.expiresAt > Date() } ?? false,
            kairoBusy: kairoProcessingCache?.value == true,
            remoteThinking: feed.processing,
            answeredRecently: feed.lastAnsweredAt.map {
                Date().timeIntervalSince($0) <= 8
            } ?? false)
    }

    func refreshProcessing() async {
        guard Date() >= nextProcessingReadAt else { return }
        // Failed reads remain unknown without turning the one-second render
        // loop into an aggressive network retry loop.
        nextProcessingReadAt = Date().addingTimeInterval(8)
        if let value = await conversation.isKairoProcessing() {
            kairoProcessingCache = (value, Date())
        } else if let cache = kairoProcessingCache, Date().timeIntervalSince(cache.at) > 30 {
            kairoProcessingCache = nil
        }
    }

    // MARK: - Contact

    /// A deliberate touch on the body surface is a contact event: it is
    /// flushed through the sensory frame and then claimed so Kairo can
    /// acknowledge the touch itself.
    func bodyContactEnded(durationMs: Int, pathLength: Double, cancelled: Bool) {
        let intent = ContactIntent.classify(durationMs: durationMs, pathLength: pathLength, cancelled: cancelled)
        guard ContactIntent.shouldSubmit(isBodySurface: destination == .stage, cancelled: cancelled,
                                         conversationBusy: conversation.isSending),
              let endpointID = body.serverEndpointID else { return }
        contactCounter += 1
        let contactID = "ipad:\(body.sessionID):\(contactCounter)"
        lastContactAt = Date()
        Task { [weak self] in
            guard let self else { return }
            guard await self.body.flushContact() else { return }
            guard let session = try? await self.conversation.prepareVisualSession() else { return }
            do {
                _ = try await self.conversation.submitTouchReflex(
                    sessionID: session, contactID: contactID,
                    endpointID: endpointID, generation: self.generationToken)
            } catch {
                await MainActor.run { self.conversation.showError(error) }
            }
        }
    }

    private var generationToken: Int { conversation.currentGeneration }

    // MARK: - Presentation apply on the stage

    func setSurfaceVisibility(_ visible: Bool) {
        rootSurfaceVisible = visible
        updateSurfaceVisibility()
    }

    func updateSurfaceVisibility() {
        let visible = rootSurfaceVisible && isForeground && !body.screensaverActive && surfaceUnobscured()
        surfaceDelivery.setDisplayVisible(visible)
        // Both sensory commands and settled output use the root display
        // panel, so scrolling or changing destination cannot hide their act.
        body.setDisplayVisible(visible)
    }

    func pairingChanged() {
        presentation.start(paired: pairing.isPaired, foreground: isForeground)
        feed.followAllSurfaces(foreground: isForeground)
        systems.start(paired: pairing.isPaired, foreground: isForeground)
        updateInvitations()
        if !pairing.isPaired { surfaceDelivery.stop(); privateRoom.stop(); clearStageDisplay() }
    }

    func displayCommand(_ text: String) {
        acknowledgedDisplayID = nil
        stageDisplayID = UUID()
        stageDisplayText = text
    }

    func acknowledgeStageDisplay(_ text: String) {
        guard text == stageDisplayText, rootSurfaceVisible, isForeground, !body.screensaverActive, surfaceUnobscured() else { return }
        acknowledgedDisplayID = stageDisplayID
    }

    private func applyStageDisplay(_ text: String) async -> Bool {
        guard rootSurfaceVisible, isForeground, !body.screensaverActive, surfaceUnobscured() else { return false }
        displayCommand(text)
        let id = stageDisplayID
        for _ in 0..<40 {
            guard rootSurfaceVisible, isForeground, !body.screensaverActive,
                  id == stageDisplayID, !Task.isCancelled, surfaceUnobscured() else { return false }
            if acknowledgedDisplayID == id { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    func clearStageDisplay() { stageDisplayText = nil; acknowledgedDisplayID = nil; stageDisplayID = UUID() }

    func acceptInvitationIntoConversation() async {
        guard let text = await invitations.accept() else { return }
        await conversation.send(text)
    }
}
