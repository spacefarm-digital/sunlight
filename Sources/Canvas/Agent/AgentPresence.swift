import AppKit
import QuartzCore

/// What Tell Sunlight is doing, shown on screen: its own pointer, which glides to each control before
/// it's pressed, typed into or scrolled, with a ripple on the press, an outline on the control, a bubble
/// with what it types, a scan line while it reads a window, an outline on the window it works in, and a
/// soft glow along the screen edges for as long as a request runs.
///
/// It's only a picture. Tell Sunlight acts through accessibility (`AppReader`), never with the user's
/// pointer or keyboard, so nothing here moves the real pointer or takes a click: the overlay panels let
/// every event through, and the actions run exactly as they would with this off
/// (Settings › Experimental › Tell Sunlight › Show what it's doing).
///
/// The pointer is attached to a spot on a window, not to a screen point: every frame it asks the canvas
/// where that window is drawn now (`CanvasController.agentDrawn`), so it rides along with a glide, a
/// camera move or a zoom. A window out of view isn't brought into view (the user keeps the camera): the
/// pointer waits at the edge of the screen, pointing towards it.
@MainActor
final class AgentPresence: NSObject {
    /// A place on a window: a fraction of its drawn size, plus window points (scaled with it) from there.
    struct Spot: Equatable {
        let window: CGWindowID
        var unit: CGPoint
        var offset: CGPoint = .zero
    }

    /// Where on a window the pointer takes hold for a canvas command.
    enum Grip {
        case titleBar, corner, close, minimize, center

        var unit: CGPoint {
            switch self {
            case .titleBar: CGPoint(x: 0.5, y: 0)
            case .corner: CGPoint(x: 1, y: 1)
            case .close, .minimize: .zero
            case .center: CGPoint(x: 0.5, y: 0.5)
            }
        }

        /// Window points from `unit`: the title bar's middle, just inside the corner, the traffic lights.
        var offset: CGPoint {
            switch self {
            case .titleBar: CGPoint(x: 0, y: 15)
            case .corner: CGPoint(x: -7, y: -7)
            case .close: CGPoint(x: 20, y: 16)
            case .minimize: CGPoint(x: 40, y: 16)
            case .center: .zero
            }
        }
    }

    /// What a press looks like once the pointer is there.
    enum Press: Equatable {
        case click
        case typed(String)
        case returnKey
        case chose(String)
        case scrolled(down: Bool)
        case failed
    }

    /// The little picture in the pointer's tag, saying what it's doing.
    enum Badge: String {
        case none = ""
        case reading = "eye.fill"
        case moving = "hand.raised.fill"
        case typing = "keyboard"
        case asking = "questionmark"
        case scrollDown = "chevron.down"
        case scrollUp = "chevron.up"
    }

    private let desk: Desk
    /// The user turned it off: nothing is drawn and nothing waits.
    private var isOn: Bool { Settings.tellSunlightPresence }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A request is running.
    private(set) var active = false
    private var panels: [PresencePanel] = []
    private var link: CADisplayLink?
    /// Until when the frame loop has to keep running after `end` (the fades).
    private var lingerUntil: CFTimeInterval = 0

    // The pointer.
    private var anchor: Spot?
    /// Where the pointer is drawn now, global points (top-left origin); nil before it first shows.
    private var pointer: CGPoint?
    /// Where the request started (under the bar): the first flight leaves from there.
    private var home: CGPoint?
    private var flight: (from: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)?
    private var badge: Badge = .none
    /// Counts requests and badges, so a delayed fade or badge reset left from an earlier one does nothing.
    private var generation = 0
    private var badgeGeneration = 0
    /// After `end`: things keep tracking their windows until this, then fade with the glow.
    private var fadeAt: CFTimeInterval = 0

    // Around it.
    /// The control about to be acted on, as a fraction of its window, until `outlineUntil`.
    private var outline: (window: CGWindowID, unit: CGRect)?
    private var outlineUntil: CFTimeInterval = 0
    /// The window the work is in.
    private var working: CGWindowID?
    private var scan: (window: CGWindowID, start: CFTimeInterval)?
    /// Typed words beside the pointer, revealed over `duration`, gone at `until`.
    private var bubble: (text: String, start: CFTimeInterval, duration: CFTimeInterval, until: CFTimeInterval)?

    init(desk: Desk) {
        self.desk = desk
        super.init()
    }

    // MARK: A request

