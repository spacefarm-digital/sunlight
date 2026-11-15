import XCTest
import CoreGraphics
import IOSurface
@testable import Canvas

final class BackgroundPipelineTests: XCTestCase {
    /// The lightest blur keeps the half size it always had; the wider the blur, the smaller the level,
    /// with the same number of pixels to a sigma.
    func testAWiderBlurIsMadeOfFewerPixels() {
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 0), 1)
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 4), 0.5)
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 8), 0.5)
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 12), 4.0 / 12, accuracy: 0.0001)
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 28), 4.0 / 28, accuracy: 0.0001)
        XCTAssertEqual(BackgroundPipeline.scale(forSigma: 60), 4.0 / 60, accuracy: 0.0001)
        let scales = BackgroundPipeline.levelRadii.dropFirst().map { BackgroundPipeline.scale(forSigma: $0) }
        XCTAssertEqual(scales, scales.sorted(by: >), "never larger for a wider blur")
        for (sigma, scale) in zip(BackgroundPipeline.levelRadii.dropFirst(), scales) {
            XCTAssertLessThanOrEqual(scale, BackgroundPipeline.blurredScale)
            XCTAssertGreaterThanOrEqual(sigma * scale, 2, "at least the lightest level's two pixels to a sigma")
        }
    }

    /// A blurred level comes out at its scale of the picture, whatever the picture's size.
    func testABlurredLevelIsRenderedAtItsScale() throws {
        let pipeline = BackgroundPipeline()
        let picture = pipeline.picture(try image(width: 600, height: 400) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        })
        let light = try XCTUnwrap(pipeline.blurred(picture, sigma: 4))
        XCTAssertEqual(light.width, 300)
        XCTAssertEqual(light.height, 200)
        let wide = try XCTUnwrap(pipeline.blurred(picture, sigma: 60))
        XCTAssertEqual(wide.width, 40)
        XCTAssertEqual(wide.height, 27)
    }

    /// A picture goes to its layer as a surface, the one buffer the window server shows, with nothing
    /// kept beside it: the right way up, in the colours it had, and marked sRGB so a wide-gamut screen
    /// doesn't take its numbers for its own.
    func testAPictureIsHeldInASurfaceAsItWas() throws {
        let pipeline = BackgroundPipeline()
        let picture = pipeline.picture(try redOverBlue(width: 200, height: 100))
        let surface = try XCTUnwrap(picture.surface, "a surface could be made")
        XCTAssertNil(picture.image, "and no image is kept beside it")
        XCTAssertEqual(picture.width, 200)
        XCTAssertEqual(picture.height, 100)
        XCTAssertEqual(IOSurfaceGetWidth(surface), 200)
        XCTAssertEqual(IOSurfaceGetHeight(surface), 100)
        XCTAssertNotNil(picture.contents)
        XCTAssertNotNil(IOSurfaceCopyValue(surface, BackgroundPipeline.surfaceColorSpaceKey), "marked with its colour space")
        // A surface's first row is the top of what a layer shows.
        let top = try pixel(of: surface, x: 100, y: 10)
        XCTAssertEqual(top.red, 204, accuracy: 2)
        XCTAssertEqual(top.green, 51, accuracy: 2)
        XCTAssertEqual(top.blue, 26, accuracy: 2)
        XCTAssertEqual(top.alpha, 255)
        let bottom = try pixel(of: surface, x: 100, y: 90)
        XCTAssertEqual(bottom.red, 26, accuracy: 2)
        XCTAssertEqual(bottom.green, 128, accuracy: 2)
        XCTAssertEqual(bottom.blue, 230, accuracy: 2)
    }

    /// A blur level is made from the surface and lands in one of its own, still the right way up and
    /// still the picture's colours.
    func testABlurredLevelIsMadeFromTheSurface() throws {
        let pipeline = BackgroundPipeline()
        let picture = pipeline.picture(try redOverBlue(width: 400, height: 200))
        XCTAssertNotNil(picture.surface)
        let level = try XCTUnwrap(pipeline.blurred(picture, sigma: 4))
        let surface = try XCTUnwrap(level.surface)
        XCTAssertNil(level.image)
        XCTAssertEqual(IOSurfaceGetWidth(surface), 200)
        XCTAssertEqual(IOSurfaceGetHeight(surface), 100)
        XCTAssertNotNil(IOSurfaceCopyValue(surface, BackgroundPipeline.surfaceColorSpaceKey))
        // Far from the line between the halves the blur leaves each colour as it was, edges included.
        let top = try pixel(of: surface, x: 100, y: 0)
        XCTAssertEqual(top.red, 204, accuracy: 3)
        XCTAssertEqual(top.blue, 26, accuracy: 3)
        let bottom = try pixel(of: surface, x: 100, y: 99)
        XCTAssertEqual(bottom.red, 26, accuracy: 3)
        XCTAssertEqual(bottom.blue, 230, accuracy: 3)
        // And across the line it is a blur: neither half's colour.
        let middle = try pixel(of: surface, x: 100, y: 50)
        XCTAssertGreaterThan(middle.red, 40)
        XCTAssertLessThan(middle.red, 190)
    }

    /// With surfaces switched off the picture and its levels are plain images, as they were.
    func testThePictureIsAnImageWithSurfacesOff() throws {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "BackgroundSurfaces")
        defer { defaults.removeObject(forKey: "BackgroundSurfaces") }
        XCTAssertFalse(BackgroundPipeline.usesSurfaces)
        let pipeline = BackgroundPipeline()
        let image = try redOverBlue(width: 400, height: 200)
        let picture = pipeline.picture(image)
        XCTAssertNil(picture.surface)
        XCTAssertTrue(picture.image === image, "the image itself, not a copy")
        XCTAssertNotNil(picture.contents)
        let level = try XCTUnwrap(pipeline.blurred(picture, sigma: 12))
        XCTAssertNil(level.surface)
        XCTAssertEqual(level.image?.width, 133)
        XCTAssertEqual(level.image?.height, 67)
        XCTAssertEqual(level.width, 133)
        XCTAssertEqual(level.height, 67)
    }

    func testSurfacesAreOnUnlessSwitchedOff() {
        UserDefaults.standard.removeObject(forKey: "BackgroundSurfaces")
        XCTAssertTrue(BackgroundPipeline.usesSurfaces)
    }

    // MARK: Helpers

    /// An sRGB image drawn by `draw`, in a context whose origin is at the bottom left.
    private func image(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// The top half (204, 51, 26), the bottom half (26, 128, 230).
    private func redOverBlue(width: Int, height: Int) throws -> CGImage {
        try image(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 26 / 255, green: 128 / 255, blue: 230 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            context.setFillColor(CGColor(srgbRed: 204 / 255, green: 51 / 255, blue: 26 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        }
    }

    /// The pixel `y` rows down from a surface's first row, out of its BGRA bytes.
    private func pixel(of surface: IOSurfaceRef, x: Int, y: Int) throws -> (red: Int, green: Int, blue: Int, alpha: Int) {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let address: UnsafeMutableRawPointer? = IOSurfaceGetBaseAddress(surface)
        let base = try XCTUnwrap(address)
        let bytes = base.advanced(by: y * IOSurfaceGetBytesPerRow(surface) + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(bytes[2]), Int(bytes[1]), Int(bytes[0]), Int(bytes[3]))
    }
}
