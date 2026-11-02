import CoreGraphics

/// The geometry of entering a window, and of a window's native place in general, as pure functions.
///
/// One invariant holds the canvas and the desktop together: at 1:1 every window sits natively where
/// the canvas draws it, `native == toScreen(worldRect)`, to the pixel and no higher than macOS lets
/// a window go (its top stays below the menu bar). The seam, the windows kept on show around the
/// entered one, the entered app's siblings and the placement check all used to work that out for
/// themselves, each with its own rounding; `nativeOrigin` is the one place it's worked out now.
///
/// Entering a window is the same move the other way round: the camera goes to the window, not the
/// window to the camera. `plan` says where the window will sit on screen at 1:1 and which camera puts
/// it there; the controller flies the camera and commits the native position at the seam.
enum Handoff {
    /// How a window is entered.
    enum Placement {
        /// In the middle of the visible area (a double-click, ⏎, the switcher).
        case centered
        /// Where the proxy already is (a pinch). At 1:1 nothing moves; zoomed out it grows to
        /// 1:1 down from its top edge, the point's x staying under the pointer.
        case inPlace(around: CGPoint)
        /// A click on the proxy at `offset` inside it (world units, which are the real window's points):
        /// it grows to 1:1 around the clicked spot, which stays under the pointer as far as the screen allows.
        case clicked(at: CGPoint, offset: CGPoint)
    }

    /// Where the window goes and how the camera gets there. All in view coordinates (the display's
    /// top-left at zero), points.
    struct Plan: Equatable {
        /// The window's top-left on screen at 1:1: pixel-aligned, and no higher than the menu bar lets it.
        let origin: CGPoint
        /// The 1:1 camera that shows the window at `origin`.
        let camera: Camera
        /// For a window that keeps its place (in place, clicked, tiled): the 1:1 camera at which it
        /// sits exactly where it is, before the menu bar had its say. In capture mode the camera ends
        /// there and the window eases to where it landed, so nothing else on the canvas moves.
        let inPlace: Camera?
        /// Where the window would sit at `inPlace`, before the menu bar had its say (`origin` when it
        /// didn't). In capture mode a window the menu bar pushed down keeps its place on the canvas and
        /// the camera settles at `camera` instead.
        let inPlaceOrigin: CGPoint
        /// Entered by a click: the way in lasts at least a double-click, so a second click lands on
        /// the canvas, not on the real window.
        let clicked: Bool
    }

    /// Where `rect` (the window's world rect) sits on screen at 1:1 for `placement`, and the camera
    /// that puts it there. `camera` is the canvas's camera now; `visible` the display's visible part
    /// in view coordinates; `tiledArea` the area the window is tiled in, if any: a tiled window keeps
    /// its place in its area and the camera lines up with the area, so the screen shows a tiled desktop.
    static func plan(_ placement: Placement, rect: CGRect, camera: Camera, visible: CGRect, scale: CGFloat,
                     tiledArea: CGRect? = nil) -> Plan {
        var origin: CGPoint
        var keepsPlace = false
        var clicked = false
        switch placement {
        case .centered:
            origin = centredOrigin(of: rect, in: visible)
        case .inPlace(let point):
            // The point's x stays under the pointer and the title bar stays at the height it is on screen
            // now: zoomed out, the window grows down from its top edge; at 1:1 nothing moves.
            origin = CGPoint(x: rect.minX - camera.toWorld(point).x + point.x, y: camera.toScreen(rect.origin).y)
            keepsPlace = true
        case .clicked(let point, let offset):
            origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            keepsPlace = true
            clicked = true
        }
        if let area = tiledArea {
            origin = CGPoint(x: visible.minX + rect.minX - area.minX, y: visible.minY + rect.minY - area.minY)
            keepsPlace = true
        }
        origin = pixelAligned(origin, scale: scale)
        let inPlace = keepsPlace ? Camera(origin: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y), zoom: 1) : nil
        let inPlaceOrigin = origin
        // macOS keeps every window's top below the menu bar; asking for higher lands it right there.
        origin.y = max(visible.minY, origin.y)
        let target = Camera(origin: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y), zoom: 1)
        return Plan(origin: origin, camera: target, inPlace: inPlace, inPlaceOrigin: inPlaceOrigin, clicked: clicked)
    }

    /// Where a window entered in the middle sits on screen: centred in the visible area, or at its
    /// top-left when it's bigger than that.
    static func centredOrigin(of rect: CGRect, in visible: CGRect) -> CGPoint {
        var origin = CGPoint(x: visible.midX - rect.width / 2, y: visible.midY - rect.height / 2)
        if rect.width > visible.width { origin.x = visible.minX }
        if rect.height > visible.height { origin.y = visible.minY }
        return origin
    }

    /// Where a window sits natively when the canvas is at `camera`: its canvas place through the
    /// camera, to the pixel, and no higher than the menu bar lets it. In view coordinates; the
    /// controller adds the display's origin for the window server.
    /// - `worldOrigin`: the window's top-left on the canvas (a widget's card less its margin).
    /// - `top`: the visible area's top in view coordinates (the menu bar's height).
    /// `clamped`: kept below the menu bar, for the window being entered (AppKit keeps an active
    /// window's top there). The window server itself takes any position, so a window kept on show or
    /// aligned beside the entered one goes exactly where the canvas draws it, above the screen's top
    /// included: clamped, a kept window whose canvas place was above the screen landed at the menu
    /// bar, over the window just entered.
    static func nativeOrigin(of worldOrigin: CGPoint, at camera: Camera, scale: CGFloat, top: CGFloat, clamped: Bool = true) -> CGPoint {
        var origin = pixelAligned(camera.toScreen(worldOrigin), scale: scale)
        if clamped { origin.y = max(top, origin.y) }
        return origin
    }

    /// The 1:1 camera at which a world rect sits exactly over a frame in view coordinates.
    static func cameraAligning(_ rect: CGRect, with frame: CGRect) -> Camera {
        Camera(origin: CGPoint(x: rect.minX - frame.minX, y: rect.minY - frame.minY), zoom: 1)
    }

    /// The 1:1 camera at which the world point under `point` (view coordinates) at `camera` is still
    /// under it: a window's native place that puts the spot the pointer is on, on the drawn window,
    /// under the pointer on the real one.
    static func cameraFixing(_ point: CGPoint, at camera: Camera) -> Camera {
        let world = camera.toWorld(point)
        return Camera(origin: CGPoint(x: world.x - point.x, y: world.y - point.y), zoom: 1)
    }

    /// Rounded to the pixel grid at `scale`, so a window lands on whole pixels and no edge is drawn soft.
    static func pixelAligned(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x * scale).rounded() / scale, y: (p.y * scale).rounded() / scale)
    }
}