    /// A request starts: the glow comes up. `home` is where the pointer first sets off from (the bar).
    func begin(home: CGPoint?) {
        guard isOn else { return }
        active = true
        self.home = home
        anchor = nil
        pointer = nil
        flight = nil
        outline = nil
        working = nil
        scan = nil
        bubble = nil
        badge = .none
        generation += 1
        buildPanels()
        for panel in panels {
            panel.orderFrontRegardless()
            panel.setGlow(true, animated: !reduceMotion)
            panel.setPointerShown(false, animated: false)
            panel.setWindowOutline(nil)
            panel.setOutline(nil, animated: false)
        }
        startLink()
        NSLog("Tell Sunlight: showing what it does on \(panels.count) display(s)")
    }

    /// Finished, failed or stopped: everything fades out after a moment to see the last step land.
    func end() {
        guard active else { return }
        active = false
        scan = nil
        let now = CACurrentMediaTime()
        fadeAt = now + 1.2
        lingerUntil = now + 1.7
        let ending = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.active, self.generation == ending else { return }
                for panel in self.panels {
                    panel.setGlow(false, animated: true)
                    panel.setPointerShown(false, animated: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, !self.active, self.generation == ending else { return }
                        self.stopLink()
                        for panel in self.panels { panel.orderOut(nil) }
                    }
                }
            }
        }
    }

    /// A request is running, or has just ended and its last step is still landing.
    private var live: Bool { active || CACurrentMediaTime() < fadeAt }

    // MARK: Steps

    /// The work moved to a window: it gets the outline.
    func workingIn(_ window: CGWindowID) {
        guard active else { return }
        working = window
    }

    /// Reading a window: the pointer heads for its title bar and a scan line sweeps down it. The read
    /// doesn't wait for the pointer to land: nothing in the app changes.
    func reading(_ window: CGWindowID) {
        guard active else { return }
        working = window
        scan = (window, CACurrentMediaTime())
        fly(to: Spot(window: window, unit: Grip.titleBar.unit, offset: Grip.titleBar.offset), badge: .reading)
    }

    /// The pointer goes to a control (`unit`: where it is, as a fraction of its window), which gets an
    /// outline. Returns once it has landed.
    func target(_ window: CGWindowID, unit: CGRect, badge: Badge = .none) async {
        guard active else { return }
        working = window
        if unit.width > 0, unit.height > 0 {
            outline = (window, unit)
            outlineUntil = .infinity
        } else {
            outline = nil
        }
        await go(to: Spot(window: window, unit: CGPoint(x: unit.midX, y: unit.midY)), badge: badge)
    }

    /// The pointer takes hold of a window for a canvas command and follows it while it glides.
    func grab(_ window: CGWindowID, _ grip: Grip) async {
        guard active else { return }
        working = window
        outline = nil
        let moving = grip == .titleBar || grip == .corner
        await go(to: Spot(window: window, unit: grip.unit, offset: grip.offset), badge: moving ? .moving : .none)
    }

    /// Done with the window it held: the hand lets go, the pointer stays where it is.
    func release() {
        guard active else { return }
        setBadge(.none)
    }

    /// The bar is asking the user about this step: the pointer waits over it with a question mark.
    func asking() {
        guard active else { return }
        setBadge(.asking)
    }

    /// The user answered: allowed, the press follows; declined, the outline goes.
    func asked(allowed: Bool) {
        guard active else { return }
        setBadge(.none)
        if !allowed { outlineUntil = CACurrentMediaTime() }
    }

    /// The action ran: a ripple where the pointer is, and what was typed or chosen beside it.
    func pressed(_ press: Press) {
        guard active, let at = pointer else { return }
        let now = CACurrentMediaTime()
        outlineUntil = now + 0.7
        setBadge(.none)
        let panel = panel(containing: at)
        switch press {
        case .failed:
            panel?.shake()
            outlineUntil = now
            return
        case .scrolled(let down):
            setBadge(down ? .scrollDown : .scrollUp)
            let shown = badgeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.badgeGeneration == shown else { return }
                    self.setBadge(.none)
                }
            }
            return
        case .typed(let text):
            setBadge(.typing)
            show(bubble: text, at: now)
        case .returnKey:
            show(bubble: "⏎ Return", at: now)
        case .chose(let text):
            show(bubble: "“\(text)”", at: now)
        case .click:
            break
        }
        panel?.ripple(at: panel?.local(at) ?? .zero, animated: !reduceMotion)
    }

    private func setBadge(_ b: Badge) {
        badge = b
        badgeGeneration += 1
    }

    private func show(bubble text: String, at now: CFTimeInterval) {
        let clipped = PresenceGeometry.clip(text, 60)
        let duration = reduceMotion ? 0 : PresenceGeometry.typingDuration(clipped.count)
        bubble = (clipped, now, duration, now + duration + 1.4)
    }

    // MARK: Flying

    /// Flies the pointer to `spot` and returns once it has landed (sooner if the request is stopped).
    private func go(to spot: Spot, badge: Badge) async {
        let duration = fly(to: spot, badge: badge)
        guard duration > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64((duration + 0.04) * 1_000_000_000))
    }

    /// Sets the pointer off towards `spot`; how long it will take.
    @discardableResult
    private func fly(to spot: Spot, badge: Badge) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        let target = resolve(spot)?.point
        let from = pointer ?? home ?? target
        anchor = spot
        setBadge(badge)
        guard let from, let target else { return 0 }
        let duration = reduceMotion ? 0 : PresenceGeometry.flightDuration(from: from, to: target)
        flight = duration > 0 ? (from, now, duration) : nil
        if pointer == nil { pointer = from }
        tick()
        return duration
    }

    /// The spot on screen now: global point, and whether it's outside its display (then clamped to its edge).
    private func resolve(_ spot: Spot) -> (point: CGPoint, display: CGRect, outside: Bool, toward: CGPoint)? {
        guard let drawn = drawn(spot.window) else { return nil }
        let p = PresenceGeometry.point(unit: spot.unit, offset: spot.offset, in: drawn.rect, zoom: drawn.zoom)
        let clamped = PresenceGeometry.clamp(p, into: drawn.display, inset: 36)
        return (clamped.point, drawn.display, clamped.outside, p)
    }

    private func drawn(_ id: CGWindowID) -> (rect: CGRect, zoom: CGFloat, display: CGRect)? {
        for canvas in desk.canvases {
            if let d = canvas.agentDrawn(id) { return d }
        }
        return nil
    }

    // MARK: Every frame

    private func startLink() {
        guard link == nil, let view = panels.first?.contentView else { return }
        let l = view.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard active || now < lingerUntil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // The pointer: towards its spot, wherever the window is drawn this frame.
        var toward: CGPoint?
        if let anchor, let spot = resolve(anchor) {
            var p = spot.point
            if let f = flight {
                let t = min(1, (now - f.start) / f.duration)
                p = PresenceGeometry.arc(from: f.from, to: spot.point, t: PresenceGeometry.ease(t))
                if t >= 1 { flight = nil }
            }
            pointer = p
            if spot.outside, flight == nil { toward = spot.toward }
        }
        let live = self.live
        let host = pointer.flatMap { panel(containing: $0) }
        for panel in panels {
            if panel === host, live, let p = pointer {
                if !panel.pointerShown { panel.setPointerShown(true, animated: !reduceMotion) }
                panel.placePointer(at: panel.local(p), pointingAt: toward.map { panel.local($0) }, badge: badge)
            } else if panel.pointerShown && live {
                panel.setPointerShown(false, animated: false)
            }
        }

        // The bubble beside it.
        if let b = bubble {
            if now > b.until {
                bubble = nil
                for panel in panels { panel.setBubble(nil) }
            } else {
                let shown = b.duration > 0 ? Int(Double(b.text.count) * min(1, (now - b.start) / b.duration)) : b.text.count
                for panel in panels { panel.setBubble(panel === host ? String(b.text.prefix(max(1, shown))) : nil) }
            }
        }

        // The control's outline, the window's outline and the scan line.
        let controlRect: CGRect? = {
            guard live, let o = outline, now < outlineUntil, let d = drawn(o.window) else { return nil }
            return PresenceGeometry.place(o.unit, in: d.rect).insetBy(dx: -3, dy: -3)
        }()
        if controlRect == nil, outline != nil, now >= outlineUntil { outline = nil }
        let windowRect = live ? working.flatMap { drawn($0)?.rect } : nil
        var scanRect: CGRect?
        var scanProgress: CGFloat = 0
        if let s = scan {
            let t = (now - s.start) / 0.9
            if t >= 1 || reduceMotion {
                scan = nil
            } else if let d = drawn(s.window) {
                scanRect = d.rect
                scanProgress = CGFloat(t)
            }
        }
        for panel in panels {
            panel.setOutline(controlRect.map { panel.local($0) }, animated: !reduceMotion)
            panel.setWindowOutline(windowRect.map { panel.local($0) })
            panel.setScan(scanRect.map { panel.local($0) }, progress: scanProgress)
        }
    }

    // MARK: Panels

    /// One panel per display, made again whenever a display came, went, moved or changed size.
    private func buildPanels() {
        let displays = Display.all
        guard panels.map(\.shownDisplay) != displays else { return }
        for panel in panels { panel.orderOut(nil) }
        stopLink()
        panels = displays.map { PresencePanel(display: $0) }
    }

    private func panel(containing p: CGPoint) -> PresencePanel? {
        panels.first { $0.quartzFrame.contains(p) } ?? panels.min {
            PresenceGeometry.distance(p, to: $0.quartzFrame) < PresenceGeometry.distance(p, to: $1.quartzFrame)
        }
    }

    /// An AppKit screen rect's middle-bottom as a global point (top-left origin): where the pointer sets off.
    static func global(bottomCenterOf cocoa: NSRect) -> CGPoint {
        let r = Display.quartz(cocoa, primaryHeight: NSScreen.screens.first?.frame.height ?? cocoa.maxY)
        return CGPoint(x: r.midX, y: r.maxY)
    }
}

