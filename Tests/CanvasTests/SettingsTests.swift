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

    func testNavigationPreferencesDefaultAndRoundTrip() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let keys = ["autoCenterAfterFourFingerPan", "singleClickBehavior", "doubleClickBehavior", "CanvasScrollBehavior", "CanvasScrollZoomModifier", "CanvasPinchEnabled", "CanvasSingleClickCommand", "CanvasDoubleClickCommand", "CanvasSecondaryClickCommand", "CanvasWindowDragAction", "TrackpadCameraSensitivity", "MouseCameraSensitivity", "WindowCenteringSensitivity",
                        "windowSnapStrength", "cameraPanSensitivity", "SnapOnPanRelease", "FreePanSteering", "CanvasEnterOnZoom"]
            let saved = keys.map { defaults.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, saved) {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            }
            keys.forEach { defaults.removeObject(forKey: $0) }
            XCTAssertFalse(Settings.snapOnPanRelease)
            XCTAssertFalse(Settings.freePanSteering)
            XCTAssertFalse(Settings.autoCenterAfterFourFingerPan)
            XCTAssertEqual(Settings.singleClickBehavior, .enterAtClickPosition)
            XCTAssertEqual(Settings.doubleClickBehavior, .centerWindow)
            XCTAssertEqual(Settings.windowClickAction(double: false), .standard(.enterAtClickPosition))
            Settings.setWindowClickAction(.command(.leftHalf), double: false)
            XCTAssertEqual(Settings.windowClickAction(double: false), .command(.leftHalf))
            XCTAssertEqual(Settings.windowClickAction(double: true), .standard(.centerWindow))
            Settings.setWindowClickAction(.standard(.none), double: false)
            XCTAssertEqual(Settings.windowClickAction(double: false), .standard(.none))
            Settings.singleClickBehavior = .centerWindow
            XCTAssertEqual(Settings.canvasScrollBehavior, .pan)
            XCTAssertTrue(Settings.scrollZoomModifier.matches([.option]))
            XCTAssertTrue(Settings.scrollZoomModifier.matches([.command]))
            XCTAssertFalse(Settings.scrollZoomModifier.matches([.shift]))
            XCTAssertTrue(Settings.canvasPinchEnabled)
            XCTAssertTrue(Settings.enterOnZoom)
            Settings.canvasScrollBehavior = .zoom
            Settings.scrollZoomModifier = .shift
            XCTAssertTrue(Settings.scrollZoomModifier.matches([.shift]))
            XCTAssertFalse(Settings.scrollZoomModifier.matches([.option]))
            Settings.canvasPinchEnabled = false
            Settings.secondaryClickAction = .command(.tidy)
            XCTAssertEqual(Settings.secondaryClickAction, .command(.tidy))
            Settings.windowDragAction = .panCanvas
            XCTAssertEqual(Settings.windowDragAction, .panCanvas)
            XCTAssertEqual(Settings.canvasScrollBehavior, .zoom)
            XCTAssertFalse(Settings.canvasPinchEnabled)
            Settings.resetTrackpadControls()
            XCTAssertEqual(Settings.canvasScrollBehavior, .pan)
            XCTAssertEqual(Settings.scrollZoomModifier, .optionOrCommand)
            XCTAssertTrue(Settings.canvasPinchEnabled)
            XCTAssertEqual(Settings.secondaryClickAction, .contextMenu)
            XCTAssertEqual(Settings.windowDragAction, .moveWindow)
            XCTAssertEqual(Settings.windowClickAction(double: false), .standard(.enterAtClickPosition))
            Settings.singleClickBehavior = .enterAtClickPosition
            XCTAssertEqual(Settings.doubleClickBehavior, .centerWindow)
            Settings.doubleClickBehavior = .none
            Settings.singleClickBehavior = .centerWindow
            XCTAssertEqual(Settings.doubleClickBehavior, .none)
            XCTAssertEqual(Settings.windowSnapStrength, .normal)
            XCTAssertEqual(Settings.cameraPanSensitivity, .normal)
            XCTAssertEqual(Settings.cameraPanSensitivity.multiplier, 1)
            XCTAssertEqual(Settings.trackpadCameraSensitivity, 1, accuracy: 0.0001)
            XCTAssertEqual(Settings.mouseCameraSensitivity, 1)
            XCTAssertEqual(Settings.windowCenteringSensitivity, 1)
            Settings.cameraPanSensitivity = .normal
            XCTAssertEqual(Settings.trackpadCameraSensitivity, 1, accuracy: 0.0001)
            Settings.trackpadCameraSensitivity = 2.2
            Settings.cameraPanSensitivity = .veryHigh
            XCTAssertEqual(Settings.trackpadCameraSensitivity, 2.2)
            Settings.mouseCameraSensitivity = 0.7
            Settings.windowCenteringSensitivity = 1.6
            XCTAssertEqual(Settings.trackpadCameraSensitivity, 2.2)
            XCTAssertEqual(Settings.mouseCameraSensitivity, 0.7)
            XCTAssertEqual(Settings.windowCenteringSensitivity, 1.6)
            Settings.windowCenteringSensitivity = 10
            XCTAssertEqual(Settings.windowCenteringSensitivity, 4)
            Settings.resetCameraSensitivities()
            XCTAssertEqual(Settings.trackpadCameraSensitivity, 1, accuracy: 0.0001)
            XCTAssertEqual(Settings.mouseCameraSensitivity, 1)
            XCTAssertEqual(Settings.windowCenteringSensitivity, 1)
            XCTAssertEqual(Settings.CameraPanSensitivity.normal.multiplier, 1)
            XCTAssertEqual(Settings.CameraPanSensitivity.veryHigh.multiplier, 1.6)

            Settings.autoCenterAfterFourFingerPan = false
            XCTAssertFalse(Settings.autoCenterAfterFourFingerPan)
            for behavior in Settings.SingleClickBehavior.allCases {
                Settings.singleClickBehavior = behavior
                XCTAssertEqual(defaults.string(forKey: "singleClickBehavior"), behavior.rawValue)
                XCTAssertEqual(Settings.singleClickBehavior, behavior)
            }
            for strength in Settings.WindowSnapStrength.allCases {
                Settings.windowSnapStrength = strength
                XCTAssertEqual(defaults.string(forKey: "windowSnapStrength"), strength.rawValue)
                XCTAssertEqual(Settings.windowSnapStrength, strength)
            }
            for sensitivity in Settings.CameraPanSensitivity.allCases {
                Settings.cameraPanSensitivity = sensitivity
                XCTAssertEqual(defaults.string(forKey: "cameraPanSensitivity"), sensitivity.rawValue)
                XCTAssertEqual(Settings.cameraPanSensitivity, sensitivity)
            }
            defaults.set("invalid", forKey: "singleClickBehavior")
            defaults.set("invalid", forKey: "windowSnapStrength")
            defaults.set("invalid", forKey: "cameraPanSensitivity")
            XCTAssertEqual(Settings.singleClickBehavior, .enterAtClickPosition)
            XCTAssertEqual(Settings.windowSnapStrength, .normal)
            XCTAssertEqual(Settings.cameraPanSensitivity, .normal)
        }
    }
}
