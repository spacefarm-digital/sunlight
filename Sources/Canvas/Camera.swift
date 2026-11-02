import CoreGraphics
import QuartzCore

/// World and screen coordinates are both top-left origin (Quartz style), in points.
/// At the identity camera the world *is* the screen, so AX / ScreenCaptureKit frames drop in unchanged.
/// `origin` is the world point visible at the top-left corner of the screen.
struct Camera: Equatable {
    var origin: CGPoint
    var zoom: CGFloat

    init(origin: CGPoint = .zero, zoom: CGFloat = 1) {
        self.origin = origin
        self.zoom = zoom
    }

    init(center: CGPoint, zoom: CGFloat, viewSize: CGSize) {
        self.zoom = zoom
        self.origin = CGPoint(x: center.x - viewSize.width / (2 * zoom),
                              y: center.y - viewSize.height / (2 * zoom))
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + origin.x, y: p.y / zoom + origin.y)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(origin: toScreen(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    func toWorld(_ r: CGRect) -> CGRect {
        CGRect(origin: toWorld(r.origin), size: CGSize(width: r.width / zoom, height: r.height / zoom))
    }

    /// Within a pixel of the other on screen: moving between them would show nothing.
    func isClose(to other: Camera) -> Bool {
        abs(zoom - other.zoom) < 0.001 && abs(origin.x - other.origin.x) * zoom < 1 && abs(origin.y - other.origin.y) * zoom < 1
    }

    func center(viewSize: CGSize) -> CGPoint {
        CGPoint(x: origin.x + viewSize.width / (2 * zoom), y: origin.y + viewSize.height / (2 * zoom))
    }

    /// Transform for the world layer.
    ///
    /// The layer tree deliberately uses Core Animation's native y-up coordinates (no `isGeometryFlipped`),
    /// so IOSurface contents and text never render upside down. A world rect (top-left, y down) is placed
    /// at the CA rect `(x, -maxY, w, h)` — see `caRect` — and this transform maps that CA world space onto
    /// the view:  x' = x·zoom − origin.x·zoom,   y' = y·zoom + viewHeight + origin.y·zoom.
    func layerTransform(viewHeight: CGFloat) -> CATransform3D {
        var t = CATransform3DMakeTranslation(-origin.x * zoom, viewHeight + origin.y * zoom, 0)
        t = CATransform3DScale(t, zoom, zoom, 1) // scale first, then translate
        return t
    }
}

/// Core Animation rect (y up) for a world rect (y down).
func caRect(_ world: CGRect) -> CGRect {
    CGRect(x: world.minX, y: -world.maxY, width: world.width, height: world.height)
}

/// Van Wijk & Nuij's smooth pan-and-zoom path between two cameras ("Smooth and efficient zooming and
/// panning", 2003; the interpolator behind d3-zoom). The camera pulls back a little on the way, more
/// for longer trips, so a move reads as travel across the canvas rather than a smear. Progress `t`
/// runs 0 → 1 and extrapolates smoothly past either end, which is what lets a spring overshoot it.
struct CameraPath {
    /// How much to pull back per unit of travel. √2 is the paper's optimum; lower is a flatter trip.
    static let rho: CGFloat = 1.1

    private let viewSize: CGSize
    private let c0: CGPoint
    private let dx: CGFloat, dy: CGFloat
    private let w0: CGFloat
    private let r0: CGFloat, coshr0: CGFloat, sinhr0: CGFloat
    private let d1: CGFloat   // distance between the centres; 0 for a pure zoom
    private let S: CGFloat    // signed path parameter at t = 1
    /// Perceptual length of the trip, pan and zoom combined, in the paper's units. Zero means no move.
    let length: CGFloat

    init(from: Camera, to: Camera, viewSize: CGSize) {
        self.viewSize = viewSize
        let rho = CameraPath.rho, rho2 = rho * rho, rho4 = rho2 * rho2
        c0 = from.center(viewSize: viewSize)
        let c1 = to.center(viewSize: viewSize)
        // w is the width of the world on screen: the paper's measure of "how far out" the camera is.
        w0 = viewSize.width / from.zoom
        let w1 = viewSize.width / to.zoom
        dx = c1.x - c0.x
        dy = c1.y - c0.y
        let d2 = dx * dx + dy * dy
        if d2 < 1e-6 {
            d1 = 0
            S = log(w1 / w0) / rho
            r0 = 0
            coshr0 = 1
            sinhr0 = 0
        } else {
            d1 = sqrt(d2)
            let b0 = (w1 * w1 - w0 * w0 + rho4 * d2) / (2 * w0 * rho2 * d1)
            let b1 = (w1 * w1 - w0 * w0 - rho4 * d2) / (2 * w1 * rho2 * d1)
            r0 = log(sqrt(b0 * b0 + 1) - b0)
            let r1 = log(sqrt(b1 * b1 + 1) - b1)
            S = (r1 - r0) / rho
            coshr0 = cosh(r0)
            sinhr0 = sinh(r0)
        }
        length = abs(S)
    }

    func camera(at t: CGFloat) -> Camera {
        let rho = CameraPath.rho
        let s = t * S
        let center: CGPoint
        let w: CGFloat
        if d1 == 0 {
            center = CGPoint(x: c0.x + t * dx, y: c0.y + t * dy)
            w = w0 * exp(rho * s)
        } else {
            let u = w0 / (rho * rho * d1) * (coshr0 * tanh(rho * s + r0) - sinhr0)
            center = CGPoint(x: c0.x + u * dx, y: c0.y + u * dy)
            w = w0 * coshr0 / cosh(rho * s + r0)
        }
        return Camera(center: center, zoom: viewSize.width / w, viewSize: viewSize)
    }
}

/// A damped spring in closed form, pulling a scalar toward 0 from offset `x0` with velocity `v0`.
/// Under-damped on purpose: the slight overshoot is the rubber band at the end of a flight.
struct Spring {
    /// Period of the undamped spring, in seconds: the tempo of the move.
    static let response: CGFloat = 0.45
    /// Damping ratio. 1 is critical (no overshoot); 0.72 overshoots by about 4 % and settles once.
    static let damping: CGFloat = 0.72

    let x0: CGFloat
    let v0: CGFloat
    var response: CGFloat = Spring.response
    var damping: CGFloat = Spring.damping

    /// Offset and velocity `t` seconds in. A damping of 1 or more is the critically damped spring (no
    /// overshoot, the quickest settle without one): the under-damped form divides by zero there, and the
    /// tile's tuck ran on it, so the first tick was NaN and Core Animation threw on the label's position.
    func evaluate(at t: CGFloat) -> (x: CGFloat, v: CGFloat) {
        let ω = 2 * CGFloat.pi / response
        let ζ = damping
        if ζ >= 1 {
            let b = v0 + ω * x0
            let decay = exp(-ω * t)
            return ((x0 + b * t) * decay, (b - ω * (x0 + b * t)) * decay)
        }
        let ωd = ω * sqrt(1 - ζ * ζ)
        let decay = exp(-ζ * ω * t)
        let a = x0
        let b = (v0 + ζ * ω * x0) / ωd
        let c = cos(ωd * t), s = sin(ωd * t)
        let x = decay * (a * c + b * s)
        let v = decay * ((b * ωd - a * ζ * ω) * c - (a * ωd + b * ζ * ω) * s)
        return (x, v)
    }
}