// MARK: - Geometry (tested)

/// The arithmetic behind the pointer: plain functions, global points with the origin top-left.
enum PresenceGeometry {
    /// Where a control is in its window, as fractions of the window: the part of it inside the window
    /// (a control scrolled out of view is pulled to the window's edge, with no size). Nil frames (an app
    /// that doesn't say) give the window's middle.
    static func unit(of element: CGRect?, in window: CGRect?) -> CGRect {
        guard let window, window.width > 1, window.height > 1 else { return CGRect(x: 0.5, y: 0.5, width: 0, height: 0) }
        guard let element, !element.isNull, element.width >= 0, element.height >= 0 else {
            return CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        }
        let inside = element.intersection(window)
        let r: CGRect
        if inside.isNull || inside.width < 1 || inside.height < 1 {
            let c = CGPoint(x: min(max(element.midX, window.minX), window.maxX), y: min(max(element.midY, window.minY), window.maxY))
            r = CGRect(origin: c, size: .zero)
        } else {
            r = inside
        }
        return CGRect(x: (r.minX - window.minX) / window.width, y: (r.minY - window.minY) / window.height,
                      width: r.width / window.width, height: r.height / window.height)
    }

    /// A fraction of a window placed in the window as drawn.
    static func place(_ unit: CGRect, in drawn: CGRect) -> CGRect {
        CGRect(x: drawn.minX + unit.minX * drawn.width, y: drawn.minY + unit.minY * drawn.height,
               width: unit.width * drawn.width, height: unit.height * drawn.height)
    }

