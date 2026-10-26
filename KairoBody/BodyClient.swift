import Foundation
import UIKit
import AVFoundation

/// The `kairo-body/1` sensory endpoint client: one authenticated WebSocket to
/// the memory service, bounded 17 s frames, capability negotiation, command
/// execution with an action-event lifecycle, and ingestion receipts for
/// camera and one-shot location observations.
@MainActor
final class BodyClient: ObservableObject {
    enum ConnectionState: String {
        case stopped = "Stopped"
        case connecting = "Connecting"
        case connected = "Connected"
        case reconnecting = "Reconnecting"
        case error = "Error"
    }

    struct DisplayState {
        var state = "awaiting state"
        var headline = "Kairo"
        var detail = "Waiting for Kairo's current expression"
        var surfaceText: String {
            [headline, state.capitalized, detail].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    var applyDisplay: (DisplayState) async -> Bool = { _ in false }

    @Published private(set) var connectionState: ConnectionState = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var lastFrameAt: Date?
    @Published private(set) var lastSensorFrame: SensorFrame?
    @Published var display = DisplayState()
    @Published private(set) var screensaverActive = false
    @Published private(set) var frontCameraSession: AVCaptureSession?
    @Published private(set) var capabilitiesConfirmedAt: Date?
    @Published private(set) var serverEndpointID: String?

    private let settings: AppSettings
    private let sensors: SensorManager
    private let speech: SpeechService
    private let camera: CameraCaptureService
    private let frontMotion = FrontCameraMotionDetector()
    private var dimmingPolicy = MotionDimmingPolicy(idleSeconds: 60, darkSeconds: 1_800)
    private var dimmingTask: Task<Void, Never>?
    private var savedBrightness: CGFloat?
    private var brightnessRampTask: Task<Void, Never>?
    private var dimmingStage: MotionDimmingPolicy.Stage = .awake
    private var isForeground = true
    private var displayVisible = false
    private var frontMotionSuspended = false
    private var responseActive = false

    private var socket: BodySocket?
    private let makeSocket: (URLRequest) -> BodySocket
    private let timing: BodyLinkTiming
    private var frameTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var gate = TransportGate()
    private var shouldRun = false
    private var sequence = 0
    private var reconnectAttempt = 0
    private var capabilitiesNegotiated = false
    private var actionEventsNegotiated = false
    private var actionLifecycle = BodyActionLifecycle()
    private let observationDelivery = ObservationDelivery()
    private var cameraBusy = false
    private var locationDeliveryPending = false
    private var lastFrameSentAt: Date?
    private var actionTasks: [String: Task<Void, Never>] = [:]
    private var transportGeneration = UUID()
    private var capabilitySequence = 0
    private var permissionRevision = 0
    private var lastCapabilityPermissions: String?
    private var capabilitySentAt: [Int: Date] = [:]
    private var acknowledgedCapabilitySequence = -1
    private var receivedDisplayCommandOnTransport = false
    private var linkActivity = LinkActivity()

    let sessionID = UUID().uuidString.lowercased()

    init(settings: AppSettings, sensors: SensorManager, speech: SpeechService,
         camera: CameraCaptureService,
         makeSocket: @escaping (URLRequest) -> BodySocket = SessionBoundSocket.open,
         timing: BodyLinkTiming = BodyLinkTiming()) {
        self.makeSocket = makeSocket
        self.timing = timing
        self.settings = settings
        self.sensors = sensors
        self.speech = speech
        self.camera = camera
        speech.onAvailabilityChange = { [weak self] in
            Task { @MainActor [weak self] in await self?.sendCapabilities() }
        }
        sensors.onPermissionsChanged = { [weak self] in
            Task { @MainActor [weak self] in await self?.sendCapabilities() }
        }
        frontMotion.onSessionChanged = { [weak self] session in
            self?.frontCameraSession = session
        }
    }

    func start() {
        guard !shouldRun else { return }
        guard URL(string: AppConfig.bodySocketURL) != nil, !AppConfig.sensoryToken.isEmpty else {
            lastError = "This copy of Kairo was not provisioned with body credentials."
            connectionState = .error
            return
        }
        shouldRun = true
        sequence = 0
        reconnectAttempt = 0
        lastError = nil
        sensors.start(sendLocation: settings.sendLocation)
        updateMotionDimming()
        connect()
    }

    func stop() {
        shouldRun = false
        capabilitiesNegotiated = false
        actionEventsNegotiated = false
        capabilitiesConfirmedAt = nil
        serverEndpointID = nil
        observationDelivery.cancel()
        actionTasks.values.forEach { $0.cancel() }; actionTasks.removeAll()
        frameTask?.cancel(); frameTask = nil
        receiveTask?.cancel(); receiveTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        livenessTask?.cancel(); livenessTask = nil
        gate.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        sensors.stop()
        sensors.onSignificantMovement = nil
        dimmingTask?.cancel(); dimmingTask = nil
        brightnessRampTask?.cancel(); brightnessRampTask = nil
        Task { await frontMotion.stop() }
        restoreBrightness()
        savedBrightness = nil
        speech.stop()
        responseActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        lastError = nil
        connectionState = .stopped
    }

    func retry() {
        guard shouldRun else { start(); return }
        guard connectionState == .reconnecting else { return }
        connect()
    }

    /// Foreground return: prove the current socket answers now instead of
    /// waiting for the next heartbeat, or skip a pending reconnect backoff.
    func checkLivenessNow() {
        guard shouldRun, isForeground else { return }
        if let transport = gate.current, let socket, connectionState == .connected {
            Task { await probe(socket, transport: transport) }
        } else if gate.reconnectPending {
            // Waiting out a backoff with no attempt in flight: try now.
            connect()
        }
    }

    private func probe(_ socket: BodySocket, transport: UUID) async {
        let alive = await LivenessProbe.answered(within: timing.livenessDeadline) {
            try await socket.sendPing()
        }
        guard gate.isCurrent(transport) else { return }
        if alive {
            linkActivity.note()
            return
        }
        handleDisconnect(BodyLinkError.noPong, transport: transport)
    }

    private func startLiveness(_ socket: BodySocket, transport: UUID) {
        livenessTask?.cancel()
        let interval = timing.livenessInterval
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.gate.isCurrent(transport) else { return }
                // Heartbeats run only while the app is active; iOS suspends it otherwise.
                guard self.isForeground else { continue }
                // The supervisor needs no cooperation from a dead peer: even if
                // pings never call back, currency tells the truth.
                if self.linkActivity.stale(at: Date(), after: self.timing.activityStale) {
                    self.handleDisconnect(BodyLinkError.noActivity, transport: transport)
                    return
                }
                await self.probe(socket, transport: transport)
            }
        }
    }

