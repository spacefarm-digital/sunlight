import XCTest
@testable import Canvas

final class NewWindowSpotTests: XCTestCase {
    private let view = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    private let gap: CGFloat = 32
    private let size = CGSize(width: 400, height: 300)

    private func spot(_ others: [CGRect], size: CGSize? = nil) -> CGRect {
        NewWindowSpot.spot(size: size ?? self.size, avoiding: others, view: view, gap: gap)
    }

    private var centred: CGRect { CGRect(x: 800, y: 450, width: 400, height: 300) }

    func testOnAnEmptyCanvasItOpensInTheMiddleOfTheView() {
        XCTAssertEqual(spot([]), centred)
    }

    func testWhenTheMiddleIsFreeItOpensThere() {
        let corner = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(spot([corner]), centred)
    }

    func testWhenTheMiddleIsTakenItGoesRightBesideTheWindowThere() {
        let a = CGRect(x: 700, y: 400, width: 600, height: 400)
        let r = spot([a])
        XCTAssertTrue(NewWindowSpot.isClear(r, of: [a], gap: gap), "\(r)")
        // Level with the middle, a gap off the window's nearer side: below it (its short side).
        XCTAssertEqual(r, CGRect(x: 800, y: 832, width: 400, height: 300))
    }

    func testItNeverLandsOnAnyWindow() {
        let windows = [CGRect(x: 600, y: 300, width: 400, height: 300), CGRect(x: 1032, y: 300, width: 400, height: 300),
                       CGRect(x: 600, y: 632, width: 400, height: 300), CGRect(x: 1032, y: 632, width: 400, height: 300)]
        let r = spot(windows)
        XCTAssertTrue(NewWindowSpot.isClear(r, of: windows, gap: gap), "\(r)")
        XCTAssertTrue(view.contains(r), "\(r)")
    }

    func testARoomySpotInViewBeatsANearerOneOffScreen() {
        // A window filling the view but for a strip on the right: the only spot in view is that strip.
        let a = CGRect(x: 0, y: 0, width: 1500, height: 1200)
        let r = spot([a])
        XCTAssertTrue(view.contains(r), "\(r)")
        XCTAssertEqual(r.minX, a.maxX + gap)
    }

