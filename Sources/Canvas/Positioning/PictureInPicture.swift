import CoreGraphics

/// Where a window in Picture in Picture is drawn on the screen: its tile's top-left and its size as a
/// fraction of the window's own. In view coordinates (the display's top-left at zero), points. The window
/// keeps its place on the canvas (its home) the whole time; the tile is drawn there instead, whatever the
/// camera does, and stays on show while the canvas is away, over everything.
struct PipFrame: Equatable {
    var origin: CGPoint
    var scale: CGFloat
}

/// Picture in Picture for any window (⌃⌥P, right-click › Picture in Picture), as the macOS video PiP
/// behaves: a tile in one of the four corners of the screen, resized from its edges keeping its aspect,
/// dragged and sprung to the nearest corner (a fling to the corner it's heading for), tucked away off the
/// left or right edge leaving a tab, and flown back when done. The geometry, as pure functions; the
/// motion is the view's.
enum PictureInPicture {
    enum Corner: Int, CaseIterable, Codable {
        case topLeft, topRight, bottomLeft, bottomRight

        var isTop: Bool { self == .topLeft || self == .topRight }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var side: Side { isLeft ? .left : .right }

        /// The corner nearest a point of the visible area.
        static func nearest(to point: CGPoint, in visible: CGRect) -> Corner {
            let left = point.x < visible.midX, top = point.y < visible.midY
            return top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        }

        /// The other corners, nearest first: the same side's other corner, then across.
        var fallbacks: [Corner] {
            switch self {
            case .topLeft: return [.bottomLeft, .topRight, .bottomRight]
            case .topRight: return [.bottomRight, .topLeft, .bottomLeft]
            case .bottomLeft: return [.topLeft, .bottomRight, .topRight]
            case .bottomRight: return [.topRight, .bottomLeft, .topLeft]
            }
        }
    }

    /// The screen edge a tile is tucked away behind.
    enum Side: Int, Codable {
        case left, right
    }

    /// The reference: what macOS video PiP does, in numbers. Approximate, from memory, until measured
    /// frame by frame; every one of them is meant to be tuned here and nowhere else.
    enum Reference {
        /// The gap between a tile at rest and the visible area's edges.
        static let margin: CGFloat = 10
        /// A new tile's width as a part of the visible area's.
        static let widthFraction: CGFloat = 0.25
        /// No tile narrower than this, unless the window itself is.
        static let minWidth: CGFloat = 240
        /// No tile bigger than this part of the visible area on either axis.
        static let maxFraction: CGFloat = 0.5
        /// Dropped with more than this part of its width past the left or right edge, a tile tucks away.
        static let tuckThreshold: CGFloat = 0.5
        /// What stays on screen of a tucked tile: the tab with the chevron.
        static let tabWidth: CGFloat = 24
        /// Over this much of the screen's width per second, a drop is a fling.
        static let flingSpeed: CGFloat = 600
        /// How far ahead the fling is projected to pick its corner, in seconds of travel.
        static let flingLookahead: CGFloat = 0.15
        /// The spring that lands a tile in its corner (snap, fling, untuck).
        static let snapResponse: CGFloat = 0.38
        static let snapDamping: CGFloat = 0.82
        /// The slide behind the edge.
        static let tuckResponse: CGFloat = 0.32
        static let tuckDamping: CGFloat = 1
        /// The flight in from the canvas or from 1:1, and the flight out.
        static let enterResponse: CGFloat = 0.55
        static let enterDamping: CGFloat = 0.92
        static let leaveResponse: CGFloat = 0.45
        static let leaveDamping: CGFloat = 0.95
        /// The tile's corners on screen, as a video's: the window's shape, through the add-on, is a rounded
        /// rectangle of this radius divided by the tile's scale (`nativeCornerRadius`).
        static let cornerRadius: CGFloat = 16
        /// The chrome (scrim, the home button, the title) fading in on hover and out after the pointer leaves.
        static let chromeFade: CFTimeInterval = 0.2
        static let chromeLinger: CFTimeInterval = 1.0
        /// The chrome strip's height on the tile, and its buttons.
        static let stripHeight: CGFloat = 44
        static let buttonSize: CGFloat = 26
    }

    /// The corner radius a window needs in its own points for its tile, drawn at `scale`, to show
    /// `Reference.cornerRadius` on screen; nothing for a window at 1:1 or bigger, which keeps its own corners.
    static func nativeCornerRadius(scale: CGFloat) -> CGFloat {
        guard scale > 0, scale < 1 else { return 0 }
        return (Reference.cornerRadius / scale).rounded()
    }

    /// The tile's rect on screen for a window of `size` (its own size, points).
    static func rect(_ f: PipFrame, size: CGSize) -> CGRect {
        CGRect(origin: f.origin, size: CGSize(width: size.width * f.scale, height: size.height * f.scale))
    }

