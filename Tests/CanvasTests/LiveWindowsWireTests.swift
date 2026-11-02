import XCTest
import CoreGraphics
@testable import Canvas

final class LiveWindowsWireTests: XCTestCase {
    func testStockMessagePackingMatchesSaM() {
        // int16 length excludes itself; no padding between opcode and the three native 32-bit fields.
        XCTAssertEqual(LiveWindowsWire.move(0x12345678, x: -25, y: 300),
                       Data([13, 0, 6, 0x78, 0x56, 0x34, 0x12, 0xe7, 0xff, 0xff, 0xff, 0x2c, 1, 0, 0]))
        XCTAssertEqual(LiveWindowsWire.order(9, relativeTo: 11, order: -1),
                       Data([13, 0, 0x10, 9, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 11, 0, 0, 0]))
        XCTAssertEqual(LiveWindowsWire.message(1), Data([1, 0, 1]))
    }

    func testInverseWindowServerTransformMapsTargetBackToNativeSurface() {
        let rect = CGRect(x: -600, y: 150, width: 900, height: 600)
        for zoom: CGFloat in [0.04, 0.5, 1, 1.5] {
            let camera = Camera(origin: CGPoint(x: -800, y: -100), zoom: zoom)
            let record = LiveWindowsWire.Window(id: 42, worldRect: rect, inset: 0, camera: camera)
            let target = camera.toScreen(rect)
            let origin = target.origin.applying(record.transform)
            let corner = CGPoint(x: target.maxX, y: target.maxY).applying(record.transform)
            XCTAssertEqual(origin.x, 0, accuracy: 0.001)
            XCTAssertEqual(origin.y, 0, accuracy: 0.001)
            XCTAssertEqual(corner.x, 900, accuracy: 0.001)
            XCTAssertEqual(corner.y, 600, accuracy: 0.001)
        }
    }

    func testWidgetMarginUsesFullNativeSurface() {
        let camera = Camera(origin: CGPoint(x: 50, y: 30), zoom: 0.5)
        let record = LiveWindowsWire.Window(id: 8, worldRect: CGRect(x: 120, y: 90, width: 200, height: 100), inset: 10, camera: camera)
        let cardTopLeft = camera.toScreen(CGPoint(x: 120, y: 90)).applying(record.transform)
        XCTAssertEqual(cardTopLeft.x, 10, accuracy: 0.001)
        XCTAssertEqual(cardTopLeft.y, 10, accuracy: 0.001)
    }

    func testEffectScaleShrinksAboutTheTargetCentre() {
        let rect = CGRect(x: -600, y: 150, width: 900, height: 600)
        let camera = Camera(origin: CGPoint(x: -800, y: -100), zoom: 0.5)
        var bloom = WindowEffect.Frame()
        bloom.scale = CGSize(width: 0.9, height: 0.9)
        let popped = LiveWindowsWire.Window(id: 42, worldRect: rect, inset: 0, camera: camera, effect: bloom)
        let target = camera.toScreen(rect)
        // The centre of the on-screen rect is still the centre of the native surface.
        let centre = CGPoint(x: target.midX, y: target.midY).applying(popped.transform)
        XCTAssertEqual(centre.x, 450, accuracy: 0.001)
        XCTAssertEqual(centre.y, 300, accuracy: 0.001)
        // Drawn at 90 %: its top-left is 5 % of the target in from the target's.
        let corner = CGPoint(x: target.minX + target.width * 0.05, y: target.minY + target.height * 0.05).applying(popped.transform)
        XCTAssertEqual(corner.x, 0, accuracy: 0.001)
        XCTAssertEqual(corner.y, 0, accuracy: 0.001)
        XCTAssertEqual(popped.transform.a, 1 / (0.5 * 0.9), accuracy: 1e-9)
        XCTAssertEqual(LiveWindowsWire.Window(id: 42, worldRect: rect, inset: 0, camera: camera, effect: .identity),
                       LiveWindowsWire.Window(id: 42, worldRect: rect, inset: 0, camera: camera))
        // Never so small that the inverse passes the addition's limit of 100.
        var gone = WindowEffect.Frame()
        gone.scale = .zero
        let tiny = LiveWindowsWire.Window(id: 42, worldRect: rect, inset: 0, camera: camera, effect: gone)
        XCTAssertLessThanOrEqual(tiny.transform.a, 100)
        XCTAssertLessThanOrEqual(tiny.transform.d, 100)
    }

