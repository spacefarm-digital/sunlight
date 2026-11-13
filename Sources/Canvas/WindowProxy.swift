import AppKit
import IOSurface
import ScreenCaptureKit

/// One real window's stand-in on the canvas: a live texture, a label, and the bookkeeping that keeps
/// the canvas position and the real screen position in agreement. The window is an app's, or a desktop
/// widget's: Notification Center draws each widget in a window of its own (see `Widgets`).
@MainActor
final class WindowProxy {
    static let cornerRadius: CGFloat = 12
    nonisolated static let labelMaxWidth: CGFloat = 420

    enum Kind {
        /// An app window: entered by handing off to it.
        case window
        /// A desktop widget: used where it is, with a click passed through to the real one. It can't be
        /// entered (it lives below every window), so it's never handed off to or in the ⌘Tab cycle.
        case widget
    }

    let kind: Kind
    let windowID: CGWindowID
    let pid: pid_t
    /// For a widget, its name ("Weather"); the window's owner is always Notification Center.
    private(set) var appName: String
    private(set) var title: String
    /// The real window as ScreenCaptureKit last described it; what captures are started from.
    var window: SCWindow?
    /// The owning app's; Notification Center's for a widget.
    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
    /// Belongs to this app: its process if known, else its bundle ID (an app still launching).
    func matches(bundleID: String?, pid: pid_t?) -> Bool {
        if let pid, self.pid == pid { return true }
        guard let bundleID else { return false }
        return self.bundleID == bundleID
    }
    var usesRealWindow = false {
        didSet {
            layer.isHidden = usesRealWindow
            if usesRealWindow { stopCapture(); layer.contents = nil; currentBuffer = nil; hasFrame = false }
        }
    }
    var onGeometryChanged: (() -> Void)?
    /// While it opens onto the canvas or leaves it (`CanvasView.Entrance`, `WindowEffect`): drawn scaled
    /// and moved as the frame says, texture and label at its opacity. The real-window renderer folds the
    /// geometry into the window's transform instead (`LiveWindowsWire.Window`), and sends the opacity as
    /// the window's alpha where the add-on takes it (sunlight-40).
    private(set) var effect = WindowEffect.Frame.identity
    /// The zoom the effect's offset (screen points) was turned into world units at.
    private var effectZoom: CGFloat = 1
    /// Leaving the canvas through a close effect: held at its last frame until the listing drops it.
    var closing = false

    /// In Picture in Picture (`PictureInPicture`): a tile in a corner of the screen whatever the camera
    /// does, on show while the canvas is away too. Its place on the canvas (`worldRect`) stands: its home,
    /// which it goes back to when PiP ends. The controller sets it; the view draws it through `effect`.
    var pip: PipFrame? {
        didSet { if (pip == nil) != (oldValue == nil) { refreshLabel() } }
    }
    /// What is drawn while the tile is on its way somewhere (into its corner, back to 1:1, home); the
    /// tile itself otherwise.
    var pipShown: PipFrame?
    var drawnPip: PipFrame? { pipShown ?? pip }
    /// The screen edge the tile is tucked away behind, with only its tab showing.
    var pipTucked: PictureInPicture.Side?
    /// The corner it was last in, for the next time it goes into Picture in Picture.
    var lastPipCorner: PictureInPicture.Corner?
    /// The tile in world units at the camera now, set by `CanvasView.applyCamera` for a window in PiP:
    /// what its chrome is laid out from and what a press hits.
    var pipWorldRect: CGRect?
    /// Where the window is seen on the canvas: its tile while in PiP, its home otherwise.
    var apparentRect: CGRect { pipWorldRect ?? worldRect }

    /// Where the window lives on the canvas (top-left world coords, points). A widget's is its card.
    /// The layers follow it on their own; nothing else has to remember to lay out after a move.
    ///
    /// Written only here: the canvas places it (`place`), or the user moved the real window and the
    /// canvas follows (`movedByUser`). Everything else reads it.
    private(set) var worldRect: CGRect {
        didSet {
            guard worldRect != oldValue else { return }
            layout(zoom: lastZoom)
            onGeometryChanged?()
            // The windows attached to this one ride with it, each at its offset.
            if worldRect.origin != oldValue.origin {
                for c in attachedChildren { c.place(at: CGPoint(x: worldRect.minX + c.attachmentOffset.x, y: worldRect.minY + c.attachmentOffset.y)) }
            }
        }
    }

    /// Whose position this is (`PositionOwner`): the canvas's, until its app comes to the front and
    /// the user may move the window by hand; the canvas's again once it has read the window back.
    /// Placing the window on the canvas makes it the canvas's: wherever the canvas puts a window is
    /// where it is, whoever was in front.
    var owner: PositionOwner = .canvas

    /// Held back from the live frames (sunlight-27): a window just opened, on its way to being entered
    /// at its spot, stays under the canvas until the pan lands and the seam lifts it, rather than
    /// showing at its spot the moment the canvas comes forward.
    var heldBack = false

    /// The canvas puts the window at `origin` (world): a drag, a drop, a placement, a layout, an
    /// animation's step. Its size stays.
    func place(at origin: CGPoint) {
        owner = .canvas
        worldRect.origin = origin
    }

    /// The canvas gives the window a rect (a resize on the canvas, with the edges that moved).
    func place(_ rect: CGRect) {
        owner = .canvas
        worldRect = rect
    }

