import Foundation
import CoreLocation

@MainActor
final class LocationAttention {
    enum Failure: LocalizedError, Equatable {
        case busy, timeout, cancelled(String), unavailable
        var errorDescription: String? {
            switch self {
            case .busy: return "A location request is already active"
            case .timeout: return "Location request timed out"
            case .cancelled(let reason): return "Location request cancelled: \(reason)"
            case .unavailable: return "Location fix unavailable"
            }
        }
    }
    private let request: () -> Void
    private let cancelRequest: () -> Void
    private var continuation: CheckedContinuation<LocationFrame, Error>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    func refresh(timeout: Duration = .seconds(30)) async throws -> LocationFrame {
        guard continuation == nil else { throw Failure.busy }
        let run = UUID()
        generation = run
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback in
                continuation = callback
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.generation == run else { return }
                    self.finish(.failure(Failure.timeout))
                }
                if Task.isCancelled { cancel(reason: "task_cancelled") } else { request() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == run else { return }
                self?.cancel(reason: "task_cancelled")
            }
        }
    }
    func receive(_ fix: CLLocation, now: Date = Date()) {
        guard continuation != nil, fix.horizontalAccuracy >= 0,
              (0...120).contains(now.timeIntervalSince(fix.timestamp)),
              CLLocationCoordinate2DIsValid(fix.coordinate) else { return }
        finish(.success(LocationFrame(enabled: true, available: true,
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            horizontalAccuracyM: fix.horizontalAccuracy, altitudeM: fix.altitude,
            speedMps: fix.speed >= 0 ? fix.speed : nil, courseDeg: fix.course >= 0 ? fix.course : nil,
            headingDeg: nil, observedAt: BodyJSON.iso8601.string(from: fix.timestamp))))
    }
    func fail() { finish(.failure(Failure.unavailable)) }
    func cancel(reason: String) { finish(.failure(Failure.cancelled(reason))) }
    private func finish(_ result: Result<LocationFrame, Error>) {
        guard let callback = continuation else { return }
        continuation = nil
        deadline?.cancel(); deadline = nil
        cancelRequest()
        callback.resume(with: result)
    }
}

/// A socket send proves delivery to the transport; only the server receipt
/// proves ingestion.
@MainActor
final class ObservationDelivery {
    enum Failure: LocalizedError, Equatable {
        case busy, sendFailed, expired, cancelled
        var errorDescription: String? { "Observation delivery \(self)" }
    }
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]

    func deliver(sequence: Int, timeout: Duration = .seconds(220), send: @escaping () async -> Bool) async throws -> String {
        guard pending[sequence] == nil else { throw Failure.busy }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback in
                pending[sequence] = callback
                deadlines[sequence] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(sequence, .failure(Failure.expired))
                }
                Task { [weak self] in
                    if await send() == false { self?.finish(sequence, .failure(Failure.sendFailed)) }
                }
                if Task.isCancelled { finish(sequence, .failure(Failure.cancelled)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pending[sequence] != nil else { return }
                self?.finish(sequence, .failure(Failure.cancelled))
            }
        }
    }
    func acknowledge(sequence: Int, observationID: String) {
        guard !observationID.isEmpty, observationID.count <= 160 else { return }
        finish(sequence, .success(observationID))
    }
    func cancel() {
        for key in Array(pending.keys) { finish(key, .failure(Failure.cancelled)) }
    }
    private func finish(_ sequence: Int, _ result: Result<String, Error>) {
        guard let callback = pending.removeValue(forKey: sequence) else { return }
        deadlines.removeValue(forKey: sequence)?.cancel()
        callback.resume(with: result)
    }
}
