import SwiftUI
import AVFoundation

private enum BodyPalette {
    static let top = Color(red: 17 / 255, green: 24 / 255, blue: 39 / 255)
    static let middle = Color(red: 13 / 255, green: 17 / 255, blue: 25 / 255)
    static let bottom = Color(red: 11 / 255, green: 12 / 255, blue: 16 / 255)
    static let blue = Color(red: 97 / 255, green: 151 / 255, blue: 255 / 255)
    static let violet = Color(red: 171 / 255, green: 141 / 255, blue: 255 / 255)
    static let pink = Color(red: 241 / 255, green: 136 / 255, blue: 179 / 255)
    static let teal = Color(red: 81 / 255, green: 203 / 255, blue: 187 / 255)
}

private struct OpeningReveal: ViewModifier {
    let phase: Int
    let appearsAt: Int
    var initialScale: CGFloat = 1
    var initialOffset: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .opacity(phase >= appearsAt ? 1 : 0)
            .scaleEffect(phase >= appearsAt ? 1 : initialScale)
            .offset(y: phase >= appearsAt ? 0 : initialOffset)
            .blur(radius: phase >= appearsAt ? 0 : 7)
            .allowsHitTesting(phase >= appearsAt)
            .accessibilityHidden(phase < appearsAt)
    }
}

