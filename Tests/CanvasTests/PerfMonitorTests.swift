import XCTest
@testable import Canvas

final class PerfMonitorTests: XCTestCase {
    /// A one-second pan at 120 a second inside a five-second summary is 120 frames a second, not 24.
    func testFramesPerSecondCountOnlyTheTimeMoving() {
        var pace = PerfMonitor.Pace()
        for i in 0...120 { pace.tick(at: 50 + Double(i) / 120) }
        XCTAssertEqual(pace.ticks, 121)
        XCTAssertEqual(pace.framesPerSecond ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(pace.moving, 1, accuracy: 0.0001)
        // Three seconds of nothing, then another half second: the pause isn't time moving.
        for i in 0...30 { pace.tick(at: 54 + Double(i) / 60) }
        XCTAssertEqual(pace.moving, 1.5, accuracy: 0.0001)
        XCTAssertEqual(pace.framesPerSecond ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(pace.summary, "100 fps over 1.5 s (152 ticks)")
    }

    func testALoneTickHasNoRateAndARunCanSpanTwoSummaries() {
        var pace = PerfMonitor.Pace()
        pace.tick(at: 10)
        XCTAssertNil(pace.framesPerSecond)
        XCTAssertEqual(pace.summary, "1 tick")
        pace.startOver()
        XCTAssertEqual(pace.ticks, 0)
        pace.tick(at: 10.01)
        XCTAssertEqual(pace.framesPerSecond ?? 0, 100, accuracy: 0.01)
    }

    func testShareOfACore() {
        let earlier = PerfMonitor.Usage(cpu: 100, at: 1000)
        XCTAssertEqual(PerfMonitor.Usage(cpu: 100.6, at: 1005).share(since: earlier) ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(PerfMonitor.Usage(cpu: 172, at: 1600).share(since: earlier) ?? 0, 12, accuracy: 0.001)
        XCTAssertNil(PerfMonitor.Usage(cpu: 101, at: 1000).share(since: earlier))
        XCTAssertGreaterThan(PerfMonitor.cpuSeconds(), 0)
    }

    func testAJumpInMemoryGetsALineWithWhatIsOpen() {
        let mb: UInt64 = 1_048_576
        XCTAssertNil(PerfMonitor.memoryLine(from: 171 * mb, to: 200 * mb, census: nil))
        XCTAssertNil(PerfMonitor.memoryLine(from: 0, to: 300 * mb, census: nil), "nothing noted yet")
        XCTAssertEqual(PerfMonitor.memoryLine(from: 171 * mb, to: 347 * mb, census: "2 windows: Sunlight 3024×1964, Canvas 640×808 hidden"),
                       "Memory: 171 → 347 MB (+176) · 2 windows: Sunlight 3024×1964, Canvas 640×808 hidden")
        XCTAssertEqual(PerfMonitor.memoryLine(from: 347 * mb, to: 180 * mb, census: nil), "Memory: 347 → 180 MB (−167)")
    }

    /// The Dock's full frames (level and stacking for every window) are counted apart from the rest in
    /// the Perf line, with the slowest of them: they are the ones that can hold a pan.
    func testFullFramesAreCountedApart() {
        XCTAssertEqual(PerfMonitor.describe(full: []), "")
        XCTAssertEqual(PerfMonitor.describe(full: [2.5, 9.2, 4]), ", 3 full max 9.20 ms")
    }
}
