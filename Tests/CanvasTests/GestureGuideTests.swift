import XCTest
@testable import Canvas

final class GestureGuideTests: XCTestCase {
    typealias Gesture = GestureGuide.Gesture

    func testEveryGestureIsInExactlyOneTab() {
        let all = GestureGuide.Group.allCases.flatMap(\.gestures)
        XCTAssertEqual(Set(all), Set(Gesture.allCases))
        XCTAssertEqual(all.count, Gesture.allCases.count)
        XCTAssertTrue(GestureGuide.Group.allCases.allSatisfy { !$0.gestures.isEmpty })
    }

    func testFingersOnTheTrackpadMatchTheGestureAndStayOnIt() {
        for gesture in Gesture.allCases {
            for step in 0...40 {
                let t = gesture.duration * Double(step) / 40
                let frame = GestureGuide.frame(for: gesture, at: t)
                XCTAssertEqual(frame.fingers.count, gesture.fingers, "\(gesture) at \(t)")
                for p in frame.fingers {
                    XCTAssertTrue((0.05...0.95).contains(p.x) && (0.05...0.95).contains(p.y), "\(gesture) at \(t): \(p)")
                }
                XCTAssertTrue((0...1).contains(frame.touch), "\(gesture) at \(t)")
                XCTAssertTrue((0...1).contains(frame.opacity), "\(gesture) at \(t)")
            }
        }
    }

    func testTheStillMomentShowsTheFingersDown() {
        for gesture in Gesture.allCases {
            let frame = GestureGuide.frame(for: gesture, at: gesture.still)
            XCTAssertEqual(frame.touch, 1, accuracy: 0.01, "\(gesture)")
            XCTAssertEqual(frame.opacity, 1, accuracy: 0.01, "\(gesture)")
        }
    }

    func testLoopsStartAndEndAlikeSoTheyDontJump() {
        for gesture in Gesture.allCases {
            let start = GestureGuide.frame(for: gesture, at: 0)
            let end = GestureGuide.frame(for: gesture, at: gesture.duration - 0.001)
            // Either the picture has faded out at both ends, or it ends where it began.
            if start.opacity > 0.01 || end.opacity > 0.01 {
                XCTAssertEqual(start.camera.zoom, end.camera.zoom, accuracy: 0.01, "\(gesture)")
                XCTAssertEqual(start.camera.center.x, end.camera.center.x, accuracy: 0.01, "\(gesture)")
            }
        }
    }

    func testFourFingerTapStaysPutAndOpensOutToEverything() {
        let before = GestureGuide.frame(for: .fourFingerTap, at: 0.5)
        let down = GestureGuide.frame(for: .fourFingerTap, at: 1.0)
        XCTAssertEqual(down.fingers[0], before.fingers[0])
        XCTAssertGreaterThan(down.touch, 0.9)
        XCTAssertEqual(before.camera, .entered)
        XCTAssertEqual(GestureGuide.frame(for: .fourFingerTap, at: 2.2).camera, .overview)
    }

    func testSwipeUpGoesUpTheTrackpadAndOutToEverything() {
        let before = GestureGuide.frame(for: .swipeUp, at: 0.45)
        let after = GestureGuide.frame(for: .swipeUp, at: 1.1)
        XCTAssertLessThan(after.fingers[0].y, before.fingers[0].y - 0.2)
        XCTAssertEqual(before.camera, .entered)
        XCTAssertEqual(GestureGuide.frame(for: .swipeUp, at: 2.0).camera, .overview)
    }

    func testFourFingerDragIsNotStraightUp() {
        let a = GestureGuide.frame(for: .fourFingerDrag, at: 1.0).fingers[0]
        let b = GestureGuide.frame(for: .fourFingerDrag, at: 2.6).fingers[0]
        XCTAssertGreaterThan(b.y, a.y, "down the trackpad, never up")
    }

    func testEnteringFillsTheScreenWithTheWindow() {
        let r = Camera.entered.screen(GestureGuide.acted)
        XCTAssertEqual(r.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(r.minY, 0, accuracy: 0.0001)
        XCTAssertEqual(r.width, 1, accuracy: 0.0001)
        XCTAssertEqual(r.height, 1, accuracy: 0.0001)
        let frame = GestureGuide.frame(for: .pinchIn, at: 2.5)
        XCTAssertEqual(frame.camera.zoom, Camera.entered.zoom, accuracy: 0.001)
    }

    func testPinchZoomsInAndBack() {
        XCTAssertGreaterThan(GestureGuide.frame(for: .pinch, at: 1.7).camera.zoom, 1.5)
        XCTAssertEqual(GestureGuide.frame(for: .pinch, at: 3.3).camera.zoom, 1, accuracy: 0.001)
    }

    func testAClickPressesOnceAndGoesIntoTheWindow() {
        XCTAssertFalse(GestureGuide.frame(for: .click, at: 1.0).raised)
        XCTAssertTrue(GestureGuide.frame(for: .click, at: 1.25).pressed)
        XCTAssertTrue(GestureGuide.frame(for: .click, at: 1.5).raised)
        let presses = stride(from: 1.0, to: 1.7, by: 0.01).map { GestureGuide.frame(for: .click, at: $0).pressed }
        let downs = zip(presses, presses.dropFirst()).filter { !$0 && $1 }.count
        XCTAssertEqual(downs, 1)
        XCTAssertEqual(GestureGuide.frame(for: .click, at: 3.0).camera.zoom, GestureGuide.Camera.entered.zoom, accuracy: 0.001)
    }

    func testADoubleClickPressesTwice() {
        let presses = stride(from: 1.0, to: 1.7, by: 0.01).map { GestureGuide.frame(for: .doubleClick, at: $0).pressed }
        let downs = zip(presses, presses.dropFirst()).filter { !$0 && $1 }.count
        XCTAssertEqual(downs, 2)
    }

    func testSpreadMovesTheWindowsAsideAndTheFingersApart() {
        let start = GestureGuide.frame(for: .spread, at: 0.5)
        let end = GestureGuide.frame(for: .spread, at: 1.6)
        XCTAssertEqual(end.desktop, 1)
        let width = { (f: GestureGuide.Frame) in f.fingers.map(\.x).max()! - f.fingers.map(\.x).min()! }
        XCTAssertGreaterThan(width(end), width(start) * 1.5)
        let moved = GestureGuide.rect(GestureGuide.acted, acted: true, in: end)
        XCTAssertLessThan(moved.midX, GestureGuide.acted.midX)
    }

    private typealias Camera = GestureGuide.Camera
}
