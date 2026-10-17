import Foundation
import AVFoundation
import UIKit
import CoreImage

final class CameraCaptureService: NSObject {
    enum CameraError: LocalizedError, Equatable {
        case blockedByBody
        case denied
        case unavailable
        case configuration
        case notReady
        case noImage

        var errorDescription: String? {
            switch self {
            case .blockedByBody: return "Rear camera is blocked by body"
            case .denied: return "Camera permission denied"
            case .unavailable: return "Requested camera unavailable"
            case .configuration: return "Could not configure camera capture"
            case .notReady: return "Camera did not become ready for a photo"
            case .noImage: return "Camera produced no image"
            }
        }
    }

    private let queue = DispatchQueue(label: "KairoBody.Camera")
    private var active: [UUID: CaptureDelegate] = [:]
    private var activeQuiet: [UUID: QuietFrameDelegate] = [:]
    private let activeLock = NSLock()

    func capture(position: AVCaptureDevice.Position) async throws -> (Data, Int, Int) {
        guard position == .front else { throw CameraError.blockedByBody }
        let authorized = await ensureAuthorization()
        guard authorized else { throw CameraError.denied }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return }
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }

                let session = AVCaptureSession()
                session.sessionPreset = .photo
                let output = AVCapturePhotoOutput()
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        continuation.resume(throwing: CameraError.configuration)
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                session.startRunning()
                guard session.isRunning else {
                    continuation.resume(throwing: CameraError.notReady)
                    return
                }
                // A newly opened front camera can produce a black first photo
                // before its exposure has settled. Keep this one-shot session
                // open briefly, then wait for the photo output to accept capture.
                let started = Date()
                while Date().timeIntervalSince(started) < 3.0 {
                    if Date().timeIntervalSince(started) >= 0.8 &&
                        output.captureReadiness == .ready && !camera.isAdjustingExposure {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard output.captureReadiness == .ready else {
                    session.stopRunning()
                    continuation.resume(throwing: CameraError.notReady)
                    return
                }

                let id = UUID()
                let delegate = CaptureDelegate(session: session) { [weak self] result in
                    self?.activeLock.lock()
                    self?.active.removeValue(forKey: id)
                    self?.activeLock.unlock()
                    continuation.resume(with: result)
                }
                self.activeLock.lock()
                self.active[id] = delegate
                self.activeLock.unlock()

                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            }
        }
    }

    /// A one-shot front-camera video frame avoids the photo shutter sound on
    /// iPadOS 17. The session stops as soon as one exposure-settled frame is
    /// encoded; no video stream leaves the device.
    func captureQuietFront() async throws -> (Data, Int, Int) {
        guard await ensureAuthorization() else { throw CameraError.denied }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                           for: .video, position: .front) else {
                    continuation.resume(throwing: CameraError.unavailable)
                    return
                }
                let session = AVCaptureSession()
                session.sessionPreset = .high
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                do {
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        continuation.resume(throwing: CameraError.configuration)
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                let id = UUID()
                let delegate = QuietFrameDelegate(session: session, camera: camera) { [weak self] result in
                    self?.activeLock.lock()
                    self?.activeQuiet.removeValue(forKey: id)
                    self?.activeLock.unlock()
                    continuation.resume(with: result)
                }
                self.activeLock.lock()
                self.activeQuiet[id] = delegate
                self.activeLock.unlock()
                output.setSampleBufferDelegate(delegate, queue: self.queue)
                session.startRunning()
                if !session.isRunning {
                    delegate.finish(.failure(CameraError.notReady))
                    return
                }
                self.queue.asyncAfter(deadline: .now() + 5) {
                    delegate.finish(.failure(CameraError.notReady))
                }
            }
        }
    }

    static func prepare(_ image: UIImage) throws -> (Data, Int, Int) {
        let resized = image.kairoResized(maxDimension: 1280)
        guard let pixels = resized.cgImage,
              let jpeg = resized.jpegData(compressionQuality: 0.52) else {
            throw CameraError.noImage
        }
        return (jpeg, pixels.width, pixels.height)
    }

    private func ensureAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

private final class QuietFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session: AVCaptureSession
    private let camera: AVCaptureDevice
    private let completion: (Result<(Data, Int, Int), Error>) -> Void
    private let started = Date()
    private let context = CIContext()
    private var completed = false

    init(session: AVCaptureSession, camera: AVCaptureDevice,
         completion: @escaping (Result<(Data, Int, Int), Error>) -> Void) {
        self.session = session
        self.camera = camera
        self.completion = completion
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !completed, Date().timeIntervalSince(started) >= 0.8,
              !camera.isAdjustingExposure,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        finish(Result { try CameraCaptureService.prepare(UIImage(cgImage: cgImage)) })
    }

    func finish(_ result: Result<(Data, Int, Int), Error>) {
        guard !completed else { return }
        completed = true
        session.stopRunning()
        completion(result)
    }
}

private final class CaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let session: AVCaptureSession
    private let completion: (Result<(Data, Int, Int), Error>) -> Void
    private var completed = false

    init(session: AVCaptureSession, completion: @escaping (Result<(Data, Int, Int), Error>) -> Void) {
        self.session = session
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard !completed else { return }
        completed = true
        defer { session.stopRunning() }
        if let error {
            completion(.failure(error))
            return
        }
        guard let raw = photo.fileDataRepresentation(), let image = UIImage(data: raw) else {
            completion(.failure(CameraCaptureService.CameraError.noImage))
            return
        }
        completion(Result { try CameraCaptureService.prepare(image) })
    }
}

private extension UIImage {
    func kairoResized(maxDimension: CGFloat) -> UIImage {
        let largest = max(size.width, size.height)
        let scale = min(1, maxDimension / largest)
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