struct BodyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var client: BodyClient
    @ObservedObject var conversation: ConversationClient
    @ObservedObject var voice: VoiceInputService
    @ObservedObject var echoConversation: EchoConversationClient
    @ObservedObject var echoPlayback: EchoActivityClient
    @State private var bodyMounted = false
    @State private var touchActive = false
    @State private var touchID = UUID().uuidString
    @State private var showingCamera = false
    @State private var showingSharedVisual = false
    @State private var showingOutputDestination = false
    @State private var messageDraft = ""
    @State private var composerExpanded = false
    @FocusState private var composerFocused: Bool
    @State private var flyingMessage = ""
    @State private var flightAtBody = false
    @State private var didAutoStart = false
    @State private var remoteProcessing = false
    @State private var globalPresentation: GlobalBodyPresentation?
    @State private var openingPhase = 0
    @State private var openingTask: Task<Void, Never>?
    @State private var hasOpened = false

    private var freshPresentation: GlobalBodyPresentation? {
        guard let snapshot = globalPresentation, model.privateBody.isPaired, snapshot.isFresh() else { return nil }
        return snapshot
    }

    private var expressionState: String {
        GlobalBodyPresentation.expressionState(snapshot: globalPresentation,
            paired: model.privateBody.isPaired, fallback: client.display.state)
    }

    private var expressionPalette: BodyExpressionPalette {
        BodyExpressionPalette.forState(expressionState)
    }

    private var bodyActivity: KairoBodyActivity {
        BodyActivityPolicy.resolve(capturing: voice.isCapturing, speaking: conversation.isSpeaking,
            sending: conversation.isSending, processing: echoConversation.processing || (freshPresentation?.processing ?? remoteProcessing),
            dotPhase: echoPlayback.state.activity?.phase,
            dotFresh: echoPlayback.connected && (echoPlayback.state.activity?.expiresAt ?? .distantPast) > Date(),
            connected: client.connectionState == .connected)
    }

    private var responseBusy: Bool {
        conversation.isSending || conversation.isSpeaking || (freshPresentation?.processing ?? remoteProcessing) || echoConversation.processing ||
            ["speaking", "replaying", "speech_detected"].contains(echoPlayback.state.activity?.phase ?? "")
    }

    private var awakeBusy: Bool {
        MotionDimmingPolicy.keepsAwake(localSending: conversation.isSending,
            localSpeaking: conversation.isSpeaking, capturing: voice.isCapturing,
            dotPhase: echoPlayback.state.activity?.phase,
            dotActivityFresh: echoPlayback.connected && (echoPlayback.state.activity?.expiresAt ?? .distantPast) > Date(),
            kairoBusy: kairoForegroundBusy)
    }

    /// Kairo is working on a turn from any surface (background reflection
    /// alone does not hold the screen awake).
    private var kairoForegroundBusy: Bool {
        echoConversation.processing ||
            ((freshPresentation?.phase).map { ["working", "queued", "waiting"].contains($0) } ?? remoteProcessing)
    }

    private var plasmaActive: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-plasma") { return true }
        #endif
        return bodyActivity == .working || bodyActivity == .speaking
    }

    private var activityCaption: String? {
        switch bodyActivity {
        case .listening: return "LISTENING"
        case .working:
            if freshPresentation?.phase == "background" { return "KAIRO IS THINKING IN THE BACKGROUND" }
            if freshPresentation?.phase == "queued" { return "KAIRO IS PREPARING" }
            return "KAIRO IS THINKING"
        case .speaking: return "KAIRO IS SPEAKING"
        default: return freshPresentation?.phase == "waiting" ? "WAITING FOR A DECISION" : nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            bodyContents(size: geo.size)
        }
        .coordinateSpace(name: "bodyDisplay")
        .statusBarHidden(true)
        .onAppear {
            bodyMounted = true
            updateDisplayVisibility()
            if !hasOpened {
                hasOpened = true
                playOpening()
            }
            conversation.setForeground(scenePhase == .active)
            model.surfaceDelivery.setForeground(scenePhase == .active)
            model.updateEcho(foreground: scenePhase == .active)
            voice.onWake = { client.noteUserActivity() }
            voice.onCommand = { command in
                client.noteUserActivity()
                conversation.speakReplies = true
                Task {
                    await conversation.send(command, attachmentIDs: model.sharedVisual.attachmentIDs(for: model.sharedVisual.sessionID ?? ""), attachmentSessionID: model.sharedVisual.sessionID)
                    if !conversation.isSending && !conversation.isSpeaking {
                        voice.responseFinished()
                    }
                }
            }
            voice.configure(enabled: model.settings.voiceWakeEnabled,
                            foreground: scenePhase == .active,
                            conversationBusy: responseBusy)
            guard !didAutoStart else { return }
            didAutoStart = true
            if client.connectionState == .stopped,
               !model.settings.websocketURL.isEmpty,
               !model.settings.bearerToken.isEmpty {
                client.start()
            }
        }
        .onDisappear {
            bodyMounted = false
            client.setDisplayVisible(false)
            model.surfaceDelivery.setDisplayVisible(false)
            openingTask?.cancel()
            openingPhase = 4
            model.sensors.cancelTouches()
            touchActive = false
            voice.configure(foreground: false)
            conversation.setForeground(false)
            model.surfaceDelivery.setForeground(false)
            model.invitations.stop()
            model.updateEcho(foreground: false)
        }
        .onReceive(model.privateBody.$isPaired.dropFirst()) { _ in
            model.updateEcho(foreground: scenePhase == .active)
        }
        .onChange(of: bodyDisplayVisible) { _, _ in updateDisplayVisibility() }
        .onChange(of: client.screensaverActive) { wasAsleep, isAsleep in
            if wasAsleep && !isAsleep { playOpening() }
        }
        .onReceive(model.settings.$voiceWakeEnabled) { enabled in
            voice.configure(enabled: enabled)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.sensors.cancelTouches(); model.sharedVisual.clear(); touchActive = false }
            if phase != .active { model.invitations.stop() }
            conversation.setForeground(phase == .active)
            model.surfaceDelivery.setForeground(phase == .active)
            client.setForeground(phase == .active)
            model.updateEcho(foreground: phase == .active)
            voice.configure(foreground: phase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if touchActive { model.sensors.cancelTouches(); touchActive = false }
        }
        .onChange(of: awakeBusy, initial: true) { _, active in client.setResponseActive(active) }
        .onChange(of: responseBusy) { wasActive, active in
            voice.configure(conversationBusy: active)
            if wasActive && !active {
                voice.responseFinished()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { globalPresentation = nil; remoteProcessing = false; return }
            while !Task.isCancelled {
                let snapshot = await model.privateBody.fetchPresentation()
                guard !Task.isCancelled else { return }
                globalPresentation = GlobalBodyPresentation.afterRefresh(snapshot, previous: globalPresentation)
                if freshPresentation != nil { remoteProcessing = false }
                else {
                    // No fresh mood is retained on failure. The legacy aggregate is activity only.
                    remoteProcessing = false
                    let processing = await conversation.isKairoProcessing()
                    guard !Task.isCancelled else { return }
                    remoteProcessing = processing ?? false
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { model.invitations.stop(); return }
            while !Task.isCancelled {
                let session = model.settings.followEcho ? model.settings.echoSessionID : model.settings.agentSessionID
                await model.invitations.refresh(sessionID: session,
                    foreground: bodyDisplayVisible && model.settings.invitationsEnabled && !responseBusy && !voice.isCapturing)
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .sheet(isPresented: $model.settingsPresented) { SettingsView() }
        .sheet(isPresented: $showingOutputDestination) {
            OutputDestinationView(conversation: conversation, privateBody: model.privateBody)
        }
        .sheet(isPresented: $showingSharedVisual) {
            SharedVisualView(context: model.sharedVisual, conversation: conversation, settings: model.settings,
                captureFront: { try await model.captureSharedFrontPhoto() })
        }
        .onReceive(model.settings.$followEcho.dropFirst()) { _ in model.sharedVisual.clear() }
        .onReceive(model.settings.$agentWorkspaceID.dropFirst()) { _ in model.sharedVisual.clear() }
        .onReceive(model.settings.$echoSessionID.dropFirst()) { _ in model.sharedVisual.clear() }
        .fullScreenCover(isPresented: $showingCamera) {
            ManualCameraPicker(onPhoto: { image in
                showingCamera = false
                Task { await client.sendManualCamera(image: image) }
                client.resumeFrontMotion()
            }, onCancel: {
                showingCamera = false
                client.resumeFrontMotion()
            })
            .ignoresSafeArea()
        }
    }

    private var bodyDisplayVisible: Bool {
        bodyMounted && scenePhase == .active && !client.screensaverActive &&
            !model.settingsPresented && !showingOutputDestination && !showingSharedVisual &&
            !showingCamera && !composerExpanded && openingPhase >= 4
    }

    private func updateDisplayVisibility() {
        client.setDisplayVisible(bodyDisplayVisible)
        model.surfaceDelivery.setDisplayVisible(bodyDisplayVisible)
        if !bodyDisplayVisible { model.invitations.stop() }
    }

    private func playOpening() {
        openingTask?.cancel()
        guard !reduceMotion else {
            openingPhase = 4
            return
        }
        openingPhase = 0
        openingTask = Task { @MainActor in
            for (pause, phase) in [(80, 1), (300, 2), (270, 3), (240, 4)] {
                try? await Task.sleep(for: .milliseconds(pause))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.58, dampingFraction: 0.78)) {
                    openingPhase = phase
                }
            }
            openingTask = nil
        }
    }

    private func bodyContents(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [BodyPalette.top, BodyPalette.middle, BodyPalette.bottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            KairoPlasmaView(expression: expressionPalette.form, activity: bodyActivity,
                            visible: plasmaActive && !reduceMotion && !client.screensaverActive)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            mainContent(size: size)
            if composerExpanded {
                expandedComposer
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    .zIndex(2)
            }
            if !flyingMessage.isEmpty { flyingMessageView(size: size) }
            if client.screensaverActive { screenSaverView }
        }
    }

    private func flyingMessageView(size: CGSize) -> some View {
        Text(flyingMessage)
            .font(.subheadline.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(expressionPalette.primary.opacity(0.28), in: Capsule())
            .frame(maxWidth: 420)
            .scaleEffect(flightAtBody ? 0.22 : 1)
            .opacity(flightAtBody ? 0 : 1)
            .offset(y: flightAtBody ? -size.height * 0.23 : size.height * 0.18)
            .allowsHitTesting(false)
            .zIndex(3)
    }

    private var screenSaverView: some View {
        GeometryReader { space in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let seconds = timeline.date.timeIntervalSince1970
                let travelX: CGFloat = max(0, space.size.width / 2 - 105)
                let travelY: CGFloat = max(0, space.size.height / 2 - 125)
                VStack(spacing: 18) {
                    KairoMetalBodyView(expression: expressionPalette.form,
                                       profile: KairoBodyProfile(), activity: .idle,
                                       activityIntensity: 0)
                        .frame(width: 144, height: 144)
                    Text(timeline.date, style: .time)
                        .font(.system(size: 32, weight: .light, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .offset(x: CGFloat(sin(seconds / 13)) * travelX,
                        y: CGFloat(cos(seconds / 17)) * travelY)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BodyPalette.bottom)
                .contentShape(Rectangle())
                .onTapGesture { client.noteUserActivity() }
                .accessibilityLabel("Kairo screen saver; tap to wake")
            }
        }
    }

    private func mainContent(size: CGSize) -> some View {
                ScrollView {
                    VStack(spacing: 22) {
                        HStack {
                            Text("KAIRO / BODY")
                                .font(.caption.monospaced().weight(.semibold))
                                .tracking(3)
                                .foregroundStyle(BodyPalette.blue)
                            Spacer()
                            if conversation.isSending || conversation.isSpeaking {
                                Button(role: .destructive) {
                                    Task { await conversation.stopResponse() }
                                } label: {
                                    Label("STOP", systemImage: "stop.fill")
                                        .font(.caption.monospaced().weight(.bold))
                                        .padding(.horizontal, 12)
                                        .frame(height: 38)
                                        .background(BodyPalette.pink.opacity(0.14), in: Capsule())
                                }
                                .accessibilityLabel("Stop Kairo response")
                            }
                            Menu {
                                Button {
                                    Task {
                                        await client.suspendFrontMotion()
                                        showingCamera = true
                                    }
                                } label: {
                                    Label("Front Snapshot", systemImage: "camera")
                                }
                                .disabled(client.connectionState != .connected)
                                if client.connectionState != .stopped {
                                    Button(role: .destructive) { client.stop() } label: {
                                        Label("Stop Body", systemImage: "stop.circle")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Body actions")
                            Button {
                                model.settingsPresented = true
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Settings")
                        }
                        .buttonStyle(.plain)
                        .modifier(OpeningReveal(phase: openingPhase, appearsAt: 3,
                                                initialOffset: -20))

                        Spacer(minLength: 4)

                        Text(client.display.headline)
                            .font(.system(size: 54, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .modifier(OpeningReveal(phase: openingPhase, appearsAt: 2,
                                                    initialScale: 0.94))

                        ZStack(alignment: .topLeading) {
                            if !reduceMotion {
                                Circle()
                                    .stroke(AngularGradient(colors: [BodyPalette.blue.opacity(0.05),
                                                                     expressionPalette.primary,
                                                                     BodyPalette.teal.opacity(0.7),
                                                                     BodyPalette.blue.opacity(0.05)],
                                                            center: .center), lineWidth: 2)
                                    .frame(width: min(min(size.width * 0.58, size.height * 0.38), 360) + 34,
                                           height: min(min(size.width * 0.58, size.height * 0.38), 360) + 34)
                                    .scaleEffect(openingPhase >= 2 ? 1.22 : 0.66)
                                    .rotationEffect(.degrees(openingPhase >= 2 ? 70 : -65))
                                    .opacity(openingPhase >= 3 ? 0 : 0.72)
                                    .offset(x: -17, y: -17)
                                    .allowsHitTesting(false)
                            }
                            touchSurface(displaySize: size)
                                .frame(
                                    width: min(min(size.width * 0.58, size.height * 0.38), 360),
                                    height: min(min(size.width * 0.58, size.height * 0.38), 360)
                                )
                                .accessibilityLabel("Touch Kairo")
                            if model.settings.cameraMode, let session = client.frontCameraSession {
                                FrontCameraCircle(session: session)
                                    .frame(width: 104, height: 104)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(BodyPalette.teal.opacity(0.7), lineWidth: 2))
                                    .offset(x: -58, y: -20)
                                    .accessibilityLabel("Local front camera preview")
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: min(min(size.width * 0.58, size.height * 0.38), 360),
                               height: min(min(size.width * 0.58, size.height * 0.38), 360),
                               alignment: .topLeading)
                        .modifier(OpeningReveal(phase: openingPhase, appearsAt: 1,
                                                initialScale: 0.72, initialOffset: 0))

                        Text(expressionState.uppercased())
                            .font(.caption.monospaced().weight(.bold))
                            .tracking(3)
                            .foregroundStyle(expressionPalette.primary)
                            .modifier(OpeningReveal(phase: openingPhase, appearsAt: 2))
                        if let activityCaption {
                            Text(activityCaption)
                                .font(.caption.monospaced().weight(.semibold))
                                .tracking(2)
                                .foregroundStyle(BodyPalette.teal)
                                .accessibilityLabel(activityCaption)
                                .modifier(OpeningReveal(phase: openingPhase, appearsAt: 2))
                        }

                        if model.privateBody.isPaired {
                            EchoPanel(conversation: echoConversation, playback: echoPlayback)
                                .modifier(OpeningReveal(phase: openingPhase, appearsAt: 4))
                        }
                        conversationPanel
                            .modifier(OpeningReveal(phase: openingPhase, appearsAt: 4))

                        if client.connectionState == .stopped || client.connectionState == .error {
                            Button("Start Body") { client.start() }
                                .buttonStyle(.borderedProminent)
                                .tint(BodyPalette.blue)
                                .controlSize(.large)
                                .modifier(OpeningReveal(phase: openingPhase, appearsAt: 4))
                        }

                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                connectionBadge
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sensorAvailability(now: timeline.date))
                                        Text(bodyPoseStatus(now: timeline.date))
                                        Text(bodyProximityStatus(now: timeline.date))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.7))
                                }
                                Spacer(minLength: 0)
                            }
                            if let lastFrame = client.lastFrameAt {
                                Text("Last body frame: \(lastFrame.formatted(date: .omitted, time: .standard))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white.opacity(0.55))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let error = client.lastError {
                                HStack(spacing: 12) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(BodyPalette.pink)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.72))
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    Button("Retry") { client.retry() }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(BodyPalette.blue)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                        .modifier(OpeningReveal(phase: openingPhase, appearsAt: 4))

                        Spacer(minLength: 4)
                    }
                    .frame(maxWidth: 940)
                    .frame(minHeight: size.height)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
    }

    private var conversationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            InvitationView(client: model.invitations, onAccept: { question in
                Task {
                    guard scenePhase == .active, !responseBusy else { return }
                    await conversation.send("I accepted your invitation: \(question)")
                }
            })
            Button("Reply destination", systemImage: "speaker.wave.2") { showingOutputDestination = true }
                .buttonStyle(.bordered)
            Button("Look together", systemImage: "photo") { showingSharedVisual = true }
                .buttonStyle(.bordered)
                .accessibilityHint("Select one image or take a front-camera photo to discuss with Kairo")
            if !conversation.reply.isEmpty {
                Text(conversation.reply)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(expressionPalette.primary.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Kairo replied: \(conversation.reply)")
            }
            if !voice.lastCommand.isEmpty {
                Text("You said: \(voice.lastCommand)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button {
                    openComposer()
                } label: {
                    HStack {
                        Image(systemName: "text.cursor")
                            .foregroundStyle(expressionPalette.primary)
                        Text(messageDraft.isEmpty ? "Message Kairo" : messageDraft)
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(messageDraft.isEmpty ? 0.55 : 0.9))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("Open message composer")
                Button {
                    model.settings.voiceWakeEnabled.toggle()
                } label: {
                    Image(systemName: model.settings.voiceWakeEnabled ? "mic.fill" : "mic.slash")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(model.settings.voiceWakeEnabled
                    ? "Turn off Kairo voice wake" : "Listen for Kairo voice wake")
                Button {
                    conversation.speakReplies.toggle()
                } label: {
                    Image(systemName: conversation.speakReplies ? "speaker.wave.2" : "speaker.slash")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(conversation.speakReplies ? "Spoken replies on" : "Spoken replies off")
                Button {
                    conversation.clearChat()
                    voice.clearTranscript()
                    messageDraft = ""
                    flyingMessage = ""
                    composerFocused = false
                    withAnimation(.easeOut(duration: 0.2)) { composerExpanded = false }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(model.settings.followEcho ? "Clear the iPad reply" : "Clear chat and start a new conversation")
            }
            .buttonStyle(.plain)
            .foregroundStyle(expressionPalette.primary)
            if model.settings.voiceWakeEnabled {
                HStack(spacing: 8) {
                    Image(systemName: voice.isCapturing ? "waveform" : "mic")
                    Text(voice.heardText.isEmpty ? voice.status : "Heard: \(voice.heardText)")
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(BodyPalette.teal)
                .accessibilityLabel("Voice input: \(voice.status)")
            }
            if let error = voice.error {
                Text(error).font(.caption).foregroundStyle(BodyPalette.pink)
            }
            conversationProgress
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func sendMessage() {
        let submitted = messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, !conversation.isSending else { return }
        composerFocused = false
        withAnimation(.easeOut(duration: 0.22)) { composerExpanded = false }
        if !reduceMotion {
            flyingMessage = String(submitted.prefix(90))
            flightAtBody = false
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                withAnimation(.easeInOut(duration: 0.65)) { flightAtBody = true }
                try? await Task.sleep(for: .milliseconds(700))
                flyingMessage = ""
            }
        }
        messageDraft = ""
        Task {
            await conversation.send(submitted, attachmentIDs: model.sharedVisual.attachmentIDs(for: model.sharedVisual.sessionID ?? ""), attachmentSessionID: model.sharedVisual.sessionID)
            // Only a message Kairo definitely did not accept returns to the
            // composer; a kept one is resent with its key via Retry instead.
            if conversation.error != nil && conversation.reply.isEmpty && conversation.pendingRecovery == nil {
                messageDraft = submitted
            }
        }
        client.noteUserActivity()
    }

    private func openComposer() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            composerExpanded = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            if composerExpanded { composerFocused = true }
        }
        client.noteUserActivity()
    }

    private var expandedComposer: some View {
        ZStack {
            BodyPalette.bottom.opacity(0.91).ignoresSafeArea()
                .onTapGesture {
                    composerFocused = false
                    withAnimation(.easeOut(duration: 0.2)) { composerExpanded = false }
                }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Speak to Kairo")
                            .font(.title2.weight(.semibold))
                        Text(client.connectionState == .connected
                             ? (model.settings.followEcho ? "Body connected · shared Echo conversation" : "Body connected · private conversation")
                             : (model.settings.followEcho ? "Shared Echo conversation" : "Private conversation"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    Spacer()
                    Button {
                        composerFocused = false
                        withAnimation(.easeOut(duration: 0.2)) { composerExpanded = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Close composer")
                }
                ZStack(alignment: .topLeading) {
                    if messageDraft.isEmpty {
                        Text("What would you like to tell Kairo?")
                            .foregroundStyle(.white.opacity(0.36))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }
                    TextEditor(text: $messageDraft)
                        .focused($composerFocused)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white)
                        .frame(minHeight: 140, maxHeight: 220)
                        .accessibilityLabel("Message to Kairo")
                }
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                HStack {
                    Text("\(messageDraft.count) / 4,000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(messageDraft.count > 4_000 ? BodyPalette.pink : .white.opacity(0.55))
                    Spacer()
                    Button("Send to Kairo") { sendMessage() }
                        .buttonStyle(.borderedProminent)
                        .tint(expressionPalette.primary)
                        .disabled(messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || messageDraft.count > 4_000 || conversation.isSending)
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
            .background(BodyPalette.middle, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28)
                .stroke(expressionPalette.primary.opacity(0.35), lineWidth: 1))
            .shadow(color: expressionPalette.primary.opacity(0.13), radius: 35)
            .padding(24)
        }
    }

    private var conversationProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = conversation.error {
                Text(error).font(.caption).foregroundStyle(BodyPalette.pink)
            } else if !conversation.status.isEmpty {
                HStack(spacing: 8) {
                    if conversation.isSending { ProgressView().controlSize(.mini) }
                    Text(conversation.status)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            if let recovery = conversation.pendingRecovery {
                Button(recovery == .unconfirmed ? "Retry sending" : "Check again for Kairo's reply",
                       systemImage: "arrow.clockwise") {
                    Task { await conversation.recoverPending() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .disabled(conversation.isSending)
                .accessibilityHint(recovery == .unconfirmed
                    ? "Sends the same message once; Kairo ignores duplicates"
                    : "Looks for the reply to your last message")
            }
            if let progress = conversation.promptProgress {
                if let total = progress.total {
                    ProgressView(value: Double(min(progress.processed, total)), total: Double(total))
                        .tint(expressionPalette.primary)
                }
                HStack {
                    Text("Prompt context: \(progress.processed.formatted())\(progress.total.map { " / \($0.formatted())" } ?? "") tokens")
                    Spacer()
                    if let cached = progress.cached { Text("\(cached.formatted()) cached") }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.58))
            }
            if !conversation.lastJobID.isEmpty {
                Text("Job \(conversation.lastJobID.suffix(8))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.43))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sensorAvailability(now: Date) -> String {
        if client.connectionState == .stopped { return "Sensors stopped" }
        guard client.connectionState == .connected, let frame = client.lastSensorFrame,
              freshReading(frame.observedAt, now: now) else { return "Sensors awaiting fresh readings" }
        let motion = frame.motion.available && frame.motion.sampleCount > 0 &&
            freshReading(frame.motion.observedAt, now: now) ? "Motion live" : "Motion unavailable"
        let pressure = frame.pressure.available && frame.pressure.pressureHPa != nil && freshReading(frame.pressure.observedAt, now: now) ? "Pressure live" : "Pressure unavailable"
        let compass = frame.motion.magneticHeadingDeg != nil && freshReading(frame.motion.observedAt, now: now) ? "Compass live" : "Compass unavailable"
        let location = frame.location.enabled ? (frame.location.available && freshReading(frame.location.observedAt, now: now) ? "Location live" : "Location unavailable") : "Location off"
        return [motion, pressure, compass, location].joined(separator: " · ")
    }

    private func bodyProximityStatus(now: Date) -> String {
        guard model.privateBody.isPaired, let snapshot = globalPresentation,
              snapshot.isFresh(at: now), let sense = snapshot.proximity, sense.isFresh(at: now) else {
            return "Body proximity awaiting a fresh reading"
        }
        return "Body proximity: \(sense.state) · phone surface"
    }

    private func freshReading(_ timestamp: String?, now: Date) -> Bool {
        guard let timestamp, let observed = BodyJSON.iso8601.date(from: timestamp) else { return false }
        return (0...35).contains(now.timeIntervalSince(observed))
    }

    private func bodyPoseStatus(now: Date) -> String {
        guard client.connectionState == .connected,
              let frame = client.lastSensorFrame,
              freshReading(frame.observedAt, now: now) else {
            return "Movement / orientation awaiting fresh readings"
        }
        var parts: [String] = []
        if frame.motion.available, frame.motion.sampleCount > 0,
           freshReading(frame.motion.observedAt, now: now) {
            switch frame.motion.movement {
            case "still": parts.append("Still")
            case "moving": parts.append("Moving")
            case "picked_up_or_jolted": parts.append("Strong movement detected")
            default: parts.append("Movement unknown")
            }
            for (name, angle) in [("roll", frame.motion.rollDeg), ("pitch", frame.motion.pitchDeg)] {
                if let angle, angle.isFinite, (-180...180).contains(angle) {
                    parts.append("\(name) \(Int(angle.rounded()))°")
                }
            }
        } else {
            parts.append("Movement unavailable")
        }
        if freshReading(frame.device.observedAt, now: now) {
            switch frame.device.orientation {
            case "portrait": parts.append("Portrait")
            case "portrait_upside_down": parts.append("Portrait upside down")
            case "landscape_left", "landscape_right": parts.append("Landscape")
            case "face_up": parts.append("Face up")
            case "face_down": parts.append("Face down")
            default: parts.append("Orientation unknown")
            }
        } else {
            parts.append("Orientation unavailable")
        }
        return parts.joined(separator: " · ")
    }

    private var connectionBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.connectionState == .connected ? BodyPalette.teal : BodyPalette.pink)
                .frame(width: 9, height: 9)
            Text(client.connectionState.rawValue)
                .font(.caption.monospaced().weight(.semibold))
        }
    }

    private func touchSurface(displaySize: CGSize) -> some View {
        GeometryReader { local in
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                KairoMetalBodyView(expression: expressionPalette.form,
                                   profile: KairoBodyProfile(), activity: bodyActivity,
                                   activityIntensity: bodyActivity == .speaking
                                       ? Float(echoPlayback.state.activity?.outputIntensity ?? 0.9)
                                       : (bodyActivity == .idle ? 0 : 0.9))
                    .clipShape(Circle())
                Circle()
                    .strokeBorder(expressionPalette.accent.opacity(touchActive ? 0.85 : 0.22),
                                  lineWidth: touchActive ? 8 : 2)
                    .animation(.easeOut(duration: 0.15), value: touchActive)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = local.frame(in: .named("bodyDisplay")).origin
                        let x = min(max((origin.x + value.location.x) / max(displaySize.width, 1), 0), 1)
                        let y = min(max((origin.y + value.location.y) / max(displaySize.height, 1), 0), 1)
                        if !touchActive {
                            client.noteUserActivity()
                            touchActive = true
                            touchID = UUID().uuidString
                            model.sensors.recordTouchBegan(id: touchID, x: x, y: y)
                        } else {
                            model.sensors.recordTouchMoved(id: touchID, x: x, y: y)
                        }
                    }
                    .onEnded { value in
                        guard touchActive else { return }
                        let origin = local.frame(in: .named("bodyDisplay")).origin
                        let x = min(max((origin.x + value.location.x) / max(displaySize.width, 1), 0), 1)
                        let y = min(max((origin.y + value.location.y) / max(displaySize.height, 1), 0), 1)
                        model.sensors.recordTouchEnded(id: touchID, x: x, y: y)
                        let endedID = touchID
                        touchActive = false
                        if client.connectionState == .connected,
                           ContactIntent.shouldSubmit(isBodySurface: true, cancelled: false,
                                conversationBusy: responseBusy || voice.isCapturing) {
                            Task {
                                guard await client.flushContact(), !responseBusy, !voice.isCapturing,
                                      let endpoint = client.serverEndpointID else { return }
                                await conversation.sendTouchReflex(contactID: endedID, endpointID: endpoint)
                            }
                        }
                    }
            )
        }
    }
}
