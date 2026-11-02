import AppKit

/// A map of the canvas in the bottom-right corner: every window and widget as a small shape, each
/// window with its app's icon in the middle, hidden and minimized windows as dashed outlines where
/// they'll come back, the desktop's files as a faint patch under them, the screen as an outline. Click to look there, drag to pan. The zoom readout, Fit (what the
/// four-finger tap does) and 1:1 run along the bottom. Canvas › Minimap hides it.
@MainActor
final class MinimapPanel: NSView {
    static let size = NSSize(width: 200, height: 125)
    static let margin: CGFloat = 12

    private weak var canvas: CanvasView?
    private let map: MinimapView
    private let zoom = Chrome.label(size: 10, color: Chrome.inkSecondary, digits: true)
    private let fit: GlyphButton
    private let oneToOne: GlyphButton

    init(canvas: CanvasView) {
        self.canvas = canvas
        map = MinimapView(canvas: canvas)
        fit = GlyphButton(symbol: "arrow.down.right.and.arrow.up.left", pointSize: 9, size: 20)
        oneToOne = GlyphButton(symbol: "1.magnifyingglass", pointSize: 10, size: 20)
        super.init(frame: NSRect(origin: .zero, size: MinimapPanel.size))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Chrome.card.cgColor
        layer?.cornerRadius = Chrome.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Chrome.hairline.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        Chrome.glass(behind: self, radius: Chrome.cardRadius)

        let s = MinimapPanel.size
        map.frame = bounds
        map.autoresizingMask = [.width, .height]
        addSubview(map)

        zoom.frame = NSRect(x: 10, y: s.height - 22, width: 60, height: 13)
        addSubview(zoom)

        oneToOne.frame.origin = CGPoint(x: s.width - 8 - 20, y: s.height - 8 - 20)
        fit.frame.origin = CGPoint(x: oneToOne.frame.minX - 2 - 20, y: oneToOne.frame.minY)
        fit.toolTip = "Fit everything"
        oneToOne.toolTip = "1:1"
        fit.action = { [weak self] in self?.canvas?.fitAll(animated: true) }
        map.onBringBack = { [weak self] p in self?.onBringBack?(p) }
        oneToOne.action = { [weak self] in self?.zoomToActual() }
        addSubview(fit)
        addSubview(oneToOne)
        redraw()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A click on a hidden or minimized window's dashed outline: bring it back and go into it.
    var onBringBack: ((WindowProxy) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Chrome.cardRadius, cornerHeight: Chrome.cardRadius, transform: nil)
    }

    /// The camera moved, or what's on the canvas changed.
    func redraw() {
        map.update()
        guard let c = canvas else { return }
        let readout = String(format: "%.0f%%", c.camera.zoom * 100)
        if zoom.stringValue != readout { zoom.stringValue = readout }
    }

    /// Whether the card belongs on screen: the setting is on and the canvas is what you're looking at,
    /// not a window (or the flight into one), another app, the desktop, or Sunlight switched off.
    nonisolated static func belongs(setting: Bool, inCanvas: Bool, showingDesktop: Bool, paused: Bool) -> Bool {
        setting && inCanvas && !showingDesktop && !paused
    }

