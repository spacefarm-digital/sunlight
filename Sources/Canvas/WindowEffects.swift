import CoreGraphics
import QuartzCore

/// How a window opens onto the canvas and how it leaves it: the curves only, kept out of the view so
/// they can be tested. The view plays them (`CanvasView`'s entrances and exits) and draws what a curve
/// asks for beyond the window itself: the dimming veil, Bloom's ring, Dealt's nudge.
///
/// The set came out of a gallery of Linux compositor effects and first-principles ones (2026-10-31).
/// What they follow:
/// - Open and close are not mirrors: opening eases out over 300–400 ms so the window is readable early,
///   closing eases in at about 60 % of that and is gone before anyone studies it.
/// - A window comes from somewhere: the point it was opened at, the window it was placed beside, the
///   window it hangs from. Motion from nowhere is noise on a canvas without edges.
/// - One idea per effect, light rather than physics: brightness, shadow and reveal, no jelly or folds,
///   nothing overshooting by more than a couple of percent.
/// - Distances are screen points, so an effect looks the same at any zoom.
/// - Only what the window server does for a live window: a positive, axis-aligned scale and a
///   translation (`LiveWindowsWire.Window`), and alpha (sunlight-40). Veils and rings are the canvas's.
enum WindowEffect: String, CaseIterable, Identifiable {
    /// Picks per window from what is known about where it came from (`style(for:context:reduceMotion:)`).
    case automatic
    case sunrise
    case unfold
    case bloom
    case dissolve
    case none

    var id: String { rawValue }

