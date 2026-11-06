import XCTest
import CoreGraphics
@testable import Canvas

final class WindowSnapTests: XCTestCase {
    // A 1512×982 display with a 33 pt menu bar.
    let view = CGSize(width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 33, width: 1512, height: 949)
    // A full screen window somewhere on the canvas, entered on the visible area.
    let full = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 1512, height: 949), spot: CGPoint(x: 0, y: 33))
    var aligned: Camera { Camera(origin: CGPoint(x: 3000, y: 467), zoom: 1) }

    func testNearlyAlignedSnapsExactly() {
        let near = Camera(origin: CGPoint(x: 3030, y: 450), zoom: 1)
        let hit = WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full])
        XCTAssertEqual(hit?.index, 0)
        XCTAssertEqual(hit?.camera, aligned)
    }

    func testNearlyOneToOneSnaps() {
        // 96 %, centred on the window: each edge is about 30 pt in.
        let near = Camera(center: aligned.center(viewSize: view), zoom: 0.96, viewSize: view)
        XCTAssertEqual(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full])?.camera, aligned)
    }

    func testTooFarOrTooZoomedOutStays() {
        let off = Camera(origin: CGPoint(x: 3200, y: 467), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: off, viewSize: view, visible: visible, windows: [full]))
        let out = Camera(center: aligned.center(viewSize: view), zoom: 0.8, viewSize: view)
        XCTAssertNil(WindowSnap.target(camera: out, viewSize: view, visible: visible, windows: [full]))
    }

    func testNormalDoesNotSnapSmallWindows() {
        let small = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 900, height: 700), spot: CGPoint(x: 306, y: 157))
        let near = Camera(origin: CGPoint(x: 3000 - 300, y: 500 - 150), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [small]))
    }

    func testClosestWins() {
        let other = WindowSnap.Window(rect: CGRect(x: 3060, y: 500, width: 1512, height: 949), spot: CGPoint(x: 0, y: 33))
        let near = Camera(origin: CGPoint(x: 3050, y: 467), zoom: 1)
        XCTAssertEqual(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [full, other])?.index, 1)
    }

    func testStrongSnapsSmallWindowWithinReach() {
        let small = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 900, height: 700), spot: CGPoint(x: 306, y: 157))
        let target = Camera(origin: CGPoint(x: 2694, y: 343), zoom: 1)
        let near = Camera(origin: CGPoint(x: 2844, y: 343), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [small], strength: .normal))
        XCTAssertEqual(WindowSnap.target(camera: near, viewSize: view, visible: visible, windows: [small], strength: .strong)?.camera, target)
    }

    func testStrongReachBoundaryAndDistantWindow() {
        let size = CGSize(width: 1000, height: 1000)
        let area = CGRect(origin: .zero, size: size)
        let window = WindowSnap.Window(rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), spot: .zero)
        let edge = Camera(origin: CGPoint(x: 150, y: 0), zoom: 1)
        let beyond = Camera(origin: CGPoint(x: 151, y: 0), zoom: 1)
        XCTAssertNotNil(WindowSnap.target(camera: edge, viewSize: size, visible: area, windows: [window], strength: .strong))
        XCTAssertNil(WindowSnap.target(camera: beyond, viewSize: size, visible: area, windows: [window], strength: .strong))
        XCTAssertNil(WindowSnap.target(camera: edge, viewSize: size, visible: area, windows: [window], strength: .normal))
    }

    func testCenteringSensitivityChangesCatchDistanceAndTravelThreshold() {
        let size = CGSize(width: 1000, height: 1000)
        let area = CGRect(origin: .zero, size: size)
        let first = WindowSnap.Window(rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), spot: .zero)
        let right = WindowSnap.Window(rect: first.rect.offsetBy(dx: 900, dy: 0), spot: .zero)
        let displaced = Camera(origin: CGPoint(x: 200, y: 0), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: displaced, viewSize: size, visible: area, windows: [first], strength: .strong, sensitivity: 0.5))
        XCTAssertNotNil(WindowSnap.target(camera: displaced, viewSize: size, visible: area, windows: [first], strength: .strong, sensitivity: 2))
        XCTAssertNil(WindowSnap.neighbour(from: Camera(origin: .zero, zoom: 1), viewSize: size, windows: [first, right], direction: CGVector(dx: 12, dy: 0), sensitivity: 0.5))
        XCTAssertEqual(WindowSnap.neighbour(from: Camera(origin: .zero, zoom: 1), viewSize: size, windows: [first, right], direction: CGVector(dx: 12, dy: 0), sensitivity: 2)?.index, 1)
    }

    func testSensitivityAboveDefaultCatchesSmallerAndMoreDistantWindows() {
        let size = CGSize(width: 1000, height: 1000)
        let area = CGRect(origin: .zero, size: size)
        let small = WindowSnap.Window(rect: CGRect(x: 0, y: 0, width: 800, height: 800), spot: .zero)
        let aligned = Camera(origin: .zero, zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: aligned, viewSize: size, visible: area, windows: [small], sensitivity: 1))
        XCTAssertNotNil(WindowSnap.target(camera: aligned, viewSize: size, visible: area, windows: [small], sensitivity: 1.25))
        let full = WindowSnap.Window(rect: area, spot: .zero)
        let displaced = Camera(origin: CGPoint(x: 70, y: 0), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: displaced, viewSize: size, visible: area, windows: [full], sensitivity: 1))
        XCTAssertNotNil(WindowSnap.target(camera: displaced, viewSize: size, visible: area, windows: [full], sensitivity: 1.25))
        let far = Camera(origin: CGPoint(x: 500, y: 0), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: far, viewSize: size, visible: area, windows: [full], sensitivity: 2))
        XCTAssertNotNil(WindowSnap.target(camera: far, viewSize: size, visible: area, windows: [full], sensitivity: 4))
    }

    func testReleaseInGapDoesNotReturnToPreviousWindowEvenAtHighSensitivity() {
        let size = CGSize(width: 1000, height: 1000)
        let visible = CGRect(origin: .zero, size: size)
        let previous = WindowSnap.Window(rect: visible, spot: .zero)
        let next = WindowSnap.Window(rect: visible.offsetBy(dx: 1200, dy: 0), spot: .zero)
        let inGap = Camera(origin: CGPoint(x: 600, y: 0), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: inGap, viewSize: size, visible: visible,
                                       windows: [previous, next], sensitivity: 4, requireCenterInside: true))
        let overNext = Camera(origin: CGPoint(x: 800, y: 0), zoom: 1)
        XCTAssertEqual(WindowSnap.target(camera: overNext, viewSize: size, visible: visible,
                                         windows: [previous, next], sensitivity: 4, requireCenterInside: true)?.index, 1)
        // The new restriction belongs to pan release; other snap callers retain their prior behavior.
        XCTAssertNotNil(WindowSnap.target(camera: inGap, viewSize: size, visible: visible,
                                          windows: [previous], sensitivity: 4))
    }

    func testPanAwayDoesNotSnapBackWhileStillOverStartingWindow() {
        let size = CGSize(width: 1000, height: 1000)
        let visible = CGRect(origin: .zero, size: size)
        let window = WindowSnap.Window(rect: visible, spot: .zero)
        let start = Camera(origin: .zero, zoom: 1)
        let away = Camera(origin: CGPoint(x: 100, y: 0), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: away, viewSize: size, visible: visible, windows: [window],
                                       sensitivity: 4, requireCenterInside: true, panStart: start))
        let returning = Camera(origin: CGPoint(x: 50, y: 0), zoom: 1)
        XCTAssertNotNil(WindowSnap.target(camera: returning, viewSize: size, visible: visible, windows: [window],
                                          sensitivity: 4, requireCenterInside: true, panStart: away))
    }

    func testNiriModeSelectsNextWindowWhileFreePanKeepsGliding() {
        let size = CGSize(width: 1000, height: 1000)
        let visible = CGRect(origin: .zero, size: size)
        let previous = WindowSnap.Window(rect: visible, spot: .zero)
        let next = WindowSnap.Window(rect: visible.offsetBy(dx: 1200, dy: 0), spot: .zero)
        let start = Camera(origin: .zero, zoom: 1)
        let released = Camera(origin: CGPoint(x: 200, y: 0), zoom: 1)
        let free = WindowSnap.releaseTarget(camera: released, viewSize: size, visible: visible,
                                            windows: [previous, next], strength: .normal,
                                            sensitivity: 1, panStart: start)
        XCTAssertNil(free)
        let niri = WindowSnap.releaseTarget(camera: released, viewSize: size, visible: visible,
                                            windows: [previous, next], strength: .normal, sensitivity: 1,
                                            panStart: start, direction: CGVector(dx: 100, dy: 0), preferredIndex: 0)
        XCTAssertEqual(niri?.index, 1)
        XCTAssertEqual(niri?.directional, true)
        let noNeighbour = WindowSnap.releaseTarget(camera: released, viewSize: size, visible: visible,
                                                   windows: [previous], strength: .normal, sensitivity: 1,
                                                   panStart: start, direction: CGVector(dx: 100, dy: 0), preferredIndex: 0)
        XCTAssertNil(noNeighbour)
        let fallbackDisabled = WindowSnap.releaseTarget(camera: start, viewSize: size, visible: visible,
                                                        windows: [previous], strength: .normal, sensitivity: 1,
                                                        panStart: start, direction: CGVector(dx: 100, dy: 0),
                                                        preferredIndex: 0, allowFallback: false)
        XCTAssertNil(fallbackDisabled)
    }

    func testOverviewPanReleaseNeverEntersAWindow() {
        let size = CGSize(width: 1000, height: 1000)
        let visible = CGRect(origin: .zero, size: size)
        let windows = [WindowSnap.Window(rect: visible, spot: .zero),
                       WindowSnap.Window(rect: visible.offsetBy(dx: 1200, dy: 0), spot: .zero)]
        let start = Camera(center: CGPoint(x: 500, y: 500), zoom: 0.5, viewSize: size)
        let released = Camera(center: CGPoint(x: 600, y: 500), zoom: 0.5, viewSize: size)
        for direction in [nil, CGVector(dx: 100, dy: 0)] as [CGVector?] {
            XCTAssertNil(WindowSnap.releaseTarget(camera: released, viewSize: size, visible: visible,
                                                  windows: windows, strength: .strong, sensitivity: 4,
                                                  panStart: start, direction: direction))
        }
    }

    func testStrongDoesNotCaptureInvisibleWindowAndCanSnapFromOverview() {
        let hidden = WindowSnap.Window(rect: CGRect(x: 3000, y: 500, width: 20, height: 20), spot: CGPoint(x: -100, y: 100))
        let camera = Camera(origin: CGPoint(x: 3100, y: 400), zoom: 1)
        XCTAssertNil(WindowSnap.target(camera: camera, viewSize: view, visible: visible, windows: [hidden], strength: .strong))
        let out = Camera(center: aligned.center(viewSize: view), zoom: 0.5, viewSize: view)
        XCTAssertEqual(WindowSnap.target(camera: out, viewSize: view, visible: visible, windows: [full], strength: .strong)?.camera, aligned)
    }

    func testStrongRejectsWorldDistantWindowWhenZoomedOut() {
        let center = aligned.center(viewSize: view)
        let nearOnScreen = Camera(center: CGPoint(x: center.x + 300, y: center.y), zoom: 0.25, viewSize: view)
        XCTAssertNil(WindowSnap.target(camera: nearOnScreen, viewSize: view, visible: visible, windows: [full], strength: .strong))
    }

    func testEqualDistanceUsesGeometryRatherThanInputOrder() {
        let other = WindowSnap.Window(rect: CGRect(x: 3060, y: 500, width: 1512, height: 949), spot: CGPoint(x: 0, y: 33))
        let middle = Camera(origin: CGPoint(x: 3030, y: 467), zoom: 1)
        let first = WindowSnap.target(camera: middle, viewSize: view, visible: visible, windows: [full, other], strength: .strong)
        let reversed = WindowSnap.target(camera: middle, viewSize: view, visible: visible, windows: [other, full], strength: .strong)
        XCTAssertEqual(first?.camera, aligned)
        XCTAssertEqual(reversed?.camera, aligned)
    }

    func testPanSelectsNeighbourInCameraTravelDirection() {
        let left = WindowSnap.Window(rect: full.rect.offsetBy(dx: -900, dy: 0), spot: full.spot)
        let right = WindowSnap.Window(rect: full.rect.offsetBy(dx: 900, dy: 0), spot: full.spot)
        let fartherRight = WindowSnap.Window(rect: full.rect.offsetBy(dx: 1800, dy: 0), spot: full.spot)
        let windows = [fartherRight, left, full, right]
        XCTAssertEqual(WindowSnap.neighbour(from: aligned, viewSize: view, windows: windows,
                                            direction: CGVector(dx: 100, dy: 0))?.index, 3)
        XCTAssertEqual(WindowSnap.neighbour(from: aligned, viewSize: view, windows: windows,
                                            direction: CGVector(dx: -100, dy: 0))?.index, 1)
    }

    func testPanDoesNotSelectDistantOrWrongDirectionWindow() {
        let far = WindowSnap.Window(rect: full.rect.offsetBy(dx: 2500, dy: 0), spot: full.spot)
        let left = WindowSnap.Window(rect: full.rect.offsetBy(dx: -500, dy: 0), spot: full.spot)
        XCTAssertNil(WindowSnap.neighbour(from: aligned, viewSize: view, windows: [full, far, left],
                                          direction: CGVector(dx: 100, dy: 0)))
        XCTAssertNil(WindowSnap.neighbour(from: aligned, viewSize: view, windows: [full, left],
                                          direction: CGVector(dx: -5, dy: 0)))
    }

    func testPanSelectsVerticalNeighbourWithoutReordering() {
        let below = WindowSnap.Window(rect: full.rect.offsetBy(dx: 0, dy: 700), spot: full.spot)
        let right = WindowSnap.Window(rect: full.rect.offsetBy(dx: 700, dy: 0), spot: full.spot)
        let windows = [right, below, full]
        XCTAssertEqual(WindowSnap.neighbour(from: aligned, viewSize: view, windows: windows,
                                            direction: CGVector(dx: 10, dy: 100))?.index, 1)
        XCTAssertEqual(WindowSnap.neighbour(from: aligned, viewSize: view, windows: Array(windows.reversed()),
                                            direction: CGVector(dx: 10, dy: 100))?.camera,
                       Camera(origin: CGPoint(x: 3000, y: 1167), zoom: 1))
    }

    func testVerticalPanBetweenTilesSharingCameraPlacement() {
        let size = CGSize(width: 1000, height: 1000)
        let top = WindowSnap.Window(rect: CGRect(x: 0, y: 0, width: 1000, height: 500), spot: .zero)
        let bottom = WindowSnap.Window(rect: CGRect(x: 0, y: 500, width: 1000, height: 500),
                                       spot: CGPoint(x: 0, y: 500))
        let windows = [top, bottom]
        let camera = Camera(origin: .zero, zoom: 1)
        XCTAssertEqual(WindowSnap.neighbour(from: camera, viewSize: size, windows: windows,
                                            direction: CGVector(dx: 0, dy: 100), preferredIndex: 0)?.index, 1)
        XCTAssertEqual(WindowSnap.neighbour(from: camera, viewSize: size, windows: windows,
                                            direction: CGVector(dx: 0, dy: -100), preferredIndex: 1)?.index, 0)
        XCTAssertNil(WindowSnap.neighbour(from: camera, viewSize: size, windows: windows,
                                          direction: CGVector(dx: 0, dy: 100), preferredIndex: 1))
    }

    func testStalePreferredWindowDoesNotOverrideCurrentCamera() {
        let right = WindowSnap.Window(rect: full.rect.offsetBy(dx: 900, dy: 0), spot: full.spot)
        let below = WindowSnap.Window(rect: full.rect.offsetBy(dx: 900, dy: 600), spot: full.spot)
        let atRight = Camera(origin: CGPoint(x: 3900, y: 467), zoom: 1)
        XCTAssertEqual(WindowSnap.neighbour(from: atRight, viewSize: view, windows: [full, right, below],
                                            direction: CGVector(dx: 0, dy: 100), preferredIndex: 0)?.index, 2)
    }

    func testNudgeSpringIsQuickWithLittleOvershoot() {
        let s = Spring(x0: -1, v0: 0, response: WindowSnap.response, damping: WindowSnap.damping)
        var peak: CGFloat = -1
        for i in 0...200 { peak = max(peak, s.evaluate(at: CGFloat(i) * 0.005).x) }
        XCTAssertLessThan(peak, 0.02)                         // under 2 % past the window
        XCTAssertLessThan(abs(s.evaluate(at: 0.3).x), 0.01)   // there within 0.3 s
    }
}
