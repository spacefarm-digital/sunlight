import AppKit
import XCTest
@testable import Canvas

/// `WindowList.exists` is existence, `isOnScreen` presence: a window the Dock holds (minimized) or one
/// ordered out exists but isn't on screen. The old `exists` asked `CGWindowListCopyWindowInfo` with
/// `optionIncludingWindow`, which leaves out minimized windows on macOS 27, so the canvas took a
/// minimized window for a closed one and forgot its place.
final class WindowListTests: XCTestCase {
    func testNoWindowDoesNotExist() {
        XCTAssertFalse(WindowList.exists(0))
        XCTAssertFalse(WindowList.exists(CGWindowID.max))
        XCTAssertFalse(WindowList.isOnScreen(0))
        XCTAssertFalse(WindowList.isOnScreen(CGWindowID.max))
    }

    @MainActor
    func testAnOrderedOutWindowStillExistsButIsNotOnScreen() {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // No order-out fade: the window stays on screen through AppKit's fade (~250 ms measured with the
        // display awake), which can outlast the wait below; without it the window leaves in ~5 ms.
        window.animationBehavior = .none
        window.orderFrontRegardless()
        let id = CGWindowID(window.windowNumber)
        XCTAssertTrue(WindowList.exists(id))
        // The window server shows (and hides) the window once the run loop has spun; ~5–30 ms measured.
        XCTAssertTrue(settles(id, onScreen: true), "ordered front, the window comes on screen")
        window.orderOut(nil)
        XCTAssertTrue(WindowList.exists(id), "ordered out, the window still exists")
        XCTAssertTrue(settles(id, onScreen: false), "ordered out, the window leaves the screen")
        window.close()
    }

    /// Spins the run loop until the window server reports the window on screen or not, a second at most.
    private func settles(_ id: CGWindowID, onScreen: Bool) -> Bool {
        let until = Date() + 1
        while WindowList.isOnScreen(id) != onScreen, Date() < until { RunLoop.current.run(until: Date() + 0.005) }
        return WindowList.isOnScreen(id) == onScreen
    }
}