    func testEffectUnfoldsFromTheTopAndMovesInScreenPoints() {
        let rect = CGRect(x: 100, y: 100, width: 800, height: 400)
        let camera = Camera(origin: .zero, zoom: 0.5)
        var unfold = WindowEffect.Frame()
        unfold.anchor = CGPoint(x: 0.5, y: 0)
        unfold.scale = CGSize(width: 1, height: 0.5)
        unfold.offset = CGVector(dx: 0, dy: 10)
        let w = LiveWindowsWire.Window(id: 7, worldRect: rect, inset: 0, camera: camera, effect: unfold)
        let target = camera.toScreen(rect)
        // The top edge stays where it was, 10 screen points down; the window is half as tall.
        let topLeft = CGPoint(x: target.minX, y: target.minY + 10).applying(w.transform)
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
        let bottom = CGPoint(x: target.minX, y: target.minY + 10 + target.height * 0.5).applying(w.transform)
        XCTAssertEqual(bottom.y, 400, accuracy: 0.001)
        XCTAssertEqual(w.transform.a, 2, accuracy: 1e-9)
        XCTAssertEqual(w.transform.d, 4, accuracy: 1e-9)
    }

    func testAnchorPacking() {
        let data = LiveWindowsWire.anchor(7, x: 1.5, y: -2)
        // Length (int16), opcode, id, then the origin as two floats.
        XCTAssertEqual(data.count, 2 + 1 + 4 + 8)
        XCTAssertEqual(data[2], LiveWindowsWire.anchor)
        XCTAssertEqual(data.subdata(in: 3..<7).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 7)
        XCTAssertEqual(data.subdata(in: 7..<11).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, 1.5)
        XCTAssertEqual(data.subdata(in: 11..<15).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, -2)
    }

    func testAlphaPacking() {
        let data = LiveWindowsWire.alpha([(5, 0.5), (9, 2)])
        // Length (int16), opcode, count, then id + float per window, values clamped to 0...1.
        XCTAssertEqual(data.count, 2 + 1 + 1 + 16)
        XCTAssertEqual(data[2], LiveWindowsWire.alpha)
        XCTAssertEqual(data[3], 2)
        let second = data.subdata(in: 16..<20).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(second, 1)
        XCTAssertTrue(LiveWindowsWire.alphaInDock("sunlight-40"))
        XCTAssertFalse(LiveWindowsWire.alphaInDock("sunlight-28"))
    }

    func testExtensionPackingAndLimits() throws {
        let record = LiveWindowsWire.Window(id: 9, worldRect: CGRect(x: 100, y: 200, width: 300, height: 400), inset: 0, camera: Camera())
        let bytes = try LiveWindowsWire.snapshot([record], backdrop: 2, overlay: 3)
        XCTAssertEqual(bytes.count, 41)
        XCTAssertEqual(Array(bytes.prefix(17)), [39, 0, 0x72, 2, 0, 0, 0, 3, 0, 0, 0, 1, 0, 9, 0, 0, 0])
        // Six IEEE-754 float32s: 1,0,0,1,-100,-200.
        XCTAssertEqual(Array(bytes.suffix(24)), [0,0,128,63, 0,0,0,0, 0,0,0,0, 0,0,128,63, 0,0,200,194, 0,0,72,195])
        XCTAssertThrowsError(try LiveWindowsWire.snapshot([record, record], backdrop: 2, overlay: 3))
        XCTAssertThrowsError(try LiveWindowsWire.snapshot([record], backdrop: 9, overlay: 3))
        let records = (10..<139).map { LiveWindowsWire.Window(id: UInt32($0), worldRect: .zero, inset: 0, camera: Camera()) }
        XCTAssertThrowsError(try LiveWindowsWire.snapshot(records, backdrop: 2, overlay: 3))
        XCTAssertLessThan(try LiveWindowsWire.snapshot(Array(records.prefix(128)), backdrop: 2, overlay: 3).count, 4096)
    }

