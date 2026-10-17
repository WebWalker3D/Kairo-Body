import XCTest
import UIKit
import ImageIO
@testable import KairoBody

final class CameraCaptureServiceTests: XCTestCase {
    func testPreparedCameraJPEGHasReportedPixelDimensionsWithinServerLimit() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4032, height: 3024), format: format)
            .image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4032, height: 3024))
            }

        let (jpeg, width, height) = try CameraCaptureService.prepare(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let actualWidth = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let actualHeight = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertEqual(width, actualWidth)
        XCTAssertEqual(height, actualHeight)
        XCTAssertLessThanOrEqual(actualWidth, 1280)
        XCTAssertLessThanOrEqual(actualHeight, 1280)
        XCTAssertLessThan(jpeg.count, 2_000_000)
    }
}
