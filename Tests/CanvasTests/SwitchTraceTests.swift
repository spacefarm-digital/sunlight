import XCTest
@testable import Canvas

final class SwitchTraceTests: XCTestCase {
    func testACommandTabFromAWindowReadsEveryPart() {
        var t = SwitchTrace(how: "⌘Tab", .began, at: 10)
        t.mark(.canvas, at: 10.104)
        t.mark(.asked, at: 10.300)
        t.to = "Safari — Start Page"
        t.mark(.takeoff, at: 10.300)
        t.mark(.landed, at: 10.898)
        t.mark(.seam, at: 10.905)
        t.mark(.activated, at: 10.908)
        t.mark(.front, at: 10.936)
        XCTAssertEqual(t.line(), "Switch: ⌘Tab → Safari — Start Page · canvas 104 · wait 0 · flight 598 · seam 7 · activate 3 · front 28 · total 636 ms")
    }

    func testAClickHasNoCanvasOrWaitAndCountsFromTheFlight() {
        var t = SwitchTrace(how: "click", .takeoff, at: 5)
        t.to = "Notes — Shopping"
        t.mark(.landed, at: 5.5)
        t.mark(.seam, at: 5.5)
        t.mark(.activated, at: 5.502)
        t.mark(.front, at: 5.53)
        XCTAssertEqual(t.line(), "Switch: click → Notes — Shopping · flight 500 · seam 0 · activate 2 · front 28 · total 530 ms")
    }

    func testTheFirstTimeAMomentIsReachedCounts() {
        var t = SwitchTrace(how: "entry", .takeoff, at: 1)
        t.mark(.landed, at: 1.42)
        t.mark(.landed, at: 9)
        XCTAssertEqual(t.ms(.takeoff, .landed), 420)
        XCTAssertNil(t.ms(.takeoff, .front))
    }

    func testAnUnfinishedSwitchSaysHowFarItGot() {
        var t = SwitchTrace(how: "⌘Tab", .began, at: 1)
        t.mark(.asked, at: 1.2)
        t.mark(.takeoff, at: 1.25)
        t.mark(.landed, at: 1.85)
        XCTAssertEqual(t.line(unfinished: "another switch began"),
                       "Switch: ⌘Tab → ? · wait 50 · flight 600 · total 650 ms · another switch began")
    }

    @MainActor
    func testTheFlightCarriesOnTheCommandTabThatAskedForIt() {
        SwitchLog.close("test")
        SwitchLog.began("⌘Tab", at: 100)
        SwitchLog.mark(.canvas, at: 100.1)
        SwitchLog.mark(.asked, at: 100.4)
        SwitchLog.takeoff(how: "entry", to: "Mail — Inbox", windowID: 42, pid: 7, at: 100.41)
        XCTAssertEqual(SwitchLog.trace?.how, "⌘Tab")
        XCTAssertEqual(SwitchLog.trace?.ms(.asked, .takeoff), 10)
        // Another window's seam isn't this switch's.
        SwitchLog.mark(.landed, window: 43, at: 100.9)
        XCTAssertNil(SwitchLog.trace?.time(.landed))
        SwitchLog.mark(.landed, window: 42, at: 101)
        SwitchLog.mark(.seam, window: 42, at: 101.01)
        // Not in front before it was asked to the front, and not for another app.
        SwitchLog.front(pid: 7, at: 101.02)
        XCTAssertNotNil(SwitchLog.trace)
        SwitchLog.mark(.activated, window: 42, at: 101.02)
        SwitchLog.front(pid: 8, at: 101.03)
        XCTAssertNotNil(SwitchLog.trace)
        SwitchLog.front(pid: 7, at: 101.05)
        XCTAssertNil(SwitchLog.trace)
    }

    @MainActor
    func testAnOldCommandTabIsNotALaterClicksSwitch() {
        SwitchLog.close("test")
        SwitchLog.began("⌘Tab", at: 100)
        SwitchLog.mark(.asked, at: 100.4)
        // The ⌘Tab went to a hidden window, brought back another way; a click five seconds on is its own.
        SwitchLog.takeoff(how: "click", to: "Mail — Inbox", windowID: 42, pid: 7, at: 100.4 + SwitchLog.askedFor + 3)
        XCTAssertEqual(SwitchLog.trace?.how, "click")
        XCTAssertNil(SwitchLog.trace?.time(.asked))
        SwitchLog.close("test")
        XCTAssertNil(SwitchLog.trace)
    }
}
