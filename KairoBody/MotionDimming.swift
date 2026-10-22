import Foundation
import AVFoundation
import CoreVideo

/// Appliance dimming: after a minute of stillness show the screensaver, after
/// the chosen window go dark. Kairo's actual work — on any surface, including
/// the Dot — keeps the display alive; a heartbeat alone never does.
struct MotionDimmingPolicy {
    enum Stage: Equatable { case awake, screensaver, dark }
    let idleSeconds: TimeInterval
    let darkSeconds: TimeInterval
    private var lastActivity: Date?

    init(idleSeconds: TimeInterval, darkSeconds: TimeInterval) {
        self.idleSeconds = idleSeconds
        self.darkSeconds = darkSeconds
    }

    /// `kairoBusy`: the server says Kairo is working, queued or waiting on the
    /// owner, on any surface — not only while this iPad's request is in flight.
    static func keepsAwake(localSending: Bool, localSpeaking: Bool, capturing: Bool,
                           dotPhase: String?, dotActivityFresh: Bool,
                           kairoBusy: Bool = false) -> Bool {
        localSending || localSpeaking || capturing || kairoBusy ||
            (dotActivityFresh && ["speech_detected", "thinking", "speaking", "replaying"].contains(dotPhase ?? ""))
    }

    mutating func observe(at time: Date, movement: Bool) -> Stage {
        if movement || lastActivity == nil { lastActivity = time }
        let quiet = time.timeIntervalSince(lastActivity ?? time)
        if quiet >= darkSeconds { return .dark }
        if quiet >= idleSeconds { return .screensaver }
        return .awake
    }

    /// A body on permanent duty - always foreground, always plugged - must
    /// never go fully dark: the dark stage for an unplugged appliance becomes
    /// the living screensaver while it is on external power. This surface
    /// shows what Kairo is doing, even at 4 a.m. with nobody in the room.
    static func effective(stage: Stage, responseActive: Bool, externalPower: Bool) -> Stage {
        if responseActive { return .awake }
        if stage == .dark && externalPower { return .screensaver }
        return stage
    }
}

struct FrameMotionAnalyzer {
    private var previous: [UInt8]?

    mutating func observe(_ pixels: [UInt8]) -> Bool {
        defer { previous = pixels }
        guard let previous, previous.count == pixels.count, !pixels.isEmpty else { return false }
        let changed = zip(previous, pixels).filter { abs(Int($0.0) - Int($0.1)) >= 24 }.count
        return Double(changed) / Double(pixels.count) >= 0.10
    }
}

/// Local-only front-camera motion presence. Frames are reduced to a 12×12
/// luma grid on device; nothing ever leaves the iPad.
final class FrontCameraMotionDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onMovement: (() -> Void)?
    var onSessionChanged: ((AVCaptureSession?) -> Void)?
    private let queue = DispatchQueue(label: "KairoBody.FrontMotion")
    private var session: AVCaptureSession?
    private var analyzer = FrameMotionAnalyzer()
    private var lastSampleAt = Date.distantPast

    func start() async -> Bool {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.session != nil {
                    continuation.resume(returning: true)
                    return
                }
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: false)
                    return
                }
                let session = AVCaptureSession()
                session.sessionPreset = .low
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    continuation.resume(returning: false)
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: self.queue)
                self.analyzer = FrameMotionAnalyzer()
                self.lastSampleAt = .distantPast
                self.session = session
                session.startRunning()
                let running = session.isRunning
                if !running { self.session = nil }
                DispatchQueue.main.async { self.onSessionChanged?(running ? session : nil) }
                continuation.resume(returning: running)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.session?.stopRunning()
                self.session = nil
                self.analyzer = FrameMotionAnalyzer()
                DispatchQueue.main.async { self.onSessionChanged?(nil) }
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= 0.5,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSampleAt = now
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0 else { return }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(144)
        for y in 0..<12 {
            for x in 0..<12 {
                pixels.append(luma[(y * height / 12) * stride + x * width / 12])
            }
        }
        if analyzer.observe(pixels) { onMovement?() }
    }
}
