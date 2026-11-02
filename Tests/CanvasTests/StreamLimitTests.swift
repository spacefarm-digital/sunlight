import XCTest
@testable import Canvas

@MainActor
final class StreamLimitTests: XCTestCase {
    private typealias Candidate = (id: ObjectIdentifier, area: CGFloat, streaming: Bool, capped: Bool)
    private let objects = (0..<12).map { _ in NSObject() }

    private func candidate(_ i: Int, area: CGFloat, streaming: Bool = false, capped: Bool = false) -> Candidate {
        (ObjectIdentifier(objects[i]), area, streaming, capped)
    }

    func testEveryoneStreamsUpToTheLimit() {
        let all = (0..<3).map { candidate($0, area: 0) }
        XCTAssertEqual(CanvasController.streamed(all, moving: false, limit: 3).count, 3)
    }

    func testTheLargestStreamPastTheLimit() {
        let all = (0..<5).map { candidate($0, area: CGFloat($0 + 1) * 100) }
        let chosen = CanvasController.streamed(all, moving: false, limit: 2)
        XCTAssertEqual(chosen, [all[4].id, all[3].id])
    }

    func testAStreamHoldsAgainstASlightlyLargerNewcomer() {
        let all = [candidate(0, area: 100, streaming: true), candidate(1, area: 120), candidate(2, area: 10)]
        XCTAssertEqual(CanvasController.streamed(all, moving: false, limit: 1), [all[0].id])
        let bigger = [candidate(0, area: 100, streaming: true), candidate(1, area: 200)]
        XCTAssertEqual(CanvasController.streamed(bigger, moving: false, limit: 1), [bigger[1].id])
    }

    func testNoNewStreamForAStillWhileTheCameraMoves() {
        let all = [candidate(0, area: 100, streaming: true), candidate(1, area: 1000, capped: true), candidate(2, area: 10)]
        XCTAssertEqual(CanvasController.streamed(all, moving: true, limit: 2), [all[0].id, all[2].id])
        XCTAssertTrue(CanvasController.streamed(all, moving: false, limit: 2).contains(all[1].id))
    }

    func testNoStreamsWithoutScreenCaptureMode() {
        let all = (0..<3).map { candidate($0, area: 100, streaming: $0 == 0) }
        XCTAssertTrue(CanvasController.streamed(all, moving: false, limit: 0).isEmpty)
    }
}

/// The live frame takes at most `LiveWindowsWire.maxWindows` windows: past that, the ones nearest the view.
@MainActor
final class FrameCapTests: XCTestCase {
    private let view = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testEveryWindowGoesWhenTheyFit() {
        let rects = (0..<5).map { CGRect(x: CGFloat($0) * 2000, y: 0, width: 100, height: 100) }
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 5), [0, 1, 2, 3, 4])
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 128), [0, 1, 2, 3, 4])
    }

    func testTheNearestGoFirstInTheirOrder() {
        // In view, just past the edge, far away, in view again, farther still.
        let rects = [CGRect(x: 100, y: 100, width: 100, height: 100),
                     CGRect(x: 1100, y: 0, width: 100, height: 100),
                     CGRect(x: 5000, y: 0, width: 100, height: 100),
                     CGRect(x: 500, y: 300, width: 100, height: 100),
                     CGRect(x: 0, y: -4000, width: 100, height: 100)]
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 3), [0, 1, 3])
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 2), [0, 3])
    }

    func testThePinnedWindowAlwaysGoes() {
        // In view, just past the edge, far away: the far one goes when it's pinned, in the nearest one's place.
        let rects = [CGRect(x: 100, y: 100, width: 100, height: 100),
                     CGRect(x: 1100, y: 0, width: 100, height: 100),
                     CGRect(x: 9000, y: 9000, width: 100, height: 100)]
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 2, pinned: 2), [0, 2])
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 1, pinned: 2), [2])
    }

    func testAtTheSameDistanceTheTopmostGoes() {
        let rects = (0..<4).map { _ in CGRect(x: 3000, y: 0, width: 100, height: 100) }
        XCTAssertEqual(CanvasController.nearestIndices(rects, to: view, limit: 2), [2, 3])
    }
}
