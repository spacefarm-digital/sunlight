import XCTest
@testable import Canvas

/// Picture in Picture for any window: where a tile starts, which corner it lands in, when it tucks away,
/// how it resizes, how the window is drawn at its tile whatever the camera, where it returns to 1:1, and
/// what a tile saves as.
final class PictureInPictureTests: XCTestCase {
    private typealias PiP = PictureInPicture
    private typealias Ref = PictureInPicture.Reference

    /// A 2000×1200 display with a 38 pt menu bar, view coordinates.
    private let visible = CGRect(x: 0, y: 38, width: 2000, height: 1162)
    private let window = CGRect(x: 3000, y: 2000, width: 800, height: 600)

    // MARK: Where a tile starts

    func testANewTileIsAQuarterOfTheScreenWide() {
        let scale = PiP.defaultScale(size: window.size, visible: visible)
        XCTAssertEqual(scale * window.width, 500, accuracy: 1e-9)
    }

    func testTheScaleBoundsKeepATileReadableAndUnderHalfTheScreen() {
        let bounds = PiP.scaleBounds(size: window.size, visible: visible)
        XCTAssertEqual(bounds.lowerBound * window.width, Ref.minWidth, accuracy: 1e-9)
        XCTAssertEqual(bounds.upperBound * window.height, visible.height / 2, accuracy: 1e-9)   // the height binds first
        // A small window is never drawn bigger than itself, and its floor is its own width.
        let small = CGSize(width: 200, height: 100)
        let s = PiP.scaleBounds(size: small, visible: visible)
        XCTAssertEqual(s.upperBound, 1)
        XCTAssertEqual(s.lowerBound, 1)
        XCTAssertEqual(PiP.defaultScale(size: small, visible: visible), 1)
    }

    func testTheCornerFramesSitAMarginInFromTheEdges() {
        let scale: CGFloat = 0.25   // 200×150
        for corner in PiP.Corner.allCases {
            let r = PiP.rect(PiP.frame(in: corner, scale: scale, size: window.size, visible: visible), size: window.size)
            XCTAssertEqual(corner.isLeft ? r.minX : r.maxX, corner.isLeft ? visible.minX + Ref.margin : visible.maxX - Ref.margin, "\(corner)")
            XCTAssertEqual(corner.isTop ? r.minY : r.maxY, corner.isTop ? visible.minY + Ref.margin : visible.maxY - Ref.margin, "\(corner)")
            XCTAssertEqual(PiP.corner(of: PiP.frame(in: corner, scale: scale, size: window.size, visible: visible), size: window.size, visible: visible), corner)
        }
    }

    // MARK: Dropping a tile

    func testADroppedTileGoesToTheNearestCorner() {
        let f = PipFrame(origin: CGPoint(x: 1300, y: 200), scale: 0.25)   // centre (1400, 275): top-right
        XCTAssertEqual(PiP.corner(for: f, velocity: .zero, size: window.size, visible: visible), .topRight)
        XCTAssertEqual(PiP.corner(for: PipFrame(origin: CGPoint(x: 100, y: 900), scale: 0.25), velocity: .zero, size: window.size, visible: visible), .bottomLeft)
    }

    func testAFlingGoesToTheCornerItIsHeadingFor() {
        let f = PipFrame(origin: CGPoint(x: 900, y: 500), scale: 0.25)   // centre (1000, 575): the very middle
        XCTAssertEqual(PiP.corner(for: f, velocity: CGVector(dx: -2000, dy: -1500), size: window.size, visible: visible), .topLeft)
        XCTAssertEqual(PiP.corner(for: f, velocity: CGVector(dx: 2000, dy: 1500), size: window.size, visible: visible), .bottomRight)
        // A slow drift isn't a fling: the nearest corner as it stands.
        XCTAssertEqual(PiP.corner(for: PipFrame(origin: CGPoint(x: 1300, y: 200), scale: 0.25), velocity: CGVector(dx: -100, dy: 0), size: window.size, visible: visible), .topRight)
    }

    func testATileDraggedPastTheEdgeTucksAway() {
        // 200 wide; more than half past the left edge tucks, less doesn't.
        XCTAssertEqual(PiP.tuck(of: PipFrame(origin: CGPoint(x: -120, y: 300), scale: 0.25), velocity: .zero, size: window.size, visible: visible), .left)
        XCTAssertNil(PiP.tuck(of: PipFrame(origin: CGPoint(x: -80, y: 300), scale: 0.25), velocity: .zero, size: window.size, visible: visible))
        XCTAssertEqual(PiP.tuck(of: PipFrame(origin: CGPoint(x: 1920, y: 300), scale: 0.25), velocity: .zero, size: window.size, visible: visible), .right)
        // Flung at the edge from nearby, it tucks too.
        XCTAssertEqual(PiP.tuck(of: PipFrame(origin: CGPoint(x: 20, y: 300), scale: 0.25), velocity: CGVector(dx: -2000, dy: 0), size: window.size, visible: visible), .left)
    }

