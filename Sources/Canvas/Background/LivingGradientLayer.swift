import AppKit
import Metal
import QuartzCore

/// A built-in gradient that drifts: the three blobs wander slowly on looping paths. A tiny Metal pass at
/// an eighth of the screen's resolution, 24 times a second, scaled up by the compositor; blobs this soft
/// show no pixels. Paused whenever the canvas isn't in front (`isPaused`). The shader is compiled from
/// source at first use; where that fails, `init` returns nil and the still gradient stays.
final class LivingGradientLayer: CAMetalLayer {
    var gradient: CanvasGradient?
    var isDark = false
    var isPaused = true {
        didSet {
            if isPaused { stop() } else { start() }
        }
    }

    private var commandQueue: MTLCommandQueue?
    private var state: MTLRenderPipelineState?
    private var timer: Timer?
    private let started = CACurrentMediaTime()
    private static let fps: TimeInterval = 24
    private static let downscale: CGFloat = 8

    private struct Uniforms {
        var ground: SIMD4<Float>
        var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var centers: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var aspect: SIMD2<Float>
        var reach: Float
        var time: Float
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    struct U { float4 ground; float4 colors[3]; float4 centers[3]; float2 aspect; float reach; float time; };
    vertex V living_vertex(uint id [[vertex_id]]) {
        float2 p = float2((id & 1) ? 1.0 : -1.0, (id & 2) ? 1.0 : -1.0);
        V v; v.position = float4(p, 0, 1); v.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); return v;
    }
    fragment float4 living_fragment(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 p = in.uv * u.aspect;
        float3 c = u.ground.rgb;
        for (int i = 0; i < 3; i++) {
            float d = distance(p, u.centers[i].xy * u.aspect) / u.reach;
            float w = exp(-d * d * 3.2);
            c = mix(c, u.colors[i].rgb, w);
        }
        // A touch of noise so slow ramps don't band.
        float n = fract(sin(dot(in.uv * 1000.0 + u.time, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
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
            let library = try device.makeLibrary(source: LivingGradientLayer.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "living_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "living_fragment")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            state = try device.makeRenderPipelineState(descriptor: descriptor)
            commandQueue = device.makeCommandQueue()
        } catch {
            Log.note("Background: living gradient shader failed to compile: \(error)")
        }
    }

    /// Nil when there's no Metal device or the shader didn't compile.
    static func make() -> LivingGradientLayer? {
        let layer = LivingGradientLayer()
        return layer.state == nil || layer.commandQueue == nil ? nil : layer
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func start() {
        guard timer == nil, state != nil else { return }
        let t = Timer(timeInterval: 1 / LivingGradientLayer.fps, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.draw() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        draw()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func draw() {
        guard let state, let commandQueue, let gradient, bounds.width > 0, bounds.height > 0 else { return }
        let size = CGSize(width: max(16, (bounds.width * contentsScale / LivingGradientLayer.downscale).rounded()),
                          height: max(16, (bounds.height * contentsScale / LivingGradientLayer.downscale).rounded()))
        if drawableSize != size { drawableSize = size }
        guard let drawable = nextDrawable(), let buffer = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let palette = gradient.palette(dark: isDark)
        let t = Float(CACurrentMediaTime() - started)
        func wander(_ i: Int) -> SIMD4<Float> {
            let base = Gradients.blobCenters[i]
            let speed = 0.045 + 0.012 * Float(i)
            let phase = Float(i) * 2.1
            return SIMD4<Float>(base.x + 0.12 * sin(t * speed + phase), base.y + 0.10 * cos(t * speed * 0.8 + phase), 0, 0)
        }
        func colour(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4<Float>(c.x, c.y, c.z, 1) }
        let blobs = palette.blobs + Array(repeating: palette.ground, count: max(0, 3 - palette.blobs.count))
        let aspect = SIMD2<Float>(Float(bounds.width / max(bounds.width, bounds.height)),
                                  Float(bounds.height / max(bounds.width, bounds.height)))
        var uniforms = Uniforms(ground: colour(palette.ground),
                                colors: (colour(blobs[0]), colour(blobs[1]), colour(blobs[2])),
                                centers: (wander(0), wander(1), wander(2)),
                                aspect: aspect, reach: Gradients.blobRadius, time: t)
        encoder.setRenderPipelineState(state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
