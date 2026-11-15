import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import IOSurface
import ImageIO
import Metal
import UniformTypeIdentifiers

/// The picture work, off the main thread: decoding a file at the screen's size, applying a style, blurring,
/// measuring. Core Image on Metal, one context for the app. Every method here is synchronous and meant
/// to run on `queue`; `BackgroundRenderer` sequences them and drops results that arrive too late.
final class BackgroundPipeline: @unchecked Sendable {
    /// The blur levels, as Gaussian sigmas in display pixels. Level 0 is the picture itself; the picture
    /// shown is a cross-fade between the two levels around `BackgroundSpec.blurPosition`.
    nonisolated static let levelRadii: [CGFloat] = [0, 4, 12, 28, 60]
    /// Blurred levels are rendered at most this much smaller: a blur hides the missing pixels, and it
    /// quarters the memory and the time.
    nonisolated static let blurredScale: CGFloat = 0.5
    /// How many pixels of a blurred level one sigma of its blur covers, at least. The lightest level has
    /// two at `blurredScale` and shows nothing of it; the heavier ones are kept at twice that, which is
    /// all a blur that wide can hold, drawn back up to the screen's size by the layer.
    nonisolated static let pixelsPerSigma: CGFloat = 4

    /// The size a level blurred by `sigma` display pixels is rendered at, as a part of the picture's:
    /// `blurredScale` for the lightest, smaller the wider the blur. Each level is held twice while it
    /// shows (the picture made here, and Core Animation's copy for the window server), and at half size
    /// every one of them was 6 MB on a 3024 × 1964 screen, however little detail the blur left in it.
    nonisolated static func scale(forSigma sigma: CGFloat) -> CGFloat {
        guard sigma > 0 else { return 1 }
        return min(blurredScale, pixelsPerSigma / sigma)
    }

    /// A picture ready for a layer: its pixels in a surface the window server shows as it is.
    ///
    /// An image given to a layer is held twice for as long as it shows: the image itself, and the copy
    /// Core Animation makes in shared memory for the window server (measured: 22.7 MB each for a
    /// 3024 × 1964 picture, and the window server's own texture on top). A surface is one buffer that
    /// all three use. `image` stands in only where no surface could be made, or with surfaces switched
    /// off (`usesSurfaces`).
    struct Picture: @unchecked Sendable {
        let surface: IOSurfaceRef?
        let image: CGImage?
        let width: Int
        let height: Int

        /// What goes in a layer's `contents`.
        var contents: Any? {
            if let surface { return surface }
            return image
        }
    }

    /// Whether pictures go to the layers as surfaces. On unless
    /// `defaults write com.spacefarm.sunlight BackgroundSurfaces -bool NO` says otherwise: the way back
    /// to plain images, should a Mac ever show a surface wrongly. Read as each picture is made.
    nonisolated static var usesSurfaces: Bool {
        UserDefaults.standard.object(forKey: "BackgroundSurfaces") as? Bool ?? true
    }

    /// 'BGRA': 8 bits a channel, the layout the window server composites without converting.
    private nonisolated static let surfaceFormat: UInt32 = 0x4247_5241

    let queue = DispatchQueue(label: "com.spacefarm.canvas.background", qos: .userInitiated)
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: Decoding