    /// Shows or hides the card with a quick pop about its centre: in from 90% past full size and back
    /// (0.18 s), out to 90% (0.1 s); a plain fade under Reduce Motion. Toggling again mid-way starts
    /// from wherever the card is on screen.
    func setShown(_ shown: Bool, animated: Bool = true) {
        guard let layer else { isHidden = !shown; return }
        let from = layer.presentation()
        let fromOpacity = isHidden ? 0 : (from?.opacity ?? layer.opacity)
        let fromTransform = isHidden ? hiddenTransform : (from?.transform ?? CATransform3DIdentity)
        transition += 1
        let current = transition
        layer.removeAnimation(forKey: "minimap.show")
        if shown { isHidden = false }
        guard animated else {
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            isHidden = !shown
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.transition == current, !shown else { return }
                self.isHidden = true
                self.layer?.opacity = 1
                self.layer?.transform = CATransform3DIdentity
            }
        }
        let duration: CFTimeInterval = shown ? 0.18 : 0.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = shown ? 1 : 0
        fade.duration = shown ? duration * 0.6 : duration
        fade.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
        let scale = CAKeyframeAnimation(keyPath: "transform")
        if shown {
            // Just past full size, then settles: the pop.
            scale.values = [fromTransform, transform(scale: 1.03), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            scale.keyTimes = [0, 0.6, 1]
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        } else {
            scale.values = [fromTransform, hiddenTransform].map { NSValue(caTransform3D: $0) }
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        scale.duration = duration
        let group = CAAnimationGroup()
        group.animations = reduceMotion ? [fade] : [fade, scale]
        group.duration = duration
        layer.opacity = shown ? 1 : 0
        layer.transform = shown ? CATransform3DIdentity : hiddenTransform
        layer.add(group, forKey: "minimap.show")
        CATransaction.commit()
    }

    /// Bumped on every show or hide, so a hide that was overtaken doesn't hide the card when it ends.
    private var transition = 0

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 90% about the centre: a small pop, not a zoom.
    private var hiddenTransform: CATransform3D {
        reduceMotion ? CATransform3DIdentity : transform(scale: 0.9)
    }

    /// Scaled about the centre (the layer's anchor is its corner).
    private func transform(scale: CGFloat) -> CATransform3D {
        let w = bounds.width / 2, h = bounds.height / 2
        var t = CATransform3DMakeTranslation(w, h, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -w, -h, 0)
    }

    private func zoomToActual() {
        guard let c = canvas else { return }
        c.animateCamera(to: Camera(center: c.camera.center(viewSize: c.bounds.size), zoom: 1, viewSize: c.bounds.size))
        c.noteUserMove()   // nearly on a full screen window, it snaps onto it
    }
}

/// The map and the pointer: the world fitted into the card, windows and widgets as small layers, the
/// viewport as an outline. Layers, not a drawing: the camera moves the outline and (when the world's
/// bounds change) the marks many times a second, and moving layers costs nothing, where redrawing the
/// card with CoreGraphics on every tick did. A press pans the viewport with the pointer; a click
/// without a drag flies the camera there, or, on a dashed outline, brings that window back.
@MainActor
final class MinimapView: NSView {
    private weak var canvas: CanvasView?
    /// Room at the bottom for the readout and the buttons.
    private static let insets = NSEdgeInsets(top: 10, left: 10, bottom: 30, right: 10)

    private struct Mapping: Equatable {
        let scale: CGFloat
        let origin: CGPoint
        func toMap(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + origin.x, y: p.y * scale + origin.y) }
        func toMap(_ r: CGRect) -> CGRect { CGRect(origin: toMap(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale)) }
        func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    }

    /// A press: the mapping is frozen for the drag so the map doesn't slide under the pointer.
    private var press: (point: CGPoint, mapping: Mapping, moved: Bool)?
    var onBringBack: ((WindowProxy) -> Void)?
    /// App icons by process, as layer contents: looked up once.
    private var icons: [pid_t: CGImage] = [:]
    /// The largest an icon is drawn, and the smallest worth drawing (points on the card).
    private static let iconSize: CGFloat = 14
    private static let minIconSize: CGFloat = 6

    /// One window or widget on the map: its shape (a filled rounded rect, or a dashed outline for a
    /// window that's away) and its app's icon.
    private final class Mark {
        let shape = CALayer()
        let outline = CAShapeLayer()
        let icon = CALayer()
        var away = false
        /// The pole the shape is tinted with (`Polarity`); nil for plain white.
        var pole: Polarity?
        var outlineSize = CGSize.zero
        var pid: pid_t = 0

