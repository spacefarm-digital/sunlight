import XCTest
import CoreGraphics
@testable import Canvas

final class CameraTests: XCTestCase {
    func testTrackpadSensitivityUsesAuthorMovementAtOneHundredPercent() {
        let travel = CGVector(dx: 0.2, dy: -0.1)
        let baseline = CameraInput.trackpadDelta(travel, viewWidth: 1000, sensitivity: 1)
        XCTAssertEqual(baseline.dx, 300, accuracy: 0.0001)
        XCTAssertEqual(baseline.dy, -150, accuracy: 0.0001)
        let increased = CameraInput.trackpadDelta(travel, viewWidth: 1000, sensitivity: 1.5)
        XCTAssertEqual(increased.dx, 450, accuracy: 0.0001)
        XCTAssertEqual(increased.dy, -225, accuracy: 0.0001)
    }

    func testCloseWithinAPixelOnScreen() {
        let a = Camera(origin: CGPoint(x: 100, y: 200), zoom: 1)
        XCTAssertTrue(a.isClose(to: Camera(origin: CGPoint(x: 100.4, y: 199.6), zoom: 1)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 101.5, y: 200), zoom: 1)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 100, y: 200), zoom: 0.9)))
    }

    func testZoomedOutAWorldPointIsLessThanAPixel() {
        let a = Camera(origin: .zero, zoom: 0.25)
        XCTAssertTrue(a.isClose(to: Camera(origin: CGPoint(x: 3, y: 0), zoom: 0.25)))
        XCTAssertFalse(a.isClose(to: Camera(origin: CGPoint(x: 5, y: 0), zoom: 0.25)))
    }
}