    /// The display moved in the arrangement: the window's place and its native frame move with it, so
    /// nothing changes on screen.
    func shift(by dx: CGFloat, _ dy: CGFloat) {
        worldRect = worldRect.offsetBy(dx: dx, dy: dy)
        lastRealFrame = lastRealFrame.offsetBy(dx: dx, dy: dy)
    }
    /// The window this one hangs from, if it's a sheet, alert, prompt or other window that opened
    /// over a window of its app and belongs to it (see `CanvasController.attach`). An attached window
    /// has no place of its own on the canvas: it sits at `attachmentOffset` from its parent, moves
    /// with it, and is left out of placement, tidying, magnetism, layouts and the switcher. A press
    /// on it is a press on its parent.
    var attachedTo: CGWindowID?
    /// Where this window sits relative to its parent's top-left, in points.
    var attachmentOffset: CGPoint = .zero
    /// The windows attached to this one (kept so a move carries them along).
    var attachedChildren: [WindowProxy] = []
    /// An app window with a place of its own on the canvas: not a widget, not attached to another.
    var standsAlone: Bool { kind == .window && attachedTo == nil }
    /// Why a window is off the canvas while keeping its place there (see `CanvasController.away`).
    enum Away {
        /// Its app is hidden (⌘H): the app's unhiding brings it back.
        case hidden
        /// In the Dock (⌘M): restoring it from the Dock brings it back.
        case minimized
        /// In macOS's own full screen (the window's green button, View › Enter Full Screen), on a Space of
        /// its own: leaving full screen brings it back; picking it goes over to that Space.
        case fullScreen
    }
    /// Nil while the window is on the canvas, and while it's gone from the screen for a reason not yet
    /// known (Accessibility is asked whether it was minimized).
    var away: Away?

    /// The slot the window was last tiled to, and the area it's in; cleared when it's dragged or resized
    /// by hand. Entering a tiled window lines the camera up with its area.
    var tile: Tiling.Tile?
    /// The real window's frame the last time we looked (top-left global screen coords): what the
    /// listing compares its frame against. Written only here, from a native frame the controller read
    /// (`placedNatively`, `movedByUser`) or a size it asked for (`resized`, `noteResize`).
    private(set) var lastRealFrame: CGRect
    var ax: AXWindow?
    /// The widget in Notification Center's Accessibility tree; nil for a window, or without Accessibility.
    var widget: AXWidget?
    /// How far the content sits inside the captured window: zero for a window, the transparent margin
    /// around a widget's card. The texture is cropped by it, so the proxy is exactly the card.
    private(set) var inset: CGFloat
    private let cornerRadius: CGFloat

    let layer = CALayer()
    /// The window's name, rendered once into a bitmap (`renderLabel`) and shown by this layer, which a
    /// zoom only moves, counter-scales and crops: a text layer re-rasterised with every width step.
    let label = CALayer()
    /// How a label is drawn: the ink, and whether it gets a shadow (on a picture).
    struct LabelStyle: Equatable {
        var ink: NSColor
        var shadow: Bool
    }
    private var labelStyle = LabelStyle(ink: .white, shadow: false)
    private var labelRendered: (text: String, style: LabelStyle, scale: CGFloat)?
    nonisolated static let labelHeight: CGFloat = 16
    /// Set by `CanvasView.applyCamera` when the proxy is far off screen at a zoom change: its chrome is
    /// laid out again once it comes near (see `layoutChrome`).
    var chromeStale = false

    /// The window's buttons while it's hovered, drawn over the window's own red, yellow and green
    /// ones as macOS draws them (`TrafficLights`): at a constant on-screen size, where the window's are.
    /// `Control` lists them left to right. Close, minimize and green sit on the window's own; the pole and
    /// the menu button sit in the title bar's top-right corner (`trailingControls`), the menu button last.
    enum Control: CaseIterable {
        case close
        case minimize
        /// Green: a click fills the window's area (again, puts it back); hovered or held, the tiling
        /// popover (`TilePopover`).
        case zoom
        /// The window's magnetic pole, ⊕ or ⊖, in its tint, in the top-right corner just before the menu
        /// button; a click flips it. Only while `showsPolarity`.
        case polarity
        /// A grey button with three dots in the title bar's top-right corner, the last one: pressed, it
        /// opens the window's right-click menu under it (`CanvasView.popUpWindowMenu`).
        case menu

        /// Whether it sits in the top-right group rather than over the window's own buttons.
        var trails: Bool { self == .polarity || self == .menu }
    }
    /// A widget can't be minimized or tiled: its only button is the ✕. A window's gains its pole while
    /// polarity is on, and always ends with the menu button.
    private var availableControls: [Control] {
        switch kind {
        case .widget: return [.close]
        case .window: return showsPolarity ? [.close, .minimize, .zoom, .polarity, .menu] : [.close, .minimize, .zoom, .menu]
        }
    }
    /// Whether the window wears its pole: it has one, and Settings › Windows › Magnetic polarity is on
    /// (with the push it builds on).
    var showsPolarity: Bool { polarity != nil && Settings.polarityActive }
    /// Where the window's own buttons are, once Accessibility has said (`CanvasController.prefetchAX`);
    /// until then, where a standard window has them.
    var trafficLights: TrafficLights.Layout? {
        didSet {
            guard trafficLights != oldValue else { return }
            buildControls(scale: scale)
            layoutChrome(zoom: lastZoom)
        }
    }
    private var lightsLayout: TrafficLights.Layout {
        kind == .widget ? WindowProxy.widgetLights : trafficLights ?? .standard
    }
    /// A widget's lone ✕, just inside its card's corner.
    private static let widgetLights = TrafficLights.Layout(centres: [CGPoint(x: 18, y: 18)], diameter: 14)
    /// However far out, the buttons stay at least this far (on screen) inside the window's corner.
    static let controlMinInset: CGFloat = 5
    /// Around the buttons, the group's hover and hit area: the pointer on it shows every button's mark.
    static let controlSlop: CGFloat = 3
    /// Below this on-screen window size the buttons would cover more window than they control; they
    /// stay hidden.
    static let controlsMinWindowSize = CGSize(width: 96, height: 64)
    /// On screen, at least this much window between the two groups, or the top-right one stays hidden.
    static let trailingControlsGap: CGFloat = 12
    /// From this zoom up, the top-right group stays hidden: near full size the window's own toolbar
    /// buttons are under it and usable, and the menu is a right-click away.
    static let trailingControlsMaxZoom: CGFloat = 0.85

