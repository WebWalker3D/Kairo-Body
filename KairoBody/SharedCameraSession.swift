import AVFoundation
import CoreImage
import UIKit

/// Local front-only viewfinder. All capture operations and sample delivery
/// share one serial queue. Only an explicit shutter request encodes a frame.
final class SharedCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "KairoBody.SharedCamera")
    private var session: AVCaptureSession?
    private var camera: AVCaptureDevice?
    private var output: AVCaptureVideoDataOutput?
    private let context = CIContext()
    private var pending: (id: UUID, completion: (Result<UIImage, Error>) -> Void)?
    private var startedAt = Date.distantPast
    private var requestedAt = Date.distantPast

    func start() async throws -> AVCaptureSession {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraCaptureService.CameraError.denied }
        default: throw CameraCaptureService.CameraError.denied
        }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if let session = self.session { continuation.resume(returning: session); return }
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                        throw CameraCaptureService.CameraError.unavailable
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let session = AVCaptureSession()
                    session.sessionPreset = .high
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw CameraCaptureService.CameraError.configuration
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.camera = camera
                    self.output = output
                    self.session = session
                    self.startedAt = Date()
                    session.startRunning()
                    guard session.isRunning else {
                        self.stopOnQueue()
                        throw CameraCaptureService.CameraError.notReady
                    }
                    continuation.resume(returning: session)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func capture(orientation: AVCaptureVideoOrientation) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session?.isRunning == true, self.pending == nil,
                      let connection = self.output?.connection(with: .video) else {
                    continuation.resume(throwing: CameraCaptureService.CameraError.notReady)
                    return
                }
                if connection.isVideoOrientationSupported { connection.videoOrientation = orientation }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                let id = UUID()
                self.requestedAt = Date()
                self.pending = (id, { continuation.resume(with: $0) })
                self.queue.asyncAfter(deadline: .now() + 5) {
                    if self.pending?.id == id { self.finish(.failure(CameraCaptureService.CameraError.notReady)) }
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { self.stopOnQueue(); continuation.resume() }
        }
    }

    private func stopOnQueue() {
        finish(.failure(CancellationError()))
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        session = nil; output = nil; camera = nil
    }

    private func finish(_ result: Result<UIImage, Error>) {
        let completion = pending?.completion
        pending = nil
        completion?(result)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard pending != nil, Date().timeIntervalSince(startedAt) >= 0.8,
              Date().timeIntervalSince(requestedAt) >= 0.2,
              camera?.isAdjustingExposure == false,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        guard let pixels = context.createCGImage(frame, from: frame.extent) else {
            finish(.failure(CameraCaptureService.CameraError.noImage)); return
        }
        finish(.success(UIImage(cgImage: pixels)))
    }
}

extension AVCaptureVideoOrientation {
    init(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        case .portraitUpsideDown: self = .portraitUpsideDown
        default: self = .portrait
        }
    }
}
