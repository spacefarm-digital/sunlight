import AppKit
import Carbon.HIToolbox
import QuartzCore
import UniformTypeIdentifiers

/// The zoomable surface. Owns the camera, the layer tree, and all pointer / gesture handling.
/// Pointer positions are converted to top-left screen coordinates once (`topLeftPoint`) and everything
/// downstream works in world space.
@MainActor
final class CanvasView: NSView {
    static let minZoom: CGFloat = 0.04
    static let maxZoom: CGFloat = 1.0
    /// Ending a pinch at or above this zoom with a window under the pointer hands off to it.
    static let handoffZoom: CGFloat = 0.9
    /// A four-finger drag across the trackpad's full width pans this many screen widths.
    static let trackpadPanGain: CGFloat = 1.5
    /// How far the pointer has to travel before pressing on a window or widget becomes moving it, not a click.
    static let dragSlop: CGFloat = 3
    /// How close, on screen, an edge has to come to a neighbour's before the alignment guides take it.
    static let snapDistance: CGFloat = 8
    /// How long a window takes to settle onto the grid when it's let go.
    nonisolated static let snapDuration: CFTimeInterval = 0.16
    nonisolated static let cameraDuration: CFTimeInterval = 0.42
    /// Bloom's ring rippling out from an arriving window's edges: how long, and how far (screen points).
    nonisolated static let ringDuration: CFTimeInterval = 0.45
    static let ringReach: CGFloat = 24

    private(set) var camera = Camera()
    private(set) var proxies: [WindowProxy] = []  // bottom → top
    /// Windows that are hidden or minimized: not drawn and not hit, but keeping their place for the
    /// minimap, which outlines them dashed. The controller owns the list (`CanvasController.away`).
    var away: [WindowProxy] = []

    /// A double-click or ⏎: bring the window to the middle of the screen and enter it.
    var onHandoff: ((WindowProxy) -> Void)?
    /// Zoomed in or out, a click on a window that didn't become a drag: enter it at 1:1 around the clicked
    /// spot (`at`: where it was pressed, view coordinates; `offset`: where in the window, world units).
    var onClickEnter: ((_ proxy: WindowProxy, _ at: CGPoint, _ offset: CGPoint) -> Void)?
    /// The window a click just started entering in place: a second click on its way in (a double-click)
    /// brings it to the middle instead. The way in lasts at least the double-click interval
    /// (`CanvasController.handoff`), so the canvas is still here to take that click.
    private weak var clickEntering: WindowProxy?
    /// A press on a window at 1:1: enter it where it is and pass the press on to the real window, so it's
    /// used straight away, as on the desktop. `press` is the mouse-down.
    var onUse: ((_ proxy: WindowProxy, _ around: CGPoint, _ press: NSEvent) -> Void)?
    /// The rest of a press `onUse` passed on that still came to the canvas: drags and the release.
    var onUseFollow: ((NSEvent) -> Void)?
    /// A scroll starting over a window at 1:1: enter it where it is and pass the scroll on, as on the desktop.
    var onUseScroll: ((_ proxy: WindowProxy, _ around: CGPoint, _ scroll: NSEvent) -> Void)?
    /// The rest of a scroll `onUseScroll` passed on that still comes to the canvas, momentum included.
    var onUseScrollFollow: ((NSEvent) -> Void)?
    /// Pinching in over a window: enter it where it is (see `CanvasController.Placement`).
    var onEnter: ((_ proxy: WindowProxy, _ around: CGPoint) -> Void)?
    /// The red button over a hovered window, or right-click › Remove Widget.
    var onClose: ((WindowProxy) -> Void)?
    /// The yellow button over a hovered window, or right-click › Minimize: into the Dock.
    var onMinimize: ((WindowProxy) -> Void)?
    /// Right-click › Hide: the window's app, as ⌘H would.
    var onHideApp: ((WindowProxy) -> Void)?
    /// Right-click › Picture in Picture / Leave Picture in Picture (`PictureInPicture`).
    var onTogglePip: ((WindowProxy) -> Void)?
    /// A tile dragged, resized or pinched and settled (in a corner, or tucked): its place changed.
    var onPipMoved: ((WindowProxy) -> Void)?
    /// A double-click on a tile: the window returns to 1:1 where the tile is, the camera staying put.
    var onPipReturn: ((WindowProxy) -> Void)?
    /// A tile drawn somewhere new this frame (a drag, a resize, a flight): the live windows follow at
    /// once, and the chrome panel with them.
    var onPipChanged: (() -> Void)?
    /// A click on a widget, at a world point; nil for the widget as a whole (⏎).
    var onPress: ((WindowProxy, CGPoint?) -> Void)?
    /// "Add Widgets…" from the context menu.
    var onAddWidgets: (() -> Void)?
    /// Right-click › Open Here… or a double-click on empty canvas, at this world point.
    var onOpenHere: ((CGPoint) -> Void)?
    /// The spot Open Here… will open an app at, ringed while its bar is up (world point).
    var openHereMark: CGPoint? {
        didSet { showOpenHereMark(was: oldValue) }
    }
    /// The camera moved, or a move was started, retargeted or dropped: what's in view may have changed.
    var onViewportChanged: (() -> Void)?
    /// The pointer (or the ⌘Tab switcher) is on a proxy, or on none: a chance to get ready for a click.
    var onHover: ((WindowProxy?) -> Void)?

    /// Where a running camera move ends; nil when the camera is still.
    var targetCamera: Camera? {
        animation?.to ?? flight.map { $0.path.camera(at: 1) }
    }
    /// The camera moved: any pan, zoom or animation frame.
    var onCameraChanged: (() -> Void)?
    /// The camera came to rest after the user moved it (a pan, a pinch, a scroll, the minimap), the
    /// fingers off and any coast run out: true when the controller took it from there (`WindowSnap`).
    var onSettle: (() -> Bool)?
    /// A flight's spring each frame: 0 where the move began, 1 where it ends (a little past 1 at the
    /// overshoot), and exactly 1 once it settles, is dropped, or had no distance to go. The ⌘Tab strip
    /// moves on this, so it and the camera are one motion.
    var onFlightProgress: ((CGFloat) -> Void)?
    /// What's on the canvas changed: a window added, removed, raised or moved.
    var onContentChanged: (() -> Void)?
    /// An edge of a window is being dragged: the proxy already has its new rect, and the real window should
    /// follow. `anchor` is the corner that stays put (see `Resizing.anchor`); `finished` once it's let go.
    var onResize: ((_ proxy: WindowProxy, _ anchor: CGPoint, _ finished: Bool) -> Void)?
    /// Whether a screen point is under the overlay (the minimap): nothing there is hovered or entered.
    var isCovered: ((CGPoint) -> Bool)?
    /// Whether a window is in use where it's drawn (`Settings.useScaledWindows`) with its app in front:
    /// the canvas isn't key then, but it's up as it is, and the camera is still the user's to move.
    var isUsingScaledWindow: (() -> Bool)?

    /// Whether the camera is the user's: the canvas is key, or stays up for a window used where it's drawn.
    private var cameraIsFree: Bool { window?.isKeyWindow == true || isUsingScaledWindow?() == true }
    /// A window or widget was dragged somewhere new and let go (it may still be settling onto the grid).
    var onMoved: ((WindowProxy) -> Void)?
    /// Right-click › Move & Resize on a window.
    var onTile: ((WindowProxy, Tiling.Preset) -> Void)?
    /// A click on a window's green button: it fills its area, or goes back from filling it.
    var onZoom: ((WindowProxy) -> Void)?
    /// A choice in the green button's popover (`TilePopover`).
    var onTileChoice: ((WindowProxy, TilePopover.Choice) -> Void)?
    /// Right-click › Tidy, Tidy By › an order, Arrange › (the window's screen, or the one in view).
    var onTidy: (() -> Void)?
    var onTidyBy: ((Tidy.Order) -> Void)?
    var onArrange: ((_ around: WindowProxy?, _ columns: Int, _ rows: Int) -> Void)?
    /// The window's ⊕/⊖ button, Flip Polarity in its menu, or P over it: its pole flips.
    var onFlipPolarity: ((WindowProxy) -> Void)?
    /// Right-click › Ungroup on a bonded window: its whole group goes free.
    var onUngroup: ((WindowProxy) -> Void)?
    /// The other displays a window can go to, by name, for its right-click menu; and the move to one
    /// of them (its index in that list).
    var otherDisplays: (() -> [String])?
    var onMoveToDisplay: ((WindowProxy, Int) -> Void)?
    /// A pulled window arrived and bonded with the one in hand (`Grouping`).
    var onBonded: (() -> Void)?

    /// The canvas colour: the light or the dark one, as the Mac's appearance and the setting decide
    /// (see `updateBackground`). Any alpha is ignored — see `applyBackground`.
    private(set) var background = Settings.defaultDarkBackground
    /// An almost-clear input surface above the real windows; the colour lives in a separate backdrop.
    var showsRealWindows = false { didSet { applyBackground() } }
    /// How much of the top of the view the menu bar covers. The canvas window spans the whole screen,
    /// so framing centres content in the area below it rather than under the menu bar.
    var topInset: CGFloat = 0
    /// The part of the view nothing sits on top of, in view coordinates (top-left origin).
    var unobscuredRect: CGRect {
        CGRect(x: 0, y: topInset, width: bounds.width, height: max(bounds.height - topInset, 1))
    }
    /// Text colour for the HUD and window labels: white on dark backgrounds, black on light ones.
    private var ink = NSColor.white
    /// What's behind the windows beyond the colour: a picture, blurred as the zoom asks (see
    /// `BackgroundRenderer`). Under `worldLayer` here; on the live-windows backdrop while the real windows
    /// are up (`hostBackground`).
    let backgroundRenderer = BackgroundRenderer()
    /// Right-click on empty canvas › Background: built by the controller, which holds the model.
    var backgroundMenu: (() -> NSMenu?)?
    /// A picture file dropped on empty canvas.
    var onDropPicture: ((URL) -> Void)?
    /// A glow round the canvas's edge while a picture is dragged over it.
    private let dropGlow = CAShapeLayer()
    /// The ring on `openHereMark`, in view coordinates: a fixed size whatever the zoom.
    private let openHereRing = CAShapeLayer()

    private let worldLayer = CALayer()
    private let windowsLayer = CALayer()
    /// The widgets' textures while the real windows are up: on the backdrop with the background, under
    /// the real windows, as on the desktop (see `hostWidgets`). Same camera as `worldLayer`.
    private let backdropWorldLayer = CALayer()
    private var widgetsOnBackdrop: Bool { backdropWorldLayer.superlayer != nil }
    /// Finder's desktop (`DesktopFloor`), under everything in the world, widgets included: in the world
    /// layer under the windows, or on the live-windows backdrop under the widgets (see `hostWidgets`).
    private var floorLayer: CALayer?
    /// The floor's world layer on the backdrop, just under `backdropWorldLayer`. Same camera.
    private let backdropFloorLayer = CALayer()
    /// Show Desktop: a dim over every window and widget (real ones too: the canvas view is over them in
    /// live mode), and the floor lifted above it into `frontFloorLayer`, so the files are what's lit.
    private let desktopDim = CALayer()
    /// The floor's world layer while the desktop is shown: over the dim. Same camera.
    private let frontFloorLayer = CALayer()
    private(set) var showsDesktop = false
    /// How dark the dim gets over the windows while the desktop is shown.
    static let desktopDimOpacity: Float = 0.6
    /// A click on a window or widget while the desktop is shown: it ends Show Desktop, and goes on as usual.
    var onDesktopDismissed: (() -> Void)?

    /// Finder's desktop, for clicks on its files: they're the floor's wherever the floor is what's seen.
    weak var desktopFloor: DesktopFloor?
    /// A press (or, `released`, the release of a press that didn't drag) on a file on the floor, or on the
    /// floor's empty ground (nil), with the modifiers held.
    var onFloorClick: ((_ icon: DesktopIcon?, _ modifiers: NSEvent.ModifierFlags, _ released: Bool) -> Void)?
    var onFloorOpen: ((DesktopIcon) -> Void)?
    /// The right-click menu of a file on the floor, or (nil) the items the floor's ground adds.
    var floorMenu: ((DesktopIcon?) -> NSMenu?)?
    var onFloorCommand: ((DesktopFiles.Command) -> Void)?
    /// Keys meant for a window the canvas is on its way into (a new one it goes over to): kept for it and
    /// not acted on here. True when kept.
    var holdsKey: ((NSEvent) -> Bool)?
    /// A widget the widgets' position setting places around the windows: a drag on it pans the canvas
    /// instead of moving it, and windows neither push it nor line up with it.
    var isPlacedBySetting: ((WindowProxy) -> Bool)?
    /// Files dragged off the floor have hovered over a window for `springDelay`: enter it where it is.
    var onSpring: ((_ proxy: WindowProxy, _ around: CGPoint) -> Void)?
    var onFileDragEnded: (() -> Void)?
    /// The last click was on a file on the floor: the keys are the desktop's (`DesktopFiles.command`)
    /// until a click lands anywhere else.
    private var floorFocused = false
    /// A press on a file on the floor: a click until the pointer travels `dragSlop`, then a drag of the files.
    private struct FloorPress {
        let icon: DesktopIcon
        let start: CGPoint
        var modifiers: NSEvent.ModifierFlags
    }
    private var floorPress: FloorPress?
    /// While files dragged off the floor are over a window: that window, the point, and the timer that
    /// enters it. One spring per drag.
    private weak var springTarget: WindowProxy?
    private var springPoint = CGPoint.zero
    private var springTimer: Timer?
    private var sprung = false
    /// How long dragged files hover over a window before it opens to them, as a Finder folder springs.
    static let springDelay: TimeInterval = 0.6
    /// Labels and floating controls: counter-scaled chrome, above every window.
    private let chromeLayer = CALayer()
    /// The HUD: the zoom percentage. The keys are in Settings › How to use › Keyboard (`ShortcutReference`).
    private let hudZoom = CATextLayer()
    private var hudPercent = -1
    /// The zoom the chrome was last laid out for; a pan leaves it alone.
    private var appliedZoom: CGFloat = -1
    /// The alignment guides of the window being dragged, in world space above every window.
    private let guidesLayer = CAShapeLayer()
    private var guides: [Snapping.Guide] = []

    /// A press on a window or widget: a click until the pointer travels `dragSlop`, then a move.
    private struct Drag {
        let proxy: WindowProxy
        let grabOffset: CGPoint
        let start: CGPoint
        /// Where it was when pressed, for undo once it has pushed something.
        let startRect: CGRect
        var moved = false
        /// Whether the alignment guides hold it on that axis, as of the last move.
        var snappedX = false
        var snappedY = false
        /// The pointer's speed on screen, for the coast when it's let go.
        var velocity = Magnetism.Velocity()
        /// The windows bonded to it (`Grouping`), which come along, each from where it started.
        var members: [Member] = []
        /// The guides holding it as of the last move; a new one is a `Haptics.Cue.detent`.
        var guideKeys = Set<GuideKey>()
    }
    private var dragging: Drag?
    /// A press on a tile: a click until the pointer travels `dragSlop`, then a move of the tile itself,
    /// in screen points, with the speed to fling it at.
    private struct PipDrag {
        let proxy: WindowProxy
        let grabOffset: CGPoint
        let start: CGPoint
        var moved = false
        var velocity = Magnetism.Velocity()
    }
    private var pipDrag: PipDrag?
    /// A tile resized from an edge: the aspect kept, the opposite corner put, settled when let go.
    private struct PipResize {
        let proxy: WindowProxy
        let edges: Resizing.Edges
        let start: PipFrame
    }
    private var pipResize: PipResize?
    /// One alignment guide, as the hand feels it: which kind, and the coordinate it holds the window at.
    /// A guide's extent changes as the window slides along it; its coordinate doesn't.
    private struct GuideKey: Hashable {
        let kind: Snapping.Guide.Kind
        let at: Int