    /// Close, minimize and green, over the window's own.
    let controls = CALayer()
    /// The pole and the menu button, in the title bar's top-right corner, as far in from the right edge as
    /// the close button is from the left.
    let trailingControls = CALayer()
    private func group(for control: Control) -> CALayer { control.trails ? trailingControls : controls }
    /// Each button's layers. The pole's `circle` is masked to a horseshoe magnet and has `tips` and an
    /// `outline`; its glyph sits beside it rather than in it, between the arms the mask cuts away.
    private var buttons: [Control: (circle: CAGradientLayer, glyph: CAShapeLayer, tips: CAShapeLayer?, outline: CAShapeLayer?)] = [:]
    private var controlsFit = true
    /// Whether the top-right group shows too: the window is wide enough on screen for both groups apart,
    /// and not near full size (`trailingControlsMaxZoom`).
    private var trailingFit = true
    private func fits(_ control: Control) -> Bool { controlsFit && (!control.trails || trailingFit) }

    private let scale: CGFloat
    private var capture: WindowCapture?
    private var currentBuffer: CVPixelBuffer?  // keeps the IOSurface alive while it's on screen
    /// A captured frame has landed: there is something to show (an arrival waits for it).
    private(set) var hasFrame = false
    private var refreshing = false
    private var seamPending = false
    private var lastZoom: CGFloat = 1
    /// The size the shadow path was last built for; a path is only rebuilt when the size changes.
    private var shadowSize: CGSize = .zero
    /// Until then, a size in the window list that differs from `lastRealFrame` is the list catching up
    /// with a resize of ours, not a size to take (see `resized(toReal:)`). Positions are never held:
    /// the owner decides those (`PositionOwner`).
    private var sizeHeldUntil = Date.distantPast
    /// A resize of ours is still settling: the listing's size for this window is stale.
    var sizeHeld: Bool { Date() < sizeHeldUntil }

    /// True while the window's pixels arrive as a stream. Off whenever the real window may be in front
    /// of the canvas, where the stream's capture pill would show on it.
    var isStreaming: Bool { capture != nil }
    private var failedStarts = 0
    /// Not before this (media time) may a stream be started again after one ended on its own.
    private(set) var retryAfter: CFTimeInterval = 0
    /// The stream ended on its own (see `captureEnded`); the owner may want to look again soon.
    var onCaptureEnded: (() -> Void)?

    /// The real window is in front of the canvas, or about to be (its app is entered, or being
    /// handed off to or absorbed): no stream, and the refresh timer keeps it fresh instead.
    var inFront = false

    /// In sight, but past the capture pass's limit on streams (`CanvasController.maxStreams`): shown
    /// as a still, which the refresh timer renews now and then, instead of a stream.
    var capped = false

    /// Where the proxy is relative to the viewport, as the capture pass last saw it. Streams of
    /// proxies out of sight are slowed, then stopped.
    enum Viewport {
        case active
        case leaving(since: CFTimeInterval)
        case far(since: CFTimeInterval)
    }
    var viewport: Viewport = .active

    /// The most detail worth dropping to for this window: the level at which its short side would
    /// still be about 48 px, so a small window is never reduced to a smear.
    var maxCaptureLevel: Int {
        let short = min(lastRealFrame.width, lastRealFrame.height) * scale
        guard short > 48 else { return 0 }
        return Int(floor(2 * log2(short / 48)))
    }

    /// On its way into the Dock (the – was pressed, the app has agreed): still on the canvas while the
    /// Dock animates it, but taking no hover and showing no controls over the animation.
    var leaving = false

    /// The hover border at two screen points, through the zoom and whatever the effect scales the layer by.
    private var hoverBorderWidth: CGFloat {
        2 / (lastZoom * (effect.keepsGeometry ? 1 : max(effect.scale.width, 0.001)))
    }

    var hovered = false {
        didSet {
            layer.borderWidth = hovered || outlined ? hoverBorderWidth : 0
            if !hovered { hoveredControl = nil; pressedControl = nil }
            if hovered { paintControls() }   // the app may have come or gone to the front since
            showControls(animated: true)
        }
    }

    /// Drawn with the hover border though the pointer isn't on it: bonded to the hovered window, so the
    /// group reads as one. No controls.
    var outlined = false {
        didSet { if outlined != oldValue { layer.borderWidth = hovered || outlined ? hoverBorderWidth : 0 } }
    }

    /// The control under the pointer. Any of them shows every button's mark, as on a real window.
    var hoveredControl: Control? {
        didSet { if hoveredControl != oldValue { paintControls() } }
    }

    /// The control held down, while the pointer is still on it: it darkens until let go.
    var pressedControl: Control? {
        didSet { if pressedControl != oldValue { paintControls() } }
    }

    /// Its magnetic pole (`Polarity`): ⊕ for a window as it arrives, flipped from the pill, its menu or
    /// the P key; nil for a widget. The pill and the label follow.
    var polarity: Polarity? {
        didSet { if polarity != oldValue { refreshPolarity() } }
    }

    /// The pill and the label as the pole and the setting now are: after a flip, and for every window
    /// when Settings › Windows › Magnetic polarity is switched.
    func refreshPolarity() {
        buildControls(scale: scale)
        refreshLabel()
        layoutChrome(zoom: lastZoom)
    }

    /// True while the real window sits on top of this proxy. Our shadow would otherwise peek out
    /// around the real window's own shadow and double it up at the seam.
    var revealed = false {
        didSet { layer.shadowOpacity = revealed ? 0 : 0.5 }
    }

