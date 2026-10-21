import Foundation
import CoreMotion
import CoreLocation
import Network
import UIKit
import AVFoundation

@MainActor
final class SensorManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var liveSummary = "Sensors stopped"
    var onSignificantMovement: (() -> Void)?
    var onPermissionsChanged: (() -> Void)?

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let location = CLLocationManager()
    private var locationEnabled = false
    lazy var locationAttention = LocationAttention(request: { [weak self] in
        self?.location.requestLocation()
    }, cancelRequest: { [weak self] in
        // Ordinary foreground sensing continues independently of this one-shot request.
        guard let self, !self.locationEnabled else { return }
        self.location.stopUpdatingLocation()
    })
    private var pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "KairoBody.NetworkPath")

    private var network = "unknown"
    private var latestLocation: CLLocation?
    private var latestHeading: CLHeading?
    private var locationObservedAt: Date?
    private var latestPressureHPa: Double?
    private var latestRelativeAltitudeM: Double?

    private var motionSamples = 0
    private var latestMotionObservedAt: Date?
    private var latestPressureObservedAt: Date?
    private var latestRoll: Double?
    private var latestPitch: Double?
    private var latestYaw: Double?
    private var peakAcceleration = 0.0
    private var latestUserAcceleration: CMAcceleration?
    private var latestGravity: CMAcceleration?
    private var latestRotationRate: CMRotationRate?
    private var latestMagneticHeading: Double?
    private var latestMagneticAccuracy: String?

    private var touches: [TouchEvent] = []
    private var touchStart: [String: Date] = [:]
    private var touchPositions: [String: (Double, Double)] = [:]
    private var touchPathSinceFrame: [String: Double] = [:]
    private var pendingMoves: [String: (Date, Double, Double)] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        // Preserve every Core Location fix even when the body stays still.
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func start(sendLocation: Bool) {
        locationEnabled = sendLocation
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        startMotion()
        startAltimeter()
        startNetwork()
        if sendLocation {
            location.requestWhenInUseAuthorization()
            location.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
        }
        liveSummary = "Motion / pressure / network active"
    }

    func stop() {
        locationEnabled = false
        cancelTouches()
        locationAttention.cancel(reason: "background_or_stopped")
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        pathMonitor.cancel()
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        liveSummary = "Sensors stopped"
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.25
        let magneticNorth = CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
        let handle: CMDeviceMotionHandler = { [weak self] sample, _ in
            guard let self, let sample else { return }
            self.lock.lock()
            self.motionSamples += 1
            self.latestMotionObservedAt = Date()
            self.latestRoll = sample.attitude.roll * 180 / .pi
            self.latestPitch = sample.attitude.pitch * 180 / .pi
            self.latestYaw = sample.attitude.yaw * 180 / .pi
            let a = sample.userAcceleration
            let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
            let rotation = sample.rotationRate
            let rotationMagnitude = sqrt(rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z)
            if magnitude >= 0.06 || rotationMagnitude >= 0.20 {
                Task { @MainActor in self.onSignificantMovement?() }
            }
            self.peakAcceleration = max(self.peakAcceleration, magnitude)
            self.latestUserAcceleration = a
            self.latestGravity = sample.gravity
            self.latestRotationRate = rotation
            if magneticNorth {
                let accuracy: String
                switch sample.magneticField.accuracy {
                case .high: accuracy = "high"
                case .medium: accuracy = "medium"
                case .low: accuracy = "low"
                default: accuracy = "uncalibrated"
                }
                self.latestMagneticAccuracy = accuracy
                self.latestMagneticHeading = accuracy != "uncalibrated" && (0...360).contains(sample.heading)
                    ? sample.heading : nil
            }
            self.lock.unlock()
        }
        if magneticNorth {
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main, withHandler: handle)
        } else {
            motion.startDeviceMotionUpdates(to: .main, withHandler: handle)
        }
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            // Core Motion reports pressure in kilopascals. 1 kPa = 10 hPa.
            self.latestPressureHPa = data.pressure.doubleValue * 10.0
            self.latestRelativeAltitudeM = data.relativeAltitude.doubleValue
            self.latestPressureObservedAt = Date()
        }
    }

    private func startNetwork() {
        pathMonitor.cancel()
        pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let value: String
            if path.status != .satisfied { value = "offline" }
            else if path.usesInterfaceType(.wifi) { value = "wifi" }
            else if path.usesInterfaceType(.cellular) { value = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { value = "ethernet" }
            else { value = "other" }
            DispatchQueue.main.async { self?.network = value }
        }
        pathMonitor.start(queue: pathQueue)
    }

    var locationAuthorization: CLAuthorizationStatus { location.authorizationStatus }

    func capabilities(settings: AppSettings) -> BodyCapabilities {
        let locationPermission: String
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: locationPermission = "granted"
        case .denied: locationPermission = "denied"
        case .restricted: locationPermission = "restricted"
        default: locationPermission = "not_determined"
        }
        let cameraPermission: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = "granted"
        case .denied: cameraPermission = "denied"
        case .restricted: cameraPermission = "restricted"
        default: cameraPermission = "not_determined"
        }
        let microphonePermission: String
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: microphonePermission = "granted"
        case .denied: microphonePermission = "denied"
        default: microphonePermission = "not_determined"
        }
        let fix = settings.sendLocation ? latestLocation : nil
        return BodyCapabilities(frontCameraEnabled: settings.allowRemoteCamera,
            cameraPermission: cameraPermission, microphoneEnabled: settings.voiceWakeEnabled,
            microphonePermission: microphonePermission, speechEnabled: !AppConfig.agentToken.isEmpty,
            locationEnabled: settings.sendLocation, locationPermission: locationPermission,
            locationObservedAt: fix.map { BodyJSON.iso8601.string(from: $0.timestamp) },
            locationAccuracyM: fix.flatMap { $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : nil },
            accuracyAuthorization: location.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            latestLocation = nil
            latestHeading = nil
            locationObservedAt = nil
            locationAttention.cancel(reason: "permission_revoked")
        }
        onPermissionsChanged?()
    }

    func setLocationEnabled(_ enabled: Bool) {
        locationEnabled = enabled
        if !enabled { locationAttention.cancel(reason: "permission_revoked") }
        if enabled {
            location.requestWhenInUseAuthorization()
            location.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
        } else {
            location.stopUpdatingLocation()
            location.stopUpdatingHeading()
            latestLocation = nil
            latestHeading = nil
            locationObservedAt = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, locationEnabled else { return }
        latestLocation = value
        locationObservedAt = value.timestamp
        locationAttention.receive(value)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationAttention.fail()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        latestHeading = newHeading
    }

    // MARK: - Touch observation

    func resetTouches() {
        lock.lock()
        touches.removeAll(); touchStart.removeAll(); touchPositions.removeAll()
        touchPathSinceFrame.removeAll(); pendingMoves.removeAll()
        lock.unlock()
    }

    func cancelTouches() {
        lock.lock()
        for (id, position) in touchPositions {
            touches.append(TouchEvent(kind: "contact_cancel", observedAt: BodyJSON.now(),
                x: position.0, y: position.1, durationMs: nil, contactID: id, pathDeltaNormalized: nil))
        }
        touchStart.removeAll(); touchPositions.removeAll(); touchPathSinceFrame.removeAll(); pendingMoves.removeAll()
        trimTouches()
        lock.unlock()
    }

    func recordTouchBegan(id: String, x: Double, y: Double) {
        lock.lock()
        touchStart[id] = Date()
        touchPositions[id] = (x, y)
        touchPathSinceFrame[id] = 0
        touches.append(TouchEvent(kind: "contact_begin", observedAt: BodyJSON.now(),
                                  x: x, y: y, durationMs: nil, contactID: id,
                                  pathDeltaNormalized: nil))
        trimTouches()
        lock.unlock()
    }

    func recordTouchMoved(id: String, x: Double, y: Double) {
        lock.lock()
        if let previous = touchPositions[id] {
            touchPathSinceFrame[id, default: 0] += hypot(x - previous.0, y - previous.1)
            touchPositions[id] = (x, y)
            pendingMoves[id] = (Date(), x, y)
        }
        lock.unlock()
    }

    func recordTouchEnded(id: String, x: Double, y: Double) {
        lock.lock()
        let start = touchStart.removeValue(forKey: id)
        let duration = start.map { Int(Date().timeIntervalSince($0) * 1000) }
        if let previous = touchPositions.removeValue(forKey: id) {
            touchPathSinceFrame[id, default: 0] += hypot(x - previous.0, y - previous.1)
        }
        if touchPathSinceFrame[id, default: 0] > 0 {
            touches.append(TouchEvent(kind: "contact_move", observedAt: BodyJSON.now(),
                                      x: x, y: y, durationMs: nil, contactID: id,
                                      pathDeltaNormalized: min(touchPathSinceFrame[id] ?? 0, 100)))
        }
        pendingMoves.removeValue(forKey: id)
        touchPathSinceFrame.removeValue(forKey: id)
        touches.append(TouchEvent(kind: "contact_end", observedAt: BodyJSON.now(),
                                  x: x, y: y, durationMs: duration, contactID: id,
                                  pathDeltaNormalized: nil))
        trimTouches()
        lock.unlock()
    }

    private func trimTouches() {
        if touches.count > 32 { touches.removeFirst(touches.count - 32) }
    }

    func snapshot(bodyID: String, sessionID: String, sequence: Int, sendLocation: Bool) -> SensorFrame {
        lock.lock()
        let count = motionSamples
        let motionObservedAt = latestMotionObservedAt
        let roll = latestRoll
        let pitch = latestPitch
        let yaw = latestYaw
        let peak = peakAcceleration
        let acceleration = latestUserAcceleration
        let gravity = latestGravity
        let rotation = latestRotationRate
        let magneticHeading = latestMagneticHeading
        let magneticAccuracy = latestMagneticAccuracy
        motionSamples = 0
        peakAcceleration = 0
        var drainedTouches = touches
        for (id, position) in touchPositions {
            if let move = pendingMoves[id] {
                drainedTouches.append(TouchEvent(kind: "contact_move",
                    observedAt: BodyJSON.iso8601.string(from: move.0),
                    x: move.1, y: move.2, durationMs: nil, contactID: id,
                    pathDeltaNormalized: min(touchPathSinceFrame[id] ?? 0, 100)))
            } else {
                drainedTouches.append(TouchEvent(kind: "contact_continue",
                    observedAt: BodyJSON.now(), x: position.0, y: position.1,
                    durationMs: nil, contactID: id, pathDeltaNormalized: nil))
            }
            touchPathSinceFrame[id] = 0
        }
        pendingMoves.removeAll(keepingCapacity: true)
        touches.removeAll(keepingCapacity: true)
        lock.unlock()
        drainedTouches.sort { $0.observedAt < $1.observedAt }
        if drainedTouches.count > 32 { drainedTouches.removeFirst(drainedTouches.count - 32) }

        let movement: String
        if count == 0 { movement = "unknown" }
        else if peak >= 0.20 { movement = "picked_up_or_jolted" }
        else if peak >= 0.035 { movement = "moving" }
        else { movement = "still" }

        let motionFrame = MotionFrame(
            available: motion.isDeviceMotionAvailable,
            observedAt: motionObservedAt.map { BodyJSON.iso8601.string(from: $0) },
            sampleCount: count,
            rollDeg: roll,
            pitchDeg: pitch,
            yawDeg: yaw,
            peakUserAccelerationG: count > 0 ? peak : nil,
            movement: movement,
            userAccelerationXG: count > 0 ? acceleration?.x : nil,
            userAccelerationYG: count > 0 ? acceleration?.y : nil,
            userAccelerationZG: count > 0 ? acceleration?.z : nil,
            gravityXG: count > 0 ? gravity?.x : nil,
            gravityYG: count > 0 ? gravity?.y : nil,
            gravityZG: count > 0 ? gravity?.z : nil,
            rotationRateXRadPerSec: count > 0 ? rotation?.x : nil,
            rotationRateYRadPerSec: count > 0 ? rotation?.y : nil,
            rotationRateZRadPerSec: count > 0 ? rotation?.z : nil,
            magneticHeadingDeg: count > 0 ? magneticHeading : nil,
            magneticAccuracy: count > 0 ? magneticAccuracy : nil
        )

        let loc = sendLocation ? latestLocation : nil
        let heading = sendLocation ? latestHeading : nil
        let speed = loc.flatMap { $0.speed >= 0 ? $0.speed : nil }
        let course = loc.flatMap { $0.course >= 0 ? $0.course : nil }
        let locationFrame = LocationFrame(
            enabled: sendLocation,
            available: loc != nil,
            latitude: loc?.coordinate.latitude,
            longitude: loc?.coordinate.longitude,
            horizontalAccuracyM: loc?.horizontalAccuracy,
            altitudeM: loc?.altitude,
            speedMps: speed,
            courseDeg: course,
            headingDeg: heading.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading },
            observedAt: locationObservedAt.map { BodyJSON.iso8601.string(from: $0) }
        )

        let pressureFrame = PressureFrame(
            available: CMAltimeter.isRelativeAltitudeAvailable(),
            observedAt: latestPressureObservedAt.map { BodyJSON.iso8601.string(from: $0) },
            pressureHPa: latestPressureHPa,
            relativeAltitudeM: latestRelativeAltitudeM
        )

        let device = UIDevice.current
        let batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "unplugged"
        default: state = "unknown"
        }

        let deviceFrame = DeviceFrame(
            observedAt: BodyJSON.now(),
            batteryLevel: batteryLevel,
            batteryState: state,
            network: network,
            orientation: Self.orientationString(),
            screenBrightness: Double(UIScreen.main.brightness)
        )

        return SensorFrame(
            bodyID: bodyID,
            sessionID: sessionID,
            sequence: sequence,
            observedAt: BodyJSON.now(),
            motion: motionFrame,
            location: locationFrame,
            pressure: pressureFrame,
            device: deviceFrame,
            touches: drainedTouches
        )
    }

    private static func orientationString() -> String {
        switch UIDevice.current.orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait_upside_down"
        case .landscapeLeft: return "landscape_left"
        case .landscapeRight: return "landscape_right"
        case .faceUp: return "face_up"
        case .faceDown: return "face_down"
        default: return "unknown"
        }
    }
}
