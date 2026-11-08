import XCTest
@testable import Canvas

final class ZoomReadoutTests: XCTestCase {
    /// Settings › Canvas › Zoom level: on until it's turned off, and switching it shows or hides the
    /// readout in the corner.
    func testZoomLevelSettingHidesTheReadout() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "ZoomReadout")
            defer {
                Settings.showZoomReadout = saved as? Bool ?? true
                if saved == nil { defaults.removeObject(forKey: "ZoomReadout") }
            }
            defaults.removeObject(forKey: "ZoomReadout")
            XCTAssertTrue(Settings.showZoomReadout, "on by default")

            let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
            XCTAssertTrue(view.zoomReadoutShown)

            Settings.showZoomReadout = false
            XCTAssertFalse(defaults.bool(forKey: "ZoomReadout"))
            view.zoomReadoutSettingChanged()   // what the notification does
            XCTAssertFalse(view.zoomReadoutShown)

            Settings.showZoomReadout = true
            view.zoomReadoutSettingChanged()
            XCTAssertTrue(view.zoomReadoutShown)
        }
    }
}