    /// The scales a tile of a window of `size` may have: from `Reference.minWidth` wide (or the window's own
    /// width when that's less) up to `Reference.maxFraction` of the visible area on either axis, never bigger
    /// than the window itself.
    static func scaleBounds(size: CGSize, visible: CGRect) -> ClosedRange<CGFloat> {
        let w = max(1, size.width), h = max(1, size.height)
        var upper = min(1, Reference.maxFraction * visible.width / w, Reference.maxFraction * visible.height / h)
        upper = max(upper, 0.01)
        let lower = min(upper, Reference.minWidth / w)
        return lower...upper
    }

    /// A new tile's scale: a quarter of the visible width, within bounds.
    static func defaultScale(size: CGSize, visible: CGRect) -> CGFloat {
        let bounds = scaleBounds(size: size, visible: visible)
        return min(max(Reference.widthFraction * visible.width / max(1, size.width), bounds.lowerBound), bounds.upperBound)
    }

    /// The frame at rest in a corner, `Reference.margin` in from its edges.
    static func frame(in corner: Corner, scale: CGFloat, size: CGSize, visible: CGRect) -> PipFrame {
        let r = rect(PipFrame(origin: .zero, scale: scale), size: size)
        let x = corner.isLeft ? visible.minX + Reference.margin : visible.maxX - Reference.margin - r.width
        let y = corner.isTop ? visible.minY + Reference.margin : visible.maxY - Reference.margin - r.height
        return PipFrame(origin: CGPoint(x: x, y: y), scale: scale)
    }

    /// The corner a frame is nearest, by its centre.
    static func corner(of f: PipFrame, size: CGSize, visible: CGRect) -> Corner {
        let r = rect(f, size: size)
        return Corner.nearest(to: CGPoint(x: r.midX, y: r.midY), in: visible)
    }

    /// The corner a dropped tile goes to: the nearest to where its centre is heading, a fling carrying it
    /// `Reference.flingLookahead` seconds on; a slow drop goes to the nearest corner as it is.
    static func corner(for f: PipFrame, velocity: CGVector, size: CGSize, visible: CGRect) -> Corner {
        let r = rect(f, size: size)
        var c = CGPoint(x: r.midX, y: r.midY)
        if hypot(velocity.dx, velocity.dy) >= Reference.flingSpeed {
            c.x += velocity.dx * Reference.flingLookahead
            c.y += velocity.dy * Reference.flingLookahead
        }
        return Corner.nearest(to: c, in: visible)
    }

    /// The side a dropped tile tucks away behind: more than `Reference.tuckThreshold` of its width past
    /// the left or right edge (a fling counted as where it's heading), or nothing.
    static func tuck(of f: PipFrame, velocity: CGVector, size: CGSize, visible: CGRect) -> Side? {
        var r = rect(f, size: size)
        if hypot(velocity.dx, velocity.dy) >= Reference.flingSpeed {
            r = r.offsetBy(dx: velocity.dx * Reference.flingLookahead, dy: 0)
        }
        let over = r.width * Reference.tuckThreshold
        if visible.minX - r.minX > over { return .left }
        if r.maxX - visible.maxX > over { return .right }
        return nil
    }

    /// The frame tucked behind a side: slid off until `Reference.tabWidth` of it is left, at the height
    /// it was dropped at, kept within the visible area top to bottom.
    static func tucked(_ f: PipFrame, behind side: Side, size: CGSize, visible: CGRect) -> PipFrame {
        let r = rect(f, size: size)
        var t = f
        t.origin.x = side == .left ? visible.minX - r.width + Reference.tabWidth : visible.maxX - Reference.tabWidth
        t.origin.y = min(max(f.origin.y, visible.minY + Reference.margin), visible.maxY - Reference.margin - r.height)
        return t
    }

    /// Where a tucked tile comes back to: the corner on its side nearest its height.
    static func untucked(_ f: PipFrame, from side: Side, size: CGSize, visible: CGRect) -> PipFrame {
        let r = rect(f, size: size)
        let top = r.midY < visible.midY
        let corner: Corner = side == .left ? (top ? .topLeft : .bottomLeft) : (top ? .topRight : .bottomRight)
        return frame(in: corner, scale: f.scale, size: size, visible: visible)
    }

    /// The frame moved so its tile is inside the visible area, scale within bounds.
    static func clamped(_ f: PipFrame, size: CGSize, visible: CGRect) -> PipFrame {
        var p = f
        let bounds = scaleBounds(size: size, visible: visible)
        p.scale = min(max(p.scale, bounds.lowerBound), bounds.upperBound)
        let r = rect(p, size: size)
        p.origin.x = min(p.origin.x, visible.maxX - r.width)
        p.origin.y = min(p.origin.y, visible.maxY - r.height)
        p.origin.x = max(p.origin.x, visible.minX)
        p.origin.y = max(p.origin.y, visible.minY)
        return p
    }

    /// A frame being dragged: wherever the pointer takes it, kept within the visible area top to bottom
    /// (a tuck needs it past the side edges).
    static func dragged(_ f: PipFrame, to origin: CGPoint, size: CGSize, visible: CGRect) -> PipFrame {
        var p = f
        p.origin = origin
        let r = rect(p, size: size)
        p.origin.y = min(max(p.origin.y, visible.minY), visible.maxY - r.height)
        return p
    }