    /// Placed where the real window is, seen through `camera`. A widget's `widget` handle names it and
    /// measures its card; without one it's "Widget" with the margin measured on 27.2.
    convenience init(window: SCWindow, kind: Kind = .window, widget: AXWidget? = nil, camera: Camera, scale: CGFloat) {
        let info = WindowInfo(id: window.windowID, pid: window.owningApplication?.processID ?? 0,
                              layer: window.windowLayer, bounds: window.frame, title: window.title, alpha: 1)
        self.init(info: info, kind: kind, widget: widget, camera: camera, scale: scale)
        self.window = window
    }

    init(info: WindowInfo, kind: Kind = .window, widget: AXWidget? = nil, camera: Camera, scale: CGFloat) {
        self.kind = kind
        windowID = info.id
        pid = info.pid
        title = info.title ?? ""
        self.widget = widget
        self.scale = scale
        lastRealFrame = info.bounds
        switch kind {
        case .window:
            appName = NSRunningApplication(processIdentifier: info.pid)?.localizedName ?? "?"
            inset = 0
            cornerRadius = WindowProxy.cornerRadius
        case .widget:
            appName = widget.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Widget"
            // The card's offset in the window, if Accessibility has it and it's plausible.
            let measured = widget?.frame.map { $0.minX - info.bounds.minX }
            inset = measured.flatMap { (0...24).contains($0) ? $0 : nil } ?? Widgets.defaultInset
            cornerRadius = Widgets.cornerRadius
        }
        worldRect = WindowProxy.worldRect(forReal: info.bounds, inset: inset, camera: camera)

        let noAnimation: [String: CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(),
            "borderWidth": NSNull(), "shadowPath": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(),
            "shadowOpacity": NSNull(), "contentsRect": NSNull(),
        ]

        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.contentsScale = scale
        layer.magnificationFilter = .linear
        // Linear, not trilinear: the texture is never much larger than the proxy on screen (the
        // capture pass sizes it to the zoom), and trilinear would have mipmaps built for every frame.
        layer.minificationFilter = .linear
        layer.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor  // until the first frame lands
        layer.cornerRadius = cornerRadius
        if kind == .widget { layer.cornerCurve = .continuous }
        layer.borderColor = NSColor(red: 0.35, green: 0.62, blue: 1, alpha: 1).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: -14)  // CA is y-up: negative = downwards
        layer.actions = noAnimation

        label.anchorPoint = .zero
        label.contentsGravity = .left   // unscaled, clipped by the bounds: a narrower label is a cropped one
        label.contentsScale = scale
        label.bounds = CGRect(x: 0, y: 0, width: WindowProxy.labelMaxWidth, height: WindowProxy.labelHeight)
        label.actions = noAnimation
        refreshLabel()

