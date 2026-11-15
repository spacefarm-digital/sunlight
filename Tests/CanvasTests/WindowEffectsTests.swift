import XCTest
@testable import Canvas

final class WindowEffectsTests: XCTestCase {
    private let styles: [WindowEffect.Style] = [.sunrise, .source, .dealt, .unfold, .bloom, .dissolve]
    private let geometry = WindowEffect.Geometry(toSource: CGVector(dx: -300, dy: 200), toNeighbour: CGVector(dx: 250, dy: 0))

    func testOpeningEndsAsTheWindowItself() {
        for style in styles {
            let d = WindowEffect.duration(style, opening: true)
            XCTAssertEqual(WindowEffect.frame(style, opening: true, at: d, geometry: geometry), .identity, "\(style)")
            XCTAssertEqual(WindowEffect.frame(style, opening: true, at: d + 1, geometry: geometry), .identity, "\(style)")
        }
    }

    func testClosingStartsAsTheWindowAndEndsGone() {
        for style in styles {
            let start = WindowEffect.frame(style, opening: false, at: 0, geometry: geometry)
            XCTAssertTrue(start.keepsGeometry, "\(style)")
            XCTAssertEqual(start.opacity, 1, "\(style)")
            XCTAssertEqual(start.dim, 0, "\(style)")
            let d = WindowEffect.duration(style, opening: false)
            XCTAssertEqual(WindowEffect.frame(style, opening: false, at: d, geometry: geometry).opacity, 0, accuracy: 1e-6, "\(style)")
            // Held there.
            XCTAssertEqual(WindowEffect.frame(style, opening: false, at: d + 5, geometry: geometry).opacity, 0, accuracy: 1e-6, "\(style)")
        }
    }

    func testOpenAndCloseAreNotMirrors() {
        for style in styles {
            XCTAssertLessThan(WindowEffect.duration(style, opening: false), WindowEffect.duration(style, opening: true), "\(style)")
            XCTAssertLessThanOrEqual(WindowEffect.duration(style, opening: true), 0.5)
        }
    }

    func testOpeningStartsUnseen() {
        // Faint or tiny at the first frame: the window is never seen at full size first.
        for style in styles where style != .unfold {
            let f = WindowEffect.frame(style, opening: true, at: 0, geometry: geometry)
            XCTAssertEqual(f.opacity, 0, accuracy: 1e-6, "\(style)")
        }
        let unfold = WindowEffect.frame(.unfold, opening: true, at: 0)
        XCTAssertLessThan(unfold.scale.height, 0.05)
        XCTAssertEqual(unfold.anchor, CGPoint(x: 0.5, y: 0))
    }

    func testSourceGrowsOutOfTheSpot() {
        let f = WindowEffect.frame(.source, opening: true, at: 0, geometry: geometry)
        XCTAssertEqual(f.offset, CGVector(dx: -300, dy: 200))
        XCTAssertEqual(f.scale.width, 0.18, accuracy: 1e-9)
        let r = f.applied(toScreen: CGRect(x: 400, y: 100, width: 200, height: 100))
        XCTAssertEqual(r.midX, 200, accuracy: 1e-9)   // its centre on the spot
        XCTAssertEqual(r.midY, 350, accuracy: 1e-9)
    }

    func testNeedsWhatItUses() {
        // Without a source or a neighbour, those become Sunrise.
        XCTAssertEqual(WindowEffect.usable(.source, WindowEffect.Geometry()), .sunrise)
        XCTAssertEqual(WindowEffect.usable(.dealt, WindowEffect.Geometry()), .sunrise)
        XCTAssertEqual(WindowEffect.frame(.source, opening: true, at: 0.1), WindowEffect.frame(.sunrise, opening: true, at: 0.1))
    }

    func testAutomaticPicksFromWhereTheWindowCameFrom() {
        typealias C = WindowEffect.Context
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(), reduceMotion: false), .sunrise)
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(source: .zero), reduceMotion: false), .source)
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(neighbour: .zero), reduceMotion: false), .dealt)
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(source: .zero, neighbour: .zero), reduceMotion: false), .source)
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(attached: true), reduceMotion: false), .unfold)
        XCTAssertEqual(WindowEffect.style(for: .bloom, context: C(source: .zero), reduceMotion: false), .bloom)
        // Reduce Motion: a fade, whatever was picked; None stays none.
        XCTAssertEqual(WindowEffect.style(for: .automatic, context: C(source: .zero), reduceMotion: true), .dissolve)
        XCTAssertEqual(WindowEffect.style(for: .unfold, context: C(), reduceMotion: true), .dissolve)
        XCTAssertNil(WindowEffect.style(for: .none, context: C(), reduceMotion: false))
        XCTAssertNil(WindowEffect.style(for: .none, context: C(), reduceMotion: true))
    }

    func testFrameAppliesInScreenAndWorld() {
        var f = WindowEffect.Frame()
        f.scale = CGSize(width: 0.5, height: 0.5)
        f.offset = CGVector(dx: 10, dy: -20)
        let screen = f.applied(toScreen: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(screen, CGRect(x: 35, y: 5, width: 50, height: 50))
        // The offset is screen points: at a zoom of 0.5 it is twice as far in the world.
        let world = f.applied(toWorld: CGRect(x: 0, y: 0, width: 100, height: 100), zoom: 0.5)
        XCTAssertEqual(world, CGRect(x: 45, y: -15, width: 50, height: 50))
    }

    func testNudgeGivesWayAndComesBack() {
        XCTAssertEqual(WindowEffect.nudge(at: 0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(WindowEffect.nudge(at: WindowEffect.nudgeDuration / 2), 0.5)
        XCTAssertEqual(WindowEffect.nudge(at: WindowEffect.nudgeDuration), 0, accuracy: 1e-9)
    }

    func testSunriseRisesAndBrightens() {
        let early = WindowEffect.frame(.sunrise, opening: true, at: 0.02)
        let late = WindowEffect.frame(.sunrise, opening: true, at: 0.2)
        XCTAssertGreaterThan(early.offset.dy, late.offset.dy)   // coming up from below
        XCTAssertGreaterThan(early.dim, late.dim)
        let closing = WindowEffect.frame(.sunrise, opening: false, at: 0.2)
        XCTAssertGreaterThan(closing.offset.dy, 0)              // and sinks as it goes
        XCTAssertGreaterThan(closing.dim, 0)
    }

    /// A window taken by the Dock in mid-fade goes out of sight for its first frames, until its alpha has
    /// landed, and so does one whose close has played out; nothing does where the add-on takes no alpha.
    func testAWindowFadingInIsTakenOutOfSightUntilItsAlphaLands() {
        let soon = CanvasController.revealAfter / 2, later = CanvasController.revealAfter * 2
        XCTAssertTrue(CanvasController.takenOutOfSight(fades: true, opacity: 0.1, takenFor: nil, closedAndHeld: false))
        XCTAssertTrue(CanvasController.takenOutOfSight(fades: true, opacity: 0.1, takenFor: soon, closedAndHeld: false))
        XCTAssertFalse(CanvasController.takenOutOfSight(fades: true, opacity: 0.1, takenFor: later, closedAndHeld: false))
        XCTAssertFalse(CanvasController.takenOutOfSight(fades: true, opacity: 1, takenFor: nil, closedAndHeld: false))
        XCTAssertTrue(CanvasController.takenOutOfSight(fades: true, opacity: 0, takenFor: later, closedAndHeld: true))
        XCTAssertFalse(CanvasController.takenOutOfSight(fades: false, opacity: 0.1, takenFor: nil, closedAndHeld: true))
    }
}
