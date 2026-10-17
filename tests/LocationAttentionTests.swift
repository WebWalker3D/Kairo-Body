import XCTest
import CoreLocation
@testable import KairoBody

@MainActor
final class LocationAttentionTests: XCTestCase {
    func testCachedOldFixIsNotRetimestamped() async throws {
        var requested = false
        let attention = LocationAttention(request: { requested = true }, cancelRequest: {})
        let task = Task { try await attention.refresh(timeout: .milliseconds(100)) }
        await Task.yield()
        XCTAssertTrue(requested)
        let old = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -74),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
            timestamp: Date().addingTimeInterval(-121))
        attention.receive(old)
        do { _ = try await task.value; XCTFail("Old fix must time out") }
        catch { XCTAssertEqual(error as? LocationAttention.Failure, .timeout) }
        let timestamp = Date().addingTimeInterval(-2)
        let fresh = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -74),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: timestamp)
        let next = Task { try await attention.refresh() }
        await Task.yield()
        attention.receive(fresh)
        let result = try await next.value
        XCTAssertEqual(result.observedAt, BodyJSON.iso8601.string(from: timestamp))
        XCTAssertEqual(result.horizontalAccuracyM, 10)
    }

    func testBackgroundAndRevocationCancelRefresh() async {
        var cancels = 0
        let attention = LocationAttention(request: {}, cancelRequest: { cancels += 1 })
        for reason in ["background", "permission_revoked"] {
            let task = Task { try await attention.refresh() }
            await Task.yield()
            attention.cancel(reason: reason)
            do { _ = try await task.value; XCTFail("Cancelled refresh must fail") }
            catch { XCTAssertEqual(error as? LocationAttention.Failure, .cancelled(reason)) }
        }
        XCTAssertEqual(cancels, 2)
    }
}
