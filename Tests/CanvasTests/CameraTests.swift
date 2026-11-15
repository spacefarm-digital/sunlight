import XCTest
import CoreGraphics
@testable import Canvas

final class CameraTests: XCTestCase {
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

    // MARK: The flight's spring

    /// When a spring from a standing start is first at rest by the flight's own measure, and how far past
    /// the target it went on the way.
    private func settle(_ spring: Spring) -> (time: CGFloat, overshoot: CGFloat) {
        var overshoot: CGFloat = 0
        var time: CGFloat = 0
        for i in 0...2000 {
            let t = CGFloat(i) / 1000
            let (x, v) = spring.evaluate(at: t)
            overshoot = max(overshoot, x)
            if time == 0, FlightSpring.isAtRest(x, v) { time = t }
        }
        return (time, overshoot)
    }

    func testTheFlightIsALittleQuickerAndBouncesLessThanItDid() {
        let before = settle(Spring(x0: -1, v0: 0, response: 0.45, damping: 0.72))
        let now = settle(FlightSpring.spring(from: 0))
        XCTAssertEqual(before.time, 0.6, accuracy: 0.05)
        XCTAssertEqual(now.time, 0.5, accuracy: 0.05)
        XCTAssertEqual(before.overshoot, 0.04, accuracy: 0.005)
        XCTAssertEqual(now.overshoot, 0.02, accuracy: 0.005)
        // Still the same move: it does go past and come back.
        XCTAssertGreaterThan(now.overshoot, 0.01)
    }

    func testATriedTempoAndBounceAreKeptWithinTheMove() {
        XCTAssertEqual(FlightSpring.spring(from: 0).response, FlightSpring.response)
        XCTAssertEqual(FlightSpring.spring(from: 0).damping, FlightSpring.damping)
        let tried = FlightSpring.spring(from: 2, response: 0.36, damping: 0.85)
        XCTAssertEqual(tried.response, 0.36, accuracy: 1e-9)
        XCTAssertEqual(tried.damping, 0.85, accuracy: 1e-9)
        XCTAssertEqual(tried.v0, 2)
        XCTAssertEqual(FlightSpring.spring(from: 0, response: 0.01, damping: 9).response, 0.2, accuracy: 1e-9)
        XCTAssertEqual(FlightSpring.spring(from: 0, response: 5, damping: 9).response, 0.8, accuracy: 1e-9)
        XCTAssertEqual(FlightSpring.spring(from: 0, response: 5, damping: 9).damping, 1, accuracy: 1e-9)
        XCTAssertEqual(FlightSpring.spring(from: 0, response: 0.4, damping: 0.1).damping, 0.5, accuracy: 1e-9)
    }
}
