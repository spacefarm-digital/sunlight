import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import QuartzCore

/// The backdrop's mood: how far along setup is, and how warm this page's light is.
struct SetupMood: Equatable, Sendable {
    var progress: Float
    var warmth: Float
}

/// The wizard's backdrop: a field of slow, warm light. A small Metal pass at a quarter of the screen's
/// resolution, scaled up by the compositor; light this soft shows no pixels. The light rises and warms
/// as setup progresses (`mood`), flares for a moment when a step finishes (`flare()`), can open on a
/// sunrise and swell softly with the welcome music (`sunrise(over:)`, `swell(_:)`), and follows the
/// Mac's appearance (`isDark`). Targets are eased per frame, so every change is a slow morph, never a cut.
final class SetupBackdropLayer: CAMetalLayer {
    /// Float4s first, then the float2, then floats: Swift and MSL pad this the same way (see the test).
    struct Uniforms {
        var ground: SIMD4<Float>
        var lights: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        /// xy centre (fractions of the width and height), z reach, w weight.
        var centers: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        /// rgb colour, w intensity.
        var horizon: SIMD4<Float>
        var aspect: SIMD2<Float>
        var time: Float
        var pulse: Float
        var darkness: Float
        var contrast: Float
        var horizonY: Float
    }

    struct Palette {
        var ground: SIMD3<Float>
        /// Amber, rose, violet, teal (dark); amber, peach, lilac, sky (light).
        var lights: [SIMD3<Float>]
        var horizon: SIMD3<Float>
        /// The horizon's strength at no progress, and what full progress adds.
        var horizonBase: Float
        var horizonGain: Float
        /// Each light's weight on the coolest page and on the warmest.
        var cool: [Float]
        var warm: [Float]

        static let dark = Palette(ground: [0.04, 0.04, 0.05],
                                  lights: [[1.00, 0.78, 0.16], [0.97, 0.38, 0.50], [0.40, 0.30, 0.95], [0.15, 0.55, 0.70]],
                                  horizon: [0.98, 0.64, 0.22], horizonBase: 0.16, horizonGain: 0.50,
                                  cool: [0.10, 0.12, 0.36, 0.36], warm: [0.30, 0.26, 0.16, 0.00])
        static let light = Palette(ground: [1.00, 0.97, 0.91],
                                   lights: [[1.00, 0.86, 0.45], [1.00, 0.78, 0.70], [0.80, 0.76, 0.98], [0.72, 0.86, 0.96]],
                                   horizon: [1.00, 0.80, 0.42], horizonBase: 0.12, horizonGain: 0.52,
                                   cool: [0.20, 0.20, 0.55, 0.55], warm: [0.65, 0.45, 0.20, 0.00])
    }

    /// Where the four lights sit, as fractions of the width and height, and how far each reaches.
    static let centers: [SIMD2<Float>] = Gradients.blobCenters + [[0.30, 0.68]]
    static let reach: [Float] = [0.62, 0.66, 0.70, 0.58]

    /// Setup's progress and this page's warmth. Eased towards over about a second.
    var mood = SetupMood(progress: 0, warmth: 0)
    var isDark = false
    var highContrast = false
    /// Reduce Motion: the light holds still; only the eased changes play.
    var freezesTime = false

