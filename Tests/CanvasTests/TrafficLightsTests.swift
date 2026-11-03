import XCTest
@testable import Canvas

final class TrafficLightsTests: XCTestCase {
    private let window = CGRect(x: 317, y: 311, width: 822, height: 449)

    /// Finder on macOS 27.2, as Accessibility gave it: a unified toolbar, 16 pt hit boxes around 14 pt circles.
    func testMeasuredFromAccessibilityFrames() {
        let layout = TrafficLights.Layout.measured(
            window: window,
            close: CGRect(x: 335, y: 329, width: 16, height: 16),
            minimize: CGRect(x: 358, y: 329, width: 16, height: 16),
            zoom: CGRect(x: 381, y: 329, width: 16, height: 16))
        XCTAssertEqual(layout, TrafficLights.Layout(centres: [CGPoint(x: 26, y: 26), CGPoint(x: 49, y: 26), CGPoint(x: 72, y: 26)],
                                                    diameter: 14))
    }

    func testNoCloseButtonIsNoLayout() {
        XCTAssertNil(TrafficLights.Layout.measured(window: window, close: nil,
                                                   minimize: CGRect(x: 358, y: 329, width: 16, height: 16), zoom: nil))
    }

    /// A sheet, or a window mid-animation, reports buttons nowhere near its corner.
    func testButtonsOutsideTheCornerAreRejected() {
        XCTAssertNil(TrafficLights.Layout.measured(window: window, close: CGRect(x: 900, y: 329, width: 16, height: 16),
                                                   minimize: nil, zoom: nil))
        XCTAssertNil(TrafficLights.Layout.measured(window: window, close: CGRect(x: 335, y: 329, width: 16, height: 16),
                                                   minimize: CGRect(x: 358, y: 340, width: 16, height: 16), zoom: nil))
    }

    /// Without a zoom button the green button still gets the third slot, one pitch on.
    func testMissingZoomCarriesOnAtThePitch() {
        let layout = TrafficLights.Layout.measured(
            window: window,
            close: CGRect(x: 325, y: 319, width: 16, height: 16),
            minimize: CGRect(x: 348, y: 319, width: 16, height: 16),
            zoom: nil)
        XCTAssertEqual(layout?.centres.count, 2)
        XCTAssertEqual(layout?.centre(2), CGPoint(x: 62, y: 16))
    }

    func testStandardMatchesAPlainTitleBar() {
        let standard = TrafficLights.Layout.standard
        XCTAssertEqual(standard.diameter, 14)
        XCTAssertEqual(standard.pitch, 23)
        XCTAssertEqual(standard.centre(0), CGPoint(x: 16, y: 16))
    }

    func testPressedIsDarkerAndInactiveIsGrey() {
        let rest = TrafficLights.look(.close, active: true, pressed: false, dark: true)
        let pressed = TrafficLights.look(.close, active: true, pressed: true, dark: true)
        XCTAssertLessThan(pressed.fill.brightnessComponent, rest.fill.brightnessComponent)
        let inactive = TrafficLights.look(.minimize, active: false, pressed: false, dark: true)
        XCTAssertEqual(inactive.fill.saturationComponent, 0, accuracy: 0.01)
        XCTAssertEqual(TrafficLights.look(.close, active: false, pressed: false, dark: true).fill, inactive.fill)
    }

    func testMenuButtonIsGreyWithThreeDotsThatAlwaysShow() {
        for active in [true, false] {
            for dark in [true, false] {
                let look = TrafficLights.look(.menu, active: active, pressed: false, dark: dark)
                XCTAssertEqual(look.fill.saturationComponent, 0, accuracy: 0.01, "grey")
                XCTAssertGreaterThan(look.glyph.alphaComponent, 0, "the dots show even in the background")
            }
        }
        let rest = TrafficLights.look(.menu, active: true, pressed: false, dark: false)
        let pressed = TrafficLights.look(.menu, active: true, pressed: true, dark: false)
        XCTAssertLessThan(pressed.fill.brightnessComponent, rest.fill.brightnessComponent)
        XCTAssertTrue(TrafficLights.glyphIsFilled(.menu))
        let box = CGRect(x: 0, y: 0, width: 14, height: 14)
        let dots = TrafficLights.glyph(.menu, in: box)
        for x in [7 - 14 * 0.24, 7, 7 + 14 * 0.24] {
            XCTAssertTrue(dots.contains(CGPoint(x: x, y: 7)), "a dot at \(x)")
        }
        XCTAssertFalse(dots.contains(CGPoint(x: 7 - 14 * 0.12, y: 7)), "space between the dots")
    }

