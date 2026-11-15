import XCTest
@testable import Canvas

final class WindowWaitTests: XCTestCase {
    func testAWaitLooksOftenThenRarelyThenStops() {
        var wait = WindowWait()
        XCTAssertTrue(wait.begin(pid: 7, now: 100))
        XCTAssertEqual(wait.nextLook(now: 100), 0.25)
        XCTAssertEqual(wait.nextLook(now: 109.9), 0.25)
        XCTAssertEqual(wait.nextLook(now: 110), 1)
        XCTAssertEqual(wait.nextLook(now: 159.5), 1)
        XCTAssertNil(wait.nextLook(now: 160))
    }

    /// The loop in the log: each attempt on a window that can't go on the canvas ended the wait and
    /// began it again a quarter second later, for six minutes. Taken up again that soon it is one wait.
    func testAWaitTakenUpAgainStraightAwayKeepsItsClock() {
        var wait = WindowWait()
        XCTAssertTrue(wait.begin(pid: 7, now: 100))
        var now = 100.0
        var looks = 0
        while let interval = wait.nextLook(now: now) {
            looks += 1
            now += interval
            XCTAssertFalse(wait.begin(pid: 7, now: now), "the same wait, \(now - 100) s in")
            XCTAssertLessThan(looks, 200, "the wait never ended")
        }
        XCTAssertEqual(now, 160, accuracy: 1.01)
        XCTAssertEqual(looks, 90)   // 40 quick ones in the first 10 s, 50 slow ones after
    }

    func testAnotherAppOrALaterWaitStartsItsOwnClock() {
        var wait = WindowWait()
        XCTAssertTrue(wait.begin(pid: 7, now: 100))
        _ = wait.nextLook(now: 130)
        XCTAssertTrue(wait.begin(pid: 8, now: 130.1), "another app")
        XCTAssertEqual(wait.nextLook(now: 130.1), 0.25)
        // The same app, long after its last look: not the same wait.
        XCTAssertTrue(wait.begin(pid: 8, now: 131 + WindowWait.gap))
        XCTAssertEqual(wait.pid, 8)
    }

    func testAWaitThatEndedStartsAfresh() {
        var wait = WindowWait()
        XCTAssertTrue(wait.begin(pid: 7, now: 100))
        _ = wait.nextLook(now: 140)
        wait.end(for: 9)
        XCTAssertFalse(wait.begin(pid: 7, now: 140.5), "another app's end isn't this wait's")
        wait.end(for: 7)
        XCTAssertEqual(wait, WindowWait())
        XCTAssertTrue(wait.begin(pid: 7, now: 141))
        XCTAssertEqual(wait.nextLook(now: 141), 0.25)
    }
}