        init() {
            for l in [shape, outline, icon] {
                l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(),
                             "contents": NSNull(), "opacity": NSNull(), "path": NSNull(), "backgroundColor": NSNull()]
            }
            shape.cornerRadius = 2
            outline.fillColor = nil
            outline.lineWidth = 1
            outline.lineDashPattern = [3, 2]
            outline.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
            icon.contentsGravity = .resizeAspect
            icon.minificationFilter = .trilinear
            shape.addSublayer(outline)
            shape.addSublayer(icon)
        }
    }
    private var marks: [ObjectIdentifier: Mark] = [:]
    /// The marks' order last applied, bottom to top: present proxies, then the away ones.
    private var order: [ObjectIdentifier] = []
    private let viewportLayer = CALayer()
    /// The desktop's files, under everything.
    private let filesLayer = CALayer()

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        filesLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        filesLayer.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        filesLayer.borderColor = NSColor(white: 1, alpha: 0.3).cgColor
        filesLayer.borderWidth = 1
        filesLayer.cornerRadius = 2
        filesLayer.zPosition = -1
        layer?.addSublayer(filesLayer)
        viewportLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "borderColor": NSNull()]
        viewportLayer.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        viewportLayer.borderColor = Chrome.ink.cgColor
        viewportLayer.borderWidth = 1
        viewportLayer.cornerRadius = 2
        viewportLayer.zPosition = 2
        layer?.addSublayer(viewportLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        icons.removeAll()   // drawn for the old scale
        for m in marks.values {
            m.icon.contentsScale = scale
            m.outline.contentsScale = scale
            if m.icon.contents != nil { m.icon.contents = icon(for: m.pid) }
        }
    }

    override func layout() {
        super.layout()
        update()
    }

    private var viewport: CGRect? {
        guard let canvas else { return nil }
        return canvas.camera.toWorld(CGRect(origin: .zero, size: canvas.bounds.size))
    }

    /// Fits the union of everything on the canvas and the viewport, with a little air, into the card.
    private func mapping() -> Mapping? {
        guard let canvas, let viewport else { return nil }
        var world = viewport
        for p in canvas.proxies + canvas.away { world = world.union(p.worldRect) }
        if let files = canvas.desktopFilesRect { world = world.union(files) }
        world = world.insetBy(dx: -world.width * 0.04, dy: -world.height * 0.04)
        let i = MinimapView.insets
        let available = CGRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        guard world.width > 0, world.height > 0, available.width > 0, available.height > 0 else { return nil }
        let scale = min(available.width / world.width, available.height / world.height)
        let origin = CGPoint(x: available.midX - world.midX * scale, y: available.midY - world.midY * scale)
        return Mapping(scale: scale, origin: origin)
    }

    /// The camera moved, or what's on the canvas changed: every mark and the outline where they belong
    /// now. A layer whose frame hasn't changed isn't touched.
    func update() {
        guard let canvas, let viewport, let m = press?.mapping ?? mapping() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var seen = Set<ObjectIdentifier>()
        var wanted: [ObjectIdentifier] = []
        for (p, away) in canvas.proxies.map({ ($0, false) }) + canvas.away.map({ ($0, true) }) {
            let id = ObjectIdentifier(p)
            seen.insert(id)
            wanted.append(id)
            let mark = marks[id] ?? makeMark(for: p)
            marks[id] = mark
            // A tile's home is drawn as an away window's: the window is in a corner of the screen, not there.
            place(mark, for: p, away: away || p.pip != nil, in: m.toMap(p.worldRect).insetBy(dx: 0.5, dy: 0.5))
        }
        for (id, mark) in marks where !seen.contains(id) {
            mark.shape.removeFromSuperlayer()
            marks[id] = nil
        }
        if wanted != order {
            // Bottom to top, as the canvas stacks them; away windows over the rest, since a hidden
            // window's place is often under the windows that stayed.
            order = wanted
            for id in wanted { if let mark = marks[id] { layer?.addSublayer(mark.shape) } }
        }
        placeHulls(m, canvas: canvas)
        let files = canvas.desktopFilesRect.map { m.toMap($0).insetBy(dx: 0.5, dy: 0.5) }
        if filesLayer.isHidden != (files == nil) { filesLayer.isHidden = files == nil }
        if let files, filesLayer.frame != files { filesLayer.frame = files }
        let v = m.toMap(viewport).insetBy(dx: 0.5, dy: 0.5)
        if viewportLayer.frame != v { viewportLayer.frame = v }
    }

    private func makeMark(for p: WindowProxy) -> Mark {
        let mark = Mark()
        mark.pid = p.pid
        let scale = window?.backingScaleFactor ?? 2
        mark.icon.contentsScale = scale
        mark.outline.contentsScale = scale
        if p.kind == .window { mark.icon.contents = icon(for: p.pid) }
        return mark
    }

    private func place(_ mark: Mark, for p: WindowProxy, away: Bool, in r: CGRect) {
        let visible = r.width > 1 && r.height > 1
        if mark.shape.isHidden == visible { mark.shape.isHidden = !visible }
        guard visible else { return }
        if mark.shape.frame != r { mark.shape.frame = r }
        let pole = p.showsPolarity ? p.polarity : nil
        if mark.away != away || mark.pole != pole || (mark.shape.backgroundColor == nil && !away) {
            mark.away = away
            mark.pole = pole
            // A window's pole tints it; otherwise the plain white of a window or a widget.
            let fill = pole.map { $0.tint.withAlphaComponent(0.6) } ?? NSColor(white: 1, alpha: p.kind == .window ? 0.35 : 0.2)
            mark.shape.backgroundColor = away ? nil : fill.cgColor
            mark.outline.isHidden = !away
            mark.icon.opacity = away ? 0.55 : 1
            mark.shape.zPosition = away ? 1 : 0
        }
        let size = CGSize(width: r.width, height: r.height)
        if away, mark.outlineSize != size {
            mark.outlineSize = size
            mark.outline.frame = CGRect(origin: .zero, size: size)
            mark.outline.path = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 2, cornerHeight: 2, transform: nil)
        }
        // The app's icon, centred, as large as `iconSize` but never more than most of the window's shape.
        let side = min(MinimapView.iconSize, r.width - 4, r.height - 4)
        let showIcon = p.kind == .window && side >= MinimapView.minIconSize
        if mark.icon.isHidden == showIcon { mark.icon.isHidden = !showIcon }
        if showIcon {
            let frame = CGRect(x: ((r.width - side) / 2).rounded(), y: ((r.height - side) / 2).rounded(), width: side, height: side)
            if mark.icon.frame != frame { mark.icon.frame = frame }
        }
    }

    /// A hairline around each bonded group (`Grouping`), so it reads as the one shape it moves as; by
    /// group number.
    private var hulls: [Int: CAShapeLayer] = [:]

    private func placeHulls(_ m: Mapping, canvas: CanvasView) {
        var unions: [Int: (rect: CGRect, count: Int)] = [:]
        for p in canvas.proxies where p.showsPolarity {
            guard let g = canvas.grouping.group(of: p.windowID) else { continue }
            if let u = unions[g] {
                unions[g] = (u.rect.union(p.worldRect), u.count + 1)
            } else {
                unions[g] = (p.worldRect, 1)
            }
        }
        let groups = unions.filter { $0.value.count > 1 }
        for (g, hull) in hulls where groups[g] == nil {
            hull.removeFromSuperlayer()
            hulls[g] = nil
        }
        for (g, u) in groups {
            let hull = hulls[g] ?? makeHull()
            hulls[g] = hull
            let r = m.toMap(u.rect).insetBy(dx: -1.5, dy: -1.5)
            if hull.frame != r {
                hull.frame = r
                hull.path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: 3, cornerHeight: 3, transform: nil)
            }
            if hull.superlayer == nil { layer?.addSublayer(hull) }
        }
    }

    private func makeHull() -> CAShapeLayer {
        let hull = CAShapeLayer()
        hull.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "path": NSNull()]
        hull.fillColor = nil
        hull.lineWidth = 1
        hull.strokeColor = NSColor(white: 1, alpha: 0.7).cgColor
        hull.contentsScale = window?.backingScaleFactor ?? 2
        hull.zPosition = 0.5   // over the windows' shapes, under the dashed outlines of those away
        return hull
    }

    private func icon(for pid: pid_t) -> CGImage? {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
        let scale = window?.backingScaleFactor ?? 2
        guard let cg = image.bitmap(pixels: Int((MinimapView.iconSize * scale).rounded(.up))) else { return nil }
        if icons.count > 64 { icons.removeAll() }   // apps come and go; a few dozen are on screen at most
        icons[pid] = cg
        return cg
    }

    override func mouseDown(with event: NSEvent) {
        guard let m = mapping() else { return }
        canvas?.cancelAnimation()
        press = (convert(event.locationInWindow, from: nil), m, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var p = press, let canvas else { return }
        let now = convert(event.locationInWindow, from: nil)
        if !p.moved {
            guard hypot(now.x - p.point.x, now.y - p.point.y) >= CanvasView.dragSlop else { return }
            p.moved = true
        }
        var camera = canvas.camera
        camera.origin.x += (now.x - p.point.x) / p.mapping.scale
        camera.origin.y += (now.y - p.point.y) / p.mapping.scale
        canvas.set(camera: camera)
        p.point = now
        press = p
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        guard let p = press, let canvas else { return }
        if p.moved {
            press = nil
            update()   // the frozen mapping goes; the map settles to the new world bounds
            canvas.noteUserMove()   // let go nearly on a full screen window, it snaps onto it
            return
        }
        let target = p.mapping.toWorld(convert(event.locationInWindow, from: nil))
        // On a hidden or minimized window's outline: that window, back. The last drawn is on top.
        if let away = canvas.away.last(where: { $0.worldRect.contains(target) }) {
            onBringBack?(away)
            return
        }
        // A click: look there, at the same zoom.
        canvas.animateCamera(to: Camera(center: target, zoom: canvas.camera.zoom, viewSize: canvas.bounds.size))
        canvas.noteUserMove()
    }
}
