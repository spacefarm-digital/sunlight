import CoreGraphics

/// A camera nearly aligned with a window can nudge the remaining distance to its 1:1 placement.
/// Normal keeps the original screen-sized-only behavior; strong also accepts smaller windows and
/// increases the reach. Candidate arithmetic is independent of the controller and view.
enum WindowSnap {
    /// A window at least this share of the visible area, each way, counts as screen-sized.
    static let fill: CGFloat = 0.9
    /// How far each edge may be from its destination, as a share of the view's dimensions.
    static let normalReach: CGFloat = 0.05
    static let strongReach: CGFloat = 0.15
    /// Never less than this, in screen points, however small the screen.
    static let minReach: CGFloat = 32
    /// The nudge's spring: quicker and stiffer than a flight's (0.45 s, 0.72), overshooting by about 1 %.
    static let response: CGFloat = 0.24
    static let damping: CGFloat = 0.82

    enum Strength {
        case normal, strong
    }

    /// A window that could be snapped to: its rect in the world, and where its top-left corner sits on
    /// screen (view coordinates, top-left origin) once it's entered at 1:1.
    struct Window {
        let rect: CGRect
        let spot: CGPoint
    }

    static func isScreenSized(_ size: CGSize, visible: CGSize) -> Bool {
        size.width >= visible.width * fill && size.height >= visible.height * fill
    }

    /// Keep the author's reach at 100%, but make each slider step have a stronger effect.
    private static func sensitivityGain(_ sensitivity: CGFloat) -> CGFloat {
        let bounded = min(4, max(0.5, sensitivity))
        return bounded * bounded
    }