    /// Settings › Motion › Opening and closing.
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .sunrise: return "Sunrise"
        case .unfold: return "Unfold"
        case .bloom: return "Bloom"
        case .dissolve: return "Dissolve"
        case .none: return "None"
        }
    }

    /// One curve, with its opening and closing halves.
    enum Style: Equatable {
        /// Rises a few points into place while brightening from half-light; closing, it sinks and dims.
        case sunrise
        /// Grows out of the point it was opened at and shrinks back into it.
        case source
        /// Slides out from behind the window it was placed beside, like a card dealt off a stack, and
        /// tucks back under it.
        case dealt
        /// Rolls down from its top edge and back up: sheets, prompts and panels.
        case unfold
        /// Springs from 90 % with a ring rippling out from its edges; closing, it pinches and fades.
        case bloom
        /// Opacity alone. What every effect becomes under Reduce Motion.
        case dissolve
    }

    /// What is known about a window as it opens: its source and its neighbour in world coordinates.
    struct Context: Equatable {
        /// Where it was asked for: the spot of Open Here….
        var source: CGPoint?
        /// The window it was placed beside (`NewWindowSpot`), as that window is.
        var neighbour: CGRect?
        /// A sheet or prompt hanging from another window.
        var attached = false
    }

    /// The curve a window gets. Nil: none at all, it simply appears (and goes).
    static func style(for setting: WindowEffect, context: Context, reduceMotion: Bool) -> Style? {
        if setting == .none { return nil }
        if reduceMotion { return .dissolve }
        switch setting {
        case .none: return nil
        case .sunrise: return .sunrise
        case .unfold: return .unfold
        case .bloom: return .bloom
        case .dissolve: return .dissolve
        case .automatic:
            if context.attached { return .unfold }
            if context.source != nil { return .source }
            if context.neighbour != nil { return .dealt }
            return .sunrise
        }
    }

    /// A curve with what it needs: one that needs a source or a neighbour it doesn't have becomes Sunrise.
    static func usable(_ style: Style, _ geometry: Geometry) -> Style {
        switch style {
        case .source where geometry.toSource == nil: return .sunrise
        case .dealt where geometry.toNeighbour == nil: return .sunrise
        default: return style
        }
    }

    /// Where the window's centre is going to or coming from, on screen (points, top-left space): the
    /// source's offset from it, the neighbour's centre's.
    struct Geometry: Equatable {
        var toSource: CGVector?
        var toNeighbour: CGVector?
    }

    /// One moment of an effect, as drawn: the window scaled about `anchor` (a unit point in its own
    /// rect, top-left space) and then moved `offset` screen points, at `opacity`, under a veil of black
    /// `dim` deep (drawn at `dim × opacity`, so a fading window takes its veil with it).
    struct Frame: Equatable {
        var scale = CGSize(width: 1, height: 1)
        var anchor = CGPoint(x: 0.5, y: 0.5)
        var offset = CGVector.zero
        var opacity: Float = 1
        var dim: Float = 0

        static let identity = Frame()
        var isIdentity: Bool { self == .identity || (scale == CGSize(width: 1, height: 1) && offset == .zero && opacity == 1 && dim == 0) }
        /// Whether the window's geometry is its own (opacity and veil aside).
        var keepsGeometry: Bool { scale == CGSize(width: 1, height: 1) && offset == .zero }

        /// Where a rect on screen (top-left space, points) is drawn.
        func applied(toScreen r: CGRect) -> CGRect {
            let w = r.width * scale.width, h = r.height * scale.height
            let ax = r.minX + r.width * anchor.x, ay = r.minY + r.height * anchor.y
            return CGRect(x: ax - w * anchor.x + offset.dx, y: ay - h * anchor.y + offset.dy, width: w, height: h)
        }

        /// The same for a world rect (top-left space), the offset taken from screen points at `zoom`.
        func applied(toWorld r: CGRect, zoom: CGFloat) -> CGRect {
            var f = self
            f.offset = CGVector(dx: offset.dx / zoom, dy: offset.dy / zoom)
            return f.applied(toScreen: r)
        }
    }

    // MARK: Timing

    static func duration(_ style: Style, opening: Bool) -> CFTimeInterval {
        switch (style, opening) {
        case (.sunrise, true): return 0.38
        case (.sunrise, false): return 0.24
        case (.source, true): return 0.34
        case (.source, false): return 0.24
        case (.dealt, true): return 0.36
        case (.dealt, false): return 0.26
        case (.unfold, true): return 0.30
        case (.unfold, false): return 0.20
        case (.bloom, true): return 0.5
        case (.bloom, false): return 0.16
        case (.dissolve, true): return 0.18
        case (.dissolve, false): return 0.15
        }
    }

    /// Bloom's spring: from 90 % with a little push, the canvas's arrival since the start.
    static let bloomScale: CGFloat = 0.9
    static let bloomSpeed: CGFloat = 0.6
    /// Dealt: how far the neighbour gives way, in screen points, and for how long.
    static let nudgeReach: CGFloat = 4
    static let nudgeDuration: CFTimeInterval = 0.42

    /// The effect `t` seconds in. Opening runs from the effect's start to `.identity`; closing from
    /// `.identity` to gone (opacity 0), and holds there past its end.
    static func frame(_ style: Style, opening: Bool, at t: CFTimeInterval, geometry: Geometry = Geometry()) -> Frame {
        let style = usable(style, geometry)
        let d = duration(style, opening: opening)
        let p = CGFloat(max(0, min(1, t / d)))
        var f = Frame()
        if opening {
            switch style {
            case .sunrise:
                let e = outExpo(p)
                f.offset = CGVector(dx: 0, dy: 18 * (1 - e))
                f.opacity = Float(min(1, p / 0.35))
                f.dim = Float(0.45 * (1 - e))
            case .source:
                let e = outQuint(p), v = geometry.toSource ?? .zero
                f.scale = uniform(0.18 + 0.82 * e)
                f.offset = CGVector(dx: v.dx * (1 - e), dy: v.dy * (1 - e))
                f.opacity = Float(min(1, p / 0.3))
            case .dealt:
                let e = outExpo(p), v = geometry.toNeighbour ?? .zero
                f.scale = uniform(0.86 + 0.14 * e)
                f.offset = CGVector(dx: v.dx * (1 - e), dy: v.dy * (1 - e))
                f.opacity = Float(min(1, p / 0.25))
            case .unfold:
                let e = outExpo(p)
                f.anchor = CGPoint(x: 0.5, y: 0)
                f.scale = CGSize(width: 0.97 + 0.03 * e, height: 0.03 + 0.97 * e)
                f.opacity = Float(0.7 + 0.3 * e)
            case .bloom:
                let spring = Spring(x0: bloomScale - 1, v0: bloomSpeed)
                f.scale = uniform(t >= d ? 1 : 1 + spring.evaluate(at: CGFloat(t)).x)
                f.opacity = Float(min(1, t / 0.2))
            case .dissolve:
                f.opacity = Float(outExpo(p))
            }
            if p >= 1 { return .identity }
        } else {
            let e = inCubic(p)
            switch style {
            case .sunrise:
                f.offset = CGVector(dx: 0, dy: 14 * e)
                f.dim = Float(0.5 * e)
                f.opacity = Float(1 - e)
            case .source:
                let v = geometry.toSource ?? .zero
                f.scale = uniform(1 - 0.82 * e)
                f.offset = CGVector(dx: v.dx * e, dy: v.dy * e)
                f.opacity = Float(p < 0.6 ? 1 : 1 - (p - 0.6) / 0.4)
            case .dealt:
                let v = geometry.toNeighbour ?? .zero
                f.scale = uniform(1 - 0.14 * e)
                f.offset = CGVector(dx: v.dx * e, dy: v.dy * e)
                f.opacity = Float(p < 0.5 ? 1 : 1 - (p - 0.5) / 0.5)
            case .unfold:
                f.anchor = CGPoint(x: 0.5, y: 0)
                f.scale = CGSize(width: 1 - 0.03 * e, height: 1 - 0.97 * e)
                f.opacity = Float(p < 0.7 ? 1 : 1 - (p - 0.7) / 0.3)
            case .bloom:
                f.scale = uniform(1 - 0.08 * e)
                f.opacity = Float(1 - e)
            case .dissolve:
                f.opacity = Float(1 - e)
            }
        }
        return f
    }

    /// How far, 0 → 1 → 0, Dealt's neighbour has given way `t` seconds in.
    static func nudge(at t: CFTimeInterval) -> CGFloat {
        let p = CGFloat(max(0, min(1, t / nudgeDuration)))
        return sin(.pi * p) * (1 - p * 0.3)
    }

    // MARK: Curves

    static func outExpo(_ p: CGFloat) -> CGFloat { p >= 1 ? 1 : 1 - pow(2, -10 * p) }
    static func outQuint(_ p: CGFloat) -> CGFloat { 1 - pow(1 - p, 5) }
    static func inCubic(_ p: CGFloat) -> CGFloat { p * p * p }
    private static func uniform(_ s: CGFloat) -> CGSize { CGSize(width: s, height: s) }
}