    func testATuckedTileLeavesItsTabOnScreenAndComesBackToACornerOnItsSide() {
        let f = PipFrame(origin: CGPoint(x: -150, y: 900), scale: 0.25)
        let tucked = PiP.tucked(f, behind: .left, size: window.size, visible: visible)
        let r = PiP.rect(tucked, size: window.size)
        XCTAssertEqual(r.maxX, visible.minX + Ref.tabWidth)
        XCTAssertEqual(r.minY, 900)
        XCTAssertEqual(tucked.scale, 0.25)
        let back = PiP.untucked(tucked, from: .left, size: window.size, visible: visible)
        XCTAssertEqual(PiP.corner(of: back, size: window.size, visible: visible), .bottomLeft)
        let right = PiP.tucked(PipFrame(origin: CGPoint(x: 1950, y: 100), scale: 0.25), behind: .right, size: window.size, visible: visible)
        XCTAssertEqual(PiP.rect(right, size: window.size).minX, visible.maxX - Ref.tabWidth)
        XCTAssertEqual(PiP.corner(of: PiP.untucked(right, from: .right, size: window.size, visible: visible), size: window.size, visible: visible), .topRight)
    }

    // MARK: Sizing a tile

    func testResizingKeepsTheAspectAndTheOppositeCorner() {
        let start = PipFrame(origin: CGPoint(x: 1000, y: 500), scale: 0.5)   // 400×300, bottom-right at (1400, 800)
        // The top-left corner pulled out and up: the bottom-right stays, the tile grows to the pointer's width.
        let grown = PiP.resized(start, edges: [.top, .left], to: CGPoint(x: 800, y: 600), size: window.size, visible: visible)
        let r = PiP.rect(grown, size: window.size)
        XCTAssertEqual(r.maxX, 1400, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 800, accuracy: 1e-9)
        XCTAssertEqual(r.width, 600, accuracy: 1e-9)
        XCTAssertEqual(r.height, 450, accuracy: 1e-9)
        // The right edge alone: the left stays, the height follows the width.
        let wider = PiP.resized(start, edges: .right, to: CGPoint(x: 1500, y: 700), size: window.size, visible: visible)
        let w = PiP.rect(wider, size: window.size)
        XCTAssertEqual(w.minX, 1000, accuracy: 1e-9)
        XCTAssertEqual(w.width, 500, accuracy: 1e-9)
        XCTAssertEqual(w.height, 375, accuracy: 1e-9)
        // Never past the bounds.
        XCTAssertEqual(PiP.resized(start, edges: .right, to: CGPoint(x: 5000, y: 700), size: window.size, visible: visible).scale,
                       PiP.scaleBounds(size: window.size, visible: visible).upperBound)
        XCTAssertEqual(PiP.resized(start, edges: .right, to: CGPoint(x: 1001, y: 700), size: window.size, visible: visible).scale,
                       PiP.scaleBounds(size: window.size, visible: visible).lowerBound)
    }

    func testScalingKeepsThePointUnderThePointerAndStaysInBounds() {
        let f = PipFrame(origin: CGPoint(x: 400, y: 300), scale: 0.5)   // 400×300 on screen
        let point = CGPoint(x: 600, y: 450)   // its centre
        let bigger = PiP.scaled(f, by: 1.5, around: point, size: window.size, visible: visible)
        XCTAssertEqual(bigger.scale, 0.75, accuracy: 1e-9)
        let r = PiP.rect(bigger, size: window.size)
        XCTAssertEqual(r.midX, 600, accuracy: 1e-6)
        XCTAssertEqual(r.midY, 450, accuracy: 1e-6)
        let bounds = PiP.scaleBounds(size: window.size, visible: visible)
        XCTAssertEqual(PiP.scaled(f, by: 0.01, around: point, size: window.size, visible: visible).scale, bounds.lowerBound)
        XCTAssertEqual(PiP.scaled(f, by: 100, around: point, size: window.size, visible: visible).scale, bounds.upperBound)
    }

    // MARK: Drawing the window at its tile