    /// The picture at `url`, decoded no larger than it takes to cover `pixelSize` and cropped to that aspect,
    /// centred. `frame` picks an image in a multi-image file (a Dynamic Desktop); nil takes the first.
    /// Decoding happens at the thumbnail size, so a 48-megapixel photo never sits in memory whole.
    func decode(_ url: URL, frame: Int? = nil, pixelSize: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let index = min(max(0, frame ?? 0), count - 1)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &height)   // the thumbnail is transformed upright; cover the upright size
        }
        let scale = max(pixelSize.width / width, pixelSize.height / height)
        let largest = (max(width, height) * min(scale, 1)).rounded(.up)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(largest),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return render(cover(CIImage(cgImage: image), pixelSize), size: pixelSize)
    }

    /// Which image in a Dynamic Desktop file suits the appearance: the one its `apple_desktop` metadata
    /// names for light or dark, else the first and the last.
    func dynamicDesktopFrame(_ url: URL, dark: Bool) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var light: Int?
        var darkIndex: Int?
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                guard let name = CGImageMetadataTagCopyName(tag) as String?,
                      let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, prefix == "apple_desktop",
                      let value = CGImageMetadataTagCopyValue(tag) as? String,
                      let data = Data(base64Encoded: value),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                // "apr": {l, d}. "solar": {ap: {l, d}, si: [...]}. "h24": {ap: {l, d}, ti: [...]}.
                let ap = name == "apr" ? plist : plist["ap"] as? [String: Any]
                if let ap {
                    light = ap["l"] as? Int
                    darkIndex = ap["d"] as? Int
                }
            }
        }
        let index = dark ? (darkIndex ?? count - 1) : (light ?? 0)
        return min(max(0, index), count - 1)
    }

    // MARK: Treatment

    /// The picture in a style: Natural leaves it; Black & White, Duotone and Colour Wash as iOS has them.
    /// `darken` scales it down (the automatic dark variant of a single picture), 0 for none.
    func styled(_ image: CGImage, style: BackgroundSpec.Style, tint: NSColor, darken: Double) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let tintColor = CIColor(color: tint) ?? CIColor(red: 0.5, green: 0.5, blue: 0.5)
        switch style {
        case .natural:
            break
        case .blackAndWhite:
            let f = CIFilter.photoEffectMono()
            f.inputImage = ci
            ci = f.outputImage ?? ci
        case .duotone:
            // Shadows a deep shade of the tint, highlights a pale one; the picture's luminance between.
            let t = tint.usingColorSpace(.sRGB) ?? tint
            let shadow = NSColor(srgbRed: t.redComponent * 0.22, green: t.greenComponent * 0.22, blue: t.blueComponent * 0.22, alpha: 1)
            let highlight = NSColor(srgbRed: 1 - (1 - t.redComponent) * 0.3, green: 1 - (1 - t.greenComponent) * 0.3,
                                    blue: 1 - (1 - t.blueComponent) * 0.3, alpha: 1)
            let f = CIFilter.falseColor()
            f.inputImage = ci
            f.color0 = CIColor(color: shadow) ?? tintColor
            f.color1 = CIColor(color: highlight) ?? tintColor
            ci = f.outputImage ?? ci
        case .colorWash:
            let wash = CIFilter.colorMonochrome()
            wash.inputImage = ci
            wash.color = tintColor
            wash.intensity = 0.65
            ci = wash.outputImage ?? ci
            let soften = CIFilter.colorControls()
            soften.inputImage = ci
            soften.contrast = 0.9
            soften.saturation = 1
            soften.brightness = 0.02
            ci = soften.outputImage ?? ci
        }
        if darken > 0 {
            let k = CGFloat(1 - min(0.9, darken))
            let f = CIFilter.colorMatrix()
            f.inputImage = ci
            f.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            ci = f.outputImage ?? ci
        }
        if style == .natural && darken <= 0 { return image }
        return render(ci, size: CGSize(width: image.width, height: image.height))
    }

    /// `image` as a picture for a layer: copied into a surface, after which the image itself can go.
    func picture(_ image: CGImage) -> Picture {
        let size = CGSize(width: image.width, height: image.height)
        if BackgroundPipeline.usesSurfaces, let made = picture(CIImage(cgImage: image), size: size), made.surface != nil { return made }
        return Picture(surface: nil, image: image, width: image.width, height: image.height)
    }

    /// The picture blurred by `sigma` display pixels, rendered at `scale(forSigma:)` of its size. The edges
    /// are clamped first so the blur doesn't darken towards them.
    func blurred(_ picture: Picture, sigma: CGFloat) -> Picture? {
        guard let source = image(of: picture) else { return nil }
        let s = BackgroundPipeline.scale(forSigma: sigma)
        let size = CGSize(width: max(1, (CGFloat(picture.width) * s).rounded()), height: max(1, (CGFloat(picture.height) * s).rounded()))
        // Blurred at `blurredScale`, as it always was, and made smaller only then: scaled down first, a
        // sharp picture loses detail between the pixels it keeps, and the blur would spread that noise.
        let half = BackgroundPipeline.blurredScale
        var ci = source.transformed(by: CGAffineTransform(scaleX: half, y: half))
        ci = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma * half)
        if s < half { ci = ci.transformed(by: CGAffineTransform(scaleX: s / half, y: s / half)) }
        return self.picture(ci.cropped(to: CGRect(origin: .zero, size: size)), size: size)
    }

    /// The picture's mean colour and its relative luminance, 0–1.
    func average(_ image: CGImage) -> (color: NSColor, luminance: CGFloat) {
        let ci = CIImage(cgImage: image)
        let f = CIFilter.areaAverage()
        f.inputImage = ci
        f.extent = ci.extent
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let out = f.outputImage else { return (.gray, 0.5) }
        context.render(out, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: colorSpace)
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return (NSColor(srgbRed: r, green: g, blue: b, alpha: 1), luminance)
    }

    /// A tint drawn from the picture: its mean colour, pushed to a usable saturation and brightness.
    func dominantTint(_ image: CGImage) -> NSColor {
        let mean = average(image).color
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        (mean.usingColorSpace(.deviceRGB) ?? mean).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: max(s, 0.55), brightness: min(0.8, max(0.45, v)), alpha: 1)
    }

    /// Grey noise the size of the screen, for the grain layer (soft-light blended at a few percent).
    func grain(pixelSize: CGSize) -> Picture? {
        let s = BackgroundPipeline.blurredScale
        let size = CGSize(width: (pixelSize.width * s).rounded(), height: (pixelSize.height * s).rounded())
        guard let noise = CIFilter.randomGenerator().outputImage else { return nil }
        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise.cropped(to: CGRect(origin: .zero, size: size))
        let third = CIVector(x: 1 / 3, y: 1 / 3, z: 1 / 3, w: 0)
        grey.rVector = third
        grey.gVector = third
        grey.bVector = third
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let out = grey.outputImage else { return nil }
        return picture(out, size: size)
    }

    /// A small picture in every style, for the Style row of the settings.
    func thumbnails(_ image: CGImage, tint: NSColor, size: CGSize) -> [BackgroundSpec.Style: CGImage] {
        let small = render(cover(CIImage(cgImage: image), size), size: size) ?? image
        var out: [BackgroundSpec.Style: CGImage] = [:]
        for style in BackgroundSpec.Style.allCases {
            out[style] = styled(small, style: style, tint: tint, darken: 0)
        }
        return out
    }

    // MARK: Helpers

    /// `image` scaled and cropped to fill `size`, centred, with its origin at zero.
    private func cover(_ image: CIImage, _ size: CGSize) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let scale = max(size.width / e.width, size.height / e.height)
        var out = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let f = out.extent
        let crop = CGRect(x: (f.minX + (f.width - size.width) / 2).rounded(), y: (f.minY + (f.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        out = out.cropped(to: crop)
        return out.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// `image` rendered for a layer: straight into a surface, or as an image where that can't be had.
    private func picture(_ image: CIImage, size: CGSize) -> Picture? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }
        if BackgroundPipeline.usesSurfaces, let surface = makeSurface(width: width, height: height) {
            context.render(image, to: surface, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
            return Picture(surface: surface, image: nil, width: width, height: height)
        }
        guard let made = render(image, size: size) else { return nil }
        return Picture(surface: nil, image: made, width: made.width, height: made.height)
    }

    /// A picture as Core Image reads it, whichever way it is held.
    private func image(of picture: Picture) -> CIImage? {
        if let surface = picture.surface { return CIImage(ioSurface: surface, options: [.colorSpace: colorSpace]) }
        return picture.image.map { CIImage(cgImage: $0) }
    }

    /// A surface of that many pixels, marked sRGB as the images are: unmarked, the window server takes a
    /// surface's numbers for the display's own colours, and a picture comes out too vivid on a wide-gamut screen.
    private func makeSurface(width: Int, height: Int) -> IOSurfaceRef? {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: BackgroundPipeline.surfaceFormat,
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary) else { return nil }
        guard let space = colorSpace.copyPropertyList() else { return nil }
        IOSurfaceSetValue(surface, BackgroundPipeline.surfaceColorSpaceKey, space)
        return surface
    }

    /// The key a surface's colour space goes under (`kIOSurfaceColorSpace`).
    nonisolated static let surfaceColorSpaceKey = "IOSurfaceColorSpace" as CFString

    private func render(_ image: CIImage, size: CGSize) -> CGImage? {
        let rect = CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded()))
        return context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace)
    }
}