    private var commandQueue: MTLCommandQueue?
    private var state: MTLRenderPipelineState?
    private let started = CACurrentMediaTime()
    private var lastFrame: CFTimeInterval?
    private var progress: Float = 0
    private var warmth: Float = 0
    private var darkness: Float = 0
    private var contrast: Float = 0
    private var pulse: Float = 0
    /// The sunrise: dark until `begin`, then up to the usual light over `duration`. Nil: the usual light.
    private var dawn: (begin: CFTimeInterval, duration: Double)?
    /// Soft swells: when, how strong, in over `rise`, out over `fall`.
    private var swells: [(start: CFTimeInterval, amount: Float, rise: Double, fall: Double)] = []
    private var primed = false
    private static let downscale: CGFloat = 4
    private static let stillTime: Float = 37

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    struct U { float4 ground; float4 lights[4]; float4 centers[4]; float4 horizon; float2 aspect;
               float time; float pulse; float darkness; float contrast; float horizonY; };
    vertex V backdrop_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? 1.0 : -1.0);
        V v; v.position = float4(p, 0, 1); v.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return v;
    }
    static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
    static float vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hash(i), b = hash(i + float2(1, 0)), c = hash(i + float2(0, 1)), d = hash(i + float2(1, 1));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    static float fbm(float2 p) {
        float v = 0.0, a = 0.5;
        for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = p * 2.03 + float2(1.7, 9.2); a *= 0.5; }
        return v;
    }
    fragment float4 backdrop_fragment(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 p = uv * u.aspect;
        float t = u.time;
        // Warped a little by slow noise: light through haze, never discs.
        float2 w = float2(fbm(p * 1.6 + t * 0.025), fbm(p * 1.6 - t * 0.02 + 5.2)) - 0.5;
        float2 q = p + 0.24 * w;
        float3 c = u.ground.rgb;
        float dim = 1.0 - 0.5 * u.contrast;
        for (int i = 0; i < 4; i++) {
            float2 centre = u.centers[i].xy * u.aspect;
            float d = distance(q, centre) / u.centers[i].z;
            float k = u.centers[i].w * dim * exp(-d * d * 2.6);
            c = mix(c, u.lights[i].rgb, clamp(k, 0.0, 1.0));
        }
        // The horizon: a band of light low on the screen that rises and strengthens as setup progresses,
        // and flares when a step finishes. Its edge is warped by the same noise, soft above and fuller
        // below. Mixed, not added, so it never clips in either palette.
        float d = uv.y + 0.07 * w.y - u.horizonY;
        float band = exp(-pow(d * (d > 0.0 ? 2.4 : 4.6), 2.0));
        float glow = band * u.horizon.w * dim * (1.0 + 0.5 * u.pulse);
        c = mix(c, u.horizon.rgb, clamp(glow, 0.0, 1.0));
        // A vignette, deeper in the dark palette.
        float2 v = uv - 0.5;
        c *= 1.0 - (0.10 + 0.25 * u.darkness) * dot(v, v) * 2.0;
        // A touch of noise so slow ramps don't band.
        float n = hash(uv * 1000.0 + fract(t)) - 0.5;
        return float4(c + n / 255.0, 1);
    }
    """

    override init() {
        super.init()
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        pixelFormat = .bgra8Unorm
        framebufferOnly = true
        isOpaque = true
        do {
            let library = try device.makeLibrary(source: SetupBackdropLayer.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "backdrop_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "backdrop_fragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            state = try device.makeRenderPipelineState(descriptor: descriptor)
            commandQueue = device.makeCommandQueue()
        } catch {
            Log.note("Setup: backdrop shader failed to compile: \(error)")
        }
    }

    /// Nil when there's no Metal device or the shader didn't compile; the still gradient stands in then.
    static func make() -> SetupBackdropLayer? {
        let layer = SetupBackdropLayer()
        return layer.state == nil || layer.commandQueue == nil ? nil : layer
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A step finished: the horizon flares, then settles over a third of a second.
    func flare() { pulse = 1 }

    /// Before the sunrise: dim and cool, the horizon still below the screen, until `sunrise(over:)`.
    func holdDark() { dawn = (.infinity, 1) }

    /// The light comes up from dark over `duration` seconds, on the welcome music's swell; 0 at once.
    func sunrise(over duration: Double) {
        dawn = duration > 0 ? (CACurrentMediaTime(), duration) : nil
    }

    /// A soft swell of the horizon, unlike `flare()`'s flash: up over `rise`, back over `fall`.
    func swell(_ amount: Float, rise: Double = 0.5, fall: Double = 1.4) {
        swells.append((CACurrentMediaTime(), amount, rise, fall))
    }

    /// How far the sunrise has come at `now`: 0 dark, 1 the usual light. The music's own curve.
    private func daylight(at now: CFTimeInterval) -> Float {
        guard let dawn else { return 1 }
        let u = min(max((now - dawn.begin) / dawn.duration, 0), 1)
        if u >= 1 { self.dawn = nil }
        return Float(pow(u, 1.3))
    }

    private func swelling(at now: CFTimeInterval) -> Float {
        swells.removeAll { now - $0.start > $0.rise + 6 * $0.fall }
        return swells.reduce(0) { total, s in
            let t = now - s.start
            guard t > 0 else { return total }
            let u = min(t / s.rise, 1)
            return total + s.amount * Float(u * u * (3 - 2 * u) * exp(-max(0, t - s.rise) / s.fall))
        }
    }
    /// Reduce Motion with nothing changing: the frame can stand.
    var isSettled: Bool {
        abs(progress - mood.progress) < 0.002 && abs(warmth - mood.warmth) < 0.002
            && abs(darkness - (isDark ? 1 : 0)) < 0.002 && abs(contrast - (highContrast ? 1 : 0)) < 0.002 && pulse < 0.005
            && dawn == nil && swells.isEmpty
    }

    /// The window's colour under the drawable, so nothing shows before the first frame.
    var groundColor: NSColor {
        let g = (isDark ? Palette.dark : Palette.light).ground
        return NSColor(srgbRed: CGFloat(g.x), green: CGFloat(g.y), blue: CGFloat(g.z), alpha: 1)
    }

    func draw(at now: CFTimeInterval) {
        guard let state, let commandQueue, bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: max(16, (bounds.width * contentsScale / SetupBackdropLayer.downscale).rounded()),
                          height: max(16, (bounds.height * contentsScale / SetupBackdropLayer.downscale).rounded()))
        if drawableSize != size { drawableSize = size }
        ease(at: now)
        guard let drawable = nextDrawable(), let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = uniforms(at: now)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Exponential easing towards the targets: about a second for the mood, a third for the flare. The
    /// first frame lands on its targets at once, so the window never opens mid-morph.
    private func ease(at now: CFTimeInterval) {
        let dt = Float(min(0.1, max(0, now - (lastFrame ?? now))))
        lastFrame = now
        let dark: Float = isDark ? 1 : 0
        let high: Float = highContrast ? 1 : 0
        if !primed {
            primed = true
            progress = mood.progress
            warmth = mood.warmth
            darkness = dark
            contrast = high
            return
        }
        let k = 1 - exp(-dt / 0.9)
        progress += (mood.progress - progress) * k
        warmth += (mood.warmth - warmth) * k
        darkness += (dark - darkness) * k
        contrast += (high - contrast) * k
        pulse *= exp(-dt / 0.35)
    }

    private func uniforms(at now: CFTimeInterval) -> Uniforms {
        let t = freezesTime ? SetupBackdropLayer.stillTime : Float(now - started)
        let day = daylight(at: now)
        let dark = Palette.dark, light = Palette.light
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * darkness }
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * darkness }
        func colour(_ c: SIMD3<Float>, _ w: Float = 1) -> SIMD4<Float> { SIMD4<Float>(c.x, c.y, c.z, w) }
        func wander(_ i: Int) -> SIMD2<Float> {
            let base = SetupBackdropLayer.centers[i]
            let speed = 0.045 + 0.012 * Float(i)
            let phase = Float(i) * 2.1
            return SIMD2<Float>(base.x + 0.10 * sin(t * speed + phase), base.y + 0.08 * cos(t * speed * 0.8 + phase))
        }
        func weight(_ i: Int) -> Float {
            let warm = warmth * day
            let l = light.cool[i] + (light.warm[i] - light.cool[i]) * warm
            let d = dark.cool[i] + (dark.warm[i] - dark.cool[i]) * warm
            return mix(l, d) * (0.3 + 0.7 * day)
        }
        func centre(_ i: Int) -> SIMD4<Float> {
            let c = wander(i)
            return SIMD4<Float>(c.x, c.y, SetupBackdropLayer.reach[i], weight(i))
        }
        let aspect = SIMD2<Float>(Float(bounds.width / max(bounds.width, bounds.height)),
                                  Float(bounds.height / max(bounds.width, bounds.height)))
        let horizonStrength = mix(light.horizonBase + light.horizonGain * progress, dark.horizonBase + dark.horizonGain * progress)
            * (0.15 + 0.85 * day)
        return Uniforms(ground: colour(mix(light.ground, dark.ground)),
                        lights: (colour(mix(light.lights[0], dark.lights[0])), colour(mix(light.lights[1], dark.lights[1])),
                                 colour(mix(light.lights[2], dark.lights[2])), colour(mix(light.lights[3], dark.lights[3]))),
                        centers: (centre(0), centre(1), centre(2), centre(3)),
                        horizon: colour(mix(light.horizon, dark.horizon), horizonStrength),
                        aspect: aspect, time: t, pulse: max(pulse, swelling(at: now)), darkness: darkness, contrast: contrast,
                        horizonY: 1.16 - 0.30 * progress + 0.22 * (1 - day))
    }
}

/// Hosts the backdrop as its backing layer and drives it from a display link while it's on screen and
/// not paused. Without Metal, a still of the Sunlight gradient fills the view instead.
@MainActor
final class SetupBackdropView: NSView {
    private(set) var backdrop: SetupBackdropLayer?
    private let grain = CALayer()
    private var link: CADisplayLink?
    private var lowPower = false

    /// Faded out, occluded, or the app in the background: no frames.
    var isPaused = false {
        didSet { updateLink() }
    }

    var mood = SetupMood(progress: 0, warmth: 0) {
        didSet {
            backdrop?.mood = mood
            updateLink()
        }
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        grain.compositingFilter = "softLightBlendMode"
        grain.contentsGravity = .resize
        grain.opacity = 0.06
        grain.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(grain)
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        if let metal = SetupBackdropLayer.make() {
            backdrop = metal
            return metal
        }
        Log.note("Setup: no Metal backdrop; showing the still gradient")
        let still = CALayer()
        still.contentsGravity = .resizeAspectFill
        return still
    }

    override var isOpaque: Bool { true }

    /// A step finished: the horizon flares.
    func flare() {
        backdrop?.flare()
        updateLink()
    }

    /// The welcome music's light: dark until the sunrise, up over `duration`, soft swells on its beats.
    func holdDark() {
        backdrop?.holdDark()
        updateLink()
    }

    func sunrise(over duration: Double) {
        backdrop?.sunrise(over: duration)
        updateLink()
    }

    func swell(_ amount: Float, rise: Double = 0.5, fall: Double = 1.4) {
        backdrop?.swell(amount, rise: rise, fall: fall)
        updateLink()
    }

    func setLowPower(_ on: Bool) {
        lowPower = on
        link?.preferredFrameRateRange = on ? CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24) : .default
    }

    func setReduceMotion(_ on: Bool) {
        backdrop?.freezesTime = on
        updateLink()
    }

    func setHighContrast(_ on: Bool) {
        backdrop?.highContrast = on
        updateLink()
    }

    /// One frame now, for a window about to fade in.
    func drawNow() {
        backdrop?.draw(at: CACurrentMediaTime())
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateLink()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopLink() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        updateLink()
    }

    override func layout() {
        super.layout()
        grain.frame = bounds
        regrain()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        grain.contentsScale = scale
        regrain()
        if backdrop == nil { restill() }
    }

    private func applyAppearance() {
        backdrop?.isDark = isDark
        if backdrop == nil { restill() }
    }

    private func restill() {
        guard backdrop == nil, let layer, bounds.width > 0 else { return }
        let scale = layer.contentsScale
        layer.contents = Gradients.render(id: "sunlight", dark: isDark,
                                          pixelSize: CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    private var grainSize = CGSize.zero
    /// Grey noise at half the screen's pixels, stretched over it: film grain, barely there.
    private func regrain() {
        let scale = layer?.contentsScale ?? 2
        let size = CGSize(width: (bounds.width * scale / 2).rounded(), height: (bounds.height * scale / 2).rounded())
        guard size.width > 0, size.height > 0, size != grainSize else { return }
        grainSize = size
        guard let noise = CIFilter.randomGenerator().outputImage else { return }
        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise.cropped(to: CGRect(origin: .zero, size: size))
        let third = CIVector(x: 1 / 3, y: 1 / 3, z: 1 / 3, w: 0)
        grey.rVector = third
        grey.gVector = third
        grey.bVector = third
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let out = grey.outputImage else { return }
        let context = CIContext(options: [.cacheIntermediates: false])
        grain.contents = context.createCGImage(out, from: CGRect(origin: .zero, size: size))
    }

    private func updateLink() {
        guard window != nil, !isPaused, let backdrop else {
            stopLink()
            return
        }
        // Reduce Motion: frames only while something is still easing.
        if backdrop.freezesTime, backdrop.isSettled, link == nil {
            backdrop.draw(at: CACurrentMediaTime())
            return
        }
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        if lowPower { l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24) }
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let backdrop else { return }
        backdrop.draw(at: link.targetTimestamp)
        if backdrop.freezesTime, backdrop.isSettled { stopLink() }
    }
}
