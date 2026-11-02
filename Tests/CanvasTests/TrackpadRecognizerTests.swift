import XCTest
@testable import Canvas

final class TrackpadRecognizerTests: XCTestCase {
    private let four: Set<Int32> = [1, 2, 3, 4]

    /// Feeds centroids (trackpad widths, y up) for one four-finger touch, then lifts; returns every phase.
    /// The frames are `interval` apart, so a ten-step path at the default is a quick stroke.
    private func touch(_ path: [CGPoint], interval: Double = 0.01, swipeUp: Bool = false) -> [TrackpadPan.Phase] {
        var r = TrackpadRecognizer()
        r.swipeUpSeesAll = swipeUp
        var phases: [TrackpadPan.Phase] = []
        for (i, p) in path.enumerated() {
            phases += r.update(device: 1, fingers: four, centroid: p, now: Double(i) * interval)
        }
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: Double(path.count) * interval)
        return phases
    }

    private func line(from a: CGPoint, to b: CGPoint, steps: Int = 10) -> [CGPoint] {
        (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private func travel(in phases: [TrackpadPan.Phase]) -> [CGVector] {
        phases.compactMap { if case .changed(let v) = $0 { v } else { nil } }
    }

    // MARK: Tap

    /// Four fingers landing together at `at`, still for `held` seconds, then lifting together.
    private func tap(held: Double, at start: Double = 0, drift: CGFloat = 0) -> [TrackpadPan.Phase] {
        var r = TrackpadRecognizer()
        var phases: [TrackpadPan.Phase] = []
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5, y: 0.5), now: start)
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5 + drift, y: 0.5), now: start + held / 2)
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5 + drift, y: 0.5), now: start + held)
        phases += r.update(device: 1, fingers: [1, 2], centroid: CGPoint(x: 0.5 + drift, y: 0.5), now: start + held + 0.01)
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: start + held + 0.02)
        return phases
    }

    func testAFourFingerTapIsSeeAllOnce() {
        XCTAssertEqual(tap(held: 0.12), [.seeAll])
    }

    func testAHandRestingOnTheTrackpadIsNotATap() {
        XCTAssertEqual(tap(held: 0.6), [])
    }

    func testFingersThatShiftedAreNotATap() {
        XCTAssertFalse(tap(held: 0.12, drift: 0.05).contains(.seeAll))
    }

    func testAFourthFingerJoiningAThreeFingerTapLateIsNotATap() {
        var r = TrackpadRecognizer()
        var phases: [TrackpadPan.Phase] = []
        phases += r.update(device: 1, fingers: [1, 2, 3], centroid: CGPoint(x: 0.5, y: 0.5), now: 0)
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5, y: 0.5), now: 0.25)
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: 0.3)
        XCTAssertEqual(phases, [])
    }

    func testAQuickStrokeUpPansLikeAnyDrag() {
        let phases = touch(line(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.51, y: 0.5)))
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertFalse(phases.contains(.seeAll))
        // Plumb: the slight lean doesn't creep sideways.
        XCTAssertTrue(travel(in: phases).allSatisfy { $0.dx == 0 && $0.dy < 0 })
    }

    func testStraightDownPansPlumb() {
        let phases = touch(line(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.49, y: 0.2)))
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertFalse(phases.contains(.seeAll))
        // y down in the travel: the fingers went down the trackpad, so the content follows them down.
        XCTAssertTrue(travel(in: phases).allSatisfy { $0.dx == 0 && $0.dy > 0 })
    }

    func testAHandNudgingWithinTheSlopDoesNothing() {
        // Half a second on the trackpad, too long for a tap, moving less than the slop.
        let phases = touch(line(from: CGPoint(x: 0.5, y: 0.3), to: CGPoint(x: 0.5, y: 0.315)), interval: 0.05)
        XCTAssertEqual(phases, [])
    }

    // MARK: Swipe up (Settings › Trackpad)

    func testWithSwipeUpChosenAQuickStrokeUpIsSeeAllAndEndsThePan() {
        let phases = touch(line(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.51, y: 0.5)), swipeUp: true)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .seeAll)
        XCTAssertEqual(phases.filter { $0 == .seeAll }.count, 1)
        XCTAssertFalse(phases.contains(.ended))
    }

    func testWithSwipeUpChosenASlowDragUpPans() {
        let phases = touch(line(from: CGPoint(x: 0.5, y: 0.1), to: CGPoint(x: 0.5, y: 0.8), steps: 30), interval: 0.1, swipeUp: true)
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        XCTAssertFalse(phases.contains(.seeAll))
    }

    func testWithSwipeUpChosenSpeedingUpLateIsStillADrag() {
        let slow = line(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.25), steps: 6)
        let fast = line(from: CGPoint(x: 0.5, y: 0.25), to: CGPoint(x: 0.5, y: 0.6), steps: 6)
        XCTAssertFalse(touch(slow + fast, interval: 0.1, swipeUp: true).contains(.seeAll))
    }

    func testWithSwipeUpChosenATapDoesNothing() {
        var r = TrackpadRecognizer()
        r.swipeUpSeesAll = true
        var phases: [TrackpadPan.Phase] = []
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5, y: 0.5), now: 0)
        phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5, y: 0.5), now: 0.1)
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: 0.12)
        XCTAssertEqual(phases, [])
    }

    // MARK: Drag

    func testHorizontalDragPansLevel() {
        let phases = touch(line(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.6, y: 0.55)))
        XCTAssertEqual(phases.first, .began)
        XCTAssertEqual(phases.last, .ended)
        let travel = travel(in: phases)
        XCTAssertFalse(travel.isEmpty)
        XCTAssertTrue(travel.allSatisfy { $0.dy == 0 && $0.dx > 0 })
        XCTAssertFalse(phases.contains(.seeAll))
    }

    func testDiagonalDragPansFreely() {
        let phases = touch(line(from: CGPoint(x: 0.2, y: 0.2), to: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(phases.first, .began)
        XCTAssertTrue(phases.contains { if case .changed(let v) = $0 { v.dx > 0 && v.dy < 0 } else { false } })
        XCTAssertFalse(phases.contains(.seeAll))
    }

    // MARK: Spread

    /// One four-finger touch with the centroid held still and the fingers' spread going from `a` to `b`.
    private func spreading(from a: CGFloat, to b: CGFloat, steps: Int = 10) -> [TrackpadPan.Phase] {
        var r = TrackpadRecognizer()
        var phases: [TrackpadPan.Phase] = []
        for i in 0...steps {
            let spread = a + (b - a) * CGFloat(i) / CGFloat(steps)
            phases += r.update(device: 1, fingers: four, centroid: CGPoint(x: 0.5, y: 0.3), spread: spread, now: 0)
        }
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: 0)
        return phases
    }

    func testSpreadingTheFingersIsShowDesktopOnce() {
        XCTAssertEqual(spreading(from: 0.06, to: 0.3), [.spread])
    }

    func testPinchingThemTogetherDoesNothing() {
        XCTAssertEqual(spreading(from: 0.3, to: 0.06), [])
    }

    func testASmallSpreadIsNotOne() {
        XCTAssertEqual(spreading(from: 0.1, to: 0.13), [])
    }

    /// A thumb and three fingers on a 16 cm trackpad, measured as `TrackpadPan.frame` measures them:
    /// the thumb moves down and left, the fingers up and right, each point by `cm` centimetres.
    private func hand(parted cm: CGFloat) -> (centroid: CGPoint, spread: CGFloat) {
        let w: CGFloat = 16
        let d = cm / w
        let points = [CGPoint(x: 0.40 - d * 0.7, y: 0.30 - d * 0.7),
                      CGPoint(x: 0.50 + d * 0.3, y: 0.55 + d * 0.9),
                      CGPoint(x: 0.58 + d * 0.5, y: 0.58 + d * 0.8),
                      CGPoint(x: 0.66 + d * 0.8, y: 0.54 + d * 0.6)]
        let c = CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
        let s = points.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / 4
        return (c, s)
    }

    func testARealHandSpreadingTwoCentimetresIsShowDesktop() {
        var r = TrackpadRecognizer()
        var phases: [TrackpadPan.Phase] = []
        for i in 0...10 {
            let h = hand(parted: 2 * CGFloat(i) / 10)
            phases += r.update(device: 1, fingers: four, centroid: h.centroid, spread: h.spread, now: Double(i) * 0.02)
        }
        phases += r.update(device: 1, fingers: [], centroid: .zero, now: 0.3)
        XCTAssertEqual(phases, [.spread])
    }

    func testAPanWithTheHandHeldTheSameStillPans() {
        var r = TrackpadRecognizer()
        var phases: [TrackpadPan.Phase] = []
        for p in line(from: CGPoint(x: 0.2, y: 0.5), to: CGPoint(x: 0.6, y: 0.5)) {
            phases += r.update(device: 1, fingers: four, centroid: p, spread: 0.1, now: 0)
        }
        XCTAssertEqual(phases.first, .began)
        XCTAssertFalse(phases.contains(.spread))
    }
}

extension TrackpadRecognizerTests {
    /// Sunlight off: the Mac's own four-finger swipes go through, so the Dock-control events aren't dropped.
    func testDockControlIsLeftAloneWhileInactive() {
        var r = TrackpadRecognizer()
        r.active = false
        _ = r.update(device: 1, fingers: [1, 2, 3, 4], centroid: CGPoint(x: 0.5, y: 0.5), now: 10)
        XCTAssertEqual(r.dropDockControlUntil, 0)
        var on = TrackpadRecognizer()
        _ = on.update(device: 1, fingers: [1, 2, 3, 4], centroid: CGPoint(x: 0.5, y: 0.5), now: 10)
        XCTAssertGreaterThan(on.dropDockControlUntil, 10)
    }
}
