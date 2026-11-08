import AppKit
import XCTest
@testable import Canvas

/// The Dock icon clicked, matched to the app in front (`ForegroundWatcher.onDockClickOnFrontApp`).
final class DockItemTests: XCTestCase {
    private let me = NSRunningApplication.current

    func testTheAppsOwnBundleIsItsIcon() throws {
        guard let bundle = me.bundleURL else { throw XCTSkip("the test runner has no bundle") }
        XCTAssertTrue(DockItem(url: bundle, title: nil).stands(for: me))
        // The Dock may give the bundle with a trailing slash, or by a path with a link in it.
        let slashed = try XCTUnwrap(URL(string: bundle.absoluteString.hasSuffix("/") ? bundle.absoluteString : bundle.absoluteString + "/"))
        XCTAssertTrue(DockItem(url: slashed, title: nil).stands(for: me))
    }

    func testAnotherBundleIsNotItsIcon() {
        let other = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        XCTAssertFalse(DockItem(url: other, title: me.localizedName).stands(for: me))
    }

    func testWithNoBundleGivenTheNameDecides() {
        XCTAssertEqual(DockItem(url: nil, title: me.localizedName).stands(for: me), me.localizedName != nil)
        XCTAssertFalse(DockItem(url: nil, title: "Not \(me.localizedName ?? "")").stands(for: me))
        XCTAssertFalse(DockItem(url: nil, title: nil).stands(for: me))
    }
}