    func testMagnetIsAHorseshoeWithItsSignBetweenTheArms() {
        let box = CGRect(x: 0, y: 0, width: 16, height: 16)
        let body = TrafficLights.magnet(in: box)
        XCTAssertTrue(body.contains(CGPoint(x: 8, y: 1.5)), "the bend")
        XCTAssertTrue(body.contains(CGPoint(x: 1.5, y: 14)), "the left arm")
        XCTAssertTrue(body.contains(CGPoint(x: 14.5, y: 14)), "the right arm")
        XCTAssertFalse(body.contains(CGPoint(x: 8, y: 11)), "the gap")
        for pole in [Polarity.plus, .minus] {
            let sign = TrafficLights.glyph(.pole(pole), in: box).boundingBoxOfPath
            for corner in [CGPoint(x: sign.minX, y: sign.minY), CGPoint(x: sign.maxX, y: sign.maxY)] {
                XCTAssertFalse(body.contains(corner), "\(pole)'s sign stays off the magnet")
            }
        }
        XCTAssertTrue(TrafficLights.magnetTips(in: box).boundingBoxOfPath.minY > 8, "tips at the ends of the arms")
    }

    func testMagnetKeepsItsPoleColourWhenInactive() {
        let plus = TrafficLights.look(.pole(.plus), active: false, pressed: false, dark: true)
        let minus = TrafficLights.look(.pole(.minus), active: false, pressed: false, dark: true)
        XCTAssertEqual(plus.fill, Polarity.plus.tint)
        XCTAssertGreaterThan(plus.fill.redComponent, plus.fill.blueComponent)
        XCTAssertGreaterThan(minus.fill.blueComponent, minus.fill.redComponent)
    }

    /// The pole sits one place past the green button: the fourth slot, at the same pitch.
    func testThePoleIsPastTheGreenButton() {
        XCTAssertEqual(TrafficLights.Layout.standard.centre(3), CGPoint(x: 85, y: 16))
    }

    func testZoomIsMacOSGreenAndGreyWhenInactive() {
        let zoom = TrafficLights.look(.zoom, active: true, pressed: false, dark: true)
        XCTAssertGreaterThan(zoom.fill.greenComponent, zoom.fill.redComponent)
        XCTAssertGreaterThan(zoom.fill.greenComponent, zoom.fill.blueComponent)
        XCTAssertEqual(TrafficLights.look(.zoom, active: false, pressed: false, dark: true).fill,
                       TrafficLights.look(.close, active: false, pressed: false, dark: true).fill)
    }

    /// Two filled triangles, their square corners top left and bottom right, inside the circle.
    func testZoomGlyphIsTwoCornerTriangles() {
        let box = CGRect(x: 0, y: 0, width: 14, height: 14)
        let glyph = TrafficLights.glyph(.zoom, in: box)
        XCTAssertTrue(TrafficLights.glyphIsFilled(.zoom))
        XCTAssertFalse(TrafficLights.glyphIsFilled(.close))
        XCTAssertTrue(glyph.contains(CGPoint(x: 4.2, y: 9.8)), "top-left triangle")
        XCTAssertTrue(glyph.contains(CGPoint(x: 9.8, y: 4.2)), "bottom-right triangle")
        XCTAssertFalse(glyph.contains(CGPoint(x: 7, y: 7)), "the gap between them")
        XCTAssertFalse(glyph.contains(CGPoint(x: 9.8, y: 9.8)), "nothing in the other corners")
        let bounds = glyph.boundingBoxOfPath
        XCTAssertTrue(box.insetBy(dx: 2, dy: 2).contains(bounds))
    }
}
