import XCTest
@testable import Canvas

/// The listing's rule: whose position a window is decides what the window server's frame may change.
final class WindowSyncTests: XCTestCase {
    private let last = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let moved = CGRect(x: 340, y: 180, width: 400, height: 300)
    private let resized = CGRect(x: 100, y: 100, width: 520, height: 300)

    private func verdict(owner: PositionOwner = .canvas, isWidget: Bool = false, capturing: Bool = false,
                         transformed: Bool = false, listed: CGRect, sizeHeld: Bool = false) -> WindowSync.Verdict {
        WindowSync.verdict(owner: owner, isWidget: isWidget, capturing: capturing, transformed: transformed,
                           listed: listed, last: last, sizeHeld: sizeHeld)
    }

    func testAnUnchangedFrameChangesNothing() {
        XCTAssertEqual(verdict(listed: last), .keep)
        XCTAssertEqual(verdict(owner: .user, listed: last), .keep)
        XCTAssertEqual(verdict(listed: last.offsetBy(dx: 0.3, dy: -0.2)), .keep, "the window server and Accessibility round differently")
    }

    func testTheUsersWindowMovesWhereTheyPutIt() {
        XCTAssertEqual(verdict(owner: .user, listed: moved), .move)
        XCTAssertEqual(verdict(owner: .user, listed: resized), .move)
    }

    func testTheCanvassWindowKeepsItsPlaceAndTakesOnlyASize() {
        XCTAssertEqual(verdict(listed: moved), .size, "a move the user didn't make: the canvas or macOS put it there")
        XCTAssertEqual(verdict(listed: resized), .size)
    }

    func testWhileLiveWindowsArePresentedTheFramesAreOurOwnOutput() {
        XCTAssertEqual(verdict(owner: .user, transformed: true, listed: moved), .keep)
        XCTAssertEqual(verdict(transformed: true, listed: resized), .keep)
    }

    func testAFrameWithNoSizeIsNowhere() {
        let nowhere = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(verdict(owner: .user, listed: nowhere), .keep)
        XCTAssertEqual(verdict(listed: nowhere), .keep)
        XCTAssertEqual(verdict(isWidget: true, listed: nowhere), .keep)
    }

    func testAResizeOfOursStillSettlingIsNotASizeToTake() {
        XCTAssertEqual(verdict(listed: resized, sizeHeld: true), .keep)
        XCTAssertEqual(verdict(owner: .user, listed: moved, sizeHeld: true), .keep)
    }

    func testAWidgetIsWhereItIsOnTheDesktop() {
        XCTAssertEqual(verdict(isWidget: true, listed: moved), .move)
    }

    func testInCaptureModeACanvasOwnedWindowTakesOnlyItsSize() {
        // The window server's frame can differ from the app's own (Accessibility, which places the
        // window at the seam and reads it back) by a constant: not a move.
        XCTAssertEqual(verdict(capturing: true, listed: moved), .size)
        XCTAssertEqual(verdict(capturing: true, listed: resized), .size)
        XCTAssertEqual(verdict(owner: .user, capturing: true, listed: moved), .move)
        XCTAssertEqual(verdict(isWidget: true, capturing: true, listed: moved), .move)
    }
}
