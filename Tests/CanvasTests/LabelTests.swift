import XCTest
@testable import Canvas

final class LabelTests: XCTestCase {
    func testLabelRendersOnceAtTheBackingScale() {
        let style = WindowProxy.LabelStyle(ink: .white, shadow: true)
        let image = WindowProxy.renderLabel("Safari — Sunlight", style: style, scale: 2)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, Int(WindowProxy.labelMaxWidth * 2))
        XCTAssertEqual(image?.height, Int(WindowProxy.labelHeight * 2))
        // Something was drawn: a pixel row through the text isn't all clear.
        guard let image, let data = image.dataProvider?.data as Data? else { return XCTFail("no bitmap") }
        let row = image.bytesPerRow * (image.height / 2)
        let drawn = data[row..<(row + 40 * 4)].contains { $0 != 0 }
        XCTAssertTrue(drawn)
        XCTAssertNotNil(WindowProxy.renderLabel("", style: style, scale: 1))
    }

    /// Settings › Canvas › Window names: on until it's turned off, and off hides every label at any zoom.
    func testWindowNamesSettingHidesTheLabel() async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            let saved = defaults.object(forKey: "WindowLabels")
            defer {
                Settings.showWindowLabels = saved as? Bool ?? true
                if saved == nil { defaults.removeObject(forKey: "WindowLabels") }
            }
            Settings.showWindowLabels = true
            let info = WindowInfo(id: 4242, pid: getpid(), layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  title: "Notes", alpha: 1)
            let proxy = WindowProxy(info: info, camera: Camera(center: .zero, zoom: 0.5, viewSize: CGSize(width: 1512, height: 982)), scale: 2)
            proxy.layoutChrome(zoom: 0.5)
            XCTAssertTrue(proxy.labelShown(zoom: 0.5))
            XCTAssertEqual(proxy.label.opacity, 1)
            XCTAssertFalse(proxy.labelShown(zoom: 1), "near 1:1 the real title bar takes over")

            Settings.showWindowLabels = false
            XCTAssertFalse(defaults.bool(forKey: "WindowLabels"))
            proxy.windowLabelsSettingChanged()
            XCTAssertFalse(proxy.labelShown(zoom: 0.5))
            XCTAssertEqual(proxy.label.opacity, 0)

            Settings.showWindowLabels = true
            proxy.windowLabelsSettingChanged()
            XCTAssertEqual(proxy.label.opacity, 1)
        }
    }
}