    func testTheEffectDrawsTheWindowAtItsTileWhateverTheCamera() {
        let f = PipFrame(origin: CGPoint(x: 1500, y: 800), scale: 0.3)
        let expected = PiP.rect(f, size: window.size)
        for camera in [Camera(origin: CGPoint(x: 2600, y: 1700), zoom: 0.25),
                       Camera(origin: CGPoint(x: -5000, y: 9000), zoom: 0.05),
                       Camera(origin: CGPoint(x: 3000, y: 2000), zoom: 1),
                       Camera(origin: CGPoint(x: 3100, y: 2100), zoom: 2.5)] {
            let effect = PiP.effect(f, worldRect: window, camera: camera)
            let drawn = effect.applied(toScreen: camera.toScreen(window))
            XCTAssertEqual(drawn.minX, expected.minX, accuracy: 1e-6, "zoom \(camera.zoom)")
            XCTAssertEqual(drawn.minY, expected.minY, accuracy: 1e-6, "zoom \(camera.zoom)")
            XCTAssertEqual(drawn.width, expected.width, accuracy: 1e-6, "zoom \(camera.zoom)")
            XCTAssertEqual(drawn.height, expected.height, accuracy: 1e-6, "zoom \(camera.zoom)")
            // And the same through the live window's transform: the tile's corners map to the window's.
            let record = LiveWindowsWire.Window(id: 7, worldRect: window, inset: 0, camera: camera, effect: effect)
            let topLeft = expected.origin.applying(record.transform)
            let bottomRight = CGPoint(x: expected.maxX, y: expected.maxY).applying(record.transform)
            XCTAssertEqual(topLeft.x, 0, accuracy: 1e-3)
            XCTAssertEqual(topLeft.y, 0, accuracy: 1e-3)
            XCTAssertEqual(bottomRight.x, 800, accuracy: 1e-3)
            XCTAssertEqual(bottomRight.y, 600, accuracy: 1e-3)
        }
    }

    func testAFramePartWayBetweenTwoAndPastTheEnd() {
        let a = PipFrame(origin: CGPoint(x: 0, y: 100), scale: 0.2), b = PipFrame(origin: CGPoint(x: 100, y: 300), scale: 1)
        XCTAssertEqual(PiP.mix(a, b, 0), a)
        XCTAssertEqual(PiP.mix(a, b, 1), b)
        let half = PiP.mix(a, b, 0.5)
        XCTAssertEqual(half.origin.x, 50, accuracy: 1e-9)
        XCTAssertEqual(half.origin.y, 200, accuracy: 1e-9)
        XCTAssertEqual(half.scale, 0.6, accuracy: 1e-9)
        XCTAssertEqual(PiP.mix(a, b, 1.1).origin.x, 110, accuracy: 1e-9)   // a spring's overshoot
    }

    // MARK: Returning to 1:1

    func testTheReturnGrowsAboutTheTileAndStaysOnScreen() {
        let f = PipFrame(origin: CGPoint(x: 1000, y: 500), scale: 0.25)   // 200×150, centred at (1100, 575)
        let r = PiP.returnRect(f, size: window.size, visible: visible, scale: 2)
        XCTAssertEqual(r.size, window.size)
        XCTAssertEqual(r.midX, 1100)
        XCTAssertEqual(r.midY, 575)
        // In a corner it's pushed inside the visible area, below the menu bar.
        let corner = PipFrame(origin: CGPoint(x: 1900, y: 40), scale: 0.1)
        let c = PiP.returnRect(corner, size: window.size, visible: visible, scale: 2)
        XCTAssertEqual(c.maxX, visible.maxX)
        XCTAssertEqual(c.minY, visible.minY)
        // Bigger than the screen: at its top-left.
        let huge = PiP.returnRect(f, size: CGSize(width: 3000, height: 2000), visible: visible, scale: 2)
        XCTAssertEqual(huge.origin, visible.origin)
        // On whole pixels.
        let odd = PiP.returnRect(PipFrame(origin: CGPoint(x: 1000.3, y: 500.7), scale: 0.25), size: window.size, visible: visible, scale: 2)
        XCTAssertEqual(odd.minX * 2, (odd.minX * 2).rounded())
        XCTAssertEqual(odd.minY * 2, (odd.minY * 2).rounded())
    }

    // MARK: The chrome

    func testTheChromeStripHoldsTheHomeButtonAtItsLeft() {
        let tile = CGRect(x: 100, y: 100, width: 400, height: 300)
        let c = PiP.Chrome(tile: tile, tucked: nil, visible: visible)
        XCTAssertEqual(c.strip, CGRect(x: 100, y: 100, width: 400, height: Ref.stripHeight))
        XCTAssertEqual(c.home.width, Ref.buttonSize)
        XCTAssertEqual(c.home.midY, c.strip.midY)
        XCTAssertLessThan(c.home.maxX, c.strip.midX)
        XCTAssertNil(c.tab)
        // Tucked behind the right edge: the tab is the sliver still on screen.
        let tucked = PiP.Chrome(tile: CGRect(x: visible.maxX - Ref.tabWidth, y: 100, width: 400, height: 300), tucked: .right, visible: visible)
        XCTAssertEqual(tucked.tab, CGRect(x: visible.maxX - Ref.tabWidth, y: 100, width: Ref.tabWidth, height: 300))
    }

