import AppKit
import QuartzCore

/// Draws the background: a small layer tree that goes under the windows in whichever host is live — the
/// canvas view in capture mode, the opaque backdrop window under the real windows in live mode (see
/// `mount`). It knows the camera only to pick a blur level and a dim, and to drift the picture when
/// depth is on; nothing here runs a filter per frame. The pictures come from `BackgroundPipeline`, off
/// the main thread; results from a request that's been superseded are dropped (`generation`).
@MainActor
final class BackgroundRenderer {
    /// Everything, sized to the host. Insert it below the host's content.
    let container = CALayer()
    private let colorLayer = CALayer()
    /// The picture: level 0 sharp at the bottom, the blurred levels stacked above it, each shown by opacity.
    private let pictureLayer = CALayer()
    private var levelLayers: [CALayer] = []
    private var living: LivingGradientLayer?
    private let dimLayer = CALayer()
    private let grainLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()

    let pipeline = BackgroundPipeline()
    private(set) var spec = BackgroundSpec.default
    private(set) var isDark = false
    private var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var scale: CGFloat = 2
    private var pixelSize: CGSize { CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded()) }
    private var camera = Camera()

    /// What the picture layers currently show, so a change of blur or dim alone doesn't redecode.
    private struct Prepared: Equatable {
        var source: BackgroundSpec.Source
        var style: BackgroundSpec.Style
        var tint: BackgroundSpec.Tint?
        var dark: Bool
        var pixelSize: CGSize
        var wallpaper: URL?
        var wallpaperDate: Date?
    }
    private var prepared: Prepared?
    private var generation = 0
    /// The styled picture and the blur levels made from it so far, by level.
    private var levels: [Int: CGImage] = [:]
    private var levelsInFlight: Set<Int> = []
    private var grainImage: CGImage?

    /// Whether black ink reads better than white on what's behind the windows now.
    private(set) var isLight = false
    /// The ink flipped, or a picture replaced a colour (labels want a shadow on a picture).
    var onLookChanged: (() -> Void)?
    /// The picture's own tint, for Duotone and Colour Wash when none is chosen.
    private(set) var dominantTint: NSColor?
    /// Small pictures in every style for the settings; nil for a colour.
    private(set) var styleThumbnails: [BackgroundSpec.Style: CGImage]?
    var onThumbnailsChanged: (() -> Void)?

    static let thumbnailSize = CGSize(width: 192, height: 120)
    nonisolated static let fadeDuration: CFTimeInterval = 0.4

    init() {
        container.anchorPoint = .zero
        container.position = .zero
        container.masksToBounds = true
        container.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        for l in [colorLayer, pictureLayer, dimLayer, grainLayer] {
            l.anchorPoint = .zero
            l.position = .zero
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull(),
                         "transform": NSNull(), "backgroundColor": NSNull()]
        }
        vignetteLayer.anchorPoint = .zero
        vignetteLayer.position = .zero
        vignetteLayer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        for _ in BackgroundPipeline.levelRadii {
            let l = CALayer()
            l.anchorPoint = .zero
            l.position = .zero
            l.contentsGravity = .resizeAspectFill
            l.minificationFilter = .linear
            l.magnificationFilter = .linear
            l.opacity = 0
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "opacity": NSNull()]
            levelLayers.append(l)
            pictureLayer.addSublayer(l)
        }
        pictureLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        grainLayer.contentsGravity = .resize
        grainLayer.compositingFilter = "softLightBlendMode"
        grainLayer.opacity = 0
        vignetteLayer.type = .radial
        vignetteLayer.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor(white: 0, alpha: 0.18).cgColor]
        vignetteLayer.locations = [0, 0.55, 1]
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1.1, y: 1.1)
        vignetteLayer.opacity = 0
        container.addSublayer(colorLayer)
        container.addSublayer(pictureLayer)
        container.addSublayer(dimLayer)
        container.addSublayer(grainLayer)
        container.addSublayer(vignetteLayer)

        // A living gradient rests while the canvas isn't in front or the Mac is saving power; the Mac's
        // wallpaper is checked again each time Canvas comes back, since nothing announces a change of it.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inFront = true
                self?.refreshMacWallpaperIfNeeded()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inFront = false }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivity() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tune(animated: true) }
        })
    }

    private var observers: [NSObjectProtocol] = []
    private var inFront = true { didSet { updateActivity() } }

    private func updateActivity() {
        isActive = inFront && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: Hosting

    /// Puts the background at the bottom of `host`, sized to `bounds`. `occlusionSafe` keeps it a touch
    /// short of opaque, as the canvas colour is: the canvas window is non-opaque so the window server
    /// never reports the real windows behind it as occluded, and an opaque picture would be the one
    /// thing in it that isn't (see `CanvasView.applyBackground`). The backdrop window under live windows
    /// is opaque on purpose, so there it's full strength.
    func mount(in host: CALayer, bounds: CGRect, scale: CGFloat, occlusionSafe: Bool) {
        container.removeFromSuperlayer()
        container.opacity = occlusionSafe ? 0.985 : 1
        host.insertSublayer(container, at: 0)
        resize(bounds: bounds, scale: scale)
        living?.isPaused = !isActive
    }

    func unmount() {
        container.removeFromSuperlayer()
        living?.isPaused = true
    }

    /// The host's size or display scale changed: everything is laid out again, and the pictures are made
    /// again if the pixel size moved.
    func resize(bounds newBounds: CGRect, scale newScale: CGFloat) {
        guard newBounds.width > 0, newBounds.height > 0 else { return }
        let changed = newBounds.size != bounds.size || newScale != scale
        bounds = CGRect(origin: .zero, size: newBounds.size)
        scale = newScale
        layoutLayers()
        if changed {
            grainImage = nil
            prepare(force: true)
        }
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = bounds
        colorLayer.frame = bounds
        dimLayer.frame = bounds
        grainLayer.frame = bounds
        vignetteLayer.frame = bounds
        // With depth on the picture is a fifth larger than the screen, so its edges never show as it drifts.
        let overscan: CGFloat = spec.depth && !spec.isPlainColor ? 0.1 : 0
        let frame = bounds.insetBy(dx: -bounds.width * overscan, dy: -bounds.height * overscan)
        pictureLayer.bounds = CGRect(origin: .zero, size: frame.size)
        pictureLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        for l in levelLayers {
            l.frame = pictureLayer.bounds
            l.contentsScale = scale
        }
        living?.frame = pictureLayer.bounds
        living?.contentsScale = scale
        grainLayer.contentsScale = scale
        applyDepth()
        CATransaction.commit()
    }

    // MARK: Applying a spec

    /// Shows `spec` for the appearance. A change of picture decodes anew (the old one stays up until the
    /// new is ready, then cross-fades); a change of blur, dim or the rest just re-tunes the layers,
    /// animated like the appearance flip when `animated`.
    func apply(_ newSpec: BackgroundSpec, dark: Bool, animated: Bool) {
        let depthChanged = newSpec.depth != spec.depth
        spec = newSpec
        isDark = dark
        if depthChanged { layoutLayers() }
        prepare(force: false)
        tune(animated: animated)
    }

    /// The camera moved: the blur level, the dim and the drift follow, with no animation.
    func cameraChanged(_ camera: Camera) {
        self.camera = camera
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFocus()
        applyDepth()
        CATransaction.commit()
    }

    /// Pauses a living gradient while the canvas isn't in front, or the Mac is saving power.
    var isActive = true {
        didSet { living?.isPaused = !isActive || !spec.living }
    }

    /// The Mac's wallpaper may have changed while Canvas was away: compare, and remake if so.
    func refreshMacWallpaperIfNeeded() {
        guard spec.source == .macWallpaper, let prepared else { return }
        let (url, date) = BackgroundSources.macWallpaper()
        if url != prepared.wallpaper || date != prepared.wallpaperDate { prepare(force: true) }
    }

    // MARK: Preparing pictures

    private func prepare(force: Bool) {
        let wallpaper: (URL?, Date?) = spec.source == .macWallpaper ? BackgroundSources.macWallpaper() : (nil, nil)
        let want = Prepared(source: spec.source, style: spec.style, tint: spec.tint, dark: isDark, pixelSize: pixelSize,
                            wallpaper: wallpaper.0, wallpaperDate: wallpaper.1)
        guard force || want != prepared else { return }
        prepared = want
        generation += 1
        let gen = generation
        levelsInFlight = []

        if spec.isPlainColor || pixelSize.width < 2 {
            levels = [:]
            dominantTint = nil
            styleThumbnails = nil
            showColorOnly(animated: true)
            onThumbnailsChanged?()
            return
        }

        let size = pixelSize
        let dark = isDark
        let style = spec.style
        let chosenTint = spec.tint?.nsColor
        let source = spec.source
        let pipeline = self.pipeline
        pipeline.queue.async {
            var raw: CGImage?
            var darkenAlone = 0.0
            switch source {
            case .color:
                break
            case .macWallpaper:
                if let url = wallpaper.0 {
                    let frame = pipeline.dynamicDesktopFrame(url, dark: dark)
                    raw = pipeline.decode(url, frame: frame, pixelSize: size)
                    // A single picture serves both appearances; it's dimmed a little for the dark one.
                    if frame == nil, dark { darkenAlone = 0.25 }
                }
            case .image(let light, let darkName):
                let name = dark ? (darkName ?? light) : light
                raw = pipeline.decode(BackgroundSources.imageURL(name), pixelSize: size)
                if dark, darkName == nil { darkenAlone = 0.25 }
            case .gradient(let id):
                raw = Gradients.render(id: id, dark: dark, pixelSize: size)
            }
            guard let raw else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.pictureFailed(generation: gen) }
                }
                return
            }
            let dominant = pipeline.dominantTint(raw)
            let tint = chosenTint ?? dominant
            let base = pipeline.styled(raw, style: style, tint: tint, darken: darkenAlone) ?? raw
            let luminance = pipeline.average(base).luminance
            let thumbnails = pipeline.thumbnails(raw, tint: tint, size: BackgroundRenderer.thumbnailSize)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pictureReady(base, luminance: luminance, dominant: dominant, thumbnails: thumbnails, generation: gen)
                }
            }
        }
    }

    private func pictureFailed(generation gen: Int) {
        guard gen == generation else { return }
        Log.note("Background: no picture for \(spec.source); showing the colour")
        levels = [:]
        dominantTint = nil
        styleThumbnails = nil
        showColorOnly(animated: true)
        onThumbnailsChanged?()
    }

    private func pictureReady(_ base: CGImage, luminance: CGFloat, dominant: NSColor,
                              thumbnails: [BackgroundSpec.Style: CGImage], generation gen: Int) {
        guard gen == generation else { return }
        let hadPicture = !levels.isEmpty
        levels = [0: base]
        dominantTint = dominant
        styleThumbnails = thumbnails
        // Ink for the picture as it will mostly be seen: with the dim it reaches when zoomed out.
        let dimmed = luminance * (1 - spec.dimAmount(forZoom: BackgroundSpec.focusFullZoom))
        let light = dimmed > 0.179

        CATransaction.begin()
        CATransaction.setAnimationDuration(BackgroundRenderer.fadeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        let sharp = levelLayers[0]
        let from = sharp.contents
        sharp.contents = base
        sharp.opacity = 1
        if let from, hadPicture {
            let fade = CABasicAnimation(keyPath: "contents")
            fade.fromValue = from
            fade.duration = BackgroundRenderer.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sharp.add(fade, forKey: "contents")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = BackgroundRenderer.fadeDuration
            sharp.add(fade, forKey: "opacity")
        }
        if !BackgroundSources.reduceMotion {
            // A new picture settles in from a touch larger, as a wallpaper does on iOS.
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = 1.03
            settle.toValue = 1
            settle.duration = BackgroundRenderer.fadeDuration * 1.5
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pictureLayer.add(settle, forKey: "settle")
        }
        // The old picture's blur levels don't match the new one: they fade out and come back as the new
        // ones are made.
        for l in levelLayers.dropFirst() {
            l.opacity = 0
            l.contents = nil
        }
        colorLayer.opacity = 1
        CATransaction.commit()

        if light != isLight || !hadPicture {
            isLight = light
            onLookChanged?()
        }
        tune(animated: true)
        onThumbnailsChanged?()
    }

    /// Makes the blur levels the current position needs, one request per level, in order.
    private func ensureLevels(around position: CGFloat) {
        guard let base = levels[0] else { return }
        let needed = Set([Int(position.rounded(.down)), Int(position.rounded(.up))]).filter { $0 >= 1 }
        // Made levels are kept for the picture's life: a level let go when the zoom moved away was made
        // again only once the zoom came back, so every zoom out (every return from a window) showed the
        // picture sharper for a moment and then faded the blur in. That was the blink. Four levels at half
        // scale are a few screens of pixels at most.
        for level in needed.sorted() where levels[level] == nil && !levelsInFlight.contains(level) {
            levelsInFlight.insert(level)
            let gen = generation
            let sigma = BackgroundPipeline.levelRadii[level]
            let pipeline = self.pipeline
            pipeline.queue.async {
                let image = pipeline.blurred(base, sigma: sigma)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.levelReady(level, image, generation: gen) }
                }
            }
        }
    }

    private func levelReady(_ level: Int, _ image: CGImage?, generation gen: Int) {
        guard gen == generation else { return }
        levelsInFlight.remove(level)
        guard let image else { return }
        levels[level] = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = levelLayers[level]
        layer.contents = image
        layer.isHidden = false
        applyFocus()
        // It arrives at the opacity the zoom asks for, with a short fade rather than a pop.
        if layer.opacity > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = layer.opacity
            fade.duration = 0.25
            layer.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    private func showColorOnly(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(BackgroundRenderer.fadeDuration)
        } else {
            CATransaction.setDisableActions(true)
        }
        for l in levelLayers {
            if animated, l.opacity > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = l.opacity
                fade.toValue = 0
                fade.duration = BackgroundRenderer.fadeDuration
                l.add(fade, forKey: "opacity")
            }
            l.opacity = 0
            l.contents = nil
        }
        if isLight != colorLayer.isLightColor {
            isLight = colorLayer.isLightColor
            onLookChanged?()
        }
        CATransaction.commit()
    }

    // MARK: Tuning the layers

    /// Colour, grain, vignette, living gradient, and the focus for the current zoom, from `spec`.
    private func tune(animated: Bool) {
        let color = Settings.canvasColor(dark: isDark)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(BackgroundRenderer.fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        animate(colorLayer, "backgroundColor", from: colorLayer.backgroundColor, to: color.cgColor, animated: animated)
        colorLayer.backgroundColor = color.cgColor
        if spec.isPlainColor || levels.isEmpty, isLight != color.isLight {
            isLight = color.isLight
            onLookChanged?()
        }

        let grainOpacity: Float = spec.isPlainColor ? 0 : spec.grain.opacity
        if grainOpacity > 0, grainImage == nil {
            let size = pixelSize
            let gen = generation
            let pipeline = self.pipeline
            pipeline.queue.async {
                let image = pipeline.grain(pixelSize: size)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard gen == self.generation, let image else { return }
                        self.grainImage = image
                        self.grainLayer.contents = image
                        self.tune(animated: true)
                    }
                }
            }
        }
        setOpacity(grainLayer, grainImage == nil ? 0 : grainOpacity, animated: animated)
        setOpacity(vignetteLayer, spec.vignette && !spec.isPlainColor ? 1 : 0, animated: animated)
        tuneLiving()
        applyFocus()
        applyDepth()
        CATransaction.commit()
    }

    private func tuneLiving() {
        if case .gradient(let id) = spec.source, spec.living, !BackgroundSources.reduceMotion {
            if living == nil, let layer = LivingGradientLayer.make() {
                layer.anchorPoint = .zero
                layer.position = .zero
                layer.frame = pictureLayer.bounds
                layer.contentsScale = scale
                pictureLayer.addSublayer(layer)
                living = layer
            }
            living?.gradient = Gradients.gradient(id: id)
            living?.isDark = isDark
            living?.isPaused = !isActive
            living?.opacity = 1
        } else if let layer = living {
            layer.isPaused = true
            layer.removeFromSuperlayer()
            living = nil
        }
    }

    /// The blur cross-fade and the dim for the current zoom. Level 0 is always up; a level above it shows
    /// as far as the position has passed the level below. Levels not made yet stay clear.
    private func applyFocus() {
        guard !levels.isEmpty, !spec.isPlainColor else {
            dimLayer.opacity = 0
            dimLayer.isHidden = true
            return
        }
        let position = spec.source.isPicture ? spec.blurPosition(forZoom: camera.zoom) : 0
        ensureLevels(around: position)
        // A clear level is hidden too: Core Animation then leaves it out of the frame for certain.
        for (i, l) in levelLayers.enumerated() where i >= 1 {
            let target = Float(min(1, max(0, position - CGFloat(i - 1))))
            let opacity = levels[i] == nil ? 0 : target
            if l.opacity != opacity { l.opacity = opacity }
            if l.isHidden != (opacity == 0) { l.isHidden = opacity == 0 }
        }
        let dim = Float(spec.dimAmount(forZoom: camera.zoom))
        if dimLayer.opacity != dim { dimLayer.opacity = dim }
        if dimLayer.isHidden != (dim == 0) { dimLayer.isHidden = dim == 0 }
    }

    /// With depth on, the picture follows a fraction of the camera's motion, held within its overscan.
    private func applyDepth() {
        guard spec.depth, !spec.isPlainColor, !BackgroundSources.reduceMotion else {
            if !CATransform3DIsIdentity(pictureLayer.transform) { pictureLayer.transform = CATransform3DIdentity }
            return
        }
        let fraction: CGFloat = 0.15
        let marginX = bounds.width * 0.1, marginY = bounds.height * 0.1
        // The world layer shifts by (−origin.x·zoom, +origin.y·zoom) in CA space; the picture by a part of that.
        let dx = min(marginX, max(-marginX, -camera.origin.x * camera.zoom * fraction))
        let dy = min(marginY, max(-marginY, camera.origin.y * camera.zoom * fraction))
        pictureLayer.transform = CATransform3DMakeTranslation(dx, dy, 0)
    }

    private func setOpacity(_ layer: CALayer, _ value: Float, animated: Bool) {
        guard layer.opacity != value else { return }
        animate(layer, "opacity", from: layer.opacity, to: value, animated: animated)
        layer.opacity = value
    }

    /// The layers here disable implicit animations (so the camera can drive them), so a deliberate change
    /// spells its animation out.
    private func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any?, animated: Bool) {
        guard animated, let from else { return }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = BackgroundRenderer.fadeDuration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: keyPath)
    }
}

private extension CALayer {
    var isLightColor: Bool {
        guard let c = backgroundColor, let color = NSColor(cgColor: c) else { return false }
        return color.isLight
    }
}