    /// A spot on a window as drawn: a fraction of it, plus window points at the zoom it's drawn at.
    static func point(unit: CGPoint, offset: CGPoint, in drawn: CGRect, zoom: CGFloat) -> CGPoint {
        CGPoint(x: drawn.minX + unit.x * drawn.width + offset.x * zoom,
                y: drawn.minY + unit.y * drawn.height + offset.y * zoom)
    }

    /// The point, or the nearest point `inset` inside the display when it's off it.
    static func clamp(_ p: CGPoint, into display: CGRect, inset: CGFloat) -> (point: CGPoint, outside: Bool) {
        let area = display.insetBy(dx: min(inset, display.width / 2), dy: min(inset, display.height / 2))
        let q = CGPoint(x: min(max(p.x, area.minX), area.maxX), y: min(max(p.y, area.minY), area.maxY))
        return (q, !display.contains(p))
    }

    /// Along a gentle curve from `a` to `b`, `t` from 0 to 1: bowed sideways by a little of the distance.
    static func arc(from a: CGPoint, to b: CGPoint, t: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return b }
        let bow = min(70, length * 0.12) * sin(.pi * t)
        return CGPoint(x: a.x + dx * t - dy / length * bow, y: a.y + dy * t + dx / length * bow)
    }

    /// Ease in and out (cubic).
    static func ease(_ t: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// Longer for a longer way, within 0.18–0.45 s.
    static func flightDuration(from a: CGPoint, to b: CGPoint) -> CFTimeInterval {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 2 else { return 0 }
        return min(0.45, max(0.18, 0.14 + Double(d) / 2600))
    }

    /// How long the bubble takes to type `count` characters out: quick, whatever its length.
    static func typingDuration(_ count: Int) -> CFTimeInterval {
        min(0.9, 0.2 + Double(count) * 0.025)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }

    static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// A global point in a display's own layer coordinates (bottom-left origin, y up).
    static func local(_ p: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: p.x - display.minX, y: display.maxY - p.y)
    }

    static func local(_ r: CGRect, display: CGRect) -> CGRect {
        CGRect(x: r.minX - display.minX, y: display.maxY - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - One display's overlay

/// A click-through panel over one whole display, above the canvas (at the bar's level), holding the
/// layers Tell Sunlight's presence draws.
@MainActor
private final class PresencePanel: NSPanel {
    let shownDisplay: Display
    /// The display, global points, top-left origin.
    var quartzFrame: CGRect { shownDisplay.frame }
    private let scale: CGFloat

    private let root = CALayer()
    private let glow = CALayer()
    private let windowOutline = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let scanBox = CALayer()
    private let scanBand = CAGradientLayer()
    private let pointerLayer = CALayer()
    private let arrow = CAShapeLayer()
    private let tag = CALayer()
    private let tagText = CATextLayer()
    private let tagBadge = CALayer()
    private let bubbleLayer = CALayer()
    private let bubbleText = CATextLayer()
    private(set) var pointerShown = false
    private var shownBadge: AgentPresence.Badge?
    private var shownBubble: String?
    // What's drawn now, so a frame where nothing moved touches no layer.
    private var shownOutline: CGRect?
    private var shownWindowOutline: CGRect?
    private var shownPointer: (at: CGPoint, toward: CGPoint?)?

    static let sun = NSColor(calibratedRed: 1, green: 0.78, blue: 0.25, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.13, green: 0.1, blue: 0.05, alpha: 1)

    init(display: Display) {
        shownDisplay = display
        scale = display.scale
        super.init(contentRect: display.cocoaFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Layer-hosting: the view takes `root` as it is and draws nothing of its own.
        let view = NSView(frame: NSRect(origin: .zero, size: display.cocoaFrame.size))
        view.layer = root
        view.wantsLayer = true
        contentView = view
        setFrame(display.cocoaFrame, display: false)
        build(size: display.cocoaFrame.size)
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func local(_ p: CGPoint) -> CGPoint { PresenceGeometry.local(p, display: quartzFrame) }
    func local(_ r: CGRect) -> CGRect { PresenceGeometry.local(r, display: quartzFrame) }

    // MARK: Building

    private func build(size: CGSize) {
        root.frame = CGRect(origin: .zero, size: size)
        let sun = Self.sun.cgColor

        // The glow: four soft bands along the edges, breathing.
        glow.frame = root.bounds
        glow.opacity = 0
        let depth: CGFloat = 26
        let edges: [(CGRect, CGPoint, CGPoint)] = [
            (CGRect(x: 0, y: size.height - depth, width: size.width, height: depth), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
            (CGRect(x: 0, y: 0, width: size.width, height: depth), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
            (CGRect(x: 0, y: 0, width: depth, height: size.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
            (CGRect(x: size.width - depth, y: 0, width: depth, height: size.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
        ]
        for (frame, start, end) in edges {
            let band = CAGradientLayer()
            band.frame = frame
            band.colors = [Self.sun.withAlphaComponent(0.42).cgColor, Self.sun.withAlphaComponent(0).cgColor]
            band.startPoint = start
            band.endPoint = end
            glow.addSublayer(band)
        }
        root.addSublayer(glow)

        windowOutline.fillColor = nil
        windowOutline.strokeColor = Self.sun.withAlphaComponent(0.75).cgColor
        windowOutline.lineWidth = 2
        windowOutline.shadowColor = sun
        windowOutline.shadowOpacity = 0.8
        windowOutline.shadowRadius = 8
        windowOutline.shadowOffset = .zero
        windowOutline.isHidden = true
        root.addSublayer(windowOutline)

        scanBox.masksToBounds = true
        scanBox.isHidden = true
        scanBand.colors = [Self.sun.withAlphaComponent(0).cgColor, Self.sun.withAlphaComponent(0.28).cgColor, Self.sun.withAlphaComponent(0).cgColor]
        scanBand.startPoint = CGPoint(x: 0.5, y: 1)
        scanBand.endPoint = CGPoint(x: 0.5, y: 0)
        scanBox.addSublayer(scanBand)
        root.addSublayer(scanBox)

        outline.fillColor = Self.sun.withAlphaComponent(0.12).cgColor
        outline.strokeColor = sun
        outline.lineWidth = 2
        outline.opacity = 0
        root.addSublayer(outline)

        // The pointer: an arrow with its tip at the layer's origin, and a tag below to its right.
        pointerLayer.bounds = .zero
        pointerLayer.opacity = 0
        arrow.path = Self.arrowPath()
        arrow.fillColor = sun
        arrow.strokeColor = Self.ink.cgColor
        arrow.lineWidth = 1.3
        arrow.lineJoin = .round
        arrow.shadowColor = NSColor.black.cgColor
        arrow.shadowOpacity = 0.45
        arrow.shadowRadius = 3
        arrow.shadowOffset = CGSize(width: 0, height: -1.5)
        pointerLayer.addSublayer(arrow)

        tag.backgroundColor = sun
        tag.cornerRadius = 9
        tag.borderColor = Self.ink.withAlphaComponent(0.35).cgColor
        tag.borderWidth = 0.5
        tag.shadowColor = NSColor.black.cgColor
        tag.shadowOpacity = 0.3
        tag.shadowRadius = 3
        tag.shadowOffset = CGSize(width: 0, height: -1)
        tagText.string = "Sunlight"
        tagText.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        tagText.fontSize = 11
        tagText.foregroundColor = Self.ink.cgColor
        tagText.contentsScale = scale
        tagText.alignmentMode = .left
        tag.addSublayer(tagText)
        tagBadge.contentsGravity = .resizeAspect
        tagBadge.contentsScale = scale
        tag.addSublayer(tagBadge)
        pointerLayer.addSublayer(tag)

        bubbleLayer.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor
        bubbleLayer.cornerRadius = 8
        bubbleLayer.borderColor = Self.sun.withAlphaComponent(0.6).cgColor
        bubbleLayer.borderWidth = 1
        bubbleLayer.isHidden = true
        bubbleText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        bubbleText.fontSize = 12
        bubbleText.foregroundColor = NSColor.white.cgColor
        bubbleText.contentsScale = scale
        bubbleLayer.addSublayer(bubbleText)
        pointerLayer.addSublayer(bubbleLayer)
        root.addSublayer(pointerLayer)
        layoutTag(.none)
    }

    /// The classic pointer, about the system's size, tip at the origin, y up.
    private static func arrowPath() -> CGPath {
        let raw: [(CGFloat, CGFloat)] = [(0, 0), (0, -18), (4.3, -14), (7.6, -21.2), (10.4, -20), (7.2, -13), (12.8, -13)]
        let points = raw.map { CGPoint(x: $0.0, y: $0.1) }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    // MARK: Updating

    func setGlow(_ on: Bool, animated: Bool) {
        let target: Float = on ? 1 : 0
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = glow.presentation()?.opacity ?? glow.opacity
            fade.toValue = target
            fade.duration = on ? 0.35 : 0.5
            glow.add(fade, forKey: "fade")
        }
        glow.opacity = target
        if on && animated {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.6
            pulse.toValue = 1
            pulse.duration = 1.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + 0.35
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for band in glow.sublayers ?? [] { band.add(pulse, forKey: "pulse") }
        } else if !on {
            for band in glow.sublayers ?? [] { band.removeAnimation(forKey: "pulse") }
        }
    }

    func setPointerShown(_ shown: Bool, animated: Bool) {
        guard shown != pointerShown else { return }
        pointerShown = shown
        let target: Float = shown ? 1 : 0
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = pointerLayer.presentation()?.opacity ?? pointerLayer.opacity
            fade.toValue = target
            fade.duration = shown ? 0.15 : 0.35
            pointerLayer.add(fade, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerLayer.opacity = target
        if !shown { bubbleLayer.isHidden = true; shownBubble = nil }
        CATransaction.commit()
    }

    /// The pointer's tip at `p`; when the spot is off the screen, the arrow turns to point at it.
    func placePointer(at p: CGPoint, pointingAt toward: CGPoint?, badge: AgentPresence.Badge) {
        if badge != shownBadge { layoutTag(badge) }
        if let shown = shownPointer, shown.at == p, shown.toward == toward { return }
        shownPointer = (p, toward)
        pointerLayer.position = p
        if let toward {
            // The arrow's own direction is up and to the left (135°).
            let angle = atan2(toward.y - p.y, toward.x - p.x) - .pi * 3 / 4
            arrow.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        } else {
            arrow.setAffineTransform(.identity)
        }
    }

    private func layoutTag(_ badge: AgentPresence.Badge) {
        shownBadge = badge
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth = ceil(("Sunlight" as NSString).size(withAttributes: [.font: font]).width)
        let badgeSize: CGFloat = badge == .none ? 0 : 11
        let gap: CGFloat = badge == .none ? 0 : 4
        let width = 8 + badgeSize + gap + textWidth + 8
        tag.frame = CGRect(x: 12, y: -40, width: width, height: 18)
        tagBadge.frame = CGRect(x: 8, y: 3.5, width: badgeSize, height: badgeSize)
        tagBadge.contents = badge == .none ? nil : Self.symbol(badge.rawValue, scale: scale)
        tagText.frame = CGRect(x: 8 + badgeSize + gap, y: 2, width: textWidth + 2, height: 14)
    }

    func setBubble(_ text: String?) {
        guard text != shownBubble else { return }
        shownBubble = text
        guard let text else {
            bubbleLayer.isHidden = true
            return
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let width = min(360, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 4)
        bubbleText.string = text
        bubbleText.frame = CGRect(x: 9, y: 4, width: width, height: 16)
        bubbleLayer.frame = CGRect(x: 12, y: -40 - 6 - 24, width: width + 18, height: 24)
        bubbleLayer.isHidden = false
    }

    func setOutline(_ rect: CGRect?, animated: Bool) {
        guard rect != shownOutline else { return }
        shownOutline = rect
        let target: Float = rect == nil ? 0 : 1
        if let rect {
            outline.path = CGPath(roundedRect: rect, cornerWidth: min(6, rect.width / 2), cornerHeight: min(6, rect.height / 2), transform: nil)
        }
        guard outline.opacity != target else { return }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = outline.presentation()?.opacity ?? outline.opacity
            fade.toValue = target
            fade.duration = rect == nil ? 0.3 : 0.12
            outline.add(fade, forKey: "fade")
        }
        outline.opacity = target
    }

    func setWindowOutline(_ rect: CGRect?) {
        let rect = rect.flatMap { $0.intersects(root.bounds.insetBy(dx: -40, dy: -40)) ? $0 : nil }
        guard rect != shownWindowOutline else { return }
        shownWindowOutline = rect
        guard let rect else {
            windowOutline.isHidden = true
            return
        }
        windowOutline.isHidden = false
        let path = CGPath(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerWidth: 12, cornerHeight: 12, transform: nil)
        windowOutline.path = path
        windowOutline.shadowPath = path.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    func setScan(_ rect: CGRect?, progress: CGFloat) {
        guard let rect, rect.intersects(root.bounds) else {
            scanBox.isHidden = true
            return
        }
        scanBox.isHidden = false
        scanBox.frame = rect
        scanBox.cornerRadius = 10
        let band = min(140, rect.height * 0.35)
        // Top to bottom: y is up here, so the band starts above the top edge.
        let y = rect.height - progress * (rect.height + band)
        scanBand.frame = CGRect(x: 0, y: y, width: rect.width, height: band)
    }

    func ripple(at p: CGPoint, animated: Bool) {
        let ring = CAShapeLayer()
        let r: CGFloat = 18
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = p
        ring.fillColor = Self.sun.withAlphaComponent(0.2).cgColor
        ring.strokeColor = Self.sun.cgColor
        ring.lineWidth = 2.5
        ring.opacity = 0
        root.insertSublayer(ring, below: pointerLayer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = animated ? 0.3 : 1
        grow.toValue = animated ? 1.5 : 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = animated ? 0.45 : 0.3
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()

        // The pointer dips as it presses.
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1, 0.82, 1]
        dip.keyTimes = [0, 0.35, 1]
        dip.duration = 0.22
        arrow.add(dip, forKey: "dip")
    }

    func shake() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -6, 6, -4, 4, 0]
        shake.duration = 0.35
        pointerLayer.add(shake, forKey: "shake")
    }

    /// An SF Symbol in the tag's ink, drawn at the display's pixel size.
    private static func symbol(_ name: String, scale: CGFloat) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)),
                                         pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