    /// The frame resized from `edges` with the pointer at `point`, the aspect kept and the opposite
    /// corner staying put, within the scale bounds. `start` is the frame when the edge was grabbed.
    static func resized(_ start: PipFrame, edges: Resizing.Edges, to point: CGPoint, size: CGSize, visible: CGRect) -> PipFrame {
        let r = rect(start, size: size)
        let anchor = Resizing.anchor(for: edges)
        let fixed = CGPoint(x: r.minX + r.width * anchor.x, y: r.minY + r.height * anchor.y)
        // The width the pointer asks for, from the fixed corner; a top or bottom edge alone asks through the height.
        var width: CGFloat
        if edges.contains(.left) || edges.contains(.right) {
            width = abs(point.x - fixed.x)
        } else {
            width = abs(point.y - fixed.y) * size.width / max(1, size.height)
        }
        if edges.contains(.top) || edges.contains(.bottom), edges.contains(.left) || edges.contains(.right) {
            // A corner: the larger of the two asks, so the tile follows the pointer out.
            width = max(width, abs(point.y - fixed.y) * size.width / max(1, size.height))
        }
        let bounds = scaleBounds(size: size, visible: visible)
        let scale = min(max(width / max(1, size.width), bounds.lowerBound), bounds.upperBound)
        let grown = rect(PipFrame(origin: .zero, scale: scale), size: size)
        let origin = CGPoint(x: fixed.x - grown.width * anchor.x, y: fixed.y - grown.height * anchor.y)
        return PipFrame(origin: origin, scale: scale)
    }

    /// The frame scaled by `factor` about a screen point (what's under the pointer stays there), within bounds.
    static func scaled(_ f: PipFrame, by factor: CGFloat, around point: CGPoint, size: CGSize, visible: CGRect) -> PipFrame {
        let bounds = scaleBounds(size: size, visible: visible)
        let scale = min(max(f.scale * factor, bounds.lowerBound), bounds.upperBound)
        let k = scale / f.scale
        let origin = CGPoint(x: point.x - (point.x - f.origin.x) * k, y: point.y - (point.y - f.origin.y) * k)
        return clamped(PipFrame(origin: origin, scale: scale), size: size, visible: visible)
    }

    /// How the canvas draws the window at its tile from its home (`WindowEffect.Frame`): scaled about its
    /// top-left from the size the camera gives it, and moved from where the camera puts it to the tile. The
    /// real-window renderer folds the same frame into the window's transform.
    static func effect(_ f: PipFrame, worldRect: CGRect, camera: Camera) -> WindowEffect.Frame {
        let screen = camera.toScreen(worldRect)
        let s = f.scale / max(camera.zoom, 0.0001)
        var e = WindowEffect.Frame()
        e.scale = CGSize(width: s, height: s)
        e.anchor = .zero
        e.offset = CGVector(dx: f.origin.x - screen.minX, dy: f.origin.y - screen.minY)
        return e
    }

    /// Where a tile returns to 1:1 (the return button, a double-click): grown about the tile's centre,
    /// kept inside the visible area (at its top-left when bigger than that), on whole pixels.
    static func returnRect(_ f: PipFrame, size: CGSize, visible: CGRect, scale: CGFloat) -> CGRect {
        let r = rect(f, size: size)
        var origin = CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2)
        origin.x = min(origin.x, visible.maxX - size.width)
        origin.y = min(origin.y, visible.maxY - size.height)
        origin.x = max(origin.x, visible.minX)
        origin.y = max(origin.y, visible.minY)
        return CGRect(origin: Handoff.pixelAligned(origin, scale: scale), size: size)
    }

    /// A frame part of the way from one to another, `t` 0...1 (past 1 overshoots, as a spring does).
    static func mix(_ a: PipFrame, _ b: PipFrame, _ t: CGFloat) -> PipFrame {
        PipFrame(origin: CGPoint(x: a.origin.x + (b.origin.x - a.origin.x) * t, y: a.origin.y + (b.origin.y - a.origin.y) * t),
                 scale: a.scale + (b.scale - a.scale) * t)
    }

    /// The tile's chrome, in the tile's own rect: the strip along its top that holds the buttons and takes
    /// the drag, ✕ at its left and the return button at its right, and the tab of a tucked tile.
    struct Chrome {
        let strip: CGRect
        /// The one button, at the strip's left: leave Picture in Picture, the window flies home to the
        /// canvas. A click anywhere else on the tile returns the window to 1:1 where the tile is.
        let home: CGRect
        let tab: CGRect?

        init(tile: CGRect, tucked: Side?, visible: CGRect) {
            let h = min(Reference.stripHeight, tile.height / 2)
            strip = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: h)
            let b = min(Reference.buttonSize, h - 8)
            let inset = (h - b) / 2
            home = CGRect(x: tile.minX + inset, y: tile.minY + inset, width: b, height: b)
            switch tucked {
            case .left: tab = CGRect(x: visible.minX, y: tile.minY, width: Reference.tabWidth, height: tile.height)
            case .right: tab = CGRect(x: visible.maxX - Reference.tabWidth, y: tile.minY, width: Reference.tabWidth, height: tile.height)
            case nil: tab = nil
            }
        }
    }
}