    func testEdgesExactlyAGapApartAreClear() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(NewWindowSpot.isClear(CGRect(x: 132, y: 0, width: 100, height: 100), of: [a], gap: gap))
        XCTAssertFalse(NewWindowSpot.isClear(CGRect(x: 120, y: 0, width: 100, height: 100), of: [a], gap: gap))
    }

    // MARK: Aimed at a spot (Open Here…)

    private func spot(_ others: [CGRect], at target: CGPoint) -> CGRect {
        NewWindowSpot.spot(size: size, avoiding: others, view: view, gap: gap, target: target)
    }

    func testAimedAtAFreeSpotItIsCentredThere() {
        XCTAssertEqual(spot([], at: CGPoint(x: 300, y: 300)), CGRect(x: 100, y: 150, width: 400, height: 300))
    }

    func testAimedNearTheEdgeOfTheViewItIsPushedJustInside() {
        XCTAssertEqual(spot([], at: CGPoint(x: 1950, y: 1150)), CGRect(x: 1600, y: 900, width: 400, height: 300))
    }

    func testAimedAtAWindowItGoesBesideItNearestTheSpot() {
        let a = CGRect(x: 0, y: 0, width: 600, height: 600)
        let r = spot([a], at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(NewWindowSpot.isClear(r, of: [a], gap: gap), "\(r)")
        // Right below it, level with the spot: nearer the spot than right of it, and in view.
        XCTAssertEqual(r, CGRect(x: 100, y: 632, width: 400, height: 300))
    }

    func testWithoutATargetItStillAimsAtTheMiddleOfTheView() {
        XCTAssertEqual(NewWindowSpot.spot(size: size, avoiding: [], view: view, gap: gap, target: nil), centred)
    }

    // MARK: A place it already has (last run's)

    func testAPlaceThatsStillFreeIsKept() {
        let r = CGRect(x: -900, y: 40, width: 400, height: 300)
        XCTAssertEqual(NewWindowSpot.free(r, avoiding: [CGRect(x: 0, y: 0, width: 400, height: 300)], gap: gap), r)
    }

    func testATakenPlaceGivesWayToTheNearestFreeOneInViewOrNot() {
        let r = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 300, y: 100, width: 600, height: 600)
        let moved = NewWindowSpot.free(r, avoiding: [b], gap: gap)
        XCTAssertTrue(NewWindowSpot.isClear(moved, of: [b], gap: gap), "\(moved)")
        // Left of the window that took it, level with where it was: the least way off.
        XCTAssertEqual(moved, CGRect(x: -132, y: 0, width: 400, height: 300))
    }

    // MARK: Opened in front, from inside a window

    private func inFront(_ window: CGRect, _ others: [CGRect], near: CGPoint) -> NewWindowSpot.InFront {
        NewWindowSpot.inFront(window, avoiding: others, view: view, gap: gap, near: near)
    }

    func testOpenedClearOfEverythingItStays() {
        let a = CGRect(x: 600, y: 0, width: 400, height: 300)
        XCTAssertEqual(inFront(CGRect(x: 0, y: 0, width: 400, height: 300), [a], near: CGPoint(x: 800, y: 150)), .stay)
    }

    func testOpenedOverTheWindowInUseWithRoomOnScreenItMovesBesideIt() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let result = inFront(CGRect(x: 40, y: 40, width: 400, height: 300), [a], near: CGPoint(x: a.midX, y: a.midY))
        // Below it, level with its middle: the nearest room on screen.
        XCTAssertEqual(result, .move(CGRect(x: 300, y: 832, width: 400, height: 300)))
    }

    func testOpenedOverAWindowFillingTheScreenTheViewGoesOverToTheNearestRoom() {
        let a = CGRect(x: 0, y: 0, width: 2000, height: 1100)
        let result = inFront(CGRect(x: 40, y: 40, width: 400, height: 300), [a], near: CGPoint(x: a.midX, y: a.midY))
        guard case .slide(let r) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(NewWindowSpot.isClear(r, of: [a], gap: gap), "\(r)")
        XCTAssertFalse(view.contains(r), "\(r)")
        // Below it, where the least of it is off screen, under its middle.
        XCTAssertEqual(r, CGRect(x: 800, y: 1132, width: 400, height: 300))
    }

    func testNeighbourIsTheWindowTheSpotWentBeside() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 1000, y: 0, width: 400, height: 300)
        // Right of a, a gap of 8 away, overlapping it vertically.
        XCTAssertEqual(NewWindowSpot.neighbour(of: CGRect(x: 408, y: 50, width: 300, height: 200), among: [b, a], gap: 8), 1)
        // Under b.
        XCTAssertEqual(NewWindowSpot.neighbour(of: CGRect(x: 1100, y: 308, width: 300, height: 200), among: [a, b], gap: 8), 1)
        // In the clear, or near but not facing an edge: none.
        XCTAssertNil(NewWindowSpot.neighbour(of: CGRect(x: 600, y: 600, width: 200, height: 200), among: [a, b], gap: 8))
        XCTAssertNil(NewWindowSpot.neighbour(of: CGRect(x: 408, y: 400, width: 200, height: 200), among: [a, b], gap: 8))
        // Between both: the nearer by centre.
        let between = CGRect(x: 408, y: 0, width: 584, height: 300)
        let wide = CGRect(x: 1000, y: 0, width: 800, height: 300)
        XCTAssertEqual(NewWindowSpot.neighbour(of: between, among: [wide, a], gap: 8), 1)
    }

    /// An app brought forward over the canvas with no window on it (a Dock click on a running app whose
    /// windows are all closed) is held for as a launch at once, before its focused window is read: handing
    /// the windows back first emptied the canvas for a few frames. Not an app with a window somewhere on
    /// a canvas, nor one already known to open none.
    func testAnAppWithNoWindowOnTheCanvasIsHeldForAsALaunch() {
        XCTAssertTrue(CanvasController.opensAsLaunch(hasWindows: false, knownWindowless: false))
        XCTAssertFalse(CanvasController.opensAsLaunch(hasWindows: true, knownWindowless: false))
        XCTAssertFalse(CanvasController.opensAsLaunch(hasWindows: false, knownWindowless: true))
    }
}