    // MARK: Saved with the canvas

    func testALayoutEntryKeepsTheTile() throws {
        var entry = Layout.Entry(kind: .window, bundleID: "com.example", appName: "Example", title: "Doc", document: nil, widget: nil,
                                 windowID: 9, frame: Layout.Rect(x: 1, y: 2, width: 800, height: 600), polarity: nil, group: nil,
                                 pip: Layout.Pip(x: 1500, y: 800, scale: 0.3, tucked: 1))
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(Layout.Entry.self, from: data)
        XCTAssertEqual(back, entry)
        XCTAssertEqual(back.pip, Layout.Pip(x: 1500, y: 800, scale: 0.3, tucked: 1))
        // A layout from before there was Picture in Picture reads with none.
        entry.pip = nil
        let old = try JSONDecoder().decode(Layout.Entry.self, from: try JSONEncoder().encode(entry))
        XCTAssertNil(old.pip)
    }

    // MARK: The tuck's spring

    func testACriticallyDampedSpringSettlesWithoutOvershootOrNaN() {
        // The tuck runs on damping 1 (`Ref.tuckDamping`): finite from the first tick, never past its rest.
        let s = Spring(x0: -1, v0: 0, response: Ref.tuckResponse, damping: Ref.tuckDamping)
        var last: CGFloat = -1
        for i in 0...120 {
            let (x, v) = s.evaluate(at: CGFloat(i) / 120)
            XCTAssertTrue(x.isFinite && v.isFinite, "tick \(i)")
            XCTAssertLessThanOrEqual(x, 0.0001, "no overshoot at tick \(i)")
            XCTAssertGreaterThanOrEqual(x, last - 0.0001, "monotone at tick \(i)")
            last = x
        }
        XCTAssertEqual(s.evaluate(at: 1).x, 0, accuracy: 0.001)
        // Flung towards rest, it still comes to rest; over-damped values take the same path.
        let flung = Spring(x0: -1, v0: 3, response: Ref.tuckResponse, damping: 1.5)
        XCTAssertTrue(flung.evaluate(at: 0).x.isFinite)
        XCTAssertEqual(flung.evaluate(at: 1.5).x, 0, accuracy: 0.001)
    }

    // MARK: Rounded corners

    func testTheNativeCornerRadiusGivesTheReferenceRadiusOnScreen() {
        XCTAssertEqual(PiP.nativeCornerRadius(scale: 0.25), (Ref.cornerRadius / 0.25).rounded())
        XCTAssertEqual(PiP.nativeCornerRadius(scale: 0.5) * 0.5, Ref.cornerRadius, accuracy: 0.5)
        XCTAssertEqual(PiP.nativeCornerRadius(scale: 1), 0)   // its own corners at 1:1
        XCTAssertEqual(PiP.nativeCornerRadius(scale: 0), 0)
    }

    // MARK: The wire

    func testTheShapeRequestIsTheWindowAndItsRadius() {
        var expected = Data([9, 0, 0x77, 0x78, 0x56, 0x34, 0x12])
        var radius: Float = 48
        withUnsafeBytes(of: &radius) { expected.append(contentsOf: $0) }
        XCTAssertEqual(LiveWindowsWire.shape(0x12345678, radius: 48), expected)
        XCTAssertEqual(LiveWindowsWire.shape(1, radius: -3).suffix(4), Data([0, 0, 0, 0]))   // never negative
        XCTAssertTrue(LiveWindowsWire.shapesInDock("sunlight-52"))
        XCTAssertFalse(LiveWindowsWire.shapesInDock("sunlight-51"))
    }

    func testThePinRequestIsACountThenTheIDs() {
        XCTAssertEqual(LiveWindowsWire.pin([0x12345678, 9]),
                       Data([10, 0, 0x76, 2, 0x78, 0x56, 0x34, 0x12, 9, 0, 0, 0]))
        XCTAssertEqual(LiveWindowsWire.pin([]), Data([2, 0, 0x76, 0]))
        XCTAssertTrue(LiveWindowsWire.pinsInDock("sunlight-42"))
        XCTAssertTrue(LiveWindowsWire.pinsInDock("sunlight-44"))
        XCTAssertFalse(LiveWindowsWire.pinsInDock("sunlight-41"))
        XCTAssertEqual(LiveWindowsWire.pinnedLevel, 3)
    }
}