        init(_ g: Snapping.Guide) {
            kind = g.kind
            let horizontal = g.from.y == g.to.y
            // A line's shared coordinate is the one constant along it; a gap's line runs across the
            // gap, so it's the other one.
            let value = horizontal == (g.kind == .line) ? g.from.y : g.from.x
            at = Int((value * 2).rounded())
        }
    }
    /// A window moving along with the one in hand — a member of its group — and where it was when the
    /// move began, for undo.
    private struct Member {
        let proxy: WindowProxy
        let from: CGRect
    }
    /// A body pushed out of the way by the one in hand (see `Magnetism`), or pulled in to it: a window,
    /// or a group moving as one. `proxy` leads: `target` and `follow` are its, and `members` keep their
    /// offsets from it. Each is remembered where it started, for undo.
    private struct Push {
        let proxy: WindowProxy
        let from: CGRect
        var members: [(proxy: WindowProxy, offset: CGVector, from: CGRect)]
        var target: CGPoint
        var follow: Magnetism.Follow
        /// An opposite pole the hand is pulling in: held at the gap, and bonded once it gets there.
        var pulled = false
    }
    /// Windows push each other: the one in hand (dragged, resized, or coasting after being flung), the
    /// ones it has pushed or is pulling, and the coast if there is one. Outlives `dragging` and
    /// `resizing`: once the hand lets go it stays while the pushed windows settle and the coast runs out.
    private struct Magnet {
        let proxy: WindowProxy
        let from: CGRect
        /// The held window's group, each from where it started; grows as pulled windows bond.
        var members: [Member]
        /// Of `members`, the ones that bonded during this gesture: undo lets them go again.
        var joined: [Member] = []
        /// Groups as they were when the hand took hold, for undo.
        let groupingBefore: Grouping
        var pushes: [Push] = []
        var coast: Magnetism.Coast?
        /// Held ⌘ when let go: no grid for it after the coast.
        var freely = false
        var snappedX = false
        var snappedY = false
        /// The hand has let go; what's left is the coast and the settling.
        var released = false
        var lastTick: CFTimeInterval?
        /// The bodies the hand itself is shoving, and the ones it's pulling in, as of the last move:
        /// a newcomer to either is a haptic cue (`Haptics`).
        var touching = Set<ObjectIdentifier>()
        var pulling = Set<ObjectIdentifier>()
    }
    private var magnet: Magnet?
    /// A press `onUse` passed on, until its release: what follows of it goes the same way.
    private var passingOn = false
    /// A scroll `onUseScroll` passed on, until the next one starts with the canvas in front.
    private var scrollingOn = false

    /// The canvas is back in front, or the window a scroll was passed to never got it: scrolls are the canvas's again.
    func endScrollingOn() { scrollingOn = false }
    /// A press on a window's edge or corner: resizing it, from the rect it had when pressed.
    private struct Resize {
        let proxy: WindowProxy
        let edges: Resizing.Edges
        let startRect: CGRect
        let start: CGPoint
        var moved = false
        var anchor: CGPoint { Resizing.anchor(for: edges) }
    }
    private var resizing: Resize?
    /// The edges under the pointer, as the cursor shows them.
    private var cursorEdges: Resizing.Edges = []
    private var panning = false
    private var lastPointer: CGPoint = .zero
    private var hovered: WindowProxy?

    private struct CameraAnimation {
        let from: Camera
        let to: Camera
        let start: CFTimeInterval
        let duration: CFTimeInterval
        /// Windows easing to new places on the canvas alongside the camera.
        let moves: [(proxy: WindowProxy, from: CGPoint, to: CGPoint)]
        /// Something else on the same curve, each frame, with the eased progress.
        let step: ((CGFloat) -> Void)?
        let completion: (() -> Void)?
    }
    private var animation: CameraAnimation?

    /// A spring-driven trip along a pan-and-zoom path (the ⌘Tab switcher's moves). Unlike
    /// `CameraAnimation` it can be retargeted mid-flight and keeps its speed when it is.
    private struct Flight {
        let path: CameraPath
        let spring: Spring   // progress along the path, as offset from 1
        let start: CFTimeInterval
        let completion: (() -> Void)?
    }
    private var flight: Flight?
    private var link: CADisplayLink?

    /// Input since the last frame, applied once per display-link tick (see `Motion`), and the coasts
    /// carrying a four-finger pan or a pinch on after the fingers lift. Scroll, pinch and the trackpad
    /// each arrive on their own clock; the display's is the one that matters.
    private var pending = Motion.PendingInput()
    private var coast: Motion.PanCoast?
    private var zoomCoast: Motion.ZoomCoast?
    /// The four-finger drag's travel so far and its speed, for the coast when it ends.
    private var panTravel = CGPoint.zero
    private var panVelocity = Magnetism.Velocity()
    /// The pinch's log-zoom so far and its speed, for the tail when it ends.
    private var pinchLog: CGFloat = 0
    private var pinchVelocity = Motion.ScalarVelocity()
    /// The user moved the camera and it hasn't come to rest since: `onSettle` is asked once it has. A move
    /// of the app's own (a handoff, a fit, the switcher) clears it.
    private var settleWhenStill = false
    /// Fingers still on the trackpad: a scroll, a pinch or a four-finger drag that hasn't ended. A pause
    /// with them down isn't a rest.
    private var scrollHeld = false
    private var pinchHeld = false
    private var fourFingersHeld = false
    /// When the last input event arrived: the link stays up this long after, so a gesture doesn't
    /// stop and restart it between events.
    private var lastInput: CFTimeInterval = 0
    nonisolated static let inputLinger: CFTimeInterval = 0.15
    /// The previous tick's time, for the coasts, and its target, for counting missed frames.
    private var lastTick: CFTimeInterval?
    private var lastTarget: CFTimeInterval?
    private let perf = PerfMonitor.shared
    /// The perf summary under the zoom readout, only with `PerfLog` on.
    private let hudPerf = CATextLayer()

    /// A window opening onto the canvas or leaving it, as `WindowEffect` draws it: the window's own
    /// frame each tick, and what the canvas draws with it — a veil to brighten or dim it, Bloom's ring,
    /// the neighbour Dealt nudges aside. Ticked by the display link alongside the camera; input never
    /// cancels it.
    private struct Entrance {
        let proxy: WindowProxy
        let added: CFTimeInterval
        /// Nil until there is something to show: the first captured frame, or at once for a real window.
        var start: CFTimeInterval?
        var opening: Bool
        var style: WindowEffect.Style
        var context: WindowEffect.Context
        /// The window it was placed beside, while it is on the canvas: Dealt comes out from behind it.
        weak var neighbour: WindowProxy?
        /// Dealt moved the window under its neighbour for the opening: on top again once it's out.
        var underNeighbour = false
        var ring: CAShapeLayer?
        var veil: CAShapeLayer?
        /// A close: what to do once the window is gone from sight.
        var completion: (() -> Void)?
    }
    private var entrances: [Entrance] = []
    /// Closed windows held gone (their last frame) until the listing drops them, or the close is undone.
    private var held: [(proxy: WindowProxy, entrance: Entrance)] = []
    /// An entrance moved this frame: the real-window renderer resends its transforms.
    var onEntranceChanged: (() -> Void)?

    // MARK: Setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        for l in [worldLayer, windowsLayer, chromeLayer, backdropWorldLayer, backdropFloorLayer, frontFloorLayer] {
            l.anchorPoint = .zero
            l.position = .zero
            l.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        worldLayer.actions = ["transform": NSNull()]
        backdropWorldLayer.actions = ["transform": NSNull()]
        backdropFloorLayer.actions = ["transform": NSNull()]
        frontFloorLayer.actions = ["transform": NSNull()]
        worldLayer.addSublayer(windowsLayer)
        worldLayer.addSublayer(chromeLayer)
        layer?.addSublayer(worldLayer)
        desktopDim.backgroundColor = NSColor.black.cgColor
        desktopDim.opacity = 0
        desktopDim.anchorPoint = .zero
        desktopDim.position = .zero
        desktopDim.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(desktopDim)
        layer?.addSublayer(frontFloorLayer)
        if let own = layer { backgroundRenderer.mount(in: own, bounds: bounds, scale: 2, occlusionSafe: true) }
        backgroundRenderer.onLookChanged = { [weak self] in self?.applyInk() }