    func testFlaggedFramesCarryOneByteAfterTheCount() throws {
        let record = LiveWindowsWire.Window(id: 9, worldRect: CGRect(x: 100, y: 200, width: 300, height: 400), inset: 0, camera: Camera())
        let full = try LiveWindowsWire.snapshot([record], backdrop: 2, overlay: 3, kind: .full)
        XCTAssertEqual(full.count, 42)
        XCTAssertEqual(Array(full.prefix(18)), [40, 0, 0x72, 2, 0, 0, 0, 3, 0, 0, 0, 1, 0, 1, 9, 0, 0, 0])
        let partial = try LiveWindowsWire.snapshot([record], backdrop: 2, overlay: 3, kind: .partial)
        XCTAssertEqual(partial[13], 0)
        XCTAssertEqual(partial.suffix(28), full.suffix(28))
        // A keepalive: no windows, not full.
        XCTAssertEqual(Array(try LiveWindowsWire.snapshot([], backdrop: 2, overlay: 3, kind: .partial)), [12, 0, 0x72, 2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0])
        // An empty full frame naming the app in front (sunlight-11): the pid after the flags byte, 15 bytes of payload.
        XCTAssertEqual(Array(try LiveWindowsWire.snapshot([], backdrop: 2, overlay: 3, kind: .full, above: 0x0102)),
                       [16, 0, 0x72, 2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 1, 2, 1, 0, 0])
        // Never on a frame with windows, nor on a legacy frame, nor with no app named.
        XCTAssertEqual(try LiveWindowsWire.snapshot([], backdrop: 2, overlay: 3, kind: .full, above: 0).count, 14)
        XCTAssertEqual(try LiveWindowsWire.snapshot([], backdrop: 2, overlay: 3, kind: .legacy, above: 7).count, 13)
        XCTAssertTrue(LiveWindowsWire.liftsCanvasInDock(LiveWindowsWire.additionVersion))
        XCTAssertFalse(LiveWindowsWire.liftsCanvasInDock("sunlight-10"))
        XCTAssertTrue(LiveWindowsWire.partialFramesInDock("sunlight-8"))
        XCTAssertTrue(LiveWindowsWire.partialFramesInDock("sunlight-12"))
        XCTAssertFalse(LiveWindowsWire.partialFramesInDock("sunlight-7"))
        XCTAssertFalse(LiveWindowsWire.partialFramesInDock(nil))
    }

    func testParkingHasTwoMargins() {
        let view = CGSize(width: 1000, height: 600)
        let inView = CGRect(x: 100, y: 100, width: 200, height: 100)
        let nearby = CGRect(x: 1400, y: 100, width: 200, height: 100)      // 0.4 screens out
        let farOff = CGRect(x: 2100, y: 100, width: 200, height: 100)      // 1.1 screens out
        let between = CGRect(x: 1700, y: 100, width: 200, height: 100)     // 0.7 screens out
        XCTAssertFalse(CanvasController.parks(wasParked: false, rect: inView, target: nil, view: view))
        XCTAssertFalse(CanvasController.parks(wasParked: false, rect: nearby, target: nil, view: view))
        XCTAssertTrue(CanvasController.parks(wasParked: false, rect: farOff, target: nil, view: view))
        // Past the park margin but not yet within the wake margin: as it was.
        XCTAssertFalse(CanvasController.parks(wasParked: false, rect: between, target: nil, view: view))
        XCTAssertTrue(CanvasController.parks(wasParked: true, rect: between, target: nil, view: view))
        XCTAssertFalse(CanvasController.parks(wasParked: true, rect: nearby, target: nil, view: view))
        // A flight that ends near it wakes it now.
        XCTAssertFalse(CanvasController.parks(wasParked: true, rect: farOff, target: inView, view: view))
    }

    func testMissingSocketIsUnavailable() {
        XCTAssertFalse(LiveWindowsConnection.probe(path: "/tmp/sunbeam-absent-\(UUID().uuidString).socket"))
    }

    func testInvalidCameraIsRejectedBeforeSending() {
        let record = LiveWindowsWire.Window(id: 9, worldRect: .zero, inset: 0, camera: Camera(zoom: 0))
        XCTAssertThrowsError(try LiveWindowsWire.snapshot([record], backdrop: 2, overlay: 3))
    }