        crop(toRealSize: info.bounds.size)
        buildControls(scale: scale)
        // No capture yet: the controller starts one once it knows the window is behind the canvas.
    }

    func stop() {
        stopCapture()
        layer.removeFromSuperlayer()
        label.removeFromSuperlayer()
        controls.removeFromSuperlayer()
        trailingControls.removeFromSuperlayer()
    }

    // MARK: Controls

    private func buildControls(scale: CGFloat) {
        // Built again when the pole, the polarity setting or the window's own buttons change.
        for button in buttons.values {
            button.circle.removeFromSuperlayer()
            button.glyph.removeFromSuperlayer()
        }
        buttons = [:]
        let lights = lightsLayout
        let d = lights.diameter
        let slop = WindowProxy.controlSlop
        let all = availableControls
        let leading = all.filter { !$0.trails }
        let trailing = all.filter(\.trails)
        let first = lights.centre(0)
        let last = lights.centre(max(0, leading.count - 1))
        let pitch = lights.pitch
        controls.bounds = CGRect(x: 0, y: 0, width: last.x - first.x + d + 2 * slop, height: d + 2 * slop)
        trailingControls.bounds = CGRect(x: 0, y: 0, width: CGFloat(max(0, trailing.count - 1)) * pitch + d + 2 * slop,
                                         height: d + 2 * slop)
        for group in [controls, trailingControls] {
            group.anchorPoint = .zero
            group.opacity = 0
            // Geometry follows the camera every frame; opacity is left animatable for the hover fade.
            group.actions = ["position": NSNull(), "transform": NSNull(), "bounds": NSNull()]
        }

        let none: [String: CAAction] = ["colors": NSNull(), "borderColor": NSNull(),
                                        "strokeColor": NSNull(), "opacity": NSNull()]
        for control in all {
            // The top-right group counts its own places from its left, at the window's pitch.
            let c = control.trails
                ? CGPoint(x: first.x + CGFloat(trailing.firstIndex(of: control) ?? 0) * pitch, y: first.y)
                : lights.centre(leading.firstIndex(of: control) ?? 0)
            let controls = group(for: control)
            let circle = CAGradientLayer()   // top to bottom: rim, colour, the deeper edge
            circle.startPoint = CGPoint(x: 0.5, y: 1)
            circle.endPoint = CGPoint(x: 0.5, y: 0)
            circle.locations = [0, 0.12, 0.55, 1]
            // CA is y-up: a centre below the first one's sits lower in the layer.
            circle.frame = CGRect(x: slop + c.x - first.x, y: slop - (c.y - first.y), width: d, height: d)
            circle.cornerRadius = d / 2
            circle.borderWidth = 0.5
            circle.masksToBounds = true
            circle.contentsScale = scale
            circle.actions = none

            let glyph = CAShapeLayer()
            glyph.contentsScale = scale
            glyph.fillColor = nil
            glyph.lineWidth = TrafficLights.glyphWidth(diameter: d)
            glyph.lineCap = .round
            glyph.lineJoin = .round
            glyph.actions = none

            var tips: CAShapeLayer?
            var outline: CAShapeLayer?
            if control == .polarity {
                // A horseshoe magnet rather than a circle, a little larger, on the same centre.
                let m = d * TrafficLights.magnetScale
                circle.frame = circle.frame.insetBy(dx: (d - m) / 2, dy: (d - m) / 2)
                circle.cornerRadius = 0
                circle.borderWidth = 0
                circle.masksToBounds = false
                let body = TrafficLights.magnet(in: circle.bounds)
                let mask = CAShapeLayer()
                mask.frame = circle.bounds
                mask.path = body
                circle.mask = mask
                let steel = CAShapeLayer()
                steel.frame = circle.bounds
                steel.contentsScale = scale
                steel.path = TrafficLights.magnetTips(in: circle.bounds)
                steel.actions = none
                circle.addSublayer(steel)
                // Stroked on the mask's edge, so half of it shows: the circles' 0.5 pt rim.
                let rim = CAShapeLayer()
                rim.frame = circle.bounds
                rim.contentsScale = scale
                rim.path = body
                rim.fillColor = nil
                rim.lineWidth = 1
                rim.actions = none
                circle.addSublayer(rim)
                tips = steel
                outline = rim
                glyph.frame = circle.frame
                glyph.path = TrafficLights.glyph(tone(for: control), in: glyph.bounds)
                controls.addSublayer(circle)
                controls.addSublayer(glyph)
            } else {
                glyph.frame = circle.bounds
                glyph.path = TrafficLights.glyph(tone(for: control), in: circle.bounds)
                circle.addSublayer(glyph)
                controls.addSublayer(circle)
            }
            buttons[control] = (circle, glyph, tips, outline)
        }
        paintControls()
    }

    private func tone(for control: Control) -> TrafficLights.Tone {
        switch control {
        case .close: return .close
        case .minimize: return .minimize
        case .zoom: return .zoom
        case .polarity: return .pole(polarity ?? .plus)
        case .menu: return .menu
        }
    }

    /// Each button in its colours: its own while Sunlight is the active app or the pointer is on the
    /// group, grey otherwise, as a window in the background; darker while pressed; marks while the
    /// pointer is on the group. Instant, as macOS's.
    private func paintControls() {
        let onGroup = hoveredControl != nil
        let active = onGroup || NSApp?.isActive != false
        // Marks show on the group the pointer is on: the two sit at opposite ends of the title bar.
        let markedGroup = hoveredControl?.trails
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (control, button) in buttons {
            let look = TrafficLights.look(tone(for: control), active: active, pressed: control == pressedControl, dark: dark)
            button.circle.colors = [look.highlight.cgColor, look.fill.cgColor, look.fill.cgColor, look.edge.cgColor]
            button.circle.borderColor = look.edge.cgColor
            button.glyph.strokeColor = look.glyph.cgColor
            button.glyph.fillColor = TrafficLights.glyphIsFilled(tone(for: control)) ? look.glyph.cgColor : nil
            button.tips?.fillColor = TrafficLights.magnetTip(active: active, pressed: control == pressedControl, dark: dark).cgColor
            button.outline?.strokeColor = look.edge.cgColor
            // The magnet always shows its sign: it says which pole the window is, not what a click does.
            // The menu button always shows its dots: a plain grey circle would read as a window in the
            // background's button.
            button.glyph.opacity = markedGroup == control.trails || control == .polarity || control == .menu ? 1 : 0
        }
    }

    private func showControls(animated: Bool) {
        let opacity: Float = hovered && controlsFit ? 1 : 0
        let trailing: Float = hovered && controlsFit && trailingFit ? 1 : 0
        guard controls.opacity != opacity || trailingControls.opacity != trailing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.12)
        controls.opacity = opacity
        trailingControls.opacity = trailing
        CATransaction.commit()
    }

    /// A group's world rect, with its slop, at its on-screen size divided by the zoom. The left one starts
    /// where the window's own buttons do, scaled with the window (but never tight against its corner):
    /// at 1:1 it covers the window's own exactly. The top-right one sits as far in from the right edge,
    /// and down from the top, as the close button is from the left.
    private func groupWorldRect(trailing: Bool, zoom: CGFloat) -> CGRect {
        let size = (trailing ? trailingControls : controls).bounds.size
        let lights = lightsLayout
        let first = lights.centre(0)
        let minInset = WindowProxy.controlMinInset
        let side = max((first.x - lights.diameter / 2) * zoom, minInset)
        let top = max((first.y - lights.diameter / 2) * zoom, minInset)
        let slop = WindowProxy.controlSlop
        let rect = apparentRect
        let x = trailing ? rect.maxX - (side - slop + size.width) / zoom : rect.minX + (side - slop) / zoom
        return CGRect(x: x, y: rect.minY + (top - slop) / zoom, width: size.width / zoom, height: size.height / zoom)
    }

    /// Where one button's circle is, in world coordinates, while the buttons are showing: what the
    /// tiling popover points at, and where the menu button's menu hangs from.
    func controlWorldRect(_ control: Control) -> CGRect? {
        guard hovered, fits(control), let circle = buttons[control]?.circle else { return nil }
        let g = group(for: control)
        let rect = groupWorldRect(trailing: control.trails, zoom: lastZoom)
        let f = circle.frame   // in the group, y-up, at on-screen size
        return CGRect(x: rect.minX + f.minX / lastZoom, y: rect.minY + (g.bounds.height - f.maxY) / lastZoom,
                      width: f.width / lastZoom, height: f.height / lastZoom)
    }

    /// The control under a world point, if the buttons are showing there: the nearest one anywhere on
    /// the group, gaps included, as a real window's.
    func control(at worldPoint: CGPoint) -> Control? {
        guard hovered, controlsFit else { return nil }
        for trails in trailingFit ? [false, true] : [false] {
            let rect = groupWorldRect(trailing: trails, zoom: lastZoom)
            guard rect.contains(worldPoint) else { continue }
            let x = (worldPoint.x - rect.minX) * lastZoom
            return buttons.filter { $0.key.trails == trails }
                .min { abs($0.value.circle.frame.midX - x) < abs($1.value.circle.frame.midX - x) }?.key
        }
        return nil
    }

    // MARK: Frames

    /// Streams the window at a level of detail. Only for a window that is behind the canvas (see
    /// `WindowCapture`), and only from the controller's capture pass, which decides the level.
    func startCapture(level: WindowCapture.Level) {
        guard !usesRealWindow, let window, capture == nil, CACurrentMediaTime() >= retryAfter else { return }
        capture = WindowCapture(window: window, size: lastRealFrame.size, scale: scale, level: level,
                                onFrame: { [weak self] buffer in self?.apply(buffer) },
                                onEnd: { [weak self] error in self?.captureEnded(error) })
        capture?.start()
        // A window that doesn't repaint sends the stream nothing, and the proxy would stay a grey
        // square until something happens in it: a one-shot shows it as it is meanwhile.
        if !hasFrame {
            DispatchQueue.main.asyncAfter(deadline: .now() + WindowProxy.silentStreamGrace) { [weak self] in
                guard let self, self.isStreaming, !self.hasFrame else { return }
                self.refresh()
            }
        }
    }

    /// How long a stream that has delivered nothing gets before a one-shot stands in for it.
    static let silentStreamGrace: TimeInterval = 1

    /// More or less detail for a running stream; nothing without one.
    func setCaptureLevel(_ level: WindowCapture.Level) {
        capture?.set(level: level)
    }

    /// Stops the stream; the last frame stays up, so the proxy freezes rather than blanks.
    func stopCapture() {
        capture?.stop()
        capture = nil
    }

    /// The stream ended on its own: the window closed, its app quit, Screen Recording was revoked, or
    /// the system stopped it. The proxy is no longer streaming, so a sync can start it again — after a
    /// pause that grows with each failure, so a window that is gone isn't retried every tick.
    private func captureEnded(_ error: Error?) {
        capture = nil
        failedStarts += 1
        retryAfter = CACurrentMediaTime() + min(30, pow(2, Double(failedStarts - 1)))
        onCaptureEnded?()
    }

    /// One fresh frame without a stream, for a window that is (or is about to be) in front of the canvas.
    /// Dropped if a stream has started again meanwhile — its frames are newer — unless the stream has
    /// delivered nothing yet: a window just created repaints nothing until something happens in it, so
    /// its stream can stay silent for a long while, and the one-shot is what the proxy has to show. `seam`
    /// asks for one even while the stream still runs (a handoff stops it a moment later) and makes sure
    /// one is taken after any capture already under way.
    func refresh(seam: Bool = false) {
        guard !usesRealWindow, let window else { return }
        if refreshing {
            if seam { seamPending = true }
            return
        }
        guard seam || !isStreaming || !hasFrame else { return }   // a silent stream's proxy takes one too
        refreshing = true
        OneShotCapture.capture(window, seam: seam) { [weak self] image in
            guard let self else { return }
            self.refreshing = false
            if let image, !self.usesRealWindow, !self.isStreaming || !self.hasFrame {
                self.currentBuffer = nil   // the stream's last IOSurface can go now
                self.show(image)
            }
            if self.seamPending {
                self.seamPending = false
                self.refresh(seam: true)
            }
        }
    }

    /// Whether the proxy is in (or near) the viewport, as the capture pass last saw it.
    var isInView: Bool {
        if case .active = viewport { return true }
        return false
    }

    private func apply(_ buffer: CVPixelBuffer) {
        guard isStreaming, let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        failedStarts = 0
        // The layer first, then the previous buffer: holding it is what keeps the stream's pool from
        // writing into a surface that is still on screen.
        show(surface)
        currentBuffer = buffer
    }

    private func show(_ contents: Any) {
        layer.contents = contents
        if !hasFrame {
            hasFrame = true
            layer.backgroundColor = nil  // captured windows already have transparent rounded corners
        }
    }

    // MARK: Geometry

    /// The window's name as the window server has it now.
    func retitle(_ newTitle: String?) {
        guard let newTitle, newTitle != title else { return }
        title = newTitle
        refreshLabel()
    }

    /// The user moved (or resized) the real window: wherever it is now, seen through `camera`, is where
    /// it lives on the canvas. `camera` is the one the window was placed at, from the snapshot the frame
    /// was read in (`FrameSnapshot`), so a frame is never paired with a camera that has moved on.
    func movedByUser(to native: CGRect, seenThrough camera: Camera) {
        lastRealFrame = native
        worldRect = WindowProxy.worldRect(forReal: native, inset: inset, camera: camera)
        crop(toRealSize: native.size)
        capture?.set(realSize: native.size)
    }

    /// The real window is at `native`, put there by the canvas (the seam, a kept window, a sibling
    /// lined up) or by macOS (a menu-bar clamp): its place on the canvas stands. The frame is remembered
    /// as is, so the listing sees no move, and a new size is taken where the window is anchored.
    func placedNatively(at native: CGRect) {
        lastRealFrame = native
        let size = native.insetBy(dx: inset, dy: inset).size
        guard size != worldRect.size, size.width > 0, size.height > 0 else { return }
        worldRect.size = size
        crop(toRealSize: native.size)
        capture?.set(realSize: native.size)
    }

    /// The real window was just resized behind the canvas (a layout restore): the proxy takes the new size
    /// where it is on the canvas. The window list reports the new frame a beat late, and until it does its
    /// stale size would read as a new one to take, so the listing ignores sizes meanwhile (`sizeHeld`).
    /// `anchor` is the corner of the proxy that stays put (a unit point, see `Resizing.anchor`): the
    /// top-left for a restore, the corner opposite the grabbed edges for a resize on the canvas.
    func resized(toReal frame: CGRect, anchor: CGPoint = .zero) {
        noteResize(toReal: frame)
        worldRect = Resizing.place(frame.insetBy(dx: inset, dy: inset).size, in: worldRect, anchor: anchor)
    }

    /// The real window took a new size while the canvas is still resizing the proxy (an edge being
    /// dragged): the stream follows and the frame is held, as in `resized(toReal:)`, but the proxy's
    /// size is the pointer's until it's let go.
    func noteResize(toReal frame: CGRect) {
        lastRealFrame = frame
        holdFrame()
        crop(toRealSize: frame.size)
        capture?.set(realSize: frame.size)
    }

    /// A resize of ours has reached the real window: until the window list has caught up with it, a
    /// different size there is the old one, not a new one to take.
    private func holdFrame() {
        sizeHeldUntil = Date().addingTimeInterval(WindowProxy.sizeSettling)
    }

    /// How long the window list may lag the app's answer to a resize.
    nonisolated static let sizeSettling: TimeInterval = 1.5

    /// World rect for a real window seen through a camera. Only the origin is seen through the camera:
    /// world units are points at 1:1, so the size is the real size no matter how far out we are zoomed.
    private static func worldRect(forReal frame: CGRect, inset: CGFloat, camera: Camera) -> CGRect {
        let content = frame.insetBy(dx: inset, dy: inset)
        return CGRect(origin: camera.toWorld(content.origin), size: content.size)
    }

    /// Where a point on the proxy is on the real screen: in the card, for a widget.
    func realPoint(forWorld p: CGPoint) -> CGPoint {
        let content = lastRealFrame.insetBy(dx: inset, dy: inset)
        return CGPoint(x: content.minX + (p.x - worldRect.minX) * content.width / max(1, worldRect.width),
                       y: content.minY + (p.y - worldRect.minY) * content.height / max(1, worldRect.height))
    }

    /// Shows only the content of the captured window: the margin is the same on every side, so the crop
    /// is symmetric and doesn't care which way up the texture is.
    private func crop(toRealSize size: CGSize) {
        guard inset > 0, size.width > 2 * inset, size.height > 2 * inset else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let dx = inset / size.width, dy = inset / size.height
        layer.contentsRect = CGRect(x: dx, y: dy, width: 1 - 2 * dx, height: 1 - 2 * dy)
    }

    /// The widget's Accessibility handle arrived after the proxy was made: take its name, and
    /// re-measure the card. World units are real points at any zoom, so a different margin moves the
    /// card's edges by the difference, with no camera involved.
    func adopt(widget w: AXWidget) {
        widget = w
        if !w.name.isEmpty {
            appName = w.name
            refreshLabel()
        }
        let measured = w.frame.map { $0.minX - lastRealFrame.minX }
        let newInset = measured.flatMap { (0...24).contains($0) ? $0 : nil } ?? Widgets.defaultInset
        guard newInset != inset else { return }
        let delta = newInset - inset
        inset = newInset
        worldRect = worldRect.insetBy(dx: delta, dy: delta)
        crop(toRealSize: lastRealFrame.size)
    }

    /// Positions every layer for the current world rect and zoom. `worldRect` calls it itself when it
    /// changes; the view calls `layoutChrome` alone when only the zoom does.
    func layout(zoom: CGFloat) {
        layoutGeometry()
        layoutChrome(zoom: zoom)
    }

    /// The window layer itself lives in world units, so it only depends on the world rect, never on
    /// the camera. The shadow path is rebuilt only when the size changes: it's the one allocation here.
    private func layoutGeometry() {
        let r = caRect(worldRect)
        layer.bounds = CGRect(origin: .zero, size: r.size)
        layer.position = r.origin
        if r.size != shadowSize {
            shadowSize = r.size
            layer.shadowPath = CGPath(roundedRect: layer.bounds,
                                      cornerWidth: cornerRadius,
                                      cornerHeight: cornerRadius,
                                      transform: nil)
        }
        if !effect.keepsGeometry { applyEffect() }   // the point it scales about moved
    }

    /// Far off screen at a zoom change, the chrome is left as it is and hidden (a label counter-scaled
    /// for another zoom could be wide enough to reach the screen); `layoutChrome` brings it back.
    func leaveChromeStale() {
        guard !chromeStale else { return }
        chromeStale = true
        label.isHidden = true
        controls.isHidden = true
        trailingControls.isHidden = true
    }

    /// The counter-scaled chrome: hover border, label and controls keep a constant on-screen size, so
    /// they move with the zoom. Nothing here changes on a pan.
    func layoutChrome(zoom: CGFloat) {
        lastZoom = zoom
        if chromeStale {
            chromeStale = false
            label.isHidden = false
            controls.isHidden = false
            trailingControls.isHidden = false
        }
        let r = caRect(apparentRect)
        if hovered || outlined { layer.borderWidth = hoverBorderWidth }

        // The label sits just above the window's top-left corner and keeps a constant on-screen size
        // (counter-scaled), fading out as you approach 1:1 where the real title bar takes over. It's no
        // wider than the window on screen, so it truncates rather than running into a neighbour's —
        // widgets side by side are narrower than their labels at most zooms.
        label.position = CGPoint(x: r.minX, y: r.maxY + 6 / zoom)
        label.transform = CATransform3DMakeScale(1 / zoom, 1 / zoom, 1)
        let labelShown: Float = labelShown(zoom: zoom) ? 1 : 0
        let labelOpacity = labelShown * effect.opacity
        if label.opacity != labelOpacity { label.opacity = labelOpacity }
        if labelShown > 0 {
            // The bitmap is cropped to the window's width on screen; 8 pt steps keep the crop from
            // jittering along the last glyph.
            let width = min(WindowProxy.labelMaxWidth, max(24, (apparentRect.width * zoom / 8).rounded(.down) * 8))
            if label.bounds.size.width != width { label.bounds.size.width = width }
        }

        // The controls are counter-scaled the same way, anchored at their bottom-left in CA space.
        controls.position = caRect(groupWorldRect(trailing: false, zoom: zoom)).origin
        controls.transform = CATransform3DMakeScale(1 / zoom, 1 / zoom, 1)
        trailingControls.position = caRect(groupWorldRect(trailing: true, zoom: zoom)).origin
        trailingControls.transform = controls.transform
        let minSize = WindowProxy.controlsMinWindowSize
        // A tile in Picture in Picture has its own chrome (✕, return) instead of the traffic lights.
        controlsFit = pip == nil && apparentRect.width * zoom >= minSize.width && apparentRect.height * zoom >= minSize.height
        let apart = groupWorldRect(trailing: true, zoom: zoom).minX - groupWorldRect(trailing: false, zoom: zoom).maxX
        trailingFit = zoom < WindowProxy.trailingControlsMaxZoom && apart * zoom >= WindowProxy.trailingControlsGap
        showControls(animated: false)
    }

    /// One frame of the window's opening or closing (see `WindowEffect`); `.identity` is the window as usual.
    func setEffect(_ frame: WindowEffect.Frame, zoom: CGFloat) {
        effect = frame
        effectZoom = zoom
        applyEffect()
        label.opacity = (labelShown(zoom: lastZoom) ? 1 : 0) * frame.opacity
    }

    /// Whether the label shows at this zoom: zoomed out (near 1:1 the real title bar takes over), with
    /// Settings › Canvas › Window names on, and not for a tile in Picture in Picture, whose chrome names
    /// it on hover, as a video's does.
    func labelShown(zoom: CGFloat) -> Bool {
        zoom < 0.85 && pip == nil && Settings.showWindowLabels
    }

    /// Settings › Canvas › Window names was switched: the label comes or goes at the zoom it was laid
    /// out for. Stale chrome (far off screen) is left for `layoutChrome` to bring back as the setting has it.
    func windowLabelsSettingChanged() {
        guard !chromeStale else { return }
        layoutChrome(zoom: lastZoom)
    }

    /// The layer's anchor is its bottom-left corner and its space is y-up, so a scale about the frame's
    /// anchor is a scale and a shift of the part of the size lost on that side, then the frame's own
    /// move. The shadow path is in layer units and scales along.
    private func applyEffect() {
        let f = effect
        if f.keepsGeometry {
            layer.transform = CATransform3DIdentity
        } else {
            let size = layer.bounds.size
            let sx = f.scale.width, sy = f.scale.height
            let zoom = max(effectZoom, 0.001)
            let tx = size.width * f.anchor.x * (1 - sx) + f.offset.dx / zoom
            let ty = size.height * (1 - f.anchor.y) * (1 - sy) - f.offset.dy / zoom
            var t = CATransform3DMakeTranslation(tx, ty, 0)
            t = CATransform3DScale(t, sx, sy, 1)   // scale first, then translate — as `Camera.layerTransform`
            layer.transform = t
        }
        layer.opacity = f.opacity
        // A tile's corners are a video's on screen (the real window is shaped to match, `PictureInPicture.Reference`):
        // the hover border follows them, counter-scaled through the zoom and the effect's scale.
        let onScreen = max(effectZoom, 0.001) * (f.keepsGeometry ? 1 : max(f.scale.width, 0.001))
        layer.cornerRadius = pip != nil ? PictureInPicture.Reference.cornerRadius / onScreen : cornerRadius
    }

    /// The ink and the shadow the canvas wants for every label (`CanvasView.applyInk`).
    func styleLabel(ink: NSColor, shadow: Bool) {
        let style = LabelStyle(ink: ink, shadow: shadow)
        guard style != labelStyle else { return }
        labelStyle = style
        refreshLabel()
    }

    private func refreshLabel() {
        let name = title.isEmpty ? appName : "\(appName) — \(title)"
        // The pole leads the label while polarity is on: the one cue you can see from far out.
        var text: String
        if showsPolarity, let pole = polarity {
            text = "\(pole.glyph) \(name)"
        } else {
            text = name
        }
        let scale = label.contentsScale
        if let r = labelRendered, r.text == text, r.style == labelStyle, r.scale == scale { return }
        labelRendered = (text, labelStyle, scale)
        label.contents = WindowProxy.renderLabel(text, style: labelStyle, scale: scale)
    }

    /// The label as a bitmap, `labelMaxWidth` by `labelHeight` points at `scale`, the shadow baked in:
    /// drawn once per title, ink or scale, never per zoom step.
    nonisolated static func renderLabel(_ text: String, style: LabelStyle, scale: CGFloat) -> CGImage? {
        let width = Int((labelMaxWidth * scale).rounded()), height = Int((labelHeight * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.ink.withAlphaComponent(0.85)]
        if style.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = (style.ink == .black ? NSColor.white : NSColor.black).withAlphaComponent(0.7)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attributes[.shadow] = shadow
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // One line, its box centred in the label's height, as the text layer drew it.
        let lineHeight = font.ascender - font.descender + font.leading
        (text as NSString).draw(at: CGPoint(x: 0, y: (labelHeight - lineHeight) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

extension CGRect {
    /// Within half a point on every edge: the window server and Accessibility round differently.
    func isClose(to r: CGRect) -> Bool {
        abs(minX - r.minX) < 0.5 && abs(minY - r.minY) < 0.5 && abs(width - r.width) < 0.5 && abs(height - r.height) < 0.5
    }
}