        dropGlow.fillColor = nil
        dropGlow.strokeColor = NSColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1).cgColor
        dropGlow.lineWidth = 4
        dropGlow.opacity = 0
        dropGlow.shadowColor = dropGlow.strokeColor
        dropGlow.shadowOpacity = 0.8
        dropGlow.shadowRadius = 12
        dropGlow.shadowOffset = .zero
        dropGlow.zPosition = 2
        dropGlow.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(dropGlow)
        let r: CGFloat = 14
        openHereRing.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        openHereRing.path = CGPath(ellipseIn: openHereRing.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        openHereRing.fillColor = NSColor(white: 1, alpha: 0.18).cgColor
        openHereRing.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        openHereRing.lineWidth = 2
        openHereRing.shadowColor = NSColor.black.cgColor
        openHereRing.shadowOpacity = 0.35
        openHereRing.shadowRadius = 4
        openHereRing.shadowOffset = .zero
        openHereRing.zPosition = 2
        openHereRing.opacity = 0
        openHereRing.actions = ["position": NSNull()]
        layer?.addSublayer(openHereRing)
        registerForDraggedTypes([.fileURL])

        guidesLayer.anchorPoint = .zero
        guidesLayer.position = .zero
        guidesLayer.zPosition = 1   // over the labels and controls, which come and go below it
        guidesLayer.fillColor = nil
        guidesLayer.strokeColor = NSColor(red: 1, green: 0.32, blue: 0.62, alpha: 1).cgColor
        guidesLayer.lineCap = .round
        guidesLayer.actions = ["path": NSNull(), "lineWidth": NSNull(), "position": NSNull(), "bounds": NSNull()]
        chromeLayer.addSublayer(guidesLayer)

        // Just the zoom: the keys are in Settings › How to use › Keyboard (`ShortcutReference`), not across the canvas.
        hudZoom.anchorPoint = CGPoint(x: 0, y: 1)
        hudZoom.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hudZoom.fontSize = 11
        hudZoom.actions = ["position": NSNull(), "contents": NSNull()]
        layer?.addSublayer(hudZoom)
        hudZoom.bounds = CGRect(x: 0, y: 0, width: 48, height: 14)
        hudPerf.anchorPoint = CGPoint(x: 0, y: 1)
        hudPerf.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        hudPerf.fontSize = 10
        hudPerf.actions = ["position": NSNull(), "contents": NSNull()]
        hudPerf.bounds = CGRect(x: 0, y: 0, width: 720, height: 13)
        layer?.addSublayer(hudPerf)
        if perf.enabled {
            perf.onSummary = { [weak self] line in self?.hudPerf.string = line }
        }
        zoomReadoutSettingChanged()
        NotificationCenter.default.addObserver(forName: Settings.zoomReadoutDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomReadoutSettingChanged() }
        }
        background = Settings.background(for: effectiveAppearance)
        applyBackground()
        backgroundRenderer.apply(Settings.backgroundSpec, dark: Settings.usesDark(for: effectiveAppearance), animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Settings › Canvas › Zoom level: the readout in the top-left corner, and the `PerfLog` line under
    /// it, shown or hidden together.
    func zoomReadoutSettingChanged() {
        let on = Settings.showZoomReadout
        hudZoom.isHidden = !on
        hudPerf.isHidden = !on || !perf.enabled
    }

    /// Whether the zoom readout is on screen, for tests.
    var zoomReadoutShown: Bool { !hudZoom.isHidden }

    override var acceptsFirstResponder: Bool { true }

    /// The Mac's appearance flipped (System Settings › Appearance, or Auto at dusk and dawn): the canvas
    /// follows if it's set to match.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground(animated: true)
    }

    /// The colour the settings and the Mac's appearance call for now. Nothing happens if it's the one
    /// already up; otherwise it's applied at once, or cross-faded like the Mac's own windows when the
    /// appearance flips.
    func updateBackground(animated: Bool = false) {
        backgroundRenderer.apply(Settings.backgroundSpec, dark: Settings.usesDark(for: effectiveAppearance), animated: animated)
        let color = Settings.background(for: effectiveAppearance)
        guard color != background else {
            applyInk()
            return
        }
        background = color
        applyBackground(animated: animated)
    }

    /// The background goes onto `host` (the live-windows backdrop, under the real windows) while they're
    /// up — the canvas view is nearly clear then — and back under the canvas with nil.
    func hostBackground(in host: CALayer?) {
        let scale = window?.backingScaleFactor ?? 2
        if let host {
            backgroundRenderer.mount(in: host, bounds: bounds, scale: scale, occlusionSafe: false)
        } else if let own = layer {
            backgroundRenderer.mount(in: own, bounds: bounds, scale: scale, occlusionSafe: true)
        }
    }

    /// The widgets go onto `host` (the live-windows backdrop, above the background) while the real
    /// windows are up, and back under the canvas's windows with nil. Live windows don't show widgets
    /// (Notification Center's windows sit in the desktop's band, and moved in with the app windows they
    /// never appear), so widgets stay captured textures, which have to be under the real windows.
    func hostWidgets(in host: CALayer?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let host {
            if backdropWorldLayer.superlayer !== host { host.addSublayer(backdropWorldLayer) }
            host.insertSublayer(backdropFloorLayer, below: backdropWorldLayer)
            backdropWorldLayer.transform = worldLayer.transform
            backdropFloorLayer.transform = worldLayer.transform
        } else {
            backdropWorldLayer.removeFromSuperlayer()
            backdropFloorLayer.removeFromSuperlayer()
        }
        placeFloor()
        // Front to back, each to the bottom, so the widgets keep their order under every window.
        let parent = host == nil ? windowsLayer : backdropWorldLayer
        for p in proxies.reversed() where p.kind == .widget { parent.insertSublayer(p.layer, at: 0) }
        CATransaction.commit()
    }

    /// Finder's desktop goes under everything in the world (see `DesktopFloor`).
    func setFloor(_ floor: CALayer) {
        floorLayer = floor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeFloor()
        CATransaction.commit()
    }

    /// Over the dim while the desktop is shown; else under the widgets on the backdrop while the real
    /// windows are up, or under the windows.
    private func placeFloor() {
        guard let floor = floorLayer else { return }
        if showsDesktop {
            if floor.superlayer !== frontFloorLayer { frontFloorLayer.addSublayer(floor) }
        } else if widgetsOnBackdrop {
            if floor.superlayer !== backdropFloorLayer { backdropFloorLayer.addSublayer(floor) }
        } else {
            worldLayer.insertSublayer(floor, below: windowsLayer)
        }
    }

    /// Show Desktop on or off: the dim fades over every window and widget, and the floor goes above it
    /// for as long as it lasts. The camera is the controller's business.
    func setShowsDesktop(_ on: Bool, animated: Bool = true) {
        guard on != showsDesktop else { return }
        showsDesktop = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeFloor()
        CATransaction.commit()
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(on ? 0.3 : 0.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        desktopDim.opacity = on ? CanvasView.desktopDimOpacity : 0
        CATransaction.commit()
    }

    private func proxiesLayer(for proxy: WindowProxy) -> CALayer {
        proxy.kind == .widget && widgetsOnBackdrop ? backdropWorldLayer : windowsLayer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        hudZoom.contentsScale = scale
        hudPerf.contentsScale = scale
        backgroundRenderer.resize(bounds: bounds, scale: scale)
    }

    override func layout() {
        super.layout()
        // The menu bar overlays the top of our full-screen window; keep the HUD below it.
        var topInset: CGFloat = 40
        if let screen = window?.screen { topInset = screen.frame.maxY - screen.visibleFrame.maxY }
        hudZoom.position = CGPoint(x: 16, y: bounds.height - topInset - 12)
        hudPerf.position = CGPoint(x: 16, y: bounds.height - topInset - 30)
        backgroundRenderer.resize(bounds: bounds, scale: window?.backingScaleFactor ?? 2)
        dropGlow.frame = bounds
        desktopDim.bounds = bounds
        dropGlow.path = CGPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), cornerWidth: 18, cornerHeight: 18, transform: nil)
        applyCamera()
    }

    private func applyBackground(animated: Bool = false) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.4)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)  // follow the colour panel live, no cross-fade
        }
        let from = layer?.backgroundColor
        // Deliberately not fully opaque: the window beneath is non-opaque too, which keeps the window
        // server from marking the real windows as occluded (occluded apps throttle or stop drawing).
        layer?.backgroundColor = background.withAlphaComponent(showsRealWindows ? 0.01 : 0.985).cgColor
        if animated, let from {
            // The view is its backing layer's delegate and gives it no implicit animations, so the fade
            // is spelled out; the text layers below pick up the transaction's on their own.
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = from
            fade.duration = 0.4
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "backgroundColor")
        }
        CATransaction.commit()
        applyInk()
    }

    /// Ink from what's behind the windows now: the colour, or the picture once it's in (its luminance,
    /// with the dim it reaches). On a picture the labels get a soft shadow, so they read anywhere on it.
    private func applyInk() {
        let onPicture = !backgroundRenderer.spec.isPlainColor
        let light = onPicture ? backgroundRenderer.isLight : background.isLight
        ink = light ? .black : .white
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hudZoom.foregroundColor = ink.withAlphaComponent(0.55).cgColor
        hudPerf.foregroundColor = ink.withAlphaComponent(0.55).cgColor
        for p in proxies { styleLabel(p) }
        CATransaction.commit()
    }

    private func styleLabel(_ proxy: WindowProxy) {
        proxy.styleLabel(ink: ink, shadow: !backgroundRenderer.spec.isPlainColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Proxies

    /// `arriving`: the window is new to the canvas (not one of the launch sync's, not one in front),
    /// so it pops in rather than appearing in a frame.
    func add(_ proxy: WindowProxy, arriving: Bool = false) {
        proxies.append(proxy)
        styleLabel(proxy)
        proxiesLayer(for: proxy).addSublayer(proxy.layer)
        chromeLayer.addSublayer(proxy.label)
        chromeLayer.addSublayer(proxy.controls)
        chromeLayer.addSublayer(proxy.trailingControls)
        proxy.layout(zoom: camera.zoom)
        orderPipOnTop()   // a new window goes under the tiles
        if arriving { beginEntrance(proxy, context: WindowEffect.Context()) }
        onContentChanged?()
    }

    func remove(_ proxy: WindowProxy) {
        proxies.removeAll { $0 === proxy }
        endEntrance(of: proxy)
        held.removeAll { $0.proxy === proxy }
        if hovered === proxy { hovered = nil }
        proxy.outlined = false
        outlinedMembers.removeAll { $0 === proxy }
        if dragging?.proxy === proxy {
            dragging = nil
            show([])
        }
        if resizing?.proxy === proxy {
            resizing = nil
            setCursor([])
        }
        if var d = dragging, d.members.contains(where: { $0.proxy === proxy }) {
            d.members.removeAll { $0.proxy === proxy }
            dragging = d
        }
        if var m = magnet {
            if m.proxy === proxy {
                settleMagnet(now: true)
            } else {
                m.members.removeAll { $0.proxy === proxy }
                m.joined.removeAll { $0.proxy === proxy }
                m.pushes.removeAll { $0.proxy === proxy }
                for i in m.pushes.indices { m.pushes[i].members.removeAll { $0.proxy === proxy } }
                magnet = m
            }
        }
        proxy.stop()
        onContentChanged?()
    }

    func bringToFront(_ proxy: WindowProxy) {
        guard let i = proxies.firstIndex(where: { $0 === proxy }) else { return }
        proxies.remove(at: i)
        proxies.append(proxy)
        proxy.layer.removeFromSuperlayer()
        proxiesLayer(for: proxy).addSublayer(proxy.layer)
        // Its sheets and prompts stay on top of it.
        for c in proxy.attachedChildren where proxies.contains(where: { $0 === c }) { bringToFront(c) }
        orderPipOnTop()   // and the tiles over all
        onContentChanged?()
    }

    /// Whether a world point is on the floor where the floor is what's seen, and the file there if any.
    /// With the desktop shown the files are lit above everything, so a file wins over the dimmed window
    /// under it, while the rest of a dimmed window is still the window. Otherwise the floor is under
    /// every window and widget.
    private func floorHit(at worldPoint: CGPoint) -> (onFloor: Bool, icon: DesktopIcon?) {
        guard let floor = desktopFloor, floor.contains(worldPoint) else { return (false, nil) }
        if showsDesktop, let icon = floor.icon(atWorld: worldPoint) { return (true, icon) }
        guard proxy(at: worldPoint) == nil else { return (false, nil) }
        return (true, floor.icon(atWorld: worldPoint))
    }

    /// The window under a world point. A sheet or prompt isn't a window of its own here: the press,
    /// hover or drag is its parent's (the real press still lands on the sheet, which is on top of it).
    func proxy(at worldPoint: CGPoint) -> WindowProxy? {
        // A window in Picture in Picture is where its tile is, over everything; its home is empty ground.
        if let tile = pipProxy(atScreen: camera.toScreen(worldPoint)) { return tile }
        guard let hit = proxies.last(where: { !$0.leaving && !$0.closing && $0.pip == nil && $0.worldRect.contains(worldPoint) }) else { return nil }
        if let parentID = hit.attachedTo, let parent = proxies.first(where: { $0.windowID == parentID }) { return parent }
        return hit
    }

    // MARK: Camera

    func set(camera: Camera) {
        self.camera = camera
        applyCamera()
    }

    /// The world layer's transform is the camera; the proxies live in world units and never move for
    /// it. Only the counter-scaled chrome depends on the zoom, so a pan touches one transform and a
    /// zoom touches a few layer properties per proxy.
    private func applyCamera() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        worldLayer.transform = camera.layerTransform(viewHeight: bounds.height)
        backdropWorldLayer.transform = worldLayer.transform
        backdropFloorLayer.transform = worldLayer.transform
        frontFloorLayer.transform = worldLayer.transform
        backgroundRenderer.cameraChanged(camera)
        // Chrome is laid out for the proxies near the view; one far off is left as it is until it comes
        // near, which a pan can bring about without the zoom changing.
        let near = CGRect(origin: .zero, size: bounds.size).insetBy(dx: -bounds.width, dy: -bounds.height)
        if camera.zoom != appliedZoom {
            appliedZoom = camera.zoom
            for p in proxies {
                if camera.toScreen(p.worldRect).intersects(near) { p.layoutChrome(zoom: camera.zoom) } else { p.leaveChromeStale() }
            }
            if !guides.isEmpty { drawGuides() }
            let percent = Int((camera.zoom * 100).rounded())
            if percent != hudPercent {
                hudPercent = percent
                hudZoom.string = "\(percent)%"
            }
        } else {
            for p in proxies where p.chromeStale && camera.toScreen(p.worldRect).intersects(near) {
                p.layoutChrome(zoom: camera.zoom)
            }
        }
        // A tile is drawn at its spot on the screen whatever the camera does: its effect and its chrome
        // follow every camera, pans included.
        for p in proxies where p.drawnPip != nil { layoutPip(p) }
        if let mark = openHereMark { openHereRing.position = layerPoint(camera.toScreen(mark)) }
        CATransaction.commit()
        onCameraChanged?()
        onViewportChanged?()
    }

    // MARK: Picture in Picture

    /// The window drawn at its tile (`PictureInPicture.effect`), its chrome laid out there. Inside a
    /// transaction with actions off, or on its own.
    private func layoutPip(_ p: WindowProxy) {
        guard let f = p.drawnPip else { return }
        p.setEffect(PictureInPicture.effect(f, worldRect: p.worldRect, camera: camera), zoom: camera.zoom)
        p.pipWorldRect = camera.toWorld(PictureInPicture.rect(f, size: p.worldRect.size))
        p.layoutChrome(zoom: camera.zoom)
    }

    /// The controller put a window into Picture in Picture, took it out, or moved its tile: drawn
    /// accordingly, above every other window while in PiP, and the live windows told.
    func pipChanged(_ p: WindowProxy) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if p.drawnPip != nil {
            layoutPip(p)
        } else {
            p.pipWorldRect = nil
            p.setEffect(.identity, zoom: camera.zoom)
            p.layoutChrome(zoom: camera.zoom)
        }
        CATransaction.commit()
        orderPipOnTop()
        onPipChanged?()
        onContentChanged?()
    }

    /// The tiles above the rest, in their own order: a tile on the screen is over whatever the camera
    /// brings under it, and the live frames send them last, just under the canvas's chrome.
    private func orderPipOnTop() {
        let tiles = proxies.filter { $0.pip != nil }
        guard let lowest = tiles.first, let i = proxies.firstIndex(where: { $0 === lowest }),
              proxies[i...].contains(where: { $0.pip == nil }) else { return }
        proxies.removeAll { $0.pip != nil }
        proxies += tiles
        for p in tiles {
            p.layer.removeFromSuperlayer()
            proxiesLayer(for: p).addSublayer(p.layer)
        }
    }

    /// A tile on its way somewhere on a spring, the camera staying put: into its corner, back to 1:1,
    /// home, behind an edge. `pipShown` follows each frame and the real window with it.
    private struct PipFlight {
        let from: PipFrame
        let to: PipFrame
        /// Progress from 0 to 1 along the way, as a spring's offset from 1 (a fling starts it moving).
        let spring: Spring
        let start: CFTimeInterval
        let completion: (() -> Void)?
    }
    private var pipFlights: [ObjectIdentifier: PipFlight] = [:]

    /// Flies a tile from where it's drawn now to `to`. `velocity` (screen points per second) carries a
    /// fling into the spring; `response` and `damping` are the spring's (`PictureInPicture.Reference`).
    /// A flight already under way is re-aimed from where it is. `completion` once there, or never if
    /// re-aimed or cancelled. With Reduce Motion on, the tile just lands.
    func flyPip(_ p: WindowProxy, to: PipFrame, velocity: CGVector = .zero,
                response: CGFloat = PictureInPicture.Reference.snapResponse,
                damping: CGFloat = PictureInPicture.Reference.snapDamping, completion: (() -> Void)? = nil) {
        let from = p.drawnPip ?? to
        let key = ObjectIdentifier(p)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || from == to {
            pipFlights.removeValue(forKey: key)
            p.pipShown = to
            pipChanged(p)
            completion?()
            return
        }
        // The spring runs along the straight way from `from` to `to`; a fling's speed along that way
        // becomes its starting velocity (in units of the way's length), crosswise speed is dropped.
        let dx = to.origin.x - from.origin.x, dy = to.origin.y - from.origin.y
        let length = max(1, hypot(dx, dy))
        let along = (velocity.dx * dx + velocity.dy * dy) / length / length
        pipFlights[key] = PipFlight(from: from, to: to,
                                    spring: Spring(x0: -1, v0: along, response: response, damping: damping),
                                    start: CACurrentMediaTime(), completion: completion)
        p.pipShown = from
        startDisplayLink()
    }

    /// Drops a tile's flight where it is, `pipShown` staying as drawn (the controller settles it).
    func cancelPipFlight(_ p: WindowProxy) {
        pipFlights.removeValue(forKey: ObjectIdentifier(p))
    }

    var isFlyingPip: Bool { !pipFlights.isEmpty }

    private func tickPip(at now: CFTimeInterval) {
        guard !pipFlights.isEmpty else { return }
        var done: [(WindowProxy, PipFlight)] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for p in proxies {
            guard let f = pipFlights[ObjectIdentifier(p)] else { continue }
            let (x, v) = f.spring.evaluate(at: CGFloat(now - f.start))
            if abs(x) < 0.001, abs(v) < 0.01 {
                p.pipShown = f.to
                done.append((p, f))
            } else {
                p.pipShown = PictureInPicture.mix(f.from, f.to, 1 + x)
            }
            layoutPip(p)
        }
        CATransaction.commit()
        onPipChanged?()
        for (p, f) in done {
            pipFlights.removeValue(forKey: ObjectIdentifier(p))
            f.completion?()
        }
    }

    /// The window whose tile is under a screen point, topmost first.
    private func pipProxy(atScreen point: CGPoint) -> WindowProxy? {
        proxies.last { p in
            guard let f = p.drawnPip, !p.leaving, !p.closing else { return false }
            return PictureInPicture.rect(f, size: p.worldRect.size).contains(point)
        }
    }

    /// Tiles are placed and dragged in view coordinates; the controller tells the view the display's
    /// visible part.
    var pipArea: (() -> CGRect)?
    private var visibleForPip: CGRect { pipArea?() ?? CGRect(origin: .zero, size: bounds.size) }

    /// A tile let go (a drag's end, a resize's end, a pinch's end): it springs to the corner it's heading
    /// for, or tucks behind an edge it was dragged past, and the controller hears where it settled.
    private func settlePip(_ p: WindowProxy, velocity: CGVector = .zero, freely: Bool = false) {
        guard let f = p.drawnPip else { return }
        let size = p.worldRect.size, visible = visibleForPip
        let target: PipFrame
        var response = PictureInPicture.Reference.snapResponse, damping = PictureInPicture.Reference.snapDamping
        if freely {
            // ⌘ held: left where it was dropped, just kept on the screen.
            p.pipTucked = nil
            target = PictureInPicture.clamped(f, size: size, visible: visible)
        } else if let side = PictureInPicture.tuck(of: f, velocity: velocity, size: size, visible: visible) {
            p.pipTucked = side
            target = PictureInPicture.tucked(f, behind: side, size: size, visible: visible)
            response = PictureInPicture.Reference.tuckResponse
            damping = PictureInPicture.Reference.tuckDamping
        } else {
            p.pipTucked = nil
            let corner = PictureInPicture.corner(for: f, velocity: velocity, size: size, visible: visible)
            target = PictureInPicture.frame(in: corner, scale: f.scale, size: size, visible: visible)
            p.lastPipCorner = corner
        }
        // Drawn where it was let go until the spring moves it: the flight starts from `drawnPip`, so the
        // resting frame is set only once that is held in `pipShown` (set first, it was already there).
        p.pipShown = f
        p.pip = target
        flyPip(p, to: target, velocity: velocity, response: response, damping: damping) { [weak self, weak p] in
            guard let self, let p else { return }
            p.pipShown = nil
            self.pipChanged(p)
            Haptics.Player.shared.play(.detent, key: ObjectIdentifier(p))
            self.onPipMoved?(p)
        }
    }

    /// A tucked tile's tab clicked, or the tile dragged back on: it springs to the corner on its side.
    func untuckPip(_ p: WindowProxy) {
        guard let side = p.pipTucked, let f = p.drawnPip else { return }
        p.pipTucked = nil
        let target = PictureInPicture.untucked(f, from: side, size: p.worldRect.size, visible: visibleForPip)
        p.lastPipCorner = PictureInPicture.corner(of: target, size: p.worldRect.size, visible: visibleForPip)
        p.pipShown = f   // the spring starts from behind the edge (see `settlePip`)
        p.pip = target
        flyPip(p, to: target) { [weak self, weak p] in
            guard let self, let p else { return }
            p.pipShown = nil
            self.pipChanged(p)
            self.onPipMoved?(p)
        }
    }

    /// The tile's rect on screen (view coordinates) as drawn now, for the chrome panel.
    func pipRect(of p: WindowProxy) -> CGRect? {
        p.drawnPip.map { PictureInPicture.rect($0, size: p.worldRect.size) }
    }

    /// A drag of a tile begun from its chrome panel rather than the canvas, at a view point.
    func beginPipDrag(_ p: WindowProxy, at screenPoint: CGPoint) {
        guard p.drawnPip != nil, pipDrag == nil, dragging == nil, resizing == nil else { return }
        cancelPipFlight(p)
        if let shown = p.pipShown { p.pip = shown; p.pipShown = nil }
        let r = PictureInPicture.rect(p.pip!, size: p.worldRect.size)
        pipDrag = PipDrag(proxy: p, grabOffset: CGPoint(x: screenPoint.x - r.minX, y: screenPoint.y - r.minY), start: screenPoint)
    }

    func movePipDrag(to screenPoint: CGPoint, timestamp: TimeInterval) {
        guard var d = pipDrag, var f = d.proxy.pip else { return }
        if !d.moved {
            guard hypot(screenPoint.x - d.start.x, screenPoint.y - d.start.y) >= CanvasView.dragSlop else { return }
            d.moved = true
            d.proxy.pipTucked = nil
        }
        d.velocity.add(screenPoint, at: timestamp)
        pipDrag = d
        f = PictureInPicture.dragged(f, to: CGPoint(x: screenPoint.x - d.grabOffset.x, y: screenPoint.y - d.grabOffset.y),
                                     size: d.proxy.worldRect.size, visible: visibleForPip)
        d.proxy.pip = f
        pipChanged(d.proxy)
    }

    /// The drag's end: true when it had moved (the tile settles); false for a click.
    @discardableResult
    func endPipDrag(timestamp: TimeInterval, freely: Bool = false) -> Bool {
        guard let d = pipDrag else { return false }
        pipDrag = nil
        if d.moved {
            settlePip(d.proxy, velocity: d.velocity.release(at: timestamp), freely: freely)
            return true
        }
        return false
    }

    /// A top-left view point in the (bottom-left) root layer's coordinates.
    private func layerPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// The Open Here… ring fades in where the bar will open an app, gently pulsing, and fades out with it.
    private func showOpenHereMark(was old: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let mark = openHereMark { openHereRing.position = layerPoint(camera.toScreen(mark)) }
        CATransaction.commit()
        let on = openHereMark != nil
        guard on != (old != nil) else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = openHereRing.presentation()?.opacity ?? openHereRing.opacity
        fade.toValue = on ? 1 : 0
        fade.duration = on ? 0.15 : 0.25
        openHereRing.add(fade, forKey: "opacity")
        openHereRing.opacity = on ? 1 : 0
        if on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1
            pulse.toValue = 1.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            openHereRing.add(pulse, forKey: "pulse")
        } else if !on {
            openHereRing.removeAnimation(forKey: "pulse")
        }
    }

    private func clampedZoom(_ z: CGFloat) -> CGFloat {
        min(CanvasView.maxZoom, max(CanvasView.minZoom, z))
    }

    /// Zooms around a fixed screen point, so whatever is under the pointer stays under the pointer.
    func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        let anchor = camera.toWorld(screenPoint)
        camera.zoom = clampedZoom(camera.zoom * factor)
        camera.origin = CGPoint(x: anchor.x - screenPoint.x / camera.zoom,
                                y: anchor.y - screenPoint.y / camera.zoom)
        applyCamera()
    }

    /// Four-finger drag (`TrackpadPan`): `travel` is in trackpad widths, and the content follows it on
    /// the next frame.
    func trackpadPan(by travel: CGVector) {
        beginInput()
        let k = bounds.width * CanvasView.trackpadPanGain
        let delta = CGVector(dx: travel.dx * k, dy: travel.dy * k)
        fourFingersHeld = true
        panTravel.x += delta.dx
        panTravel.y += delta.dy
        panVelocity.add(panTravel, at: CACurrentMediaTime())
        pending.addPan(delta)
    }

    /// The four fingers lifted: the pan coasts on from the speed it had, slowing as a scroll does
    /// (see `Motion.PanCoast`). Any input, click or key stops it. Nothing with pan inertia off in
    /// Settings, or under Reduce Motion.
    func trackpadPanEnded() {
        let now = CACurrentMediaTime()
        let v = panVelocity.release(at: now)
        panTravel = .zero
        panVelocity = Magnetism.Velocity()
        fingersLifted()
        guard Settings.panInertia, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        coast = Motion.PanCoast(velocity: v, at: now)
        if coast != nil { startDisplayLink() }
    }

    /// The four-finger drag turned out to be a flick: the pan stops where it is, no coast.
    func trackpadPanCancelled() {
        panTravel = .zero
        panVelocity = Magnetism.Velocity()
        fourFingersHeld = false
    }

    /// A gesture's fingers came off: the camera may be at rest already, with the link long stopped, so
    /// one comes round to see (`settleIfStill`).
    private func fingersLifted() {
        fourFingersHeld = false
        guard settleWhenStill else { return }
        startDisplayLink()
    }

    /// The user moved the camera without input events of the view's own (the minimap): ask `onSettle`
    /// once it's at rest.
    func noteUserMove() {
        settleWhenStill = true
        startDisplayLink()
    }

    /// At rest after the user moved it, nothing held and nothing in hand: `onSettle` gets its one look.
    private func settleIfStill(at now: CFTimeInterval) {
        guard settleWhenStill, animation == nil, flight == nil, magnet == nil, pending.isEmpty, coast == nil,
              zoomCoast == nil, now - lastInput > CanvasView.inputLinger, !scrollHeld, !pinchHeld,
              !fourFingersHeld, !panning, dragging == nil, resizing == nil else { return }
        settleWhenStill = false
        _ = onSettle?()
    }

    /// An input event is about to change the camera: whatever motion was running stops, and the
    /// change goes into `pending` for the next display frame. The link is kept rather than stopped
    /// and restarted between the events of one gesture.
    private func beginInput() {
        lastInput = CACurrentMediaTime()
        settleWhenStill = true
        interruptMotion()
        startDisplayLink()
    }

    /// Applies gathered input now rather than on the next frame: for a decision that needs the camera
    /// as the gesture left it (the pinch handoff).
    private func flushInput() {
        guard !pending.isEmpty else { return }
        camera = pending.applied(to: camera, clamp: clampedZoom)
        pending = Motion.PendingInput()
        applyCamera()
    }

    func fitAll(animated: Bool) {
        guard let target = overviewCamera else { return }
        if animated { animateCamera(to: target) } else { set(camera: target) }
    }

    /// Frames a world rect with some air around it, never closer than 1:1.
    func fit(_ rect: CGRect, animated: Bool) {
        let target = framing(rect)
        if animated { animateCamera(to: target) } else { set(camera: target) }
    }

    /// The camera that frames a world rect with some air around it, never closer than 1:1.
    func framing(_ rect: CGRect) -> Camera {
        let padded = rect.insetBy(dx: -rect.width * 0.08 - 40, dy: -rect.height * 0.08 - 60)
        let area = unobscuredRect
        let zoom = clampedZoom(min(area.width / padded.width, area.height / padded.height))
        // Camera centres on the whole view; shift so the rect lands in the middle of the unobscured area.
        return Camera(center: CGPoint(x: padded.midX, y: padded.midY - (area.midY - bounds.midY) / zoom),
                      zoom: zoom, viewSize: bounds.size)
    }

    /// The camera that frames every window; nil when the canvas is empty. The desktop (its files and
    /// widgets) is left out so See All is as close as the windows allow; with no windows, it's what's framed.
    var overviewCamera: Camera? {
        // Tiles in Picture in Picture are on the screen wherever the camera goes: their homes needn't be in view.
        var rects = proxies.filter { $0.kind == .window && $0.pip == nil }.map(\.worldRect)
        if rects.isEmpty {
            rects = proxies.map(\.worldRect)
            if let files = desktopFilesRect { rects.append(files) }
        }
        guard let first = rects.first else { return nil }
        return framing(rects.dropFirst().reduce(first) { $0.union($1) })
    }

    /// The window under the pointer, if any: what a tiling shortcut acts on.
    var hoveredWindow: WindowProxy? { hovered?.kind == .window ? hovered : nil }

    /// Programmatic hover: the ⌘Tab switcher walks the recent windows with it.
    func highlight(_ proxy: WindowProxy?) { setHovered(proxy) }

    /// Display-link driven so zoom interpolates in log space and the centre moves in a straight line —
    /// the two things Core Animation's implicit transform interpolation gets subtly wrong.
    /// `moving` eases windows to new world origins over the same curve.
    func animateCamera(to target: Camera, duration: CFTimeInterval = CanvasView.cameraDuration,
                       moving: [(proxy: WindowProxy, to: CGPoint)] = [], step: ((CGFloat) -> Void)? = nil,
                       completion: (() -> Void)? = nil) {
        interruptMotion()
        settleWhenStill = false
        animation = CameraAnimation(from: camera, to: target, start: CACurrentMediaTime(), duration: duration,
                                    moves: moving.map { ($0.proxy, $0.proxy.worldRect.origin, $0.to) },
                                    step: step, completion: completion)
        startDisplayLink()
        onViewportChanged?()   // the target is known from the first frame
    }

    /// Eases windows to new places on the canvas, the camera staying where it is. No completion: one
    /// would be reported as a cancelled handoff if something interrupted the glide.
    func glide(_ moves: [(proxy: WindowProxy, to: CGPoint)], duration: CFTimeInterval = CanvasView.snapDuration) {
        let moves = moves.filter { $0.proxy.worldRect.origin != $0.to }
        guard !moves.isEmpty else { return }
        animateCamera(to: camera, duration: duration, moving: moves)
    }

    var isFlying: Bool { flight != nil }

    /// Something is moving under the hand or on its own: a drag, a resize, a push settling, the camera or
    /// a glide. Strip mode waits for it before laying the strip out again.
    var isBusy: Bool { animation != nil || flight != nil || dragging != nil || resizing != nil || magnet != nil }

    /// Where the desktop's files are drawn in the world, while they are.
    var desktopFilesRect: CGRect? {
        guard let floor = desktopFloor, floor.isEnabled, floor.windowID != nil else { return nil }
        return floor.worldRect
    }

    /// Nothing moving at all, the hand's pans and their coasts included: the desktop's blocks may glide.
    var isStill: Bool { !isBusy && !panning && coast == nil && zoomCoast == nil && floorPress == nil }

    /// The camera at 1:1, where a window on the canvas is used as it is on the desktop (`onUse`).
    var isOneToOne: Bool { abs(camera.zoom - 1) < 0.001 }

    /// Marks the mouse events Sunlight posts to pass a press on (`eventSourceUserData`), so the canvas
    /// never takes one of its own for the user's.
    static let passedOnMark: Int64 = 0x53554e4c

    private static func isPassedOn(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == passedOnMark
    }

    /// At 1:1 a press on a window behind the one in use is that window's, as on the desktop: it comes
    /// through on the click that brings the canvas forward instead of needing a second one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Using windows at any zoom, another app is in front while Sunlight still shows the canvas: a
        // drag on a window's title strip (or anywhere with ⌘ ⌥) moves it on the first press.
        if let event, Settings.useScaledWindows, showsRealWindows, !isOneToOne, isCovered?(topLeftPoint(event)) != true,
           proxy(at: camera.toWorld(topLeftPoint(event)))?.kind == .window { return true }
        guard let event, isOneToOne, isCovered?(topLeftPoint(event)) != true else { return false }
        return proxy(at: camera.toWorld(topLeftPoint(event)))?.kind == .window
    }

    /// Flies to a camera along a pan-and-zoom path, driven by a spring that overshoots a little and
    /// settles. Calling it mid-flight re-aims from where the camera is, keeping its speed, so walking
    /// the switcher quickly stays one fluid move instead of restarting at every step.
    func fly(to target: Camera, completion: (() -> Void)? = nil) {
        var speed: CGFloat = 0   // along the path, in the path's own units per second
        if let f = flight {
            let (x, v) = f.spring.evaluate(at: CGFloat(CACurrentMediaTime() - f.start))
            camera = f.path.camera(at: 1 + x)
            speed = v * f.path.length
            flight = nil
            if f.completion != nil { onAnimationCancelled?() }
        } else {
            interruptMotion()
        }
        settleWhenStill = false
        let path = CameraPath(from: camera, to: target, viewSize: bounds.size)
        guard path.length > 1e-4 else {
            set(camera: target)
            onFlightProgress?(1)
            completion?()
            return
        }
        flight = Flight(path: path, spring: Spring(x0: -1, v0: speed / path.length),
                        start: CACurrentMediaTime(), completion: completion)
        startDisplayLink()
        onViewportChanged?()
    }

    /// The last bit of the way onto a window the camera came to rest nearly on (`WindowSnap`): a short
    /// flight on a quick, stiff spring that barely overshoots. Under Reduce Motion it's there at once.
    func snap(to target: Camera, completion: @escaping () -> Void) {
        interruptMotion()
        settleWhenStill = false
        let path = CameraPath(from: camera, to: target, viewSize: bounds.size)
        guard path.length > 1e-4, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            set(camera: target)
            completion()
            return
        }
        flight = Flight(path: path, spring: Spring(x0: -1, v0: 0, response: WindowSnap.response, damping: WindowSnap.damping),
                        start: CACurrentMediaTime(), completion: completion)
        startDisplayLink()
        onViewportChanged?()
    }

    /// Called when something interrupts a camera move that carried a completion (a handoff), which
    /// then never runs.
    var onAnimationCancelled: (() -> Void)?

    func cancelAnimation() {
        interruptMotion()
        stopLinkIfIdle()
    }

    /// Drops whatever camera motion is running. A move with a completion is reported as cancelled so
    /// the controller can undo the state it set up for it.
    private func interruptMotion() {
        // Windows on their way somewhere (where the real one already is, the grid, a layout's spot) go
        // straight there.
        for m in animation?.moves ?? [] { m.proxy.place(at: m.to) }
        let hadCompletion = animation?.completion != nil || flight?.completion != nil
        let hadTarget = animation != nil || flight != nil
        let hadFlight = flight != nil
        animation = nil
        flight = nil
        coast = nil
        zoomCoast = nil
        if hadFlight { onFlightProgress?(1) }
        if hadCompletion { onAnimationCancelled?() }
        if hadTarget { onViewportChanged?() }
    }

    private func startDisplayLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = nil
        lastTarget = nil
    }

    /// Camera motion is over, settled or dropped. The link itself stays while an entrance needs it.
    private func finishMotion() {
        let hadTarget = animation != nil || flight != nil
        animation = nil
        flight = nil
        if hadTarget { onViewportChanged?() }
    }

    private func stopLinkIfIdle() {
        guard animation == nil, flight == nil, entrances.isEmpty, magnet == nil, pipFlights.isEmpty,
              pending.isEmpty, coast == nil, zoomCoast == nil,
              CACurrentMediaTime() - lastInput > CanvasView.inputLinger else { return }
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let began = CACurrentMediaTime()
        // The time this frame will be shown, not the time the callback ran: even pacing under load.
        let now = link.targetTimestamp
        var missed = 0
        if let last = lastTarget, link.duration > 0 {
            missed = max(0, Int(((now - last) / link.duration).rounded()) - 1)
        }
        lastTarget = now
        let coalesced = pending.events
        tickInput(at: now)
        tickCamera(at: now)
        tickEntrances(at: now)
        tickMagnet(at: now)
        tickPip(at: now)
        settleIfStill(at: now)   // may start a move of its own, which keeps the link
        lastTick = now
        perf.tick(apply: CACurrentMediaTime() - began, coalesced: coalesced, missed: missed)
        stopLinkIfIdle()   // after the completions: one may have started the next move
    }

    /// The input gathered since the last frame and the coasts, as one camera change.
    private func tickInput(at now: CFTimeInterval) {
        var input = pending
        pending = Motion.PendingInput()
        let from = lastTick ?? now
        if let c = coast {
            input.addPan(c.travel(from: from, to: now))
            if c.isOver(at: now) { coast = nil }
        }
        if let z = zoomCoast {
            input.addZoom(by: z.factor(from: from, to: now), around: z.anchor)
            if z.isOver(at: now) { zoomCoast = nil }
        }
        guard !input.isEmpty else { return }
        camera = input.applied(to: camera, clamp: clampedZoom)
        applyCamera()
        updateHover(at: pointerTopLeft)
    }

    private func tickCamera(at now: CFTimeInterval) {
        if let f = flight {
            let (x, v) = f.spring.evaluate(at: CGFloat(now - f.start))
            if abs(x) < 0.002, abs(v) < 0.02 {
                camera = f.path.camera(at: 1)
                applyCamera()
                onFlightProgress?(1)
                finishMotion()
                f.completion?()
            } else {
                camera = f.path.camera(at: 1 + x)
                applyCamera()
                onFlightProgress?(1 + x)
            }
            return
        }
        guard let a = animation else { return }
        let raw = min(1, max(0, (now - a.start) / a.duration))
        let s = 1 - pow(1 - raw, 3)  // ease-out cubic
        let zoom = a.from.zoom * pow(a.to.zoom / a.from.zoom, s)
        let c0 = a.from.center(viewSize: bounds.size), c1 = a.to.center(viewSize: bounds.size)
        let center = CGPoint(x: c0.x + (c1.x - c0.x) * s, y: c0.y + (c1.y - c0.y) * s)
        camera = raw >= 1 ? a.to : Camera(center: center, zoom: zoom, viewSize: bounds.size)
        for m in a.moves {
            m.proxy.place(at: raw >= 1 ? m.to
                : CGPoint(x: m.from.x + (m.to.x - m.from.x) * s, y: m.from.y + (m.to.y - m.from.y) * s))
        }
        a.step?(raw >= 1 ? 1 : s)
        applyCamera()
        if raw >= 1 {
            finishMotion()
            a.completion?()
        }
    }

    // MARK: Entrances

    /// The effect a window gets now, from Settings › Motion › Opening and closing.
    private func effectStyle(for context: WindowEffect.Context) -> WindowEffect.Style? {
        WindowEffect.style(for: Settings.windowEffect, context: context,
                           reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func beginEntrance(_ proxy: WindowProxy, context: WindowEffect.Context, style forced: WindowEffect.Style? = nil) {
        endEntrance(of: proxy)
        guard let style = forced ?? effectStyle(for: context) else { return }
        var entrance = Entrance(proxy: proxy, added: CACurrentMediaTime(), start: nil, opening: true,
                                style: style, context: context)
        decorate(&entrance)
        // The first frame is already small and faint: the window is never seen at full size first.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = advance(&entrance, at: entrance.added)
        CATransaction.commit()
        entrances.append(entrance)
        startDisplayLink()
    }

    /// The ring and the veil a style draws, made fresh.
    private func decorate(_ e: inout Entrance) {
        e.ring?.removeFromSuperlayer(); e.ring = nil
        e.veil?.removeFromSuperlayer(); e.veil = nil
        func layer() -> CAShapeLayer {
            let l = CAShapeLayer()
            l.anchorPoint = .zero
            l.position = .zero
            l.actions = ["path": NSNull(), "lineWidth": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull()]
            l.opacity = 0
            chromeLayer.insertSublayer(l, at: 0)   // over every window, under the labels and the guides
            return l
        }
        if e.opening, e.style == .bloom {
            let ring = layer()
            ring.fillColor = nil
            ring.strokeColor = ink.withAlphaComponent(0.8).cgColor
            ring.lineCap = .round
            e.ring = ring
        }
        if e.style == .sunrise {
            let veil = layer()
            veil.fillColor = NSColor.black.cgColor
            e.veil = veil
        }
    }

    /// What is known of a window that just opened, now that the controller has placed it: where it
    /// was asked for, the window it went beside, whether it hangs from another. Picks its effect again;
    /// the entrance hasn't been seen yet (it starts in this same turn of the run loop).
    func setArrival(of proxy: WindowProxy, context: WindowEffect.Context, neighbour: WindowProxy? = nil) {
        guard let i = entrances.firstIndex(where: { $0.proxy === proxy && $0.opening }) else { return }
        guard let style = effectStyle(for: context) else {
            endEntrance(of: proxy)
            return
        }
        var e = entrances[i]
        e.context = context
        e.neighbour = neighbour
        if style != e.style {
            e.style = style
            decorate(&e)
        }
        // Dealt comes out from behind its neighbour: under it until it's clear.
        if style == .dealt, let neighbour, neighbour.layer.superlayer === proxy.layer.superlayer,
           let n = proxies.firstIndex(where: { $0 === neighbour }), let p = proxies.firstIndex(where: { $0 === proxy }), n < p {
            proxies.remove(at: p)
            proxies.insert(proxy, at: n)
            proxy.layer.superlayer?.insertSublayer(proxy.layer, below: neighbour.layer)
            e.underNeighbour = true
            onContentChanged?()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = advance(&e, at: e.start ?? e.added)
        CATransaction.commit()
        entrances[i] = e
        onEntranceChanged?()
    }

    /// A window closing from the canvas: its closing effect plays, then `completion` (the press of its
    /// close button), and it is held gone until the listing drops it — or `cancelExit` brings it back,
    /// if the app said no. No effect at all: `completion` at once.
    func beginExit(_ proxy: WindowProxy, context: WindowEffect.Context, completion: @escaping () -> Void) {
        endEntrance(of: proxy)
        guard proxies.contains(where: { $0 === proxy }), let style = effectStyle(for: context) else {
            completion()
            return
        }
        // A close has no source or neighbour to go back to: those would be wherever the window was
        // opened, long ago. It sets like the sun instead.
        let closing: WindowEffect.Style = style == .source || style == .dealt ? .sunrise : style
        var exit = Entrance(proxy: proxy, added: CACurrentMediaTime(), start: CACurrentMediaTime(), opening: false,
                            style: closing, context: context, completion: completion)
        decorate(&exit)
        proxy.closing = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = advance(&exit, at: exit.added)
        CATransaction.commit()
        entrances.append(exit)
        startDisplayLink()
        onEntranceChanged?()
    }

    /// Whether a window is playing its close, or held gone after it.
    func isClosing(_ proxy: WindowProxy) -> Bool {
        held.contains { $0.proxy === proxy } || entrances.contains { $0.proxy === proxy && !$0.opening }
    }

    /// The app kept the window (a "save changes?" sheet, a refusal): it opens again, the same way.
    func cancelExit(_ proxy: WindowProxy) {
        let style: WindowEffect.Style
        let context: WindowEffect.Context
        if let i = held.firstIndex(where: { $0.proxy === proxy }) {
            style = held[i].entrance.style; context = held[i].entrance.context
            held.remove(at: i)
        } else if let e = entrances.first(where: { $0.proxy === proxy && !$0.opening }) {
            style = e.style; context = e.context
            endEntrance(of: proxy)
        } else { return }
        proxy.closing = false
        beginEntrance(proxy, context: context, style: style)
        onEntranceChanged?()
    }

    private func endEntrance(of proxy: WindowProxy) {
        guard let i = entrances.firstIndex(where: { $0.proxy === proxy }) else { return }
        let e = entrances[i]
        e.ring?.removeFromSuperlayer()
        e.veil?.removeFromSuperlayer()
        entrances.remove(at: i)
        // Not a neighbour closing or held hidden after its close: `.identity` would show it again.
        if let n = e.neighbour, !entrances.contains(where: { $0.proxy === n }), !n.closing, !held.contains(where: { $0.proxy === n }) {
            n.setEffect(.identity, zoom: camera.zoom)
        }
        if e.underNeighbour { bringToFront(proxy) }
        if !e.opening { proxy.closing = false }
        proxy.setEffect(.identity, zoom: camera.zoom)
    }

    /// Every opening and closing window a frame on. The real-window renderer is told once, after the ones
    /// that finished have been put back to size, so the last transforms it sends are the camera's exactly.
    private func tickEntrances(at now: CFTimeInterval) {
        guard !entrances.isEmpty else { return }
        var finished: [Entrance] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Read before the loop: `advance` mustn't look at the list while one of its entries is inout.
        // Playing an entrance or held hidden after a close: neither is nudged by a neighbour's.
        let moving = Set(entrances.map { ObjectIdentifier($0.proxy) } + held.map { ObjectIdentifier($0.proxy) })
        for i in entrances.indices where advance(&entrances[i], at: now, moving: moving) {
            finished.append(entrances[i])
        }
        for e in finished {
            if e.opening {
                endEntrance(of: e.proxy)
            } else {
                // Gone from sight: held there (its last frame stays on it) until it's dropped or comes back.
                guard let i = entrances.firstIndex(where: { $0.proxy === e.proxy }) else { continue }
                e.ring?.removeFromSuperlayer()
                e.veil?.removeFromSuperlayer()
                entrances.remove(at: i)
                var kept = e
                kept.completion = nil
                held.append((e.proxy, kept))
            }
        }
        CATransaction.commit()
        onEntranceChanged?()
        for e in finished where !e.opening { e.completion?() }
    }

    /// Where the window's centre is going to or coming from, on screen.
    private func geometry(of e: Entrance) -> WindowEffect.Geometry {
        let r = camera.toScreen(e.proxy.worldRect)
        let centre = CGPoint(x: r.midX, y: r.midY)
        var g = WindowEffect.Geometry()
        if let source = e.context.source {
            let s = camera.toScreen(source)
            g.toSource = CGVector(dx: s.x - centre.x, dy: s.y - centre.y)
        }
        if let rect = e.neighbour.map({ $0.worldRect }) ?? e.context.neighbour {
            let n = camera.toScreen(rect)
            g.toNeighbour = CGVector(dx: n.midX - centre.x, dy: n.midY - centre.y)
        }
        return g
    }

    /// One frame of an entrance or exit; true once it is over. Everything is read from the window as it
    /// is now — its world rect, the zoom — so a window placed or a camera moved meanwhile is followed.
    /// `moving`: every window with an effect of its own playing, which Dealt leaves alone.
    private func advance(_ e: inout Entrance, at now: CFTimeInterval, moving: Set<ObjectIdentifier> = []) -> Bool {
        // Not before there is something to show: a capture proxy's grey placeholder shouldn't pop and
        // then have the texture land mid-spring. An unstreamable window shows the placeholder after all.
        if e.start == nil, e.proxy.hasFrame || e.proxy.usesRealWindow || now - e.added > 1.5 {
            e.start = now
        }
        let geometry = geometry(of: e)
        guard let start = e.start else {
            e.proxy.setEffect(WindowEffect.frame(e.style, opening: true, at: 0, geometry: geometry), zoom: camera.zoom)
            return false
        }
        let t = now - start
        let frame = WindowEffect.frame(e.style, opening: e.opening, at: t, geometry: geometry)
        e.proxy.setEffect(frame, zoom: camera.zoom)
        let shown = frame.applied(toWorld: e.proxy.worldRect, zoom: camera.zoom)
        let radius = e.proxy.layer.cornerRadius * min(frame.scale.width, frame.scale.height)

        if let veil = e.veil {
            let r = caRect(shown)
            veil.path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            veil.opacity = frame.dim * frame.opacity
        }
        // Bloom's ring: a hairline rounded rect spreading from the edges and fading. In world units, but
        // sized from the zoom, so its reach and stroke are the same on screen whatever the camera does.
        if let ring = e.ring {
            let p = min(1, CGFloat(t / CanvasView.ringDuration))
            let d = CanvasView.ringReach * (1 - pow(1 - p, 3)) / camera.zoom
            let r = caRect(e.proxy.worldRect).insetBy(dx: -d, dy: -d)
            let ringRadius = e.proxy.layer.cornerRadius + d
            ring.path = CGPath(roundedRect: r, cornerWidth: ringRadius, cornerHeight: ringRadius, transform: nil)
            ring.lineWidth = 1 / camera.zoom
            ring.opacity = Float(1 - p)
        }
        // Dealt's neighbour gives way a few points as the window comes out from behind it.
        if e.opening, e.style == .dealt, let n = e.neighbour, !n.closing, !moving.contains(ObjectIdentifier(n)) {
            let away = geometry.toNeighbour.map { v -> CGVector in
                let length = max(hypot(v.dx, v.dy), 1)
                return CGVector(dx: v.dx / length, dy: v.dy / length)
            } ?? .zero
            let push = WindowEffect.nudgeReach * WindowEffect.nudge(at: t)
            var nudge = WindowEffect.Frame()
            nudge.offset = CGVector(dx: away.dx * push, dy: away.dy * push)
            n.setEffect(t >= WindowEffect.nudgeDuration ? .identity : nudge, zoom: camera.zoom)
        }
        // Out from behind its neighbour: on top again, where a new window belongs.
        if e.underNeighbour, let n = e.neighbour, !shown.intersects(n.worldRect) || t > WindowEffect.duration(e.style, opening: true) * 0.6 {
            bringToFront(e.proxy)
            e.underNeighbour = false
        }
        let end = max(WindowEffect.duration(WindowEffect.usable(e.style, geometry), opening: e.opening),
                      e.opening && e.style == .dealt ? WindowEffect.nudgeDuration : 0)
        return t >= end
    }

    // MARK: Snapping

    /// What a dragged window can line up with: every other window and widget at least partly on screen.
    /// One you can't see would hold the drag for no visible reason.
    private func neighbours(of proxy: WindowProxy) -> [CGRect] {
        let visible = camera.toWorld(CGRect(origin: .zero, size: bounds.size))
        // Nor what moves with it (its group), nor what the hand is pulling in: a guide to those would
        // hold the hand off the very windows coming to it.
        var excluded = [proxy] + (dragging?.members.map(\.proxy) ?? [])
        for push in magnet?.pushes ?? [] where push.pulled {
            excluded.append(push.proxy)
            excluded += push.members.map(\.proxy)
        }
        return proxies.filter { p in
            !excluded.contains { $0 === p } && isPlacedBySetting?(p) != true && p.worldRect.intersects(visible)
        }.map(\.worldRect)
    }

    /// Let go: the window settles onto the grid, except on an axis a guide is holding it, so edges it was
    /// lined up with stay lined up. ⌘ leaves it exactly where it was dropped.
    private func drop(_ d: Drag, freely: Bool) {
        show([])
        drop(d.proxy, members: d.members, freely: freely, snappedX: d.snappedX, snappedY: d.snappedY)
    }

    /// The window in hand, or just out of it, comes to rest: onto the grid unless ⌘ or a guide says
    /// not to, its group along with it. Anything it pushed is lined up against where it settles and
    /// left to catch up; anything pulled that has arrived bonds first, so it lands with the rest.
    private func drop(_ proxy: WindowProxy, members: [Member], freely: Bool, snappedX: Bool, snappedY: Bool) {
        bond()
        var members = members
        var target = proxy.worldRect.origin
        if Settings.snapToGrid, !Settings.stripMode, !freely {
            target = Snapping.grid(target, size: Settings.gridSize, keepX: snappedX, keepY: snappedY)
        }
        if var m = magnet, m.proxy === proxy {
            m.released = true
            magnet = m
            members = m.members
            if !freely {
                // The pushed windows' targets are set from where it will land, not where it is now.
                let rect = CGRect(origin: target, size: proxy.worldRect.size)
                push(from: proxy, startRect: m.from, members: m.members, fixedAt: rect)
            }
            settleMagnet(now: false)
        }
        let delta = CGVector(dx: target.x - proxy.worldRect.minX, dy: target.y - proxy.worldRect.minY)
        var moves: [(proxy: WindowProxy, to: CGPoint)] = [(proxy, target)]
        for member in members {
            moves.append((member.proxy, CGPoint(x: member.proxy.worldRect.minX + delta.dx, y: member.proxy.worldRect.minY + delta.dy)))
        }
        glide(moves)
        onMoved?(proxy)
        for member in members { onMoved?(member.proxy) }
    }

    // MARK: Groups

    /// Which windows are bonded into groups (Settings › Windows › Magnetic polarity, see `Grouping`). The
    /// controller writes it down with the layout, and takes windows out as they close or are placed by
    /// hand. While polarity is off the groups are inert: nothing moves together.
    private(set) var grouping = Grouping()

    /// Whether poles act: magnetism and polarity both on.
    private var polarityActive: Bool { Settings.polarityActive }

    /// The windows bonded to `proxy`, not `proxy` itself: the ones on the canvas, bottom to top, and
    /// with `includingAway` the hidden and minimized ones too, which keep their place in the group.
    private func members(of proxy: WindowProxy, includingAway: Bool = false) -> [WindowProxy] {
        guard polarityActive else { return [] }
        let ids = grouping.members(of: proxy.windowID).dropFirst()
        guard !ids.isEmpty else { return [] }
        let pool = includingAway ? proxies + away : proxies
        return pool.filter { q in q !== proxy && ids.contains(q.windowID) }
    }

    /// The windows bonded to `proxy`, on the canvas or away.
    func groupMembers(of proxy: WindowProxy) -> [WindowProxy] { members(of: proxy, includingAway: true) }

    /// The window leaves its group; what's left is split into the pieces that still sit together.
    func release(_ proxy: WindowProxy) {
        guard grouping.group(of: proxy.windowID) != nil else { return }
        var rects: [CGWindowID: CGRect] = [:]
        for q in proxies + away { rects[q.windowID] = q.worldRect }
        grouping.remove(proxy.windowID, rects: rects, gap: Settings.tileGap)
        onContentChanged?()
    }

    /// The window's whole group goes free.
    func dissolve(groupOf proxy: WindowProxy) {
        grouping.dissolve(groupOf: proxy.windowID)
        onContentChanged?()
    }

    /// Undo: the groups as given.
    func restoreGrouping(_ g: Grouping) {
        grouping = g
        onContentChanged?()
    }

    /// A restore: the window joins the group written down as `saved` (see `Grouping.adopt`).
    func adopt(group saved: Int, for proxy: WindowProxy, remap: inout [Int: Int]) {
        grouping.adopt(saved: saved, for: proxy.windowID, remap: &remap)
    }

    /// The window comes to the front with its group, the group's order kept and the window on top.
    private func raise(_ proxy: WindowProxy) {
        for member in members(of: proxy) { bringToFront(member) }
        bringToFront(proxy)
    }

    /// The window in hand goes to `origin`, and the windows bonded to it by the same amount.
    private func place(_ proxy: WindowProxy, at origin: CGPoint, members: [Member]) {
        let delta = CGVector(dx: origin.x - proxy.worldRect.minX, dy: origin.y - proxy.worldRect.minY)
        proxy.place(at: origin)
        guard delta != .zero else { return }
        for member in members {
            member.proxy.place(at: CGPoint(x: member.proxy.worldRect.minX + delta.dx, y: member.proxy.worldRect.minY + delta.dy))
        }
    }

    /// A pushed body shown at `origin`: its lead there, its members at their offsets from it.
    private func land(_ push: Push, at origin: CGPoint) {
        push.proxy.place(at: origin)
        for member in push.members {
            member.proxy.place(at: CGPoint(x: origin.x + member.offset.dx, y: origin.y + member.offset.dy))
        }
    }

    /// Pulled windows that have arrived at the gap bond with the hand: from now on they're part of it,
    /// and come along. Undo lets them go again (`Magnet.joined`).
    private func bond() {
        guard var m = magnet, polarityActive else { return }
        let arrived = m.pushes.filter { $0.pulled && $0.proxy.worldRect.origin == $0.target && $0.follow.isAtRest(at: $0.target) }
        guard !arrived.isEmpty else { return }
        for push in arrived {
            grouping.merge(m.proxy.windowID, push.proxy.windowID)
            let joined = [Member(proxy: push.proxy, from: push.from)] + push.members.map { Member(proxy: $0.proxy, from: $0.from) }
            m.members += joined
            m.joined += joined
            Log.note("Polarity: \(push.proxy.appName) — \(push.proxy.title) bonded with \(m.proxy.appName) — \(m.proxy.title)")
        }
        m.pushes.removeAll { push in arrived.contains { $0.proxy === push.proxy } }
        // The clack of magnets meeting, while the hand still has the one they met.
        if !m.released, let first = arrived.first {
            Haptics.Player.shared.play(.bond, key: ObjectIdentifier(first.proxy))
        }
        magnet = m
        if var d = dragging, d.proxy === m.proxy {
            d.members += m.joined.filter { j in !d.members.contains { $0.proxy === j.proxy } }
            dragging = d
        }
        onBonded?()
    }

    /// A line across the gap between the hand and each window it's pulling in, drawn like a gap guide,
    /// at the gap the window is heading for.
    private func pullGuides() -> [Snapping.Guide] {
        guard let m = magnet else { return [] }
        let held = ([m.proxy] + m.members.map(\.proxy)).map(\.worldRect)
        var guides: [Snapping.Guide] = []
        for push in m.pushes where push.pulled {
            let target = CGRect(origin: push.target, size: push.proxy.worldRect.size)
            guard let line = held.lazy.compactMap({ Magnetism.gapLine(between: $0, and: target) }).first else { continue }
            guides.append(Snapping.Guide(kind: .gap, from: line.from, to: line.to))
        }
        return guides
    }

    // MARK: Magnetism

    /// The window in hand has moved or grown: whatever is in its way is given somewhere else to be, and
    /// with polarity on, whatever it draws is given the gap beside it. Called with the hand's position
    /// on every move; the targets are worked out afresh from the current layout each time (see
    /// `Magnetism.resolve`), the pushed windows ease after them on the display link. The hand is the
    /// held window and its group, as one body; `fixedAt` stands in for the held window's rect when it's
    /// about to settle elsewhere, the group shifted along. `members` is the group as the hand takes hold.
    private func push(from proxy: WindowProxy, startRect: CGRect, members: [Member] = [], fixedAt: CGRect? = nil) {
        if magnet == nil || magnet?.proxy !== proxy {
            settleMagnet(now: true)
            magnet = Magnet(proxy: proxy, from: startRect, members: members, groupingBefore: grouping)
        }
        guard var m = magnet else { return }
        let pushes = m.pushes
        // Windows gliding somewhere of their own (onto the grid, into a layout) are left to get there.
        let gliding = animation?.moves.map { $0.proxy } ?? []
        // The hand: the held window and the group it has on the canvas, where they'll be.
        let held = [proxy] + m.members.map(\.proxy).filter { q in proxies.contains { $0 === q } }
        let shift = fixedAt.map { CGVector(dx: $0.minX - proxy.worldRect.minX, dy: $0.minY - proxy.worldRect.minY) } ?? .zero
        var handRects = held.map { $0.worldRect.offsetBy(dx: shift.dx, dy: shift.dy) }
        if let fixedAt { handRects[0] = fixedAt }
        let hand = Magnetism.Body(rects: handRects, poles: held.map(\.polarity))
        let others = proxies.filter { p in
            !held.contains { $0 === p } && !gliding.contains { $0 === p } && isPlacedBySetting?(p) != true && p.attachedTo == nil
        }

        // Everyone else, a group as one body, each from where it's heading if it's already on the move.
        func heading(_ q: WindowProxy) -> CGRect {
            for push in pushes {
                if push.proxy === q { return CGRect(origin: push.target, size: q.worldRect.size) }
                if let member = push.members.first(where: { $0.proxy === q }) {
                    return CGRect(origin: CGPoint(x: push.target.x + member.offset.dx, y: push.target.y + member.offset.dy), size: q.worldRect.size)
                }
            }
            return q.worldRect
        }
        var bodies: [Magnetism.Body] = []
        var groups: [[WindowProxy]] = []
        var taken = Set<ObjectIdentifier>()
        for p in others where !taken.contains(ObjectIdentifier(p)) {
            var group: [WindowProxy] = [p] + self.members(of: p).filter { q in others.contains { $0 === q } }
            // A group already on the move keeps the window that leads its push.
            if let lead = group.firstIndex(where: { q in pushes.contains { $0.proxy === q } }), lead != 0 { group.swapAt(0, lead) }
            for q in group { taken.insert(ObjectIdentifier(q)) }
            bodies.append(Magnetism.Body(rects: group.map(heading), poles: group.map(\.polarity)))
            groups.append(group)
        }

        let reach = Magnetism.Strength(Settings.magnetismStrength).reach(gap: Settings.tileGap)
        let attraction = polarityActive ? Magnetism.Attraction(reach: Polarity.attractDistance / camera.zoom, gap: reach) : nil
        let result = Magnetism.resolve(fixed: hand, others: bodies, reach: reach, attraction: attraction)
        feel(result, hand: hand, bodies: bodies, groups: groups, reach: reach, in: &m)
        // A pull the hand let go of this move eases on to where it was heading, but no longer bonds there.
        for i in m.pushes.indices { m.pushes[i].pulled = false }
        for (i, group) in groups.enumerated() where result.moved.contains(i) || result.pulled.contains(i) {
            let lead = group[0]
            let target = CGPoint(x: bodies[i].rects[0].minX + result.offsets[i].dx, y: bodies[i].rects[0].minY + result.offsets[i].dy)
            let rest = group.dropFirst().map { q in
                (proxy: q, offset: CGVector(dx: q.worldRect.minX - lead.worldRect.minX, dy: q.worldRect.minY - lead.worldRect.minY), from: q.worldRect)
            }
            if let j = m.pushes.firstIndex(where: { $0.proxy === lead }) {
                let known = m.pushes[j].members
                m.pushes[j].target = target
                m.pushes[j].pulled = result.pulled.contains(i)
                // The group as it is now; a member already on the move keeps where it started.
                m.pushes[j].members = rest.map { r in
                    known.first { $0.proxy === r.proxy }.map { (proxy: r.proxy, offset: r.offset, from: $0.from) } ?? r
                }
            } else {
                m.pushes.append(Push(proxy: lead, from: lead.worldRect, members: rest, target: target,
                                     follow: Magnetism.Follow(position: lead.worldRect.origin), pulled: result.pulled.contains(i)))
            }
        }
        magnet = m
        if !m.pushes.isEmpty { startDisplayLink() }
    }

    /// What the hand runs into on this move, on the trackpad (`Haptics`): a body the hand itself has
    /// started to shove is a bump, or a cushion when it's a like pole giving way without touching; an
    /// opposite pole it has started to draw in is a catch. What a shoved body shoves behind it is weight
    /// under the hand, not a knock, and stays silent. Nothing once the hand has let go: the trackpad
    /// wouldn't play it, and the coast and the drop shouldn't be felt anyway.
    private func feel(_ result: Magnetism.BodyResolution, hand: Magnetism.Body, bodies: [Magnetism.Body], groups: [[WindowProxy]],
                      reach: CGFloat, in m: inout Magnet) {
        var touching = Set<ObjectIdentifier>()
        var pulling = Set<ObjectIdentifier>()
        defer {
            m.touching = touching
            m.pulling = pulling
        }
        guard !m.released, dragging != nil || resizing != nil else { return }
        let player = Haptics.Player.shared
        for (i, group) in groups.enumerated() {
            let lead = group[0]
            let id = ObjectIdentifier(lead)
            if result.pulled.contains(i) {
                pulling.insert(id)
                if !m.pulling.contains(id) { player.play(.catch, key: id) }
                continue
            }
            // In the hand's own way, not just in the way of something the hand pushed.
            guard result.moved.contains(i), Magnetism.displacement(of: bodies[i], outOf: hand, reach: reach) != .zero else { continue }
            touching.insert(id)
            guard !m.touching.contains(id) else { continue }
            // A like pole gives way before it's touched; anything else is hit.
            let repelled = polarityActive && bodies[i].poles[0] != nil
                && hand.poles.contains { Polarity.relation($0, bodies[i].poles[0]) == .repel }
            player.play(repelled ? .cushion : .bump, key: id)
        }
    }

    /// The pushed windows arrive. `now` puts them straight at their targets (another press, the window
    /// in hand going away); otherwise they keep easing and the magnet ends once they're all at rest.
    /// Anything pulled that got there bonds. One undo covers the move, the pushes and the bonds.
    private func settleMagnet(now: Bool) {
        guard var m = magnet else { return }
        m.released = true
        guard now || (m.coast == nil && m.pushes.allSatisfy { $0.follow.isAtRest(at: $0.target) }) else {
            magnet = m
            startDisplayLink()
            return
        }
        if let c = m.coast {
            place(m.proxy, at: c.end, members: m.members)
            m.coast = nil
            onMoved?(m.proxy)
            for member in m.members { onMoved?(member.proxy) }
        }
        for push in m.pushes {
            land(push, at: push.target)
            onMoved?(push.proxy)
            for member in push.members { onMoved?(member.proxy) }
        }
        magnet = m
        bond()
        guard let settled = magnet else { return }
        magnet = nil
        let pushed = settled.pushes.flatMap { push in [(push.proxy, push.from)] + push.members.map { ($0.proxy, $0.from) } }
        if !pushed.isEmpty || !settled.joined.isEmpty {
            onContentChanged?()
            registerUndo(for: [(settled.proxy, settled.from)] + settled.members.map { ($0.proxy, $0.from) } + pushed,
                         grouping: settled.groupingBefore)
        }
    }

    /// One frame of a coast and of the pushed windows catching up.
    private func tickMagnet(at now: CFTimeInterval) {
        guard var m = magnet else { return }
        let dt = CGFloat(now - (m.lastTick ?? now))
        m.lastTick = now
        var changed = false
        if let c = m.coast {
            place(m.proxy, at: c.position(at: now), members: m.members)
            magnet = m
            push(from: m.proxy, startRect: m.from)
            if c.isOver(at: now) {
                magnet?.coast = nil
                // At rest: the normal drop, grid and all.
                drop(m.proxy, members: magnet?.members ?? m.members, freely: m.freely, snappedX: m.snappedX, snappedY: m.snappedY)
            }
            guard let again = magnet else { onContentChanged?(); return }
            m = again
            changed = true
        }
        let strength = Magnetism.Strength(Settings.magnetismStrength)
        let response = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : strength.response
        for i in m.pushes.indices {
            var push = m.pushes[i]
            guard !push.follow.isAtRest(at: push.target) || push.proxy.worldRect.origin != push.target else { continue }
            push.follow.step(toward: push.target, dt: dt, response: response)
            if push.follow.isAtRest(at: push.target) { push.follow.position = push.target }
            land(push, at: push.follow.position)
            m.pushes[i] = push
            changed = true
        }
        magnet = m
        bond()
        if changed { onContentChanged?() }
        if magnet?.released == true { settleMagnet(now: false) }
    }

    /// ⌘Z after a drag that pushed other windows, or bonded some, puts every one of them back where it
    /// was and the groups as they were; ⇧⌘Z does the drag again. Positions only: a resize that pushed
    /// keeps its size, since the real window has it.
    private func registerUndo(for rects: [(WindowProxy, CGRect)], grouping before: Grouping) {
        guard let undo = window?.undoManager else { return }
        let after = rects.map { ($0.0, $0.0.worldRect) }
        let groupingAfter = grouping
        undo.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated {
                view.settleMagnet(now: true)
                for (p, r) in rects where view.proxies.contains(where: { $0 === p }) || view.away.contains(where: { $0 === p }) {
                    p.place(at: r.origin)
                    view.onMoved?(p)
                }
                view.grouping = before
                view.onContentChanged?()
                view.registerUndo(for: after, grouping: groupingAfter)
            }
        }
        undo.setActionName("Move Windows")
    }

    private func show(_ guides: [Snapping.Guide]) {
        guard !(guides.isEmpty && self.guides.isEmpty) else { return }
        self.guides = guides
        drawGuides()
    }

    /// Hairlines at any zoom: the path is in world space, so the line width is divided by the zoom. A gap
    /// gets a tick at each end, like a dimension.
    private func drawGuides() {
        let zoom = camera.zoom
        let tick = 4 / zoom
        let path = CGMutablePath()
        // CA space is y-up: a world point (x, y) is at (x, -y) here, as in `caRect`.
        func ca(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: -p.y) }
        for g in guides {
            path.move(to: ca(g.from))
            path.addLine(to: ca(g.to))
            guard g.kind == .gap else { continue }
            let horizontal = g.from.y == g.to.y
            for end in [g.from, g.to] {
                let a = horizontal ? CGPoint(x: end.x, y: end.y - tick) : CGPoint(x: end.x - tick, y: end.y)
                let b = horizontal ? CGPoint(x: end.x, y: end.y + tick) : CGPoint(x: end.x + tick, y: end.y)
                path.move(to: ca(a))
                path.addLine(to: ca(b))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guidesLayer.lineWidth = 1 / zoom
        guidesLayer.path = guides.isEmpty ? nil : path
        CATransaction.commit()
    }

    // MARK: Pointer

    /// Event location in top-left screen coordinates (the canvas's native space).
    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private var pointerTopLeft: CGPoint {
        guard let window else { return .zero }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    /// The edges of a window a screen point is on, for resizing it: never a widget's, and never where
    /// its floating controls are.
    private func resizeEdges(of p: WindowProxy?, at screenPoint: CGPoint) -> Resizing.Edges {
        guard let p, p.kind == .window, p.control(at: camera.toWorld(screenPoint)) == nil else { return [] }
        // A tile resizes from its edges too, where it's drawn; not while tucked (its tab is the grip).
        if let f = p.drawnPip {
            guard p.pipTucked == nil, pipFlights[ObjectIdentifier(p)] == nil else { return [] }
            return Resizing.edges(at: screenPoint, in: PictureInPicture.rect(f, size: p.worldRect.size))
        }
        return Resizing.edges(at: screenPoint, in: camera.toScreen(p.worldRect))
    }

    /// The green button held down: after `TilePopover.holdDelay` the popover comes, and letting go
    /// is no longer a click.
    private func startZoomHold(_ p: WindowProxy) {
        zoomHoldTimer?.invalidate()
        zoomHeld = false
        zoomHoldTimer = Timer.scheduledTimer(withTimeInterval: TilePopover.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let press = self.controlPress, press.proxy === p, press.control == .zoom,
                      p.pressedControl == .zoom else { return }
                self.zoomHeld = true
                p.pressedControl = nil
                self.showTilePopover(for: p)
            }
        }
    }

    private func setCursor(_ edges: Resizing.Edges) {
        guard edges != cursorEdges else { return }
        cursorEdges = edges
        guard !edges.isEmpty else {
            NSCursor.arrow.set()
            return
        }
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        default: position = .right
        }
        NSCursor.frameResize(position: position, directions: .all).set()
    }

    private func setHovered(_ proxy: WindowProxy?) {
        guard hovered !== proxy else { return }
        hovered?.hovered = false
        for member in outlinedMembers { member.outlined = false }
        hovered = proxy
        proxy?.hovered = true
        // Its group is outlined with it, so the pieces that move together look like one.
        outlinedMembers = proxy.map { members(of: $0) } ?? []
        for member in outlinedMembers { member.outlined = true }
        onHover?(proxy)
    }
    /// The hover off a window that stops taking it (one on its way into the Dock), until the pointer
    /// moves again and lands on whatever is under it.
    func dropHover(of proxy: WindowProxy) {
        if hovered === proxy { setHovered(nil) }
    }
    /// The hovered window's group, outlined with it.
    private var outlinedMembers: [WindowProxy] = []
    /// A window button held down (`WindowProxy.Control`): it acts on the release.
    private var controlPress: (proxy: WindowProxy, control: WindowProxy.Control)?
    /// The green button's popover, and what brings it: the pointer resting on the button, or the
    /// button held down (`TilePopover.hoverDelay`, `holdDelay`). A hold that brought it isn't a click.
    let tilePopover = TilePopover()
    private var zoomHoverTimer: Timer?
    private weak var zoomHoverProxy: WindowProxy?
    private var zoomHoldTimer: Timer?
    private var zoomHeld = false

    /// Hover follows the pointer, and the camera moving under a still pointer. Nothing under the
    /// overlay is hovered.
    private func updateHover(at screenPoint: CGPoint) {
        guard resizing == nil else { return }   // the resize cursor stays until it's let go
        if isCovered?(screenPoint) == true {
            setHovered(nil)
            setCursor([])
            return
        }
        let worldPoint = camera.toWorld(screenPoint)
        let p = proxy(at: worldPoint)
        setHovered(p)
        p?.hoveredControl = p?.control(at: worldPoint)
        followZoomHover(p)
        setCursor(resizeEdges(of: p, at: screenPoint))
    }

    /// The pointer resting on a window's green button brings its popover; off it, the popover closes
    /// unless the pointer went into it.
    private func followZoomHover(_ p: WindowProxy?) {
        let on = p?.hoveredControl == .zoom ? p : nil
        guard let on else {
            zoomHoverTimer?.invalidate()
            zoomHoverTimer = nil
            zoomHoverProxy = nil
            return
        }
        guard zoomHoverProxy !== on else { return }
        zoomHoverTimer?.invalidate()
        zoomHoverProxy = on
        zoomHoverTimer = Timer.scheduledTimer(withTimeInterval: TilePopover.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.zoomHoverProxy, p.hoveredControl == .zoom, self.controlPress == nil else { return }
                self.showTilePopover(for: p)
            }
        }
    }

    /// The popover under a window's green button, while its buttons show.
    private func showTilePopover(for p: WindowProxy) {
        guard window != nil, let world = p.controlWorldRect(.zoom) else { return }
        let r = camera.toScreen(world)   // top-left origin; the view isn't flipped
        let rect = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        let others = proxies.filter { $0.kind == .window && $0 !== p }.count
        tilePopover.show(for: p, relativeTo: rect, of: self, others: others) { [weak self] proxy, choice in
            self?.onTileChoice?(proxy, choice)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: topLeftPoint(event))
        if let p = passThroughTarget() { onPassThrough?(p) }
    }

    /// "Use windows at any zoom" (`Settings.useScaledWindows`): the pointer is over a window's content
    /// and the canvas should step aside for it, so the press, scroll or keys go to the app where the
    /// window is drawn. The window server hit-tests through a window's scale, so nothing is mapped here.
    var onPassThrough: ((WindowProxy) -> Void)?
    /// A click on a window's title strip while windows are used at any zoom: focus it, no zoom.
    var onFocus: ((WindowProxy) -> Void)?
    /// With the clicks swapped (`Settings.scaledClickZooms`), the second click of a double-click: the
    /// first click's way in is dropped and the window is focused where it was.
    var onClickFocus: ((WindowProxy) -> Void)?

    /// Windows are used where they're drawn (`Settings.useScaledWindows`, with live windows).
    var scaledWindowsInUse: Bool { Settings.useScaledWindows && showsRealWindows }

    /// A click's way in began outside the view (through the press tap): a second click re-aims it.
    func noteClickEntering(_ p: WindowProxy) { clickEntering = p }

    /// The title strip a window keeps for the canvas (drag to move it, its controls): its title bar,
    /// in its own points, and never less than `passThroughGrip` on screen however far out the zoom.
    static let passThroughTitleStrip: CGFloat = 28
    static let passThroughGrip: CGFloat = 16

    /// The window whose content is under the pointer, when the canvas would let the pointer through to
    /// it: live windows, not at 1:1 (the press there is passed on already, `onUse`), nothing moving, no
    /// ⌥ ⌘ ⌃ held (they pan and zoom over windows), off the title strip, the edges, its controls and
    /// whatever covers the canvas. Asked on every move while the pointer is through, too.
    func passThroughTarget() -> WindowProxy? {
        guard Settings.useScaledWindows, showsRealWindows, !isOneToOne, !isBusy, !panning, coast == nil,
              zoomCoast == nil, floorPress == nil, !showsDesktop, NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.isDisjoint(with: [.option, .command, .control]) else { return nil }
        let screenPoint = pointerTopLeft
        guard bounds.contains(CGPoint(x: screenPoint.x, y: bounds.height - screenPoint.y)),
              isCovered?(screenPoint) != true else { return nil }
        let worldPoint = camera.toWorld(screenPoint)
        // A tile in Picture in Picture is drawn at its corner, not where the camera has its home: the canvas
        // keeps the pointer there.
        guard let p = proxy(at: worldPoint), p.kind == .window, p.usesRealWindow, p.away == nil, !p.heldBack,
              !p.leaving, !p.closing, p.drawnPip == nil, p.control(at: worldPoint) == nil,
              worldPoint.y >= p.worldRect.minY + max(Self.passThroughTitleStrip, Self.passThroughGrip / camera.zoom),
              resizeEdges(of: p, at: screenPoint).isEmpty else { return nil }
        return p
    }

    /// Right-click on empty canvas or a widget: the widget items of the desktop's own menus, and on
    /// empty canvas the background. Over a window: Move & Resize, Minimize and Hide; its other menus
    /// are the real window's, once entered.
    override func menu(for event: NSEvent) -> NSMenu? {
        let worldPoint = camera.toWorld(topLeftPoint(event))
        let ground = floorHit(at: worldPoint)
        if let icon = ground.icon {
            floorFocused = true
            return floorMenu?(icon)
        }
        floorFocused = false
        let p = proxy(at: worldPoint)
        if let p, p.kind == .window { return tileMenu(for: p) }
        let menu = NSMenu()
        // Open Here… first: it's about this spot. Not on the strip, which lays every window out itself.
        if p == nil, onOpenHere != nil, !Settings.stripMode {
            let open = NSMenuItem(title: "Open Here…", action: #selector(openHere(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = NSValue(point: worldPoint)
            menu.addItem(open)
            menu.addItem(.separator())
        }
        // Placement next, as in the Window menu; there's no window here to Move & Resize.
        menuProxy = nil
        let placement = TileMenu.placementItems(target: self, actions: placementActions)
        for item in placement { menu.addItem(item) }
        if !placement.isEmpty { menu.addItem(.separator()) }
        // The desktop's ground: its own items (New Folder) next.
        if ground.onFloor, let items = floorMenu?(nil), !items.items.isEmpty {
            for item in items.items {
                items.removeItem(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if let p {
            let remove = NSMenuItem(title: "Remove Widget", action: #selector(removeWidget(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = p
            menu.addItem(remove)
            menu.addItem(.separator())
        }
        let add = NSMenuItem(title: "Add Widgets…", action: #selector(addWidgets(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        if p == nil, let submenu = backgroundMenu?() {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Dropping a picture

    /// The one picture file in a drag, if that's what it is.
    private func draggedPicture(_ info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              urls.count == 1 else { return nil }
        return urls.first
    }

    private func showDropGlow(_ on: Bool) {
        let opacity: Float = on ? 1 : 0
        guard dropGlow.opacity != opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dropGlow.opacity
        fade.toValue = opacity
        fade.duration = 0.2
        dropGlow.add(fade, forKey: "opacity")
        dropGlow.opacity = opacity
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Files dragged off the floor are on their way into a window, not to the background.
        guard sender.draggingSource as? CanvasView !== self, draggedPicture(sender) != nil else { return [] }
        showDropGlow(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropGlow(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        showDropGlow(false)
    }

    /// A picture dropped on the canvas becomes the background (⌘Z puts the old one back).
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropGlow(false)
        guard sender.draggingSource as? CanvasView !== self, let url = draggedPicture(sender) else { return false }
        onDropPicture?(url)
        return true
    }

    /// The window a right-click menu is up for: what Arrange takes its screen from.
    private weak var menuProxy: WindowProxy?

    private var placementActions: TileMenu.Actions {
        TileMenu.Actions(tidy: #selector(tidy(_:)), tidyBy: #selector(tidyBy(_:)), arrange: #selector(arrange(_:)),
                         tile: #selector(tile(_:)))
    }

    private func tileMenu(for proxy: WindowProxy) -> NSMenu {
        let menu = NSMenu()
        menuProxy = proxy
        // Picture in Picture first: it's about this window on this screen (⌃⌥P does the same).
        let pip = NSMenuItem(title: proxy.pip == nil ? "Picture in Picture" : "Leave Picture in Picture", action: #selector(togglePip(_:)),
                             keyEquivalent: TileMenu.pipKey)
        pip.keyEquivalentModifierMask = TileMenu.modifiers
        pip.target = self
        pip.representedObject = proxy
        menu.addItem(pip)
        menu.addItem(.separator())
        for item in TileMenu.placementItems(target: self, actions: placementActions,
                                            represent: { TileChoice(proxy: proxy, preset: $0) }) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if proxy.showsPolarity, let pole = proxy.polarity {
            let flip = NSMenuItem(title: "Flip Polarity (now \(pole.glyph))", action: #selector(flipPolarity(_:)), keyEquivalent: "")
            flip.target = self
            flip.representedObject = proxy
            menu.addItem(flip)
            if grouping.isGrouped(proxy.windowID) {
                let ungroup = NSMenuItem(title: "Ungroup", action: #selector(ungroupWindow(_:)), keyEquivalent: "")
                ungroup.target = self
                ungroup.representedObject = proxy
                menu.addItem(ungroup)
            }
            menu.addItem(.separator())
        }
        let displays = otherDisplays?() ?? []
        for (i, name) in displays.enumerated() {
            let move = NSMenuItem(title: "Move to \(name)", action: #selector(moveToDisplay(_:)), keyEquivalent: "")
            move.target = self
            move.representedObject = DisplayChoice(proxy: proxy, index: i)
            menu.addItem(move)
        }
        if !displays.isEmpty { menu.addItem(.separator()) }
        let minimize = NSMenuItem(title: "Minimize", action: #selector(minimizeWindow(_:)), keyEquivalent: "")
        minimize.target = self
        minimize.representedObject = proxy
        menu.addItem(minimize)
        let hide = NSMenuItem(title: "Hide \(proxy.appName)", action: #selector(hideApp(_:)), keyEquivalent: "")
        hide.target = self
        hide.representedObject = proxy
        menu.addItem(hide)
        return menu
    }

    private final class DisplayChoice {
        let proxy: WindowProxy
        let index: Int
        init(proxy: WindowProxy, index: Int) {
            self.proxy = proxy
            self.index = index
        }
    }

    @objc private func moveToDisplay(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DisplayChoice else { return }
        onMoveToDisplay?(choice.proxy, choice.index)
    }

    @objc private func togglePip(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onTogglePip?(p)
    }

    @objc private func minimizeWindow(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onMinimize?(p)
    }

    @objc private func hideApp(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onHideApp?(p)
    }

    @objc private func flipPolarity(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onFlipPolarity?(p)
    }

    @objc private func ungroupWindow(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onUngroup?(p)
    }

    private struct TileChoice {
        let proxy: WindowProxy
        let preset: Tiling.Preset
    }

    @objc private func tile(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? TileChoice else { return }
        onTile?(choice.proxy, choice.preset)
    }

    @objc private func tidy(_ sender: NSMenuItem) {
        onTidy?()
    }

    @objc private func tidyBy(_ sender: NSMenuItem) {
        guard let order = TileMenu.order(of: sender) else { return }
        onTidyBy?(order)
    }

    @objc private func arrange(_ sender: NSMenuItem) {
        guard let a = TileMenu.arrangement(of: sender) else { return }
        onArrange?(menuProxy, a.columns, a.rows)
    }

    @objc private func removeWidget(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? WindowProxy else { return }
        onClose?(p)
    }

    @objc private func addWidgets(_ sender: Any?) {
        onAddWidgets?()
    }

    @objc private func openHere(_ sender: NSMenuItem) {
        guard let point = (sender.representedObject as? NSValue)?.pointValue else { return }
        onOpenHere?(point)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is a right-click.
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if CanvasView.isPassedOn(event) { return }
        let screenPoint = topLeftPoint(event)
        let worldPoint = camera.toWorld(screenPoint)
        passingOn = false
        cancelAnimation()
        settleMagnet(now: true)   // the last drag's pushed windows go straight to their places
        floorPress = nil
        // The second click of a double-click, the first one's way in just stopped above: the same window,
        // to the middle now, from wherever the camera got to.
        let entering = clickEntering
        clickEntering = nil
        if event.clickCount >= 2, let p = entering {
            dragging = nil
            // Using windows at any zoom with the clicks swapped, the double-click focuses it where it was.
            if scaledWindowsInUse, Settings.scaledClickZooms { onClickFocus?(p) } else { onHandoff?(p) }
            return
        }
        let ground = floorHit(at: worldPoint)
        floorFocused = ground.icon != nil
        if let icon = ground.icon {
            // A file on the desktop: selected on the press, opened by a double-click, dragged by a drag.
            dragging = nil
            if event.clickCount >= 2 {
                onFloorOpen?(icon)
                return
            }
            onFloorClick?(icon, event.modifierFlags, false)
            floorPress = FloorPress(icon: icon, start: screenPoint, modifiers: event.modifierFlags)
            return
        }
        // The desktop's empty ground deselects its files, as on the desktop, and pans.
        if ground.onFloor { onFloorClick?(nil, event.modifierFlags, false) }
        if let p = proxy(at: worldPoint) {
            if showsDesktop { onDesktopDismissed?() }
            if let control = p.control(at: worldPoint) {
                dragging = nil
                // The menu button opens its menu on the press, as a pop-up button does: drag to an item
                // and let go, or click and pick.
                if control == .menu {
                    popUpWindowMenu(for: p)
                    return
                }
                // Pressed now, done on the release if the pointer is still on it, as a real window's.
                controlPress = (p, control)
                p.pressedControl = control
                if control == .zoom { startZoomHold(p) }
                return
            }
            // A tile in Picture in Picture: a click (or a double-click) returns the window to 1:1 where
            // the tile is (the click on the release, `mouseUp`); a drag moves the tile (tucked, the tab
            // brings it back); a press on an edge resizes it. Most presses never get here: the tile's
            // chrome panel takes them (`PipChrome`); the edges, and a tile on its way somewhere, are the
            // canvas's.
            if p.drawnPip != nil {
                dragging = nil
                if event.clickCount >= 2 {
                    pipDrag = nil
                    onPipReturn?(p)
                    return
                }
                if p.pipTucked != nil {
                    untuckPip(p)
                    return
                }
                let edges = resizeEdges(of: p, at: screenPoint)
                if !edges.isEmpty, let f = p.drawnPip {
                    cancelPipFlight(p)
                    p.pip = f
                    p.pipShown = nil
                    pipResize = PipResize(proxy: p, edges: edges, start: f)
                    setCursor(edges)
                    return
                }
                beginPipDrag(p, at: screenPoint)
                return
            }
            let edges = resizeEdges(of: p, at: screenPoint)
            if !edges.isEmpty {
                dragging = nil
                bringToFront(p)
                resizing = Resize(proxy: p, edges: edges, startRect: p.worldRect, start: screenPoint)
                setCursor(edges)
                Haptics.Player.shared.begin()
                return
            }
            // A widget's second click doesn't press it again: that would flip a toggle straight back.
            if event.clickCount >= 2, p.kind == .widget {
                dragging = nil
                return
            }
            // At 1:1 the proxy is the real window, pixel for pixel: the press is the window's own.
            if isOneToOne, p.kind == .window {
                dragging = nil
                passingOn = true
                onUse?(p, screenPoint, event)
                return
            }
            // Zoomed in or out, a double-click brings the window to the middle and enters it (the second
            // click usually lands while the first is on its way in, above).
            if event.clickCount >= 2, p.kind == .window {
                dragging = nil
                if scaledWindowsInUse, Settings.scaledClickZooms { onClickFocus?(p) } else { onHandoff?(p) }
                return
            }
            // The press brings it to the front, with its group; a drag moves it.
            beginDrag(p, at: screenPoint)
        } else if event.clickCount == 2, onOpenHere != nil, !Settings.stripMode, !showsDesktop {
            // A double-click on the empty canvas: Open Here…, as from its right-click menu.
            onOpenHere?(worldPoint)
        } else {
            panning = true
            lastPointer = screenPoint
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if CanvasView.isPassedOn(event) { return }
        if passingOn {
            onUseFollow?(event)
            return
        }
        let screenPoint = topLeftPoint(event)
        if let press = controlPress {
            // Off the button it lightens again, back on it darkens; the window doesn't move.
            let under = press.proxy.control(at: camera.toWorld(screenPoint))
            press.proxy.hoveredControl = under
            press.proxy.pressedControl = under == press.control && !zoomHeld ? press.control : nil
            return
        }
        if let press = floorPress {
            guard hypot(screenPoint.x - press.start.x, screenPoint.y - press.start.y) >= CanvasView.dragSlop else { return }
            floorPress = nil
            beginFileDrag(press, event: event)
            return
        }
        if pipDrag != nil {
            movePipDrag(to: screenPoint, timestamp: event.timestamp)
            return
        }
        if let r = pipResize {
            r.proxy.pip = PictureInPicture.resized(r.start, edges: r.edges, to: screenPoint, size: r.proxy.worldRect.size, visible: visibleForPip)
            pipChanged(r.proxy)
            return
        }
        if var r = resizing {
            if !r.moved {
                guard hypot(screenPoint.x - r.start.x, screenPoint.y - r.start.y) >= CanvasView.dragSlop else { return }
                r.moved = true
                resizing = r
            }
            let delta = CGVector(dx: (screenPoint.x - r.start.x) / camera.zoom, dy: (screenPoint.y - r.start.y) / camera.zoom)
            r.proxy.place(Resizing.resize(r.startRect, edges: r.edges, by: delta))
            // A growing edge shoves what's in its way; ⌘ lets it grow over. Its own group stays put
            // (part of the hand, so not shoved), and is left as it was.
            if Settings.magnetism, !Settings.stripMode, !event.modifierFlags.contains(.command) {
                push(from: r.proxy, startRect: r.startRect, members: members(of: r.proxy).map { Member(proxy: $0, from: $0.worldRect) })
            }
            onContentChanged?()
            onResize?(r.proxy, r.anchor, false)
        } else if dragging != nil {
            dragWindow(to: screenPoint, modifiers: event.modifierFlags, timestamp: event.timestamp)
        } else if panning {
            beginInput()
            pending.addPan(CGVector(dx: screenPoint.x - lastPointer.x, dy: screenPoint.y - lastPointer.y))
            lastPointer = screenPoint
        }
    }

    override func mouseUp(with event: NSEvent) {
        if CanvasView.isPassedOn(event) { return }
        if passingOn {
            passingOn = false
            onUseFollow?(event)
            return
        }
        if let press = controlPress {
            controlPress = nil
            let p = press.proxy
            let released = p.control(at: camera.toWorld(topLeftPoint(event)))
            p.pressedControl = nil
            zoomHoldTimer?.invalidate()
            zoomHoldTimer = nil
            let held = zoomHeld
            zoomHeld = false
            if released == press.control, !held {
                switch press.control {
                case .close: onClose?(p)
                case .minimize: onMinimize?(p)
                case .zoom:
                    tilePopover.close()
                    onZoom?(p)
                case .polarity: onFlipPolarity?(p)
                case .menu: break   // opened on the press
                }
            }
            updateHover(at: topLeftPoint(event))
            return
        }
        if let press = floorPress {
            floorPress = nil
            onFloorClick?(press.icon, press.modifiers, true)
            return
        }
        if let r = pipResize {
            pipResize = nil
            setCursor([])
            settlePip(r.proxy)
            updateHover(at: topLeftPoint(event))
            panning = false
            return
        }
        if let d = pipDrag {
            // Let go where it was pressed: a click, which returns the window to 1:1 where the tile is.
            if !endPipDrag(timestamp: event.timestamp, freely: event.modifierFlags.contains(.command)) { onPipReturn?(d.proxy) }
            updateHover(at: topLeftPoint(event))
            panning = false
            return
        }
        if let r = resizing {
            resizing = nil
            if r.moved {
                // The edges that moved settle onto the grid, as a dropped window does; ⌘ leaves them be.
                if Settings.snapToGrid, !Settings.stripMode, !event.modifierFlags.contains(.command) {
                    r.proxy.place(Resizing.grid(r.proxy.worldRect, edges: r.edges, size: Settings.gridSize))
                    onContentChanged?()
                }
                // What it pushed keeps clear of the size it settled at.
                if var m = magnet, m.proxy === r.proxy {
                    m.released = true
                    magnet = m
                    push(from: r.proxy, startRect: r.startRect)
                    settleMagnet(now: false)
                }
                onResize?(r.proxy, r.anchor, true)
            }
            updateHover(at: topLeftPoint(event))
            panning = false
            return
        }
        if let d = dragging, d.moved {
            finishDrag(d, modifiers: event.modifierFlags, timestamp: event.timestamp)
        } else if let d = dragging {
            switch d.proxy.kind {
            case .widget:
                // One click uses a widget, as on the desktop, right away: there's no double-click to wait for.
                let r = d.proxy.worldRect
                onPress?(d.proxy, CGPoint(x: r.minX + d.grabOffset.x, y: r.minY + d.grabOffset.y))
            case .window where scaledWindowsInUse && !Settings.scaledClickZooms:
                // Using windows at any zoom, a click on the title strip focuses the window where it is,
                // as a click in its content does; a double-click brings it to the middle (`mouseDown`).
                onFocus?(d.proxy)
            case .window:
                // Brought to the front on the press. Zoomed in or out, the click enters it at 1:1 right
                // where it is, around the clicked spot; a double-click brings it to the middle instead.
                clickEntering = d.proxy
                onClickEnter?(d.proxy, d.start, d.grabOffset)
            }
        }
        dragging = nil
        if panning {
            panning = false
            fingersLifted()
        }
    }

    /// A press on a window or widget that may become a drag: it comes to the front with its group.
    private func beginDrag(_ p: WindowProxy, at screenPoint: CGPoint) {
        let worldPoint = camera.toWorld(screenPoint)
        raise(p)
        dragging = Drag(proxy: p, grabOffset: CGPoint(x: worldPoint.x - p.worldRect.minX, y: worldPoint.y - p.worldRect.minY),
                        start: screenPoint, startRect: p.worldRect,
                        members: members(of: p, includingAway: true).map { Member(proxy: $0, from: $0.worldRect) })
        Haptics.Player.shared.begin()
    }

    /// The pointer moved with a window pressed: past the slop it moves, guided, snapped and shoving.
    private func dragWindow(to screenPoint: CGPoint, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        guard var d = dragging else { return }
        if !d.moved {
            guard hypot(screenPoint.x - d.start.x, screenPoint.y - d.start.y) >= CanvasView.dragSlop else { return }
            // A widget the setting places stays put: the drag pans the canvas, as on the ground.
            if isPlacedBySetting?(d.proxy) == true {
                dragging = nil
                panning = true
                lastPointer = screenPoint
                return
            }
            d.moved = true
            // ⌘ from the first move pulls a bonded window out of its group: it goes on alone.
            if modifiers.contains(.command), !d.members.isEmpty {
                release(d.proxy)
                d.members = []
                Haptics.Player.shared.play(.split, key: ObjectIdentifier(d.proxy))
            }
            dragging = d
        }
        // The group as the magnet has it: a pulled window may have bonded since the last move.
        if let m = magnet, m.proxy === d.proxy { d.members = m.members }
        d.velocity.add(screenPoint, at: timestamp)
        let w = camera.toWorld(screenPoint)
        var origin = CGPoint(x: w.x - d.grabOffset.x, y: w.y - d.grabOffset.y)
        d.snappedX = false
        d.snappedY = false
        var guides: [Snapping.Guide] = []
        // ⌘ places the window freely: no guides now, no grid when it's let go.
        if Settings.alignmentGuides, !Settings.stripMode, !modifiers.contains(.command) {
            let a = Snapping.align(CGRect(origin: origin, size: d.proxy.worldRect.size), to: neighbours(of: d.proxy),
                                   threshold: CanvasView.snapDistance / camera.zoom, gap: Settings.gridSize)
            origin = a.origin
            d.snappedX = a.snappedX
            d.snappedY = a.snappedY
            guides = a.guides
        }
        // A guide the window wasn't on a moment ago has just caught it: a detent under the finger.
        // One per move, however many guides the catch lined it up with at once.
        let keys = Set(guides.map(GuideKey.init))
        if let caught = keys.subtracting(d.guideKeys).first {
            Haptics.Player.shared.play(.detent, key: caught)
        }
        d.guideKeys = keys
        dragging = d
        place(d.proxy, at: origin, members: d.members)
        if Settings.magnetism, !Settings.stripMode, !modifiers.contains(.command) {
            push(from: d.proxy, startRect: d.startRect, members: d.members)
            guides += pullGuides()
        }
        onContentChanged?()
        show(guides)
    }

    /// A moved window let go: it coasts or drops.
    private func finishDrag(_ d: Drag, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        let freely = modifiers.contains(.command)
        // A group coasts as one: its whole width bounds the coast.
        let body = ([d.proxy] + d.members.map(\.proxy)).map(\.worldRect).reduce(CGRect.null) { $0.union($1) }
        if var m = magnet, m.proxy === d.proxy, !freely,
           let coast = Magnetism.Coast(from: d.proxy.worldRect.origin, screenVelocity: d.velocity.release(at: timestamp),
                                       zoom: camera.zoom, width: body.width, at: CACurrentMediaTime()),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Flung: it keeps going a little, shoving as it goes, and drops when it stops (`tickMagnet`).
            m.coast = coast
            m.freely = false
            m.snappedX = d.snappedX
            m.snappedY = d.snappedY
            m.released = true
            magnet = m
            show([])
            startDisplayLink()
        } else {
            drop(d, freely: freely)
        }
    }

    // MARK: Drags from outside the view

    /// A drag the canvas never got the press for: using windows at any zoom, the press went through the
    /// canvas to the app, and the press tap (`PressTap`) found it to be a move. It moves the window just
    /// as a drag on the canvas does. `screenPoint` is in the view's top-left space.
    func beginExternalDrag(_ p: WindowProxy, at screenPoint: CGPoint) {
        guard dragging == nil, resizing == nil, !p.leaving, !p.closing else { return }
        cancelAnimation()
        settleMagnet(now: true)
        floorPress = nil
        clickEntering = nil
        beginDrag(p, at: screenPoint)
    }

    func moveExternalDrag(to screenPoint: CGPoint, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        guard dragging != nil else { return }
        dragWindow(to: screenPoint, modifiers: modifiers, timestamp: timestamp)
    }

    func endExternalDrag(modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        guard let d = dragging else { return }
        if d.moved { finishDrag(d, modifiers: modifiers, timestamp: timestamp) }
        dragging = nil
    }

    var isExternalDragging: Bool { dragging != nil }

    override func scrollWheel(with event: NSEvent) {
        if CanvasView.isPassedOn(event) { return }
        let inFront = cameraIsFree
        // A new scroll with the canvas in front is the canvas's to place: a trackpad's starts with `began`,
        // a mouse wheel's clicks have no phase at all.
        let starts = event.phase == .began || (event.phase == [] && event.momentumPhase == [] && !scrollingOn)
        // A trackpad scroll starting here while a window is in use is over another window or the canvas
        // around it: not the one passed on.
        if starts, inFront || event.phase == .began { scrollingOn = false }
        if scrollingOn {
            onUseScrollFollow?(event)
            return
        }
        // macOS delivers scroll and pinch to inactive windows too; while an entered window is in front,
        // moving the camera would silently desync it from its proxy. A window used where it's drawn is
        // different: the canvas stays as it is, and a scroll beside it pans as ever.
        guard inFront else { return }
        // At 1:1 a scroll over a window is the window's, as on the desktop; ⌥ and ⌘ still zoom.
        let screenPoint = topLeftPoint(event)
        if starts, isOneToOne, !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command),
           isCovered?(screenPoint) != true, let p = proxy(at: camera.toWorld(screenPoint)), p.kind == .window, p.pip == nil {
            scrollingOn = true
            onUseScroll?(p, screenPoint, event)
            return
        }
        panOrZoom(event, at: screenPoint)
    }

    /// A two-finger scroll over a window the canvas has stepped aside for, taken by the press tap: the
    /// canvas pans (⌥ or ⌘ held, zooms), whether or not the canvas is key, as over empty canvas.
    func externalScroll(_ event: NSEvent, at screenPoint: CGPoint) {
        panOrZoom(event, at: screenPoint)
    }

    private func panOrZoom(_ event: NSEvent, at screenPoint: CGPoint) {
        // The Mac's own momentum events come through here too, so a scroll pan coasts by itself; with
        // pan inertia off in Settings (or Reduce Motion on) they're dropped and the pan stops with the
        // fingers.
        if event.phase == .began || event.phase == .changed { scrollHeld = true }
        if event.phase == .ended || event.phase == .cancelled {
            scrollHeld = false
            fingersLifted()
        }
        if event.momentumPhase != [],
           !Settings.panInertia || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        // ⌥-scroll over a tile sizes the tile, not the canvas.
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command),
           isCovered?(screenPoint) != true, let p = pipProxy(atScreen: screenPoint), p.pip != nil {
            scalePip(of: p, by: exp(-event.scrollingDeltaY * 0.01), around: screenPoint, settled: event.phase == .ended || event.phase == [])
            return
        }
        beginInput()
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            pending.addZoom(by: exp(-event.scrollingDeltaY * 0.01), around: screenPoint)
        } else {
            pending.addPan(CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
        }
    }

    /// A tile sized about the pointer (`PictureInPicture.scaled`, a pinch or ⌥-scroll over it); `settled`:
    /// the gesture is over, the tile springs back into its corner.
    private func scalePip(of p: WindowProxy, by factor: CGFloat, around screenPoint: CGPoint, settled: Bool) {
        guard p.pipTucked == nil else { return }
        cancelPipFlight(p)
        if let shown = p.pipShown { p.pip = shown; p.pipShown = nil }
        guard let f = p.pip else { return }
        p.pip = PictureInPicture.scaled(f, by: factor, around: screenPoint, size: p.worldRect.size, visible: visibleForPip)
        pipChanged(p)
        if settled { settlePip(p) }
    }

    /// The tile a pinch began over, if any: the whole pinch sizes it.
    private weak var pinchingPip: WindowProxy?

    override func magnify(with event: NSEvent) {
        guard cameraIsFree else {
            if event.phase == .began { Log.note("Pinch: dropped, the canvas isn't key and no window is in use where it's drawn") }
            return
        }
        let pinchPoint = topLeftPoint(event)
        if event.phase == .began {
            pinchingPip = isCovered?(pinchPoint) != true ? pipProxy(atScreen: pinchPoint) : nil
        }
        if let p = pinchingPip {
            let over = event.phase == .ended || event.phase == .cancelled
            scalePip(of: p, by: max(0.01, 1 + event.magnification), around: pinchPoint, settled: over)
            if over { pinchingPip = nil }
            return
        }
        pinch(event, at: pinchPoint)
    }

    /// A pinch over a window the canvas has stepped aside for, taken by the press tap from the window
    /// server's gesture stream: the canvas's zoom, whether or not the canvas is key (the window's app
    /// may be in front).
    func externalPinch(magnification: CGFloat, phase: NSEvent.Phase, timestamp: TimeInterval, at screenPoint: CGPoint) {
        // Anchored where the pointer is now, read the way the canvas's own gestures read it, rather
        // than where the tap's thread saw it.
        let anchor = window != nil ? pointerTopLeft : screenPoint
        pinch(magnification: magnification, phase: phase, timestamp: timestamp, at: anchor)
    }

    /// Sunlight's menu for a window the canvas has stepped aside for, on a right-click taken by the press
    /// tap: the same menu a right-click on the window gives when the canvas is in front, popped up at
    /// the click (top-left origin), whether or not the canvas is key.
    func showTileMenu(for proxy: WindowProxy, atTopLeft point: CGPoint) {
        tileMenu(for: proxy).popUp(positioning: nil, at: CGPoint(x: point.x, y: bounds.height - point.y), in: self)
    }

    /// The window's right-click menu (`tileMenu`), from its menu button: hung just under the button,
    /// left edges lined up, the button held darker while it's open.
    private func popUpWindowMenu(for proxy: WindowProxy) {
        guard let button = proxy.controlWorldRect(.menu) else { return }
        tilePopover.close()   // one menu at a time
        let onScreen = camera.toScreen(button)
        let menu = tileMenu(for: proxy)
        proxy.pressedControl = .menu
        // Tracks the menu until it closes; a pick runs its action before this returns.
        menu.popUp(positioning: nil, at: CGPoint(x: onScreen.minX, y: bounds.height - onScreen.maxY - 3), in: self)
        proxy.pressedControl = nil
        updateHover(at: pointerTopLeft)
    }

    private func pinch(_ event: NSEvent, at screenPoint: CGPoint) {
        pinch(magnification: event.magnification, phase: event.phase, timestamp: event.timestamp, at: screenPoint)
    }

    private func pinch(magnification: CGFloat, phase: NSEvent.Phase, timestamp: TimeInterval, at screenPoint: CGPoint) {
        beginInput()
        if phase == .began {
            pinchLog = 0
            pinchVelocity = Motion.ScalarVelocity()
        }
        pinchHeld = !(phase == .ended || phase == .cancelled)
        let factor = max(0.01, 1 + magnification)
        pinchLog += log(factor)
        pinchVelocity.add(pinchLog, at: timestamp)
        pending.addZoom(by: factor, around: screenPoint)
        guard phase == .ended || phase == .cancelled else { return }
        // The gesture is over: the camera as it left it, now, decides what follows.
        flushInput()
        updateHover(at: screenPoint)
        let v = pinchVelocity.release(at: timestamp)
        pinchLog = 0
        pinchVelocity = Motion.ScalarVelocity()
        // Ended nearly on a full screen window: onto it and in, centred, rather than in place.
        if onSettle?() == true { return }
        // "Zoom all the way in" is the handoff gesture, finishing the zoom where the fingers are.
        // A widget is already as real as it gets; the minimap is neither.
        if camera.zoom >= CanvasView.handoffZoom, isCovered?(screenPoint) != true {
            let worldPoint = camera.toWorld(screenPoint)
            if let p = proxy(at: worldPoint), p.kind == .window {
                onEnter?(p, screenPoint)
                return
            }
        }
        // Not a handoff: the pinch tails off for a moment, never up across the handoff zoom, which
        // the fingers didn't reach. Nothing with zoom inertia off in Settings, or under Reduce Motion.
        guard Settings.zoomInertia, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let tail = Motion.ZoomCoast(velocity: v, anchor: screenPoint, at: timestamp),
              camera.zoom >= CanvasView.handoffZoom || tail.end(from: camera.zoom, at: timestamp) < CanvasView.handoffZoom
        else { return }
        zoomCoast = tail
        startDisplayLink()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if holdsKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if holdsKey?(event) == true { return }
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if holdsKey?(event) == true { return }
        // The desktop's keys, while its files have the canvas's attention and something's selected.
        if floorFocused, let command = DesktopFiles.command(keyCode: Int(event.keyCode), modifiers: event.modifierFlags),
           command == .selectAll || desktopFloor?.selection.isEmpty == false {
            if command == .deselect { floorFocused = false }
            onFloorCommand?(command)
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            break   // nothing, and no beep: seeing everything is the four-finger tap, or the minimap's Fit
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Over a widget: open it. Anywhere else: enter the window under the pointer, or the top one.
            guard let p = hovered ?? proxy(at: camera.toWorld(pointerTopLeft)) ?? proxies.last(where: { $0.kind == .window })
            else { break }
            switch p.kind {
            case .widget: onPress?(p, nil)
            case .window: onHandoff?(p)
            }
        case kVK_ANSI_P:
            // Over a window with a pole, plain P flips it (Settings › Windows › Magnetic polarity).
            guard let p = hovered, p.showsPolarity, event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { super.keyDown(with: event); break }
            onFlipPolarity?(p)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: Dragging files off the floor

extension CanvasView: NSDraggingSource {
    /// The pressed file, and the rest of the selection with it when it's part of one, each lifting off
    /// from where it is on the floor.
    private func beginFileDrag(_ press: FloorPress, event: NSEvent) {
        let selection = desktopFloor?.selection ?? []
        let icons = selection.contains { $0.key == press.icon.key } ? selection : [press.icon]
        let items = icons.compactMap { icon -> NSDraggingItem? in
            guard let url = icon.url else { return nil }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let r = camera.toScreen(desktopFloor?.worldRect(forScreen: icon.frame) ?? icon.frame)
            item.setDraggingFrame(NSRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        Log.note("Desktop: dragging \(items.count) file\(items.count == 1 ? "" : "s") off the desktop")
        springTarget = nil
        sprung = false
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Not onto the canvas itself; anywhere else, what Finder offers.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        trackSpring(at: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        springTimer?.invalidate()
        springTimer = nil
        springTarget = nil
        setHovered(nil)
        Log.note("Desktop: the files' drag ended (\(operation.isEmpty ? "nothing took them" : "dropped"))")
        onFileDragEnded?()
        desktopFloor?.refreshSoon()   // a move takes them off the desktop
    }

    /// The window under dragged files lights up and, held there for `springDelay`, opens to them.
    private func trackSpring(at screenPoint: NSPoint) {
        guard !sprung, let window else { return }
        let p = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let topLeft = CGPoint(x: p.x, y: bounds.height - p.y)
        springPoint = topLeft
        let target = isCovered?(topLeft) == true ? nil : proxy(at: camera.toWorld(topLeft)).flatMap { $0.kind == .window ? $0 : nil }
        guard target !== springTarget else { return }
        springTarget = target
        setHovered(target)
        springTimer?.invalidate()
        springTimer = nil
        guard target != nil else { return }
        let t = Timer(timeInterval: CanvasView.springDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spring() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common includes event tracking, which a drag runs in
        springTimer = t
    }

    private func spring() {
        springTimer = nil
        guard let target = springTarget, !sprung else { return }
        sprung = true
        onSpring?(target, springPoint)
    }
}