    func testHandoffPacking() {
        // Window, x, y as float32: 13 bytes after the length.
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: CGPoint(x: 1, y: -2)),
                       Data([13, 0, 0x73, 2, 0, 0, 0, 0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0]))
        // With the canvas's overlay and backdrop: 21, for an add-on that raises and tucks itself.
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: CGPoint(x: 1, y: -2), overlay: 7, backdrop: 5),
                       Data([21, 0, 0x73, 2, 0, 0, 0, 0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0, 7, 0, 0, 0, 5, 0, 0, 0]))
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: .zero, overlay: 0, backdrop: 0), LiveWindowsWire.handoff(2, at: .zero))
        // With windows kept on show (sunlight-10): a count, then window, x, y for each.
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: CGPoint(x: 1, y: -2), overlay: 7, backdrop: 5, keeping: [(3, CGPoint(x: 4, y: 8))]),
                       Data([34, 0, 0x73, 2, 0, 0, 0, 0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0, 7, 0, 0, 0, 5, 0, 0, 0,
                             1, 3, 0, 0, 0, 0, 0, 0x80, 0x40, 0, 0, 0, 0x41]))
        // Nothing kept is the 21-byte handoff, and without the canvas's IDs nothing can be kept.
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: .zero, overlay: 7, backdrop: 5, keeping: []),
                       LiveWindowsWire.handoff(2, at: .zero, overlay: 7, backdrop: 5))
        XCTAssertEqual(LiveWindowsWire.handoff(2, at: .zero, keeping: [(3, .zero)]), LiveWindowsWire.handoff(2, at: .zero))
        // At most `maxKept`, the top ones.
        let many = (0..<(LiveWindowsWire.maxKept + 3)).map { (CGWindowID(100 + $0), CGPoint.zero) }
        let packed = LiveWindowsWire.handoff(2, at: .zero, overlay: 7, backdrop: 5, keeping: many)
        XCTAssertEqual(packed.count, 2 + 22 + LiveWindowsWire.maxKept * 12)
        XCTAssertEqual(packed[23], UInt8(LiveWindowsWire.maxKept))
        XCTAssertEqual(packed[24], 103)   // the first three, the bottom ones, left out
    }

    func testAddOnVersionDecidesWhoRaises() {
        XCTAssertTrue(LiveWindowsWire.handoffInDock("sunlight-3"))
        XCTAssertTrue(LiveWindowsWire.handoffInDock("sunlight-4"))
        XCTAssertTrue(LiveWindowsWire.handoffInDock("sunlight-12"))
        XCTAssertTrue(LiveWindowsWire.handoffInDock(LiveWindowsWire.additionVersion))
        XCTAssertFalse(LiveWindowsWire.handoffInDock("sunlight-2"))
        XCTAssertFalse(LiveWindowsWire.handoffInDock("yabai-v7.1.4"))
        XCTAssertFalse(LiveWindowsWire.handoffInDock(nil))
    }

    func testShadowRequestPacking() {
        let inactive = LiveWindowsWire.ShadowLook(radius: 8, density: 0.22, rimDensity: 0.55, offset: 7)
        let active = LiveWindowsWire.ShadowLook(radius: 20, density: 0.4, rimDensity: 0.6, offset: 18)
        let bytes = LiveWindowsWire.shadow(9, inactiveWeight: 0.5, activeWeight: 1, inactive: inactive, active: active)
        XCTAssertEqual(bytes.count, 47)
        // Window, then the two weights as float32s (0.5 is 0x3f000000, 1 is 0x3f800000).
        XCTAssertEqual(Array(bytes.prefix(15)), [45, 0, 0x74, 9, 0, 0, 0, 0, 0, 0, 0x3f, 0, 0, 0x80, 0x3f])
        // The inactive look: 8, 0.22, 0.55, 7.
        XCTAssertEqual(Array(bytes[15..<31]), [0, 0, 0, 0x41, 0xae, 0x47, 0x61, 0x3e, 0xcd, 0xcc, 0xc, 0x3f, 0, 0, 0xe0, 0x40])
        // The active look: 20, 0.4, 0.6, 18.
        XCTAssertEqual(Array(bytes[31..<47]), [0, 0, 0xa0, 0x41, 0xcd, 0xcc, 0xcc, 0x3e, 0x9a, 0x99, 0x19, 0x3f, 0, 0, 0x90, 0x41])
        // The standard looks are the default.
        XCTAssertEqual(LiveWindowsWire.shadow(9, inactiveWeight: 0.5, activeWeight: 1), bytes)
        XCTAssertTrue(LiveWindowsWire.shadowInDock("sunlight-7"))
        XCTAssertTrue(LiveWindowsWire.shadowInDock(LiveWindowsWire.additionVersion))
        XCTAssertFalse(LiveWindowsWire.shadowInDock("sunlight-6"))
        XCTAssertFalse(LiveWindowsWire.shadowInDock(nil))
    }

    func testAddOnVersionDecidesWhetherAHandoffNeedsALease() {
        XCTAssertEqual(LiveWindowsWire.additionNumber("sunlight-5"), 5)
        XCTAssertEqual(LiveWindowsWire.additionNumber("sunlight-12"), 12)
        XCTAssertEqual(LiveWindowsWire.additionNumber("yabai-v7.1.4"), 0)
        XCTAssertEqual(LiveWindowsWire.additionNumber("sunlight-"), 0)
        XCTAssertEqual(LiveWindowsWire.additionNumber(nil), 0)
        XCTAssertTrue(LiveWindowsWire.handoffTakesAnyWindow("sunlight-5"))
        XCTAssertTrue(LiveWindowsWire.handoffTakesAnyWindow(LiveWindowsWire.additionVersion))
        XCTAssertFalse(LiveWindowsWire.handoffTakesAnyWindow("sunlight-4"))
        XCTAssertFalse(LiveWindowsWire.handoffTakesAnyWindow(nil))
    }
}