    func updateMotionDimming() {
        guard shouldRun else { return }
        UIApplication.shared.isIdleTimerDisabled = settings.keepAwake || settings.dimWhenStill
        dimmingTask?.cancel(); dimmingTask = nil
        restoreBrightness()
        if !settings.dimWhenStill && !settings.cameraMode {
            sensors.onSignificantMovement = nil
            Task { await frontMotion.stop() }
            restoreBrightness()
            savedBrightness = nil
            return
        }
        if !settings.dimWhenStill {
            sensors.onSignificantMovement = nil
            if isForeground { resumeFrontMotion() }
            return
        }
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        dimmingPolicy = MotionDimmingPolicy(idleSeconds: 60,
                                            darkSeconds: TimeInterval(settings.screensaverMinutes * 60))
        sensors.onSignificantMovement = { [weak self] in self?.noteUserActivity() }
        frontMotion.onMovement = { [weak self] in
            Task { @MainActor [weak self] in self?.noteUserActivity() }
        }
        if isForeground { resumeFrontMotion() }
        dimmingTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.shouldRun {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.shouldRun, self.isForeground else { continue }
                self.applyDimming(self.dimmingPolicy.observe(at: Date(), movement: self.dimmingIsBusy()))
            }
        }
    }

    /// The screensaver clock advances only on genuine quiet. Local work and
    /// Kairo's actual activity on any surface (seen through AppModel) count as
    /// movement; a bare heartbeat never does. The closure keeps this client
    /// independent of the composition root.
    var dimmingBusyProbe: () -> Bool = { false }
    private func dimmingIsBusy() -> Bool { responseActive || dimmingBusyProbe() }

    func noteUserActivity() {
        guard shouldRun, settings.dimWhenStill, isForeground else { return }
        applyDimming(dimmingPolicy.observe(at: Date(), movement: true))
    }

    func setResponseActive(_ active: Bool) {
        guard responseActive != active else { return }
        responseActive = active
        guard shouldRun, settings.dimWhenStill, isForeground else { return }
        applyDimming(dimmingPolicy.observe(at: Date(), movement: true))
    }

    func setDisplayVisible(_ value: Bool) {
        guard displayVisible != value else { return }
        displayVisible = value
        Task { await sendCapabilities() }
    }

    func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        Task { await sendCapabilities() }
        if foreground {
            checkLivenessNow()
            if shouldRun { sensors.start(sendLocation: settings.sendLocation) }
            dimmingPolicy = MotionDimmingPolicy(idleSeconds: 60,
                                                darkSeconds: TimeInterval(settings.screensaverMinutes * 60))
            if shouldRun, (settings.dimWhenStill || settings.cameraMode) { resumeFrontMotion() }
        } else {
            sensors.stop()
            speech.stop()
            observationDelivery.cancel()
            actionTasks.values.forEach { $0.cancel() }; actionTasks.removeAll()
            Task { await frontMotion.stop() }
            restoreBrightness()
        }
    }

    func suspendFrontMotion() async {
        frontMotionSuspended = true
        await frontMotion.stop()
    }

    func resumeFrontMotion() {
        frontMotionSuspended = false
        guard shouldRun, (settings.dimWhenStill || settings.cameraMode), isForeground else { return }
        Task { [weak self] in
            guard let self else { return }
            let started = await self.frontMotion.start()
            if !self.shouldRun || !self.isForeground || self.frontMotionSuspended ||
                !(self.settings.dimWhenStill || self.settings.cameraMode) {
                await self.frontMotion.stop()
            } else if !started {
                self.lastError = "Front camera motion detection unavailable; iPad movement still wakes the display."
            }
        }
    }

    private func applyDimming(_ stage: MotionDimmingPolicy.Stage) {
        let stage = responseActive ? MotionDimmingPolicy.Stage.awake : stage
        guard stage != dimmingStage else {
            if stage == .awake && brightnessRampTask == nil {
                savedBrightness = UIScreen.main.brightness
            }
            return
        }
        dimmingStage = stage
        screensaverActive = stage != .awake
        switch stage {
        case .awake: rampBrightness(to: savedBrightness ?? 0.5, seconds: 0.8)
        case .screensaver: rampBrightness(to: min(savedBrightness ?? 0.5, 0.25), seconds: 3)
        case .dark: rampBrightness(to: 0, seconds: 3)
        }
    }

    private func rampBrightness(to target: CGFloat, seconds: Double) {
        brightnessRampTask?.cancel()
        let initial = UIScreen.main.brightness
        brightnessRampTask = Task { [weak self] in
            let steps = max(1, Int(seconds * 20))
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                let progress = CGFloat(step) / CGFloat(steps)
                UIScreen.main.brightness = initial + (target - initial) * progress
            }
            self?.brightnessRampTask = nil
        }
    }

    private func restoreBrightness() {
        brightnessRampTask?.cancel(); brightnessRampTask = nil
        if dimmingStage != .awake { UIScreen.main.brightness = savedBrightness ?? 0.5 }
        dimmingStage = .awake
        screensaverActive = false
    }

    func sendSensorFrame() async {
        await sendCapabilities()
        guard shouldRun, isForeground, !locationDeliveryPending, connectionState == .connected,
              lastFrameSentAt.map({ Date().timeIntervalSince($0) >= 17 }) ?? true else { return }
        lastFrameSentAt = Date()
        sequence += 1
        let frame = sensors.snapshot(bodyID: AppConfig.bodyID, sessionID: sessionID,
                                     sequence: sequence, sendLocation: settings.sendLocation)
        if await sendCodable(frame) {
            lastSensorFrame = frame
            lastFrameAt = Date()
        }
    }

    func flushContact() async -> Bool {
        if let last = lastFrameSentAt {
            let wait = max(0, 17 - Date().timeIntervalSince(last))
            if wait > 0 { do { try await Task.sleep(for: .seconds(wait)) } catch { return false } }
        }
        guard shouldRun, isForeground, connectionState == .connected, serverEndpointID != nil else { return false }
        await sendSensorFrame()
        return true
    }

    func captureSharedFrontPhoto() async throws -> UIImage {
        guard isForeground, !cameraBusy else { throw CameraCaptureService.CameraError.notReady }
        cameraBusy = true
        await suspendFrontMotion()
        defer { cameraBusy = false; resumeFrontMotion() }
        let (jpeg, _, _) = try await camera.captureQuietFront()
        try Task.checkCancellation()
        guard isForeground, let image = UIImage(data: jpeg) else { throw CameraCaptureService.CameraError.noImage }
        return image
    }

    func sendManualCamera(image: UIImage) async {
        guard shouldRun, connectionState == .connected else { return }
        do {
            let (jpeg, width, height) = try CameraCaptureService.prepare(image)
            _ = try await sendCameraFrame(jpeg: jpeg, width: width, height: height,
                                          position: .front, commandID: nil)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func connect() {
        guard shouldRun else { return }
        guard let url = URL(string: AppConfig.bodySocketURL) else {
            lastError = "The Kairo body endpoint is invalid."
            connectionState = .error
            return
        }
        // Exactly one reconnect sequence: whoever connects cancels any pending one.
        reconnectTask?.cancel(); reconnectTask = nil
        livenessTask?.cancel(); livenessTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !AppConfig.sensoryToken.isEmpty {
            request.setValue("Bearer \(AppConfig.sensoryToken)", forHTTPHeaderField: "Authorization")
        }

        let socket = makeSocket(request)
        self.socket = socket
        let transport = gate.begin()
        transportGeneration = transport
        sensors.resetTouches()
        lastFrameSentAt = nil
        capabilitiesNegotiated = false
        actionEventsNegotiated = false
        capabilitySequence = 0
        permissionRevision = 0
        lastCapabilityPermissions = nil
        capabilitiesConfirmedAt = nil
        serverEndpointID = nil
        capabilitySentAt.removeAll()
        acknowledgedCapabilitySequence = -1
        receivedDisplayCommandOnTransport = false
        linkActivity.reset()
        socket.resume()

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            // The opening ping gets the same deadline as heartbeats; with
            // waitsForConnectivity it could otherwise wait indefinitely.
            let opened = await LivenessProbe.answered(within: self.timing.openingDeadline) {
                try await socket.sendPing()
            }
            guard self.gate.isCurrent(transport), !Task.isCancelled else { return }
            guard opened else { self.handleDisconnect(BodyLinkError.noPong, transport: transport); return }
            self.connectionState = .connected
            self.lastError = nil
            self.reconnectAttempt = 0
            self.linkActivity.note()
            self.startLiveness(socket, transport: transport)
            await self.sendHello()
            await self.sendCodable(DisplayStateRequest(bodyID: AppConfig.bodyID,
                                                       sessionID: self.sessionID))
            await self.sendSensorFrame()
            self.startFrameLoop()
            await self.receiveLoop(socket, transport: transport)
        }
    }

    private func receiveLoop(_ socket: BodySocket, transport: UUID) async {
        while shouldRun, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                guard gate.isCurrent(transport), !Task.isCancelled else { return }
                linkActivity.note()
                await handleIncoming(data)
            } catch {
                handleDisconnect(error, transport: transport)
                return
            }
        }
    }

    /// Tears down `transport` once and schedules the single reconnect. Late
    /// callbacks from an already replaced or failed socket are ignored.
    private func handleDisconnect(_ error: Error, transport: UUID) {
        guard shouldRun, gate.fail(transport) else { return }
        lastError = error.localizedDescription
        capabilitiesNegotiated = false
        actionEventsNegotiated = false
        capabilitiesConfirmedAt = nil
        serverEndpointID = nil
        observationDelivery.cancel()
        sensors.locationAttention.cancel(reason: "session_changed")
        actionTasks.values.forEach { $0.cancel() }; actionTasks.removeAll()
        capabilitySentAt.removeAll()
        connectionState = .reconnecting
        frameTask?.cancel(); frameTask = nil
        livenessTask?.cancel(); livenessTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        reconnectAttempt += 1
        let delay = timing.reconnectDelay(reconnectAttempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.shouldRun else { return }
            self.connect()
        }
    }

    private func startFrameLoop() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            var first = true
            while let self, !Task.isCancelled, self.shouldRun {
                // The server's 15-second limit starts after frame ingest, which
                // includes the first hello/session setup on a new transport.
                try? await Task.sleep(nanoseconds: first ? 19_000_000_000 : 17_000_000_000)
                first = false
                guard !Task.isCancelled, self.shouldRun else { break }
                await self.sendSensorFrame()
            }
        }
    }

    private func sendHello() async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let hello = HelloFrame(
            bodyID: AppConfig.bodyID,
            sessionID: sessionID,
            appVersion: version,
            capabilities: ["motion", "pressure", "battery", "network", "touch", "location_opt_in",
                           "camera_opt_in", "speak", "display", "body_capabilities_v1", "body_action_events_v1"]
        )
        await sendCodable(hello)
    }

    @discardableResult
    private func sendCodable<T: Encodable>(_ value: T) async -> Bool {
        guard let socket, let transport = gate.current else { return false }
        do {
            let data = try BodyJSON.encoder.encode(value)
            guard data.count <= 2_500_000 else {
                lastError = "Outbound message exceeded 2.5 MB cap"
                return false
            }
            try await transmit(socket, data)
            return true
        } catch {
            handleDisconnect(error, transport: transport)
            return false
        }
    }

    /// One bounded write on the live socket. A stalled `URLSessionWebSocketTask.send`
    /// must never hold a caller suspended forever: the deadline throws, the
    /// caller's catch tears the transport down, and the reconnect loop replaces it.
    /// A successful write is the strongest evidence the link is current, so it
    /// advances the supervisor.
    private func transmit(_ socket: BodySocket, _ data: Data) async throws {
        try await StalledOperation.call(timing.sendDeadline) { [socket] in
            try await socket.send(.data(data))
        }
        linkActivity.note()
    }

    func sendCapabilities() async {
        guard capabilitiesNegotiated, shouldRun, connectionState == .connected, let socket,
              let transport = gate.current else { return }
        var facts = sensors.capabilities(settings: settings)
        facts.speechBusy = speech.isBusy
        facts.displayVisible = displayVisible && !screensaverActive
        let permissions = "\(facts.frontCameraEnabled):\(facts.cameraPermission):\(facts.microphoneEnabled):\(facts.microphonePermission):\(facts.locationEnabled):\(facts.locationPermission):\(facts.speechEnabled)"
        if lastCapabilityPermissions != permissions {
            permissionRevision += 1
            lastCapabilityPermissions = permissions
        }
        facts.permissionRevision = permissionRevision
        capabilitySequence += 1
        let seq = capabilitySequence
        let message = facts.makeMessage(sequence: seq, bodyID: AppConfig.bodyID,
                                        sessionID: sessionID, foreground: isForeground)
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
            capabilitySentAt = capabilitySentAt.filter { Date().timeIntervalSince($0.value) < 45 }
            capabilitySentAt[seq] = Date()
            try await transmit(socket, data)
        } catch { handleDisconnect(error, transport: transport) }
    }

    private func handleIncoming(_ data: Data) async {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["bodyID"] as? String == AppConfig.bodyID, object["sessionID"] as? String == sessionID {
            if object["type"] as? String == "hello_ack",
               object["protocolVersion"] as? String == "kairo-body/1",
               (object["capabilities"] as? [String])?.contains("body_capabilities_v1") == true {
                serverEndpointID = object["endpointID"] as? String
                capabilitiesNegotiated = true
                actionEventsNegotiated = (object["capabilities"] as? [String])?.contains("body_action_events_v1") == true
                await sendCapabilities()
                return
            }
            if object["type"] as? String == "observation_ack",
               let seq = object["sequence"] as? Int, let observation = object["observationID"] as? String {
                observationDelivery.acknowledge(sequence: seq, observationID: observation)
                return
            }
            if object["type"] as? String == "capabilities_ack",
               object["accepted"] as? Bool == true,
               let seq = object["sequence"] as? Int, seq > acknowledgedCapabilitySequence,
               let sentAt = capabilitySentAt.removeValue(forKey: seq), Date().timeIntervalSince(sentAt) < 45 {
                acknowledgedCapabilitySequence = seq
                capabilitiesConfirmedAt = sentAt
                return
            }
        }

        if let snapshot = try? JSONDecoder().decode(DisplayStateSnapshot.self, from: data),
           snapshot.isValid(bodyID: AppConfig.bodyID, sessionID: sessionID) {
            if !receivedDisplayCommandOnTransport {
                display = DisplayState(state: snapshot.state,
                                       headline: snapshot.headline,
                                       detail: snapshot.detail)
            }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "command",
              let command = object["command"] as? String,
              let commandID = object["id"] as? String else { return }
        let args = object["args"] as? [String: Any] ?? [:]

        if actionEventsNegotiated {
            guard actionLifecycle.transition(commandID: commandID, phase: .accepted, detail: "device accepted command") != nil else {
                if let previous = actionLifecycle.lastEvent(commandID: commandID) { await sendActionEvent(previous) }
                return
            }
            if let accepted = actionLifecycle.lastEvent(commandID: commandID) { await sendActionEvent(accepted) }
        }
        switch command {
        case "speak":
            let text = args["text"] as? String ?? ""
            guard isForeground else { await commandResult(id: commandID, ok: false, detail: "app background"); return }
            let run = transportGeneration
            let accepted = speech.speak(text, onEvent: { [weak self] phase, detail in
                guard let self, self.transportGeneration == run else { return }
                Task { await self.actionEvent(id: commandID, phase: phase, detail: detail) }
            })
            if !accepted { await commandResult(id: commandID, ok: false, detail: "voice unavailable") }
            else if !actionEventsNegotiated {
                await commandResult(id: commandID, ok: false, detail: "server cannot confirm actual playback lifecycle")
            }

        case "stop_speaking":
            await actionEvent(id: commandID, phase: .started, detail: "stopping speech")
            speech.stop()
            await commandResult(id: commandID, ok: true, detail: "speech stopped")

        case "display":
            guard isForeground, displayVisible, !screensaverActive else { await commandResult(id: commandID, ok: false, detail: "body display is not visible"); return }
            await actionEvent(id: commandID, phase: .started, detail: "applying visible display")
            guard isForeground, displayVisible, !screensaverActive else { await commandResult(id: commandID, ok: false, detail: "body display became obscured"); return }
            let state = String((args["state"] as? String ?? "present").prefix(64))
            let headline = String((args["headline"] as? String ?? "Kairo").prefix(160))
            let detail = String((args["detail"] as? String ?? "").prefix(500))
            display = DisplayState(state: state, headline: headline, detail: detail)
            receivedDisplayCommandOnTransport = true
            if let brightness = args["brightness"] as? Double {
                savedBrightness = CGFloat(min(max(brightness, 0.10), 1.0))
                switch dimmingStage {
                case .awake: UIScreen.main.brightness = savedBrightness ?? 0.5
                case .screensaver: UIScreen.main.brightness = min(savedBrightness ?? 0.5, 0.25)
                case .dark: break
                }
            }
            let applied = await applyDisplay(display)
            let visible = applied && isForeground && displayVisible && !screensaverActive
            await commandResult(id: commandID, ok: visible, detail: visible ? "display updated visibly" : "body display did not acknowledge visible output")

        case "capture_camera":
            guard settings.allowRemoteCamera else {
                await commandResult(id: commandID, ok: false, detail: "remote camera disabled on device")
                return
            }
            let requested = args["camera"] as? String ?? ""
            let position: AVCaptureDevice.Position = requested == "front" ? .front : .back
            guard requested == "front", isForeground, !cameraBusy else {
                await commandResult(id: commandID, ok: false, detail: "front camera only; foreground and idle camera required")
                return
            }
            let run = transportGeneration
            actionTasks[commandID] = Task { [weak self] in
                guard let self else { return }
                await self.actionEvent(id: commandID, phase: .started, detail: "front camera capture started")
                await self.captureAndSendCamera(position: position, commandID: commandID)
                if self.transportGeneration == run { self.actionTasks.removeValue(forKey: commandID) }
            }

        case "refresh_location":
            guard args.isEmpty, settings.sendLocation, isForeground, capabilitiesNegotiated,
                  sensors.capabilities(settings: settings).locationPermission == "granted" else {
                await commandResult(id: commandID, ok: false, detail: "location disabled, denied, or background")
                return
            }
            let run = transportGeneration
            actionTasks[commandID] = Task { [weak self] in
                guard let self else { return }
                do {
                    await self.actionEvent(id: commandID, phase: .started, detail: "location refresh started")
                    let fix = try await self.sensors.locationAttention.refresh()
                    self.locationDeliveryPending = true
                    defer { self.locationDeliveryPending = false }
                    // Preserve normal sensor-ingest cadence rather than bypassing its admission limit.
                    if let last = self.lastFrameSentAt {
                        let wait = max(0, 17 - Date().timeIntervalSince(last))
                        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    }
                    try Task.checkCancellation()
                    guard self.isForeground, self.settings.sendLocation,
                          self.transportGeneration == run else { throw ObservationDelivery.Failure.cancelled }
                    self.lastFrameSentAt = Date()
                    self.sequence += 1
                    var frame = self.sensors.snapshot(bodyID: AppConfig.bodyID, sessionID: self.sessionID,
                        sequence: self.sequence, sendLocation: true)
                    frame.location = fix
                    let observation = try await self.observationDelivery.deliver(sequence: frame.sequence, timeout: .seconds(10)) {
                        await self.sendCodable(frame)
                    }
                    self.lastSensorFrame = frame
                    self.lastFrameAt = Date()
                    await self.commandResult(id: commandID, ok: true,
                        detail: "Location observed \(fix.observedAt ?? "unknown"); accuracy \(fix.horizontalAccuracyM ?? -1)m; observation \(observation)")
                } catch {
                    if self.transportGeneration == run {
                        await self.commandResult(id: commandID, ok: false, detail: error.localizedDescription)
                    }
                }
                if self.transportGeneration == run { self.actionTasks.removeValue(forKey: commandID) }
            }

        case "ping":
            await commandResult(id: commandID, ok: true, detail: "pong")

        default:
            await commandResult(id: commandID, ok: false, detail: "unknown command")
        }
    }

    private func captureAndSendCamera(position: AVCaptureDevice.Position, commandID: String?) async {
        guard position == .front, !cameraBusy, isForeground else {
            if let commandID { await commandResult(id: commandID, ok: false, detail: "front camera unavailable") }
            return
        }
        cameraBusy = true
        let run = transportGeneration
        await suspendFrontMotion()
        defer { cameraBusy = false; resumeFrontMotion() }
        do {
            let (jpeg, width, height) = try await (position == .front
                ? camera.captureQuietFront() : camera.capture(position: position))
            try Task.checkCancellation()
            guard isForeground, settings.allowRemoteCamera, transportGeneration == run else { throw ObservationDelivery.Failure.cancelled }
            let observation = try await sendCameraFrame(jpeg: jpeg, width: width, height: height,
                                          position: position, commandID: commandID)
            if let commandID { await commandResult(id: commandID, ok: true, detail: "Camera observation ingested: \(observation)") }
        } catch {
            lastError = error.localizedDescription
            if let commandID, transportGeneration == run { await commandResult(id: commandID, ok: false, detail: error.localizedDescription) }
        }
    }

    private func sendCameraFrame(jpeg: Data, width: Int, height: Int,
                                 position: AVCaptureDevice.Position, commandID: String?) async throws -> String {
        guard position == .front, isForeground, capabilitiesNegotiated else { throw ObservationDelivery.Failure.sendFailed }
        sequence += 1
        let frame = CameraFrame(
            bodyID: AppConfig.bodyID,
            sessionID: sessionID,
            commandID: commandID,
            sequence: sequence,
            observedAt: BodyJSON.now(),
            camera: position == .front ? "front" : "rear",
            width: width,
            height: height,
            jpegBase64: jpeg.base64EncodedString()
        )
        return try await observationDelivery.deliver(sequence: frame.sequence) { [weak self] in
            guard let self else { return false }
            return await self.sendCodable(frame)
        }
    }

    private func sendActionEvent(_ event: BodyActionEvent) async {
        guard actionEventsNegotiated, let socket, let transport = gate.current else { return }
        let message: [String: Any] = ["type": "action_event", "protocolVersion": "kairo-body/1",
            "bodyID": AppConfig.bodyID, "sessionID": sessionID, "commandID": event.commandID,
            "sequence": event.sequence, "phase": event.phase.rawValue, "detail": event.detail]
        do {
            try await transmit(socket, JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
        } catch { handleDisconnect(error, transport: transport) }
    }

    private func actionEvent(id: String, phase: ActionPhase, detail: String) async {
        guard actionEventsNegotiated,
              let event = actionLifecycle.transition(commandID: id, phase: phase, detail: detail) else { return }
        await sendActionEvent(event)
    }

    private func commandResult(id: String, ok: Bool, detail: String) async {
        if actionEventsNegotiated {
            await actionEvent(id: id, phase: ok ? .completed : .failed, detail: detail)
            return
        }
        await sendCodable(CommandResult(bodyID: AppConfig.bodyID, sessionID: sessionID, commandID: id, ok: ok, detail: detail))
    }
}

/// The body transport's socket operations; a seam so reconnect and liveness
/// behaviour can be exercised without a server.
protocol BodySocket: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func sendPing() async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// A WebSocket task together with the URLSession that owns it, released together.
final class SessionBoundSocket: BodySocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    static func open(_ request: URLRequest) -> BodySocket {
        // No silent URLSession retries: a failing handshake errors into our
        // receive loop, which schedules exactly one bounded reconnect.
        let session = URLSession(configuration: TransportConfig.websocket())
        return SessionBoundSocket(session: session, task: session.webSocketTask(with: request))
    }

    private init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    func resume() { task.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }

    func sendPing() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
        session.invalidateAndCancel()
    }
}

/// Heartbeat and reconnect timing; tests shorten it, production uses the defaults.
struct BodyLinkTiming {
    var livenessInterval: Double = LivenessSchedule.interval
    var livenessDeadline: Double = LivenessSchedule.deadline
    var openingDeadline: Double = 15
    /// No single socket write may outlive this; a stalled send is a dead link.
    var sendDeadline: Double = 10
    /// The supervisor tolerates this much silence on a "connected" transport.
    /// It must stay strictly more patient than the ping probe, which answers
    /// within livenessInterval + livenessDeadline.
    var activityStale: Double = 60
    var reconnectDelay: (Int) -> Double = { attempt in min(pow(2.0, Double(attempt - 1)), 30.0) }
}

enum BodyLinkError: LocalizedError {
    case noPong
    case noActivity
    var errorDescription: String? {
        switch self {
        case .noPong: return "Kairo's body link stopped answering; reconnecting."
        case .noActivity: return "Kairo's body link stopped carrying data; reconnecting."
        }
    }
}
