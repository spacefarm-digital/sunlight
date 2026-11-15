import AppKit
import XCTest
@testable import Canvas

final class SettingsTests: XCTestCase {
    func testCommandLineCanDisableLayoutPersistenceWithoutChangingSavedPreferences() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
            var arguments = original
            // NSArgumentDomain contains strings for flags passed to a development/test launch.
            arguments["CanvasRemember"] = "NO"
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            XCTAssertFalse(Settings.rememberCanvas)
            arguments["CanvasRemember"] = "YES"
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            XCTAssertTrue(Settings.rememberCanvas)
        }
    }

    func testSwitcherEdgeDefaultsToBottomAndRoundTrips() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "SwitcherEdge")
            defer { defaults.set(saved, forKey: "SwitcherEdge") }
            defaults.removeObject(forKey: "SwitcherEdge")
            XCTAssertEqual(Settings.switcherEdge, .bottom)
            for edge in SwitcherEdge.allCases {
                Settings.switcherEdge = edge
                XCTAssertEqual(Settings.switcherEdge, edge)
            }
            defaults.set("diagonal", forKey: "SwitcherEdge")
            XCTAssertEqual(Settings.switcherEdge, .bottom)
        }
    }

    /// The Settings window's pictures run only while some of it can be seen: hidden with the app, closed
    /// or wholly covered, they hold (`SettingsWindowController.isOnScreen`).
    func testSettingsIsOnScreenOnlyWhenOrderedInAndNotHidden() {
        XCTAssertTrue(SettingsWindowController.isOnScreen(visible: true, occlusion: [.visible]))
        XCTAssertFalse(SettingsWindowController.isOnScreen(visible: true, occlusion: []))
        XCTAssertFalse(SettingsWindowController.isOnScreen(visible: false, occlusion: [.visible]))
        XCTAssertFalse(SettingsWindowController.isOnScreen(visible: false, occlusion: []))
    }
}