    /// The closest eligible window and its 1:1 camera. Equal distances are resolved by world geometry,
    /// rather than the order in which windows happened to be listed.
    static func target(camera: Camera, viewSize: CGSize, visible: CGRect, windows: [Window],
                       strength: Strength = .normal, sensitivity: CGFloat = 1,
                       requireCenterInside: Bool = false, panStart: Camera? = nil) -> (index: Int, camera: Camera)? {
        let reach: CGFloat
        switch strength {
        case .normal: reach = normalReach
        case .strong: reach = strongReach
        }
        let gain = sensitivityGain(sensitivity)
        let rx = max(minReach, viewSize.width * reach) * gain, ry = max(minReach, viewSize.height * reach) * gain
        var best: (index: Int, camera: Camera, off: CGFloat, rect: CGRect, spot: CGPoint)?
        for (i, w) in windows.enumerated() {
            // At 100%, normal mode retains the author's screen-sized-window rule. Raising the
            // sensitivity gradually admits smaller windows too, so its extra reach is useful there.
            let minimumFill = fill / max(1, gain)
            guard w.rect.width > 0, w.rect.height > 0,
                  strength != .normal || (w.rect.width >= visible.width * minimumFill &&
                                          w.rect.height >= visible.height * minimumFill) else { continue }
            let now = camera.toScreen(w.rect)
            if requireCenterInside && !now.contains(CGPoint(x: visible.midX, y: visible.midY)) { continue }
            if let panStart {
                let midpoint = CGPoint(x: visible.midX, y: visible.midY)
                let start = panStart.toWorld(midpoint)
                let end = camera.toWorld(midpoint)
                if w.rect.contains(start) {
                    let before = hypot(start.x - w.rect.midX, start.y - w.rect.midY)
                    let after = hypot(end.x - w.rect.midX, end.y - w.rect.midY)
                    if after > before + 1 { continue }
                }
            }
            let intersection = now.intersection(visible)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let destination = Camera(origin: CGPoint(x: w.rect.minX - w.spot.x, y: w.rect.minY - w.spot.y), zoom: 1)
            let off: CGFloat
            if strength == .normal {
                let then = CGRect(origin: w.spot, size: w.rect.size)
                let dx = max(abs(now.minX - then.minX), abs(now.maxX - then.maxX))
                let dy = max(abs(now.minY - then.minY), abs(now.maxY - then.maxY))
                guard dx <= rx, dy <= ry else { continue }
                off = dx / rx + dy / ry
            } else {
                let currentCenter = camera.toWorld(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
                let destinationCenter = destination.toWorld(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
                let dx = abs(currentCenter.x - destinationCenter.x) * camera.zoom
                let dy = abs(currentCenter.y - destinationCenter.y) * camera.zoom
                let visibleFraction = intersection.width * intersection.height / (now.width * now.height)
                // Bound travel in world points as well as screen points, so a zoomed-out overview
                // cannot pull in a window that is visually nearby but far away on the canvas.
                let scale = min(camera.zoom, 1)
                guard scale > 0, dx <= rx * scale, dy <= ry * scale, visibleFraction >= 0.25 else { continue }
                let windowCenterX = abs(now.midX - visible.midX) / max(visible.width, 1)
                let windowCenterY = abs(now.midY - visible.midY) / max(visible.height, 1)
                off = dx / rx + dy / ry + windowCenterX + windowCenterY + (1 - visibleFraction)
            }
            if let best {
                let rect = w.rect, previous = best.rect
                let geometry = (rect.minX, rect.minY, rect.width, rect.height, w.spot.x, w.spot.y)
                let prior = (previous.minX, previous.minY, previous.width, previous.height, best.spot.x, best.spot.y)
                guard off < best.off || (off == best.off && geometry < prior) else { continue }
            }
            best = (i, Camera(origin: CGPoint(x: w.rect.minX - w.spot.x, y: w.rect.minY - w.spot.y), zoom: 1), off, w.rect, w.spot)
        }
        return best.map { ($0.index, $0.camera) }
    }

    /// Directional navigation chooses the next window immediately, even if the release happened in a
    /// gap. Free pan only snaps when the release itself is over an eligible window.
    static func releaseTarget(camera: Camera, viewSize: CGSize, visible: CGRect, windows: [Window],
                              strength: Strength, sensitivity: CGFloat, panStart: Camera?,
                              direction: CGVector? = nil, preferredIndex: Int? = nil, allowFallback: Bool = true)
        -> (index: Int, camera: Camera, directional: Bool)? {
        // A zoomed-out canvas is an overview: panning it must never enter a window on release.
        // Keep this check here so both directional navigation and ordinary release snap respect it.
        guard camera.zoom >= 1 - 0.001 else { return nil }
        if let panStart, let direction,
           let next = neighbour(from: panStart, viewSize: viewSize, windows: windows,
                                direction: direction, preferredIndex: preferredIndex, sensitivity: sensitivity) {
            return (next.index, next.camera, true)
        }
        guard allowFallback else { return nil }
        guard let hit = target(camera: camera, viewSize: viewSize, visible: visible, windows: windows,
                               strength: strength, sensitivity: sensitivity, requireCenterInside: true,
                               panStart: panStart) else { return nil }
        return (hit.index, hit.camera, false)
    }

    /// Step from the window nearest the gesture's starting camera to a neighbour in the camera's
    /// travel direction. Bounds are in world points, so zooming out cannot capture distant windows.
    static func neighbour(from start: Camera, viewSize: CGSize, windows: [Window],
                          direction: CGVector, preferredIndex: Int? = nil,
                          sensitivity: CGFloat = 1) -> (index: Int, camera: Camera)? {
        let gain = sensitivityGain(sensitivity)
        guard viewSize.width > 0, viewSize.height > 0,
              hypot(direction.dx, direction.dy) >= 18 / gain else { return nil }
        let center = start.center(viewSize: viewSize)
        func targetCenter(_ w: Window) -> CGPoint {
            CGPoint(x: w.rect.minX - w.spot.x + viewSize.width / 2,
                    y: w.rect.minY - w.spot.y + viewSize.height / 2)
        }
        var anchor: (index: Int, score: CGFloat, x: CGFloat, y: CGFloat)?
        for (i, w) in windows.enumerated() where w.rect.width > 0 && w.rect.height > 0 {
            let p = targetCenter(w)
            let dx = abs(p.x - center.x) / viewSize.width
            let dy = abs(p.y - center.y) / viewSize.height
            guard dx <= 0.75 * gain, dy <= 0.75 * gain else { continue }
            let candidate = (dx * dx + dy * dy, p.x, p.y)
            if let a = anchor, candidate >= (a.score, a.x, a.y) { continue }
            anchor = (i, candidate.0, p.x, p.y)
        }
        // Tiled windows can share an identical camera target. When returning from a real window,
        // retain that window as the anchor rather than picking another tile by array order.
        if let i = preferredIndex, windows.indices.contains(i) {
            let w = windows[i]
            let target = Camera(origin: CGPoint(x: w.rect.minX - w.spot.x, y: w.rect.minY - w.spot.y), zoom: 1)
            if w.rect.width > 0, w.rect.height > 0, start.isClose(to: target) {
                let p = targetCenter(w)
                anchor = (i, 0, p.x, p.y)
            }
        }
        guard let anchor else { return nil }
        let anchorRect = windows[anchor.index].rect
        let horizontal = abs(direction.dx) >= abs(direction.dy)
        let sign: CGFloat = (horizontal ? direction.dx : direction.dy) >= 0 ? 1 : -1
        let alongLimit = (horizontal ? viewSize.width : viewSize.height) * 1.5 * gain
        let acrossLimit = (horizontal ? viewSize.height : viewSize.width) * 0.75 * gain
        var best: (index: Int, score: CGFloat, x: CGFloat, y: CGFloat)?
        for (i, w) in windows.enumerated() where i != anchor.index && w.rect.width > 0 && w.rect.height > 0 {
            let p = CGPoint(x: w.rect.midX, y: w.rect.midY)
            // Geometry, not camera destinations: tiles in the same area can share one destination.
            let dx = w.rect.midX - anchorRect.midX, dy = w.rect.midY - anchorRect.midY
            let along = (horizontal ? dx : dy) * sign
            let across = abs(horizontal ? dy : dx)
            guard along > 1, along <= alongLimit, across <= acrossLimit else { continue }
            let candidate: (CGFloat, CGFloat, CGFloat) = (along / alongLimit + across / acrossLimit, p.x, p.y)
            if let b = best, candidate >= (b.score, b.x, b.y) { continue }
            best = (i, candidate.0, p.x, p.y)
        }
        guard let best else { return nil }
        let w = windows[best.index]
        return (best.index, Camera(origin: CGPoint(x: w.rect.minX - w.spot.x, y: w.rect.minY - w.spot.y), zoom: 1))
    }
}
