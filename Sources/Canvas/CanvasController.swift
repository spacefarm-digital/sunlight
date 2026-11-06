import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Carbon's way of making a process frontmost. Deprecated since 10.9 and hidden from Swift, but still
/// exported by HIServices and not subject to cooperative activation. Used only as a fallback when
/// `NSApplication.activate()` is refused.
@_silgen_name("SetFrontProcessWithOptions")
private func SetFrontProcessWithOptions(_ psn: UnsafePointer<ProcessSerialNumber>, _ options: UInt32) -> OSStatus
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
private let kCurrentProcessPSN: UInt32 = 2          // kCurrentProcess
private let kFrontWindowOnly: UInt32 = 1 << 0       // kSetFrontProcessFrontWindowOnly

/// Sunlight to the front past cooperative activation, which refuses an app the user hasn't just
/// interacted with: a key from the key tap, typed inside another app's window, is exactly that.
@discardableResult
func forceSunlightFront() -> OSStatus {
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: kCurrentProcessPSN)
    return SetFrontProcessWithOptions(&psn, kFrontWindowOnly)
}

/// Another app to the front the same way (`forceSunlightFront`), for when cooperative activation
/// refuses the request: Sunlight asking from behind another app (a window entered by ⌘Tab while one
/// was in use where it's drawn) isn't the front app yielding, and the plain request may be declined.
func forceAppFront(_ pid: pid_t) -> OSStatus {
    var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
    let err = GetProcessForPID(pid, &psn)
    guard err == noErr else { return err }
    return SetFrontProcessWithOptions(&psn, kFrontWindowOnly)
}

final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Let the borderless window cover the whole screen, menu bar strip included.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The desktop model:
///
/// * The canvas is a full-screen, borderless, *normal-level* window. While our app is active it covers
///   every real window; each one is shown as a live proxy.
/// * Handing off = animate the camera to 1:1 with the chosen proxy, AX-move the real window to that exact
///   rect while it's still hidden, then activate its app. Its window comes to the front of the canvas,
///   pixel-matched; every other window stays hidden behind the canvas. The user works in the real window.
/// * Coming back = our app activates (click the canvas, ⌘-tab, or the Mission Control key) and the canvas is in front again,
///   with the proxy already where the real window was.
///
/// With takeover mode running, the same model absorbs everything that happens outside the canvas. An app
/// activated by the Dock, Spotlight, a notification or a URL while a window is entered is treated as
/// entered too, with the camera placed at 1:1 under its focused window (the real window is never moved).
/// Activated while the canvas is in front, an app already on the canvas is entered where its window is;
/// one that isn't yet is kept behind the canvas, and its window arrives on the canvas at the current zoom
/// (`keepOnCanvas`). The ⌘Tab switcher and the Mission Control keys arrive here through `handle(_:)`.
///
/// Capture policy: a proxy streams only while its real window is behind the canvas, where the capture
/// pill macOS puts on a streamed window can't be seen. An app's streams stop before its windows come in
/// front (handoff, absorb), and `refreshTimer` keeps those proxies fresh with one-shot captures, which
/// leave no pill. Every stream is restarted by the first capture pass after the canvas is in front again.
@MainActor
final class CanvasController {
    let window: CanvasWindow
    let view: CanvasView
    /// Screen-space chrome over the canvas: the minimap.
    let overlay: OverlayView
    let minimap: MinimapPanel
    /// The background behind the windows: the settings and the right-click menu change it here.
    let background: BackgroundModel
    /// Finder's desktop, under every window and widget, where its position setting puts it.
    private let desktopFloor = DesktopFloor()
    /// Show Desktop is up: the camera flew to the floor and everything over it is dimmed. The camera it
    /// left, to fly back to when Show Desktop is asked for again.
    private var desktopShown: Camera? { didSet { if (oldValue == nil) != (desktopShown == nil) { updateMinimap() } } }
    /// Show Desktop was asked for from a window: it happens once the canvas is back in front.
    private var pendingShowDesktop = false
    /// The actions of the floor's right-click menu that's up.
    private var floorMenuActions: MenuActions?
    /// Files dragged off the floor sprang a window open: the canvas lets the pointer through to it until
    /// the drag ends (`fileDragEnded`).
    private var springDrag = false

    /// Set once takeover mode exists. Its watcher and key tap only feed us while it is running.
    weak var takeover: TakeoverMode?

    /// The display this canvas covers. Its world is global coordinates like every canvas's (see `Display`);
    /// its view starts at the display's origin.
    private(set) var display: Display
    private var scale: CGFloat { display.scale }
    /// The canvases on every display, once there's more than this one to think of.
    weak var desk: Desk?
    /// The canvas on the primary display: the one that owns what there's only one of (the Dock add-on's
    /// reloads, the first-sync tasks, layouts).
    let isLead: Bool
    private let myPID = ProcessInfo.processInfo.processIdentifier
    private var proxies: [CGWindowID: WindowProxy] = [:]
    /// Hidden and minimized windows (`WindowProxy.Away`): off the canvas, their proxies kept so the
    /// window comes back where it was. Also windows just gone from the screen whose reason is being asked
    /// of Accessibility (`away` nil): minimized, or on another Space, which takes them off the canvas.
    private var away: [CGWindowID: WindowProxy] = [:]
    /// Windows seen going into the Dock (takeover's watcher, the – on a proxy), and when: put away
    /// without asking once the listing finds them gone. An entry the listing never claims (the app
    /// refused after all) lapses after `minimizingLapse`.
    private var minimizing: [CGWindowID: CFTimeInterval] = [:]
    static let minimizingLapse: CFTimeInterval = 3
    private var askingMinimized: Set<CGWindowID> = []
    /// The last entered window, kept while it's off screen (native full screen), asked once whether
    /// it's minimized instead.
    private var askedKept: CGWindowID?
    /// Windows their app closed that the window server still lists on screen, and when Accessibility was
    /// last asked whether they're back. Music's last window, closed, stayed ordered in at alpha 1 while
    /// Accessibility listed no window for the app (2026-11-08): its proxy, chrome and all, stayed on the
    /// canvas and in ⌘Tab, and ⌘Tab to it activated Music with nothing to show. These are off the canvas
    /// as any closed window is, until the app names them again or the window server lets them go.
    /// Music doesn't always leave it on screen: it may order the closed window out and keep it, alive and
    /// in no app's list. A window off screen that still exists would otherwise pass for the last entered
    /// window gone full screen, kept for good; so these count as closed while the window server has them
    /// at all, on screen or not, with their app (`pid`) to ask.
    /// `home`: where the window was natively before `closeForApp` moved it off the screen, for it to go
    /// back to when its app shows it again (or Sunlight quits), so it never reopens off the screen.
    private var closedByApp: [CGWindowID: (pid: pid_t, asked: CFTimeInterval, home: CGPoint?)] = [:]
    private var askingClosed: Set<CGWindowID> = []
    /// When the app in front last had its windows on the canvas looked over for ones it closed
    /// (`sweepFrontApp`), and whether that look is still under way.
    private var frontSweptAt: CFTimeInterval = 0
    private var frontSweeping = false
    /// How often the app in front is looked over.
    static let frontSweepInterval: CFTimeInterval = 1.5
    /// Where the sweeps ask: their own queue, so an app slow to answer holds up nothing else.
    private static let sweepQueue = DispatchQueue(label: "canvas.ax.sweep", qos: .utility)
    /// How often a window closed by its app but still listed is looked up again in its app's windows.
    static let closedRecheck: CFTimeInterval = 2
    /// The window we handed off to; nil while the canvas is in front.
    private var activeProxy: WindowProxy? { didSet { if (oldValue == nil) != (activeProxy == nil) { updateMinimap() } } }
    private var lastActiveProxy: WindowProxy?
    /// The view camera the entered window's app was placed at (`enter`): what its windows' native frames
    /// are read against on the way back, whatever the camera is doing by then.
    private var enteredCamera: Camera?
    /// The 1:1 camera a window was last entered at: where the screen is in the world, as the user last
    /// saw it at 1x. A window placed on the canvas while the canvas is up goes natively to its spot
    /// through this camera, so its real place agrees with its canvas place (outside the windows it was
    /// placed beside, not over the one in use) before anything enters or raises it.
    private var lastOneToOne: Camera?
    private var handingOff = false { didSet { if oldValue != handingOff { updateMinimap() } } }
    private var didInitialFit = false
    private var refreshTimer: Timer?
    private var refreshCursor = 0
    private(set) var renderer: Settings.Renderer = .capture
    private var configuringRenderer = true
    private var rendererRevision = 0
    private let realWindows = RealWindowDriver()
    /// Brings the addition back when the Dock restarts, which unloads it.
    private let reloader = AdditionReloader()
    private var reloading = false
    /// Preview mode's badge in the canvas's bottom-left (`Settings.previewMode`), while the renderer is capture.
    private var previewBadge: PreviewBadge?
    /// A preview was seen this launch, so the first live windows deserve a word.
    private var previewShown = false
    /// The demo mode card's Use Full Version: Set Up Sunlight, at the live-windows steps.
    var onSetUp: (() -> Void)?
    /// ⌘? through the key tap (`KeyTap.Command.howToUse`): Settings › How to use.
    var onHowToUse: (() -> Void)?
    /// The setup window is asking for Screen Recording at launch: the capture fallback doesn't also
    /// put up the system's prompt.
    var permissionsAskedElsewhere = false
    /// After a fall-back from live windows: asks the addition again, at growing intervals, and goes
    /// back to live windows once it answers (see `scheduleLiveRecovery`).
    private var liveRecoveryTimer: Timer?
    private var liveRecoveryAttempts = 0
    /// When live windows last came on; a mode that held for a while resets the recovery backoff.
    private var liveSince = Date.distantPast
    private var backdrop: NSWindow?
    private var realWindowsPresented = false
    /// A fresh on-screen listing is required after returning from another app/Space. Retained
    /// proxies can include a now-hidden settings panel or fullscreen window, which must stay native.
    private var realWindowListReady = false
    private var liveTimer: Timer?
    private var requestedCapturePermission = false

    // Capture policy (see `capturePass`)
    /// The window being handed off to: its app's windows are about to be in front.
    private var handoffTarget: WindowProxy?
    /// A flight into a live window: its inactive shadow look is eased towards the active one over it
    /// (`flightShadow`), so the window server's switch as the window becomes key changes nothing, and
    /// the seam shows no shadow blink (see `LiveWindowsWire.ShadowLook`).
    private var shadowFlight: (id: CGWindowID, start: CFTimeInterval, duration: CFTimeInterval)?
    /// `show()` is easing the entered window's active look back before it activates; the window gets its
    /// standard looks again once the canvas is in front.
    private var showing = false
    private var shadowEasedBack: CGWindowID?
    private var passScheduled = false
    private var passTimer: Timer?
    /// The level of detail every stream is at, and the one the zoom asks for.
    private struct LevelOfDetail {
        var applied = 0
        var wanted = 0
        var wantedSince: CFTimeInterval = 0
        var lastCameraChange: CFTimeInterval = 0
        var lastCamera: Camera?
    }
    private var lod = LevelOfDetail()
    /// The canvas window is off screen or fully covered: nothing on it can be seen.
    private var canvasOccluded = false
    /// The screen is locked or asleep, or the session is someone else's: no capture at all.
    private var asleep = false
    private let dormancy = DormancyMonitor()
    private var lastCaptureSummary = ""
    private var refreshTicks = 0

    // Takeover bookkeeping
    /// Entered windows, most recent first. Drives the ⌘Tab switcher.
    /// Most recently entered first, across every display (the desk keeps it).
    private var mru: [CGWindowID] {
        get { desk?.mru ?? [] }
        set { desk?.mru = newValue }
    }
    /// The app we activated ourselves in `enter`: its activation notification is ours, not foreign.
    private var expectedActivationPID: pid_t = 0
    private var expectedActivationTimeout: DispatchWorkItem?
    /// An app that became active with no window yet; absorbed as soon as it shows one.
    private var pendingAbsorbPID: pid_t = 0
    private var pendingTimer: Timer?
    /// An app launched from the canvas (the Dock, Spotlight, a URL…): its windows belong behind the
    /// canvas, so its own activations are answered by bringing the canvas back, not by entering it — until
    /// its first window has been on the canvas a moment, or it has had long enough to show one.
    private struct Launch {
        let name: String
        let deadline: Date
        var arrived: Date?
    }
    private var launches: [pid_t: Launch] = [:]
    private var launchTimer: Timer?
    /// How long a launch may take to show its first window; a slow one is then treated like any app.
    static let launchWait: TimeInterval = 8
    /// Once arrived: after this, a Dock click on it enters it, as for any app on the canvas.
    static let launchSettle: TimeInterval = 1.5
    /// Apps whose launch showed no canvas window in `launchWait` (a panel, an overlay, a window under
    /// 120×80, nothing at all): from the canvas they're let to the front like any app, not held behind
    /// the canvas again, which took them back every time they were activated.
    private var windowlessApps: Set<pid_t> = []
    private var pendingFitAll = false
    /// A placement key pressed inside a real window (⌃⌥A, ⌃⌥3): done once the canvas is up and synced.
    private var pendingPlacement: (() -> Void)?
    private var enteredTimer: Timer?
    /// The ⌘Tab switcher while ⌘ is held: apps, their windows, and the highlighted one.
    private var switcher: SwitcherCycle?
    /// Its icon strip, on the overlay.
    private let switcherHUD = SwitcherHUD()
    /// Switcher input that arrived while the canvas was still coming to the front, applied in
    /// `returnedToCanvas` so the camera only ever moves with the canvas in front.
    private var pendingSwitcherMoves: [SwitcherMove] = []
    private var pendingSwitcherCommit = false
    /// Four-finger travel that arrived while the canvas was still coming to the front; applied in
    /// `returnedToCanvas` for the same reason.
    private var pendingPan: PendingTrackpadPan?
    private var pendingPanEnded = false
    /// The four-finger drag under way began from a window, so the canvas is in front because of it.
    private var panBroughtCanvas = false

    /// "Add Widgets…", from picking "Edit Widgets…" until the desktop's edit mode ends.
    private struct AddingWidgets {
        let started = Date()
        /// The gallery's window, once it's there, and when it was first seen on screen (it slides up from
        /// below, and away again after Done).
        var gallery: AXUIElement?
        var galleryShown: Date?
        /// Edit mode took the canvas off the screen, as it does every window. It puts it back when it ends.
        var canvasHidden = false
        /// Edit mode left the canvas up, so it was ordered out to uncover the desktop.
        var orderedOut = false
        /// Notification Center is being asked about the gallery, off the main thread.
        var probing = false
    }
    private var addingWidgets: AddingWidgets?
    /// Set Up Sunlight is up, full-screen over the canvas: the canvas holds its own activations (the Mission Control key,
    /// the swipes, the Mission Control key, takeover's absorbing) so nothing comes up over it or pulls
    /// Sunlight back in front of the System Settings a step opened.
    var isSetupShowing = false {
        didSet { if isSetupShowing { closeSwitcher(clearHighlight: true) } }
    }
    private var addingWidgetsTimer: Timer?

    // Layouts
    /// How long after launch windows that were on the canvas last run are still put back as they show
    /// up. At login, apps reopen their windows over a while.
    static let rememberedWindow: TimeInterval = 120
    /// How long a layout restore waits for the apps and documents it opened to show their windows.
    static let restoreWait: TimeInterval = 12
    static let restoreDuration: CFTimeInterval = 0.6
    /// The canvas as the last run left it, for its camera, and those of its entries no window has
    /// turned up for yet (see `placeRemembered`).
    /// Last run's canvas and the windows of it still to come back, kept by the desk for every display.
    private var remembered: Layout? { desk?.remembered }
    private var unclaimed: [Layout.Entry] {
        get { desk?.unclaimed ?? [] }
        set { desk?.unclaimed = newValue }
    }
    private var rememberedUntil: Date { desk?.rememberedUntil ?? .distantPast }
    /// Last run's group numbers → groups on the canvas, as their members show up (`Grouping.adopt`).
    private var rememberedGroups: [Int: Int] = [:]
    private var rememberWork: DispatchWorkItem?

    /// A layout restore that opened apps or documents, while it waits for their windows.
    private struct RestoringLayout {
        let layout: Layout
        /// The layout's entries still without a window, by index.
        var pending: [Int]
        let policy: Settings.OtherWindows
        /// Apps it opened: their activations are the launch, not the user, and their windows are new.
        let apps: Set<String>
        /// Every window on the canvas so far; anything else that shows up is new.
        var known: Set<CGWindowID>
        /// Where the next window moved aside goes.
        var parkX: CGFloat
        /// The layout's group numbers → groups on the canvas, as members arrive (`Grouping.adopt`).
        var groups: [Int: Int]
        let deadline: Date
    }
    private var restoring: RestoringLayout?
    private var restoringTimer: Timer?

    private var env: TakeoverMode? { takeover?.isRunning == true ? takeover : nil }

    init(display: Display, desk: Desk? = nil, lead: Bool = true) {
        self.display = display
        self.desk = desk
        isLead = lead

        view = CanvasView(frame: NSRect(origin: .zero, size: display.frame.size))
        view.topInset = display.topInset
        // At home the canvas shows its display at 1:1, the world where the screen is.
        if display.origin != .zero { view.set(camera: .home(viewOrigin: display.origin)) }
        background = BackgroundModel(renderer: view.backgroundRenderer)
        view.setFloor(desktopFloor.layer)
        overlay = OverlayView(frame: view.frame)
        minimap = MinimapPanel(canvas: view)
        window = CanvasWindow(contentRect: display.cocoaFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // The canvas view hosts its own layers, so the overlay sits next to it, not in it: a plain
        // container holds the two, the overlay on top.
        let container = NSView(frame: view.frame)
        container.autoresizesSubviews = true
        view.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.addSubview(overlay)
        window.contentView = container
        window.initialFirstResponder = view
        window.isOpaque = false          // keeps the windows beneath from being reported as occluded
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal           // the whole trick: an activated app's window rises above us
        window.isMovable = false
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.title = "Sunlight"

        view.onHandoff = { [weak self] proxy in self?.handoff(to: proxy) }
        view.onCenteredClick = { [weak self] proxy, double in self?.handoff(to: proxy, click: !double) }
        view.onDesktopDismissed = { [weak self] in self?.endShowDesktop(flyBack: false) }
        view.desktopFloor = desktopFloor
        view.onFloorClick = { [weak self] icon, modifiers, released in self?.floorClick(icon, modifiers: modifiers, released: released) }
        view.onFloorOpen = { [weak self] icon in self?.openFiles([icon]) }
        view.floorMenu = { [weak self] icon in self?.floorMenu(for: icon) }
        view.onFloorCommand = { [weak self] command in self?.floorCommand(command) }
        view.holdsKey = { [weak self] event in self?.holdKey(event) ?? false }
        view.onSpring = { [weak self] proxy, point in self?.springInto(proxy, around: point) }
        view.onFileDragEnded = { [weak self] in self?.fileDragEnded() }
        view.onEnter = { [weak self] proxy, point in self?.handoff(to: proxy, placement: .inPlace(around: point)) }
        view.onClickEnter = { [weak self] proxy, point, offset, double in
            self?.preClickCamera = self?.view.camera
            self?.handoff(to: proxy, placement: .clicked(at: point, offset: offset), click: !double)
        }
        view.onClickCommand = { [weak self] proxy, command in
            guard let self else { return }
            if let preset = command.preset { self.tile(proxy, preset) }
            else if let arrangement = command.arrangement { self.arrange(columns: arrangement.columns, rows: arrangement.rows, around: proxy) }
            else { self.desk?.perform(command, on: self) }
        }
        view.onClickFocus = { [weak self] proxy in self?.focusFromFlight(proxy) }
        view.onUse = { [weak self] proxy, point, press in self?.use(proxy, around: point, press: press) }
        view.onPassThrough = { [weak self] proxy in self?.passThrough(to: proxy) }
        view.onFocus = { [weak self] proxy in self?.focusInPlace(proxy) }
        view.onUseFollow = { [weak self] event in self?.followPress(event) }
        view.onUseScroll = { [weak self] proxy, point, scroll in self?.useScroll(proxy, around: point, scroll: scroll) }
        view.onUseScrollFollow = { [weak self] event in self?.followScroll(event) }
        view.onClose = { [weak self] proxy in self?.close(proxy) }
        view.onTogglePip = { [weak self] proxy in self?.togglePip(proxy) }
        view.onPipMoved = { [weak self] _ in self?.rememberSoon() }
        view.onPipReturn = { [weak self] proxy in self?.handoff(to: proxy) }
        view.onPipChanged = { [weak self] in
            guard let self else { return }
            self.updatePipChrome()
            guard self.renderer == .realWindows else { return }
            self.updateRealWindows()   // straight to the driver, as an entrance's frame goes
        }
        view.pipArea = { [weak self] in self?.visibleTopLeft ?? .zero }
        view.onMinimize = { [weak self] proxy in self?.minimize(proxy) }
        view.onHideApp = { [weak self] proxy in self?.hideApp(of: proxy) }
        minimap.onBringBack = { [weak self] proxy in self?.bringBack(proxy) }
        view.onPress = { [weak self] proxy, point in self?.press(proxy, at: point) }
        view.onAddWidgets = { [weak self] in self?.addWidgets() }
        view.onOpenHere = { [weak self] point in self?.openHere(at: point) }
        view.onAnimationCancelled = { [weak self] in
            guard let self else { return }
            handoffTarget?.heldBack = false
            if let t = handoffTarget { unpark(t) }
            if let t = handoffTarget, t.pipShown != nil { t.pipShown = nil; view.pipChanged(t) }   // a return cut short
            handingOff = false
            handoffTarget = nil   // the target's streams come back with the next pass
            shadowFlight = nil
            passedPress = nil
            passedScroll = nil
            view.endScrollingOn()
            scheduleCapturePass()
        }
        view.onViewportChanged = { [weak self] in self?.scheduleCapturePass() }
        view.onSettle = { [weak self] in self?.snapToWindow() ?? false }
        view.onPanRelease = { [weak self] start in self?.snapToWindow(requireCenterInside: true, releaseStart: start) ?? false }
        view.onFourFingerPanEnd = { [weak self] start, direction in
            self?.snapToWindow(pan: (start, direction), requireCenterInside: true, releaseStart: start) ?? false
        }
        view.onHover = { [weak self] p in if let p { self?.prefetchAX(p) } }
        view.onMoved = { [weak self] p in
            p.tile = nil   // placed by hand
            self?.stripWindowDropped(p)
            self?.rememberSoon()
        }
        view.onResize = { [weak self] proxy, anchor, finished in
            if finished { proxy.tile = nil }
            self?.canvasResized(proxy, anchor: anchor, finished: finished)
            // The column reflows around the new size (the app's own, once it answers, at the next listing).
            if finished { self?.layoutStrip(animated: true) }
        }
        view.onTile = { [weak self] proxy, preset in self?.tile(proxy, preset) }
        view.onZoom = { [weak self] proxy in self?.zoom(proxy) }
        view.onTileChoice = { [weak self] proxy, choice in self?.tileChoice(proxy, choice) }
        view.onTidy = { [weak self] in self?.tidy() }
        view.onTidyBy = { [weak self] order in self?.tidy(by: order) }
        view.onArrange = { [weak self] proxy, columns, rows in self?.arrange(columns: columns, rows: rows, around: proxy) }
        view.onFlipPolarity = { [weak self] proxy in self?.flipPolarity(of: proxy) }
        view.onUngroup = { [weak self] proxy in self?.ungroup(proxy) }
        view.otherDisplays = { [weak self] in self?.otherCanvases.map(\.display.name) ?? [] }
        view.onMoveToDisplay = { [weak self] proxy, index in
            guard let self, index < self.otherCanvases.count else { return }
            self.move(proxy, to: self.otherCanvases[index])
        }
        view.onBonded = { [weak self] in self?.rememberSoon() }
        NotificationCenter.default.addObserver(forName: Settings.magneticPolarityDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.polaritySettingChanged() }
        }
        NotificationCenter.default.addObserver(forName: Settings.windowLabelsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for p in self.proxies.values { p.windowLabelsSettingChanged() }
                for p in self.away.values { p.windowLabelsSettingChanged() }
            }
        }
        view.isPlacedBySetting = { p in p.kind == .widget }
        desktopFloor.onContentChanged = { [weak self] in self?.arrangeDesktop(animated: false) }
        desktopPlacementChanged(animated: false)
        NotificationCenter.default.addObserver(forName: Settings.desktopPlacementDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.desktopPlacementChanged(animated: true) }
        }
        NotificationCenter.default.addObserver(forName: Settings.stripModeRequested, object: nil, queue: .main) { [weak self] n in
            let on = (n.object as? NSNumber)?.boolValue ?? false
            MainActor.assumeIsolated { self?.setStripMode(on) }
        }
        background.undoManager = window.undoManager
        background.onChanged = { [weak self] animated in self?.view.updateBackground(animated: animated) }
        view.backgroundMenu = { [weak self] in self?.background.menu() }
        view.onDropPicture = { [weak self] url in self?.background.useImportedPicture(at: url) }

        overlay.canvas = view
        overlay.addSubview(minimap)
        minimap.isHidden = true
        placeMinimap()
        updateMinimap(animated: false)
        view.isCovered = { [weak overlay] in overlay?.covers($0) ?? false }
        view.isUsingScaledWindow = { [weak self] in self?.usingScaledWindow ?? false }
        view.onCameraChanged = { [weak self] in self?.cameraChanged() }
        // The ⌘Tab strip may be on another display's canvas than the flight it follows.
        view.onFlightProgress = { [weak self] t in
            for c in self?.deskCanvases ?? [] where c.switcherHUD.isActive { c.switcherHUD.progress(t) }
        }
        switcherHUD.onHover = { [weak self] app, window in self?.pointSwitcher(app: app, window: window) }
        switcherHUD.onPick = { [weak self] app, window in self?.pickSwitcher(app: app, window: window) }
        view.onEntranceChanged = { [weak self] in
            guard let self, self.renderer == .realWindows else { return }
            self.updateRealWindows()   // straight to the driver's mailbox, not the (coalesced) capture pass
        }
        view.onContentChanged = { [weak self] in
            self?.minimap.redraw()
            self?.scheduleCapturePass()
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wantsFrontUntil = 0   // it has the front
                // Back from a window used where it's drawn: the next app activated is the user's again.
                self?.usedScaledPIDs = []
                self?.hoverFocusedID = nil
                self?.focusedScaledID = nil
                self?.returnedToCanvas()
                self?.runPendingPlacement()
                self?.updateMinimap()
            }
        }
        // Another app came in front (the canvas was ⌘-tabbed away from, say): its windows must not
        // stream. Both fire whether or not takeover is on.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reassertFrontIfTakenBack()
                // A window entered on another display: this one's canvas stays up as it is.
                if !self.staysUp {
                    // The front app as the workspace has it. At this moment it can still be this app (the
                    // activation that took the front hasn't been reported yet): an app launched from the
                    // canvas's Dock showed up that way, and handing the windows back for an unknown front
                    // emptied the canvas for two frames before it came straight back. An unknown front is
                    // held for too: whoever took it either sends the canvas back or enters a window, which
                    // hands the windows back itself; the hold's timer covers the rest.
                    let front = NSWorkspace.shared.frontmostApplication
                    if let front, front.processIdentifier != self.myPID, !self.sendsStraightBack(front) {
                        self.suspendRealWindows(keepingLook: true)
                    } else if let front, front.processIdentifier != self.myPID {
                        self.holdThroughForeignFront(front)
                    } else if self.realWindowsPresented, self.activeProxy == nil {
                        self.holdThroughForeignFront(nil)
                    } else {
                        self.suspendRealWindows(keepingLook: true)
                    }
                }
                self.scheduleCapturePass()
                self.updateMinimap()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let self, let pid, self.isScaledUseActivation(pid) { self.usedScaledPIDs.insert(pid) }
                self?.scheduleCapturePass(after: 0.05)
                self?.scheduleDiff(after: 0.3)
            }
        }
        // The system says when the desktop changed; the 1 s listing is the fallback, not the way.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleDiff(after: 0.3)
                self?.scheduleDiff(after: 1.5)   // the first window comes well after the launch
            }
        }
        workspace.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.appDeactivated(pid) }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid { self?.bundleIDs[pid] = nil }
                self?.scheduleDiff(after: 0.3)
            }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDiff(after: 0.3) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.placeMinimap()
                self?.placePreviewBadge()
                self?.scheduleDiff(after: 0.5)
            }
        }
        // Nothing on a hidden canvas can be seen; the pass treats it as an empty viewport.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canvasOccluded = !self.window.occlusionState.contains(.visible)
                self.scheduleCapturePass()
            }
        }
        dormancy.onChange = { [weak self] asleep in
            // Off in the menu bar: already asleep, and staying so until it's on again (`setPaused`).
            guard let self, !self.paused else { return }
            self.dormancyChanged(asleep)
        }
        realWindows.onFailure = { [weak self] reason in self?.fallBackFromRealWindows(reason) }
        reloader.onDockRestarted = { [weak self] in self?.dockRestarted() }
        reloader.onPaused = { [weak self] in
            guard let self else { return }
            CanvasToast.show("The Dock kept restarting after live windows loaded, so they're paused. Reload Live Windows… tries again.",
                             in: self.overlay, for: 8)
        }
        // With a desk, it hands the window server's news to every display's canvas.
        if desk == nil {
            WindowServerEvents.onWindowCreated = { [weak self] id in self?.windowServerCreated(id) }
            WindowServerEvents.onWindowRemoved = { [weak self] _ in self?.windowServerRemoved() }
        }
        WindowServerEvents.start()

        // Launched with the screen already locked (a login item, say): nothing until it's unlocked.
        asleep = dormancy.asleep
        if !asleep { startSyncTimer() }
        configureRenderer(Settings.renderer)
        // Open Here…'s list of apps, walked in the background before the first right-click wants it.
        if isLead {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated { AppCatalog.shared.refresh() }
            }
        }
    }

    // MARK: Rendering mode

    func configureRenderer(_ asked: Settings.Renderer) {
        // Live windows on another display's canvas need an add-on that holds a lease per canvas; with an
        // older one the lead has the add-on and the others show captured pictures.
        // Safe mode (`Stability`): pictures only, this launch, with nothing scheduled to try live windows again.
        let requested = Stability.safeMode || asked == .realWindows && !isLead
            && (desk?.lead.additionNumber ?? 0) < LiveWindowsWire.leasePerCanvas ? Settings.Renderer.capture : asked
        rendererRevision += 1
        let revision = rendererRevision
        configuringRenderer = true
        liveRecoveryTimer?.invalidate(); liveRecoveryTimer = nil
        reloader.watch(isLead && requested == .realWindows)
        view.cancelAnimation()
        handingOff = false
        handoffTarget = nil
        suspendRealWindows()
        for p in proxies.values { p.stopCapture() }
        refreshTimer?.invalidate(); refreshTimer = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let available = requested == .realWindows && LiveWindowsConnection.probe()
            let version = available ? LiveWindowsConnection.version() : nil
            DispatchQueue.main.async {
                guard let self, self.rendererRevision == revision else { return }
                self.renderer = available ? .realWindows : .capture
                self.configuringRenderer = false
                self.additionOutdated = available && version != LiveWindowsWire.additionVersion
                self.additionNumber = available ? LiveWindowsWire.additionNumber(version) : 0
                self.rendererSettled()
                for p in self.proxies.values { p.usesRealWindow = available && p.kind == .window }
                self.liveTimer?.invalidate(); self.liveTimer = nil
                if available {
                    self.liveSince = Date()
                    Log.note("Rendering: scaled real windows (live-window protocol v1, add-on \(version ?? "?"))")
                    self.lowerStrays()
                    if self.additionOutdated {
                        // Still usable, with what it has (an older handoff can show a frame in between);
                        // the one in this build goes into the Dock once, with the password prompt if need be.
                        Log.note("Rendering: the Dock runs add-on \(version ?? "?"), this build carries \(LiveWindowsWire.additionVersion); reloading it")
                        self.reloadAddition()
                    }
                } else {
                    if requested == .realWindows { Log.note("Rendering: addition unavailable or incompatible; using capture proxies") }
                    self.enableCaptureFallback()
                    // Takeover may have restarted the Dock before the canvas was up to see it happen.
                    if requested == .realWindows {
                        self.reloadAddition()
                        self.liveRecoveryAttempts += 1
                        self.scheduleLiveRecovery()
                    }
                }
                self.scheduleDiff()
                self.scheduleCapturePass()
            }
        }
    }

    private func enableCaptureFallback() {
        if !requestedCapturePermission {
            requestedCapturePermission = true
            if !permissionsAskedElsewhere { Permissions.requestScreenCapture() }
        }
        unstreamable.removeAll()
        requestFullSync(for: Set(proxies.keys))
    }

    private func fallBackFromRealWindows(_ reason: String) {
        guard renderer == .realWindows else { return }
        Log.note("Rendering: live-window connection failed — \(reason); restoring and falling back")
        resetPipShapes()
        view.cancelAnimation()
        handingOff = false
        handoffTarget = nil
        suspendRealWindows()
        lowerOwnWindows()   // whatever the lease's end did or didn't manage
        lowerOnShow()       // the entered window and the ones kept with it, left above everything otherwise
        renderer = .capture
        rendererSettled()
        liveTimer?.invalidate(); liveTimer = nil
        for p in proxies.values { p.usesRealWindow = false }
        enableCaptureFallback()
        scheduleDiff()
        scheduleCapturePass()
        // A mode that held for a while fell to something new; one that keeps failing backs off.
        if Date().timeIntervalSince(liveSince) >= CanvasController.liveRecoveryReset { liveRecoveryAttempts = 0 }
        scheduleLiveRecovery()
    }

    /// Live windows are wanted but the canvas is on capture proxies: the addition is asked again after
    /// a while — a second, then twice as long each time, up to half a minute — and live windows come
    /// back by themselves once it answers, with the canvas in front. A fall-back was never the end of
    /// live mode until the next launch; it was a lost connection, a Dock that restarted, or a stall,
    /// and the addition is usually there again moments later (`reloadAddition` puts it back into a
    /// new Dock meanwhile). The probe is one socket connection, so asking every half minute costs
    /// nothing.
    static let liveRecoveryReset: TimeInterval = 30
    static let liveRecoveryMaxDelay: TimeInterval = 30

    private func scheduleLiveRecovery() {
        guard isLead, Settings.renderer == .realWindows, renderer != .realWindows, !Stability.safeMode else { return }
        liveRecoveryTimer?.invalidate()
        let delay = min(CanvasController.liveRecoveryMaxDelay, pow(2, Double(liveRecoveryAttempts)))
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveRecoveryTick() }
        }
        t.tolerance = delay / 4
        RunLoop.main.add(t, forMode: .common)
        liveRecoveryTimer = t
    }

    private func liveRecoveryTick() {
        liveRecoveryTimer = nil
        guard Settings.renderer == .realWindows, renderer != .realWindows, !configuringRenderer else { return }
        // Not while a reload is under way, or from inside a window: the switch back wants the canvas in
        // front, the way a renderer change from Settings does. Ask again shortly.
        guard !reloading, NSApp.isActive, activeProxy == nil, !handingOff, addingWidgets == nil else {
            liveRecoveryAttempts = min(liveRecoveryAttempts, 1)
            scheduleLiveRecovery()
            return
        }
        let revision = rendererRevision
        let safeMode = Stability.safeMode
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = !safeMode && LiveWindowsConnection.probe()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.rendererRevision == revision, Settings.renderer == .realWindows,
                          self.renderer != .realWindows else { return }
                    guard available else {
                        self.liveRecoveryAttempts += 1
                        self.scheduleLiveRecovery()
                        return
                    }
                    Log.note("Rendering: the live-window addition answers again; back to scaled real windows")
                    self.configureRenderer(.realWindows)
                }
            }
        }
    }

    /// A new Dock: the addition went with the old one. The lease is gone, so the windows go back to
    /// capture proxies until the addition is loaded into the new Dock and answers again.
    private func dockRestarted() {
        guard Settings.renderer == .realWindows else { return }
        if renderer == .realWindows { fallBackFromRealWindows("the Dock restarted") }
        // The add-on can only be loaded into a Dock that has finished starting.
        DispatchQueue.main.asyncAfter(deadline: .now() + AdditionReloader.dockSettle) { [weak self] in
            MainActor.assumeIsolated { self?.reloadAddition() }
        }
    }

    /// Whether the menu's Reload Live Windows… has something to do: live windows wanted, not running.
    var canReloadLiveWindows: Bool {
        Settings.renderer == .realWindows && (renderer != .realWindows || additionOutdated) && !configuringRenderer && !reloading
            && !Stability.safeMode
    }
    /// The add-on answering in the Dock is older than the one this build carries (`configureRenderer`).
    private var additionOutdated = false

    /// Loads the addition into the running Dock and goes back to live windows once it answers. Quietly
    /// once per Dock (`sudo -n`, which works where sudoers allows it); where that needs a password, the
    /// administrator prompt comes up by itself, once per Dock, and sets up `sudo -n` for next time.
    /// `interactive` goes straight to the prompt, for the menu item.
    /// `asked` is false only for the prompt Sunlight brings up by itself after a quiet try needed a password.
    func reloadAddition(interactive: Bool = false, asked: Bool = true, failure: ((String) -> Void)? = nil) {
        guard Settings.renderer == .realWindows, !reloading, interactive || reloader.mayTryQuietly else { return }
        // Not by itself in preview mode, nor on a Mac that can't load the add-on yet (SIP on, or no boot
        // argument): the load would fail and only leave an administrator prompt or a Login Items request
        // behind. Set Up Sunlight loads when the person asks.
        if !interactive, Stability.safeMode {
            Log.note("Rendering: not loading the live-window addition by itself (safe mode)")
            return
        }
        if !interactive, Settings.previewMode || !SetupStatus.liveWindowsPossible() {
            Log.note("Rendering: not loading the live-window addition by itself (\(Settings.previewMode ? "preview mode" : "SIP or the boot argument isn't set"))")
            return
        }
        if interactive { _ = reloader.claimPrompt() }
        reloading = true
        Log.note("Rendering: loading the live-window addition into the Dock\(interactive ? " (administrator prompt)" : "")")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.reloader.reload(interactive: interactive, asked: interactive && asked)
            self.reloading = false
            Log.note("Rendering: reload \(outcome.description)")
            // Asked for from the menu: a failure is said, not only logged.
            if interactive, outcome != .loaded, !outcome.description.contains("(-128)") {   // -128: cancelled
                if let failure {
                    failure(outcome.description)   // the setup window says it on its page
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Live windows couldn't be reloaded"
                    alert.informativeText = "The live-window addition \(outcome.description). Sunlight keeps using capture proxies."
                    alert.beginSheetModal(for: self.window, completionHandler: nil)
                }
            }
            if !interactive, outcome == .needsPassword, self.reloader.claimPrompt() {
                self.reloadAddition(interactive: true, asked: false)
                return
            }
            guard outcome == .loaded, Settings.renderer == .realWindows,
                  self.renderer != .realWindows || self.additionOutdated else { return }
            self.configureRenderer(.realWindows)
        }
    }

    // MARK: Preview mode

    /// The badge and the first-live toast follow the renderer: the badge while it's capture in preview
    /// mode; and the first time live windows answer on this Mac, preview mode is over for good.
    private func rendererSettled() {
        if isLead, !configuringRenderer { desk?.leadRendererSettled() }
        if renderer == .realWindows, !Settings.liveWindowsEverLoaded {
            Settings.liveWindowsEverLoaded = true
            Log.note("Rendering: live windows loaded for the first time on this Mac; preview mode is over")
            // Only after a preview was seen this launch: an upgrade already on live windows says nothing.
            if previewShown { CanvasToast.show("This is the real thing: your live windows.", in: overlay) }
        }
        updatePreviewBadge()
    }

    private func updatePreviewBadge() {
        let wanted = renderer == .capture && !configuringRenderer && Settings.previewMode
        if wanted {
            if previewBadge == nil {
                let badge = PreviewBadge()
                badge.onGoLive = { [weak self] in self?.onSetUp?() }
                overlay.addSubview(badge)
                previewBadge = badge
                previewShown = true
            }
            placePreviewBadge()
        } else if let badge = previewBadge {
            badge.removeFromSuperview()
            previewBadge = nil
        }
    }

    /// Bottom-left, inside the Dock when it's showing (the minimap has bottom-right), and out of the
    /// ⌘Tab strip's way while it shows, like the minimap.
    private func placePreviewBadge(animated: Bool = false) {
        guard let badge = previewBadge else { return }
        var frame = badge.frame(in: visibleTopLeft)
        if let strip = switcherHUD.activeLayout { frame = strip.clearing(frame) }
        guard frame != badge.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                badge.animator().frame = frame
            }
        } else {
            badge.frame = frame
        }
    }

    /// Takeover is about to restart the Dock: hand every window back first. A lease the Dock dies
    /// holding can't restore the windows it transformed.
    func releaseLiveWindowsForDockRestart() {
        guard renderer == .realWindows else { return }
        fallBackFromRealWindows("the Dock is about to restart")
    }

    /// `keepingLook`: hand the windows back but leave the canvas as it looks in live mode, the
    /// almost-clear input window over the opaque backdrop. Leaving for a window (or another app) keeps
    /// it, so the window the user was in is still visible between the two when the canvas comes back,
    /// rather than covered by an empty canvas until the next snapshot lands: that was the blink.
    private func suspendRealWindows(keepingLook: Bool = false) {
        realWindowListReady = false
        lastFrame = nil
        parked.removeAll()
        lastFullIDs = []
        lastFullParked = []
        fullFrameNeeded = true
        // Nothing presented and the live look already down: nothing to do. The live timer lands here
        // twice a second whenever the canvas is away; re-mounting the background each time was work.
        guard realWindowsPresented || keepingLook || view.showsRealWindows || backdrop?.isVisible == true else { return }
        if realWindowsPresented {
            realWindowsPresented = false
            liveTimer?.invalidate(); liveTimer = nil
            // Deactivating for another app: its windows were raised to the front of the normal level,
            // and the canvas, coming down from its own level (sunlight-11), goes under them, where it
            // would have been (`LiveWindowsWire.liftsCanvasInDock`).
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let above: pid_t = NSApp.isActive || front == myPID ? 0 : front
            _ = realWindows.restore(overlay: CGWindowID(window.windowNumber),
                                    backdrop: backdrop.map { CGWindowID($0.windowNumber) } ?? 0,
                                    above: above, pinned: above != 0 ? pipIDs() : [])
            // An add-on from sunlight-27 keeps the canvas up above every other window while an app is
            // in front, with that app's windows lifted above it; the canvas comes down only when it
            // goes dormant or lets live windows go.
            if above == 0 || additionNumber < 27 { lowerOwnWindows() }
        }
        guard !keepingLook else { return }
        backdrop?.orderOut(nil)
        view.showsRealWindows = false
        view.hostBackground(in: nil)
        view.hostWidgets(in: nil)
    }

    /// An app the canvas sends straight back behind it as it comes forward (`foreignActivation`): one
    /// still launching (from the canvas a launch stays on it), a launch kept on the canvas activating
    /// itself again as its window shows, the app macOS brings forward after a close, one a layout
    /// restore opened.
    private func sendsStraightBack(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        // As `foreignActivation` lets an activation through before it gets to these.
        guard pid != myPID, activeProxy == nil, realWindowsPresented, app.activationPolicy == .regular,
              let env, Date() >= env.ignoreActivationsUntil, addingWidgets == nil, !isSetupShowing,
              pid != expectedActivationPID else { return false }
        if Date() < quietAfterCloseUntil || !app.isFinishedLaunching { return true }
        if let launch = launches[pid], Date() < launch.deadline { return true }
        if let restoring, let id = app.bundleIdentifier, restoring.apps.contains(id) { return true }
        return false
    }

    /// The canvas keeps its windows while such an app is in front for a moment: handing them back put
    /// them at full size where they are natively, over the zoomed canvas, until it came back. If it
    /// doesn't come back after all, they're handed back as usual.
    /// `app` nil: an activation that took the front but isn't reported yet, held for the same way.
    private func holdThroughForeignFront(_ app: NSRunningApplication?) {
        if let app {
            Log.note("Canvas: \(app.localizedName ?? "pid \(app.processIdentifier)") came forward to be sent back — the windows stay on the canvas")
        } else {
            Log.note("Canvas: deactivated for an app not yet reported — the windows stay on the canvas for now")
        }
        foreignFrontHeldUntil = CACurrentMediaTime() + CanvasController.foreignFrontHold
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.foreignFrontHold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !NSApp.isActive, !self.staysUp, self.realWindowsPresented else { return }
                Log.note("Canvas: still not back in front — handing the windows back")
                self.foreignFrontHeldUntil = 0
                self.suspendRealWindows(keepingLook: true)
            }
        }
    }

    static let foreignFrontHold: TimeInterval = 0.5

    /// Until when the windows are held on the canvas for an app sent straight back (above). The frame
    /// pass asks for a frame on the way (a capture pass, the live timer) and, finding the canvas not in
    /// front, handed the windows back after all, 10 ms after the hold began: the canvas came down to the
    /// normal level, and the window the launching app then opened was born on top of it, full-size, for
    /// the frames until the canvas was back and had scaled it. While the hold lasts, the pass sends nothing.
    private var foreignFrontHeldUntil: CFTimeInterval = 0

    /// The canvas's own two windows back at the normal level, in case a lease ended without the add-on
    /// putting them there (the Dock died holding it, a socket error): an add-on from sunlight-11 lifts
    /// them one level up while live windows are presented, and AppKit's idea of their level never
    /// changes, so this goes to the window server directly. A no-op when they are already there.
    private func lowerOwnWindows() {
        WindowServerEvents.setLevel(of: CGWindowID(window.windowNumber), to: 0)
        if let backdrop { WindowServerEvents.setLevel(of: CGWindowID(backdrop.windowNumber), to: 0) }
    }

    /// The frame last handed to the driver, so an identical one isn't sent again: the camera callback
    /// and the capture pass both ask on a camera change, and the live timer asks at rest. `keepalive`
    /// sends it anyway: the Dock gives up a lease that has seen no frame for three seconds, so the
    /// timer's frame goes out whether or not anything changed (the Dock does nothing with it).
    private var lastFrame: (windows: [LiveWindowsWire.Window], shadow: Data?)?
    /// The alpha last sent for each leased window not at its own (a window opening or closing), so only
    /// changes go out (`LiveWindowsWire.alpha`).
    private var sentAlpha: [CGWindowID: Float] = [:]
    /// The canvas has had more windows than a frame takes (`nearestIndices`), said once.
    private var loggedFrameCap = false
    /// The add-on's number (`LiveWindowsWire.additionNumber`) as it answered when the renderer was set up:
    /// from 8 a frame carries flags, and the canvas decides what is full (below).
    private(set) var additionNumber = 0
    /// The add-on keeps every window's native place under the menu bar (sunlight-28): the native place
    /// the canvas expects for any window is the clamped one, its drawn place carried by the transform.
    private var clampsNatively: Bool { renderer == .realWindows && additionNumber >= 28 }
    /// Windows far off screen, with the transform they were last sent at: a window past a screen's
    /// width around the viewport is left out of partial frames, so a pan or a zoom costs the Dock one
    /// transform per window near the view rather than one per window. Its stale transform keeps it
    /// where it was, at least a screen away, until the camera brings its true place within half a
    /// screen of the view; then a full frame (the set changed) moves it. The two margins keep a window
    /// at the edge from flapping between the two.
    private var parked: [CGWindowID: LiveWindowsWire.Window] = [:]
    /// The windows of the last full frame, bottom to top: the order the Dock asserted; and which of
    /// them were parked, since a window is parked or woken by a full frame (the one a fresh lease
    /// starts from has to carry every window where it is).
    private var lastFullIDs: [CGWindowID] = []
    private var lastFullParked: Set<CGWindowID> = []
    /// The next frame asserts level and stacking for every window: the listing showed an order the
    /// canvas didn't ask for (an app raised a window of its own), or the camera has been still for a
    /// second since it last moved (the add-on's old clock did this every second, pans included).
    private var fullFrameNeeded = true
    private var lastCameraMotion: CFTimeInterval = 0
    private var settledSinceMotion = true
    /// Listings in a row whose order differed from the asserted one: logged once if it keeps happening.
    private var orderMismatches = 0

    /// How far past the viewport a window is parked, and how near it has to come to be moved again, in
    /// screens (half a screen is what the capture pass counts as leaving).
    nonisolated static let parkMargin: CGFloat = 1
    nonisolated static let wakeMargin: CGFloat = 0.5
    /// How long the camera is still before a full frame reasserts level and stacking.
    static let settleReassert: CFTimeInterval = 1

    /// Whether a window is parked: its screen rect (and the one where a flight ends, if the camera is
    /// on its way) is past `parkMargin` screens around the view, or, already parked, not yet within
    /// `wakeMargin`.
    nonisolated static func parks(wasParked: Bool, rect: CGRect, target: CGRect?, view: CGSize) -> Bool {
        let margin = wasParked ? wakeMargin : parkMargin
        let zone = CGRect(origin: .zero, size: view).insetBy(dx: -view.width * margin, dy: -view.height * margin)
        return !(rect.intersects(zone) || target?.intersects(zone) == true)
    }

    /// Of `rects` (on screen), the indices of at most `limit` of them nearest the view: the ones in view
    /// or closest to it, `pinned` always among them, in their original order. The add-on takes at most
    /// `LiveWindowsWire.maxWindows` in a frame; a canvas with more windows than that shows the ones near
    /// the view live and leaves the rest under the backdrop until the camera brings them near. (Sending
    /// them all threw, the renderer fell back to pictures, recovered a second later and threw again: a
    /// canvas of 129 windows flapped between the two modes for as long as it lived.)
    nonisolated static func nearestIndices(_ rects: [CGRect], to view: CGRect, limit: Int, pinned: Int? = nil) -> [Int] {
        guard rects.count > limit, limit > 0 else { return Array(rects.indices) }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(0, view.minX - r.maxX, r.minX - view.maxX)
            let dy = max(0, view.minY - r.maxY, r.minY - view.maxY)
            return hypot(dx, dy)
        }
        var order = rects.indices.sorted { a, b in
            let da = distance(rects[a]), db = distance(rects[b])
            return da != db ? da < db : a > b   // the same distance: the topmost first
        }
        if let pinned, rects.indices.contains(pinned), let at = order.firstIndex(of: pinned) {
            order.remove(at: at)
            order.insert(pinned, at: 0)
        }
        return order.prefix(limit).sorted()
    }

    private func updateRealWindows(keepalive: Bool = false) {
        guard renderer == .realWindows, !configuringRenderer else { return }
        guard !asleep, addingWidgets == nil else {
            suspendRealWindows()
            return
        }
        guard isUp, activeProxy == nil else {
            if activeProxy == nil, CACurrentMediaTime() < foreignFrontHeldUntil { return }   // held for an app on its way back behind the canvas
            suspendRealWindows(keepingLook: true)
            return
        }
        foreignFrontHeldUntil = 0
        guard realWindowListReady else { return }
        if backdrop == nil {
            let background = NSWindow(contentRect: display.cocoaFrame, styleMask: .borderless, backing: .buffered, defer: false)
            background.isReleasedWhenClosed = false
            background.backgroundColor = view.background
            background.isOpaque = true
            background.hasShadow = false
            background.ignoresMouseEvents = true
            background.collectionBehavior = window.collectionBehavior
            background.contentView?.wantsLayer = true
            backdrop = background
        }
        guard let backdrop else { return }
        if !realWindowsPresented {
            // A backdrop still up from before (see `suspendRealWindows`) stays where it is: the window
            // just left sits above it, and putting the backdrop back under the canvas would cover that
            // window until the snapshot orders it in. The snapshot orders everything from the backdrop up.
            backdrop.backgroundColor = view.background
            if !backdrop.isVisible { backdrop.order(.below, relativeTo: window.windowNumber) }
            view.showsRealWindows = true
            // The picture goes with the colour: onto the backdrop, under the real windows.
            if let host = backdrop.contentView?.layer {
                view.hostBackground(in: host)
                view.hostWidgets(in: host)
            }
            realWindowsPresented = true
            lastFrame = nil
            startLiveTimer()
        }
        // Widgets aren't among them: they stay captured (`streamWidgets`), on the backdrop.
        let flagged = additionNumber >= 8
        let camera = view.camera
        let wire = global(camera)   // the add-on places windows in global points
        let target = view.targetCamera
        let size = view.bounds.size
        var all: [LiveWindowsWire.Window] = []      // every window, parked ones at their parked transform
        var near: [LiveWindowsWire.Window] = []     // the ones a partial frame moves
        var ids: [CGWindowID] = []
        all.reserveCapacity(view.proxies.count)
        // One record per window, the topmost proxy's where two name the same window (a proxy replaced
        // mid-listing), and never more than the add-on takes: the ones nearest the view, the handoff
        // target always among them. The frame is built from what's here, so nothing below can throw.
        var candidates: [WindowProxy] = []
        var seenIDs = Set<CGWindowID>()
        for p in view.proxies.reversed() where p.kind == .window && lastWantedIDs.contains(p.windowID) && !p.heldBack {
            let r = p.worldRect
            guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, r.width > 0, r.height > 0 else { continue }
            if seenIDs.insert(p.windowID).inserted { candidates.append(p) }
        }
        candidates.reverse()
        if candidates.count > LiveWindowsWire.maxWindows {
            let keep = CanvasController.nearestIndices(candidates.map { camera.toScreen($0.worldRect) },
                                                       to: CGRect(origin: .zero, size: size), limit: LiveWindowsWire.maxWindows,
                                                       pinned: handoffTarget.flatMap { t in candidates.firstIndex { $0 === t } })
            if !loggedFrameCap {
                loggedFrameCap = true
                Log.note("Rendering: \(candidates.count) windows on the canvas, more than the add-on takes in one frame (\(LiveWindowsWire.maxWindows)); the ones nearest the view are live, the rest wait under the backdrop")
            }
            candidates = keep.map { candidates[$0] }
        }
        for p in candidates {
            let id = p.windowID
            ids.append(id)
            if flagged, p !== handoffTarget, p.pip == nil {   // a tile is on the screen whatever the camera does
                let r = camera.toScreen(p.worldRect)
                let rt = target.map { $0.toScreen(p.worldRect) }
                let park = CanvasController.parks(wasParked: parked[id] != nil, rect: r, target: rt, view: size)
                if park, let parkedAt = parked[id] {
                    all.append(parkedAt)
                    continue
                }
                let window = LiveWindowsWire.Window(id: id, worldRect: p.worldRect, inset: p.inset, camera: wire, effect: p.effect)
                if park {
                    parked[id] = window
                } else {
                    parked[id] = nil
                    near.append(window)
                }
                all.append(window)
            } else {
                let window = LiveWindowsWire.Window(id: id, worldRect: p.worldRect, inset: p.inset, camera: wire, effect: p.effect)
                all.append(window)
                near.append(window)
            }
        }
        let shadow = flightShadow
        // Full: the whole set, level and stacking asserted. A frame is full when the set or its order
        // changed (a window arrived, left, was parked or woken), on the first frame of a presentation,
        // and when asked (`fullFrameNeeded`). Otherwise partial: only the windows near the view. A
        // full frame costs the Dock three window-server calls per window; a partial one, one per
        // window near the view whose transform changed, all in one transaction.
        let parkedNow = Set(parked.keys)
        let full = !flagged || fullFrameNeeded || lastFrame == nil || ids != lastFullIDs || parkedNow != lastFullParked
        let windows = full ? all : near
        // Windows opening or closing fade where the add-on takes alpha (sunlight-40): what changed since
        // the last frame, and on a full frame every window not at its own alpha, in case the lease is new.
        if lastFrame == nil { sentAlpha = [:] }
        var alphas: [CGWindowID: Float] = [:]
        var present = Set<CGWindowID>()
        for p in candidates {
            let id = p.windowID, a = p.effect.opacity
            present.insert(id)
            if a != (sentAlpha[id] ?? 1) || (full && a != 1) { alphas[id] = a }
            sentAlpha[id] = a == 1 ? nil : a
        }
        sentAlpha = sentAlpha.filter { present.contains($0.key) }
        if !keepalive, !full, alphas.isEmpty, let last = lastFrame, last.windows == windows, last.shadow == shadow { return }
        lastFrame = (windows, shadow)
        if full {
            lastFullIDs = ids
            lastFullParked = parkedNow
            fullFrameNeeded = false
            settledSinceMotion = true
        }
        do {
            realWindows.submit(try LiveWindowsWire.snapshot(windows, backdrop: CGWindowID(backdrop.windowNumber),
                                                     overlay: CGWindowID(window.windowNumber),
                                                     kind: flagged ? (full ? .full : .partial) : .legacy),
                               shadow: shadow, full: full, alphas: alphas)
        } catch { fallBackFromRealWindows(error.localizedDescription) }
    }

    /// The live timer runs only while real windows are presented: it is the lease's keepalive (the Dock
    /// drops a lease that has seen no frame for three seconds) and the widgets' still clock, and both
    /// are idle while the canvas is away or asleep.
    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    /// The live timer's tick, twice a second: the keepalive frame, and once the camera has been still
    /// for `settleReassert`, a full one, so an app that raised a window of its own behind the canvas's
    /// back during the gesture is put back under the canvas.
    private func liveTick() {
        if !settledSinceMotion, CACurrentMediaTime() - lastCameraMotion >= CanvasController.settleReassert {
            settledSinceMotion = true
            fullFrameNeeded = true
        }
        updateRealWindows(keepalive: true)
        streamWidgets()
    }

    // MARK: Timers and dormancy

    /// How often the window server's list is read without an event asking for it: moves and title
    /// changes wait this long at most. New windows and windows leaving the Space come as events
    /// (`WindowServerEvents`) and list at once.
    nonisolated static let listingInterval: TimeInterval = 3

    /// A listing every `listingInterval` (cheap), a full ScreenCaptureKit enumeration every 30 s to
    /// freshen the handles and retry windows it didn't return. Both in the common modes, so a menu or
    /// a sheet doesn't pause them; both only while the canvas is active.
    private func startSyncTimer() {
        guard diffTimer == nil else { return }
        let d = Timer(timeInterval: CanvasController.listingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDiff() }
        }
        d.tolerance = 0.25
        RunLoop.main.add(d, forMode: .common)
        diffTimer = d
        let h = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.activeProxy == nil else { return }
                self.unstreamable.removeAll()
                self.requestFullSync(for: [])
            }
        }
        h.tolerance = 5
        RunLoop.main.add(h, forMode: .common)
        heartbeatTimer = h
    }

    private func stopSyncTimer() {
        diffTimer?.invalidate()
        diffTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// The refresh timer exists only while something in front isn't streaming: on the canvas, with
    /// every window behind it, there is nothing for it to do.
    private func ensureRefreshTimer() {
        let needed = renderer == .capture && !configuringRenderer && OneShotCapture.isAvailable && !asleep
            && view.proxies.contains { ($0.inFront || $0.capped) && !$0.isStreaming }
        if needed, refreshTimer == nil {
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTick() }
            }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        } else if !needed, refreshTimer != nil {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    /// Asleep: every stream stops and the timers with them. Awake: a sync (which restarts what can be
    /// seen) if the canvas is in front, else the pass and the refresh timer for the window the user
    /// unlocked into.
    private func dormancyChanged(_ asleep: Bool) {
        self.asleep = asleep
        if asleep {
            suspendRealWindows()
            capturePass()
            stopSyncTimer()
            stopEnteredTimer()   // nothing to watch with the display off; back once it wakes
            ensureRefreshTimer()
            passTimer?.invalidate()
            passTimer = nil
        } else {
            startSyncTimer()
            if activeProxy != nil, env != nil { startEnteredTimer() }
            if NSApp.isActive {
                scheduleDiff()
            } else {
                scheduleCapturePass()
            }
        }
    }

    func show() {
        guard !paused else { return }   // off in the menu bar; the switch brings it back
        // The canvas wants the front from now (`frontTakenBack`); a show on top of one still on its way
        // doesn't extend the wish, so an app that keeps taking the front can't be fought for ever.
        let now = CACurrentMediaTime()
        if now >= wantsFrontUntil { wantsFrontUntil = now + CanvasController.wantsFrontFor }
        // Live mode, from an entered window: its active shadow look (the one shown while it is key) is
        // eased back to the inactive one first, over a few frames, so the window server's switch as the
        // canvas takes the screen changes nothing (see `shadowFlight`). A click on the canvas activates us
        // by itself, and doesn't pass here.
        if renderer == .realWindows, !NSApp.isActive, let p = activeProxy {
            guard !showing else { return }
            showing = true
            shadowEasedBack = p.windowID
            let steps = 5
            let requests = (1...steps).map { LiveWindowsWire.shadow(p.windowID, inactiveWeight: 0, activeWeight: Float(steps - $0) / Float(steps)) }
            realWindows.ease(shadows: requests, interval: 1.0 / 60) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showing = false
                    self.showNow()
                }
            }
            return
        }
        showNow()
    }

    private func showNow() {
        springDrag = false
        window.ignoresMouseEvents = false
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        desk?.bringForward(besides: self)
        // Keys go to the canvas view.
        if window.firstResponder === window { window.makeFirstResponder(view) }
        // Cooperative activation (macOS 14+) refuses an app the user hasn't interacted with, which is
        // exactly our situation when a tap command or a closed window brings the canvas back. The canvas
        // has to come back regardless: Carbon's SetFrontProcess still does it (verified on 27.2), and
        // ordering the window front covers the screen even before activation lands. Right after a
        // handoff `isActive` still reads true while the other app's activation is landing, so an
        // entered window counts as "not in front" too.
        // The workspace's front app likewise: it can be another app while this one still reads as
        // active (its deactivation on the way: an app clicked in the Dock reported by the workspace
        // first), and an activation asked for then changed nothing.
        if !NSApp.isActive || activeProxy != nil || NSWorkspace.shared.frontmostApplication?.processIdentifier != myPID { forceFront() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !NSApp.isActive else { return }
            Log.note("Sunlight: still not active 300 ms after show()")
            // ⌘Tab is waiting on the canvas, or an app on its way took the front back; don't leave the
            // user stranded in the window.
            if self.switcher != nil || self.frontTakenBack() { self.forceFront() }
        }
    }

    /// Until when the canvas wants the front, from the last `show`: the user asked for the canvas, or
    /// it is on its way over to a window (`slide`). Cleared as it arrives, and whenever it yields on
    /// purpose (`enter`, a window used where it's drawn, an app the user went to instead).
    private var wantsFrontUntil: CFTimeInterval = 0
    static let wantsFrontFor: CFTimeInterval = 1.5

    /// Whether an app took the front back from the canvas on its way forward (`show`), so it never came:
    /// the one the user was in, whose activation from the handoff landed after the canvas was asked
    /// back (⌘Tab or the Mission Control key right after entering a window: the canvas came forward,
    /// read as active still, and the app's activation then landed over it), or the one the canvas is
    /// going over to, whose Dock-click activation the workspace reported before AppKit deactivated
    /// Sunlight, so `show` found it active and asked for nothing. ⌘Tab's pick, a pan, Show Desktop
    /// or the placement then waited for a canvas that wasn't coming. Only those two apps: any other
    /// in front is the user's own doing (a click, a Dock click meanwhile), answered by `foreignActivation`.
    private func frontTakenBack() -> Bool {
        guard !NSApp.isActive, CACurrentMediaTime() < wantsFrontUntil,
              let front = NSWorkspace.shared.frontmostApplication, front.activationPolicy == .regular else { return false }
        let pid = front.processIdentifier
        guard pid != myPID else { return false }
        return pid == activeProxy?.pid || pid == expectedActivationPID || pid == slidingIn?.pid
    }

    /// A moment after the canvas lost the front while it wanted it (`didResignActive`): back, if the app
    /// that took it is one of the two above. A moment, not at once: the activation that took the front
    /// is reported just after, and `foreignActivation` is the one to answer a user's.
    private func reassertFrontIfTakenBack() {
        guard frontTakenBack() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.frontTakenBack() else { return }
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
                Log.note("Sunlight: \(front) took the front back while the canvas was on its way — coming back")
                self.show()
            }
        }
    }

    private func forceFront() {
        let err = forceSunlightFront()
        window.orderFrontRegardless()
        if err != noErr { Log.note("Sunlight: SetFrontProcess failed (\(err))") }
    }

    /// Brings the canvas back from wherever the user is; optionally frames everything once it's up.
    func showCanvas(fitAll: Bool) {
        if fitAll { endShowDesktop(flyBack: false) }
        if NSApp.isActive {
            if fitAll { view.fitAll(animated: true) }
            return
        }
        pendingFitAll = fitAll
        show()
    }

    /// Opened without activating it, so its windows come up behind the canvas, where the next listing
    /// finds them. An app that activates itself anyway is put back behind (`foreignActivation`).
    private func open(appAt url: URL, name: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            if let error { Log.note("Launch: \(name) failed — \(error.localizedDescription)") }
            guard let app else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.expectArrival(of: app, name: name) }
            }
        }
    }

    // MARK: Open Here

    /// Right-click › Open Here… picked an app: its next window on the canvas lands on `spot`
    /// (`placeNewWindows`), the windows it already has excepted.
    private struct OpenHere {
        let name: String
        let bundleID: String?
        let pid: pid_t?
        /// World point the window's middle goes to.
        let spot: CGPoint
        /// ⌘⏎: go into the window once it's there.
        let enter: Bool
        let known: Set<CGWindowID>
        let deadline: Date
        /// When the first window took the spot: others of the app arriving with it (a browser restoring
        /// several) go beside it for a moment more.
        var placedAt: Date?
        /// ⌘N from inside this window (`newWindowBeside`): if no window comes, back into it.
        var returnTo: WindowProxy? = nil
    }
    private var openingHere: OpenHere?
    private var openHerePanel: OpenHerePanel?
    /// A running app asked for a new window gets this long to show one before its last-used window is
    /// brought to the spot instead.
    static let openHereNewWindowWait: TimeInterval = 2
    /// After the first window, how long the app's other new windows still count as Open Here's.
    static let openHereSiblingWait: TimeInterval = 1

    /// The bar over the canvas, ringing the spot until it's dismissed.
    func openHere(at spot: CGPoint) {
        guard NSApp.isActive, activeProxy == nil, !handingOff, restoring == nil, addingWidgets == nil,
              !Settings.stripMode else { return }
        if openHerePanel == nil {
            let panel = OpenHerePanel(catalog: AppCatalog.shared)
            panel.onDismiss = { [weak self] in self?.view.openHereMark = nil }
            openHerePanel = panel
        }
        openHerePanel?.onOpen = { [weak self] app, enter in self?.open(app, at: spot, enter: enter) }
        closeSwitcher(clearHighlight: true)
        view.openHereMark = spot
        openHerePanel?.show(over: window)
    }

    /// The app picked in the bar. Not running, or running with no window: opened (a running app is sent
    /// the reopen a Dock click sends), behind the canvas. Running with windows: its New Window item is
    /// pressed, and if no window shows in `openHereNewWindowWait` (an app with one window, an item that
    /// makes no window) the window used last glides to the spot instead.
    private func open(_ app: AppEntry, at spot: CGPoint, enter: Bool) {
        let bundleID = Bundle(url: app.url)?.bundleIdentifier
        guard bundleID == nil || bundleID != Bundle.main.bundleIdentifier else { return NSSound.beep() }
        AppCatalog.shared.noteLaunch(app)
        let running = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first { !$0.isTerminated } }
        let pid = running?.processIdentifier
        let known = Set((Array(proxies.values) + Array(away.values)).filter { $0.matches(bundleID: bundleID, pid: pid) }.map(\.windowID))
        openingHere = OpenHere(name: app.name, bundleID: bundleID, pid: pid, spot: spot, enter: enter, known: known,
                            deadline: Date().addingTimeInterval(CanvasController.launchWait))
        guard let running, !known.isEmpty else {
            Log.note("Open Here: \(running == nil ? "launching" : "reopening") \(app.name) at \(spot)")
            open(appAt: app.url, name: app.name)
            return
        }
        Log.note("Open Here: asking \(app.name) for a new window at \(spot)")
        let pidValue = running.processIdentifier
        AXQueue.interactive.async { [weak self] in
            let pressed = NewWindowMenu.press(pid: pidValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.openingHere?.pid == pidValue, self.openingHere?.placedAt == nil else { return }
                    if pressed, let running = NSRunningApplication(processIdentifier: pidValue) {
                        self.expectArrival(of: running, name: app.name)
                        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.openHereNewWindowWait) { [weak self] in
                            MainActor.assumeIsolated { self?.openHereFallback(pid: pidValue) }
                        }
                    } else {
                        Log.note("Open Here: \(app.name) has no New Window item")
                        self.openHereFallback(pid: pidValue)
                    }
                }
            }
        }
    }

    /// No new window came: the app's window used last glides to the spot (beside what's there), as a drag
    /// would put it.
    private func openHereFallback(pid: pid_t) {
        guard let pending = openingHere, pending.pid == pid, pending.placedAt == nil else { return }
        openingHere = nil
        guard NSApp.isActive, activeProxy == nil, !handingOff, restoring == nil, !Settings.stripMode else { return }
        if let back = pending.returnTo {
            Log.note("New window: none came from \(pending.name) — back into \(back.title)")
            if proxies[back.windowID] === back { handoff(to: back) } else { dropHeldKeys() }
            return
        }
        let windows = view.proxies.filter { $0.kind == .window && $0.pid == pid }
        guard let p = mru.lazy.compactMap({ id in windows.first { $0.windowID == id } }).first ?? windows.last else {
            Log.note("Open Here: \(pending.name) has no window on the canvas to bring over")
            return
        }
        view.release(p)   // moved on its own: it leaves its group
        let others = view.proxies.filter { $0.kind == .window && $0 !== p }.map(\.worldRect) + away.values.map(\.worldRect)
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        let to = NewWindowSpot.spot(size: p.worldRect.size, avoiding: others, view: view.camera.toWorld(visibleTopLeft),
                                    gap: gap, target: pending.spot)
        Log.note("Open Here: no new window from \(pending.name) — bringing \(p.title) over, \(p.worldRect.origin) → \(to.origin)")
        p.tile = nil
        view.bringToFront(p)
        view.glide([(p, to.origin)], duration: CanvasView.cameraDuration)
        rememberSoon()
        if pending.enter { enterOpenedHere(p, after: CanvasView.cameraDuration + 0.05) }
    }

    /// The spot a window just made should take, if it's the one Open Here… is waiting for: the app's, and
    /// not one it already had. The first one marks the spot taken; the app's others for a moment after
    /// go beside it.
    private func openHereSpot(for p: WindowProxy) -> CGPoint? {
        guard var pending = openingHere else { return nil }
        let now = Date()
        let expired = pending.placedAt.map { now >= $0.addingTimeInterval(CanvasController.openHereSiblingWait) } ?? (now >= pending.deadline)
        guard !expired else {
            openingHere = nil
            return nil
        }
        guard p.kind == .window, !pending.known.contains(p.windowID), p.matches(bundleID: pending.bundleID, pid: pending.pid) else { return nil }
        if pending.placedAt == nil {
            pending.placedAt = now
            if pending.enter { enterOpenedHere(p, after: 0.35) }
        }
        openingHere = pending
        return pending.spot
    }

    /// ⌘⏎ in the bar: into the window once it has popped in (or glided over).
    private func enterOpenedHere(_ p: WindowProxy, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, self.proxies[p.windowID] === p, NSApp.isActive, self.activeProxy == nil else { return }
                self.handoff(to: p)
            }
        }
    }

    /// The Mission Control key — on the canvas: go back into the last window. In a window: come back to the canvas.
    func toggle() {
        guard addingWidgets == nil, !isSetupShowing, !paused else { return }   // the desktop is in edit mode; Done comes back
        if NSApp.isActive {
            if let p = lastActiveProxy, proxies[p.windowID] != nil { handoff(to: p) }
            else if let p = lastActiveProxy, away[p.windowID] === p { bringBack(p) }
        } else {
            show()
        }
    }

    /// A four-finger drag pans the canvas from wherever the user is. From a window (or any other app)
    /// the canvas comes to the front first, as with the Mission Control key, and the travel waits for it to arrive.
    /// Gestures that fire instead of panning (a tap, a flick, a spread) arrive as `.gesture`, which
    /// `Desk` turns into the command Settings › Trackpad gives them.
    func trackpadPan(_ phase: TrackpadPan.Phase) {
        let inFront = NSApp.isActive && activeProxy == nil
        switch phase {
        case .gesture:
            break   // Desk handles these; a canvas only sees them through `seeAll()` or its commands.
        case .began:
            Log.note("Pan: four-finger drag\(inFront ? "" : ", bringing the canvas back")")
            pendingPan = nil
            pendingPanEnded = false
            panBroughtCanvas = !inFront
            if !inFront {
                pendingPan = PendingTrackpadPan(viewWidth: view.bounds.width, sensitivity: CGFloat(Settings.trackpadCameraSensitivity), at: CACurrentMediaTime())
                show()
            }
        case .changed(let travel):
            if var pending = pendingPan {
                pending.add(travel, at: CACurrentMediaTime())
                pendingPan = pending
            } else if inFront {
                view.trackpadPan(by: travel)
            } else {
                // Something took the front mid-drag (typically the activation of a window just handed
                // off to, landing late). The drag still wants the canvas.
                Log.note("Pan: lost the front mid-drag, bringing the canvas back")
                var pending = PendingTrackpadPan(viewWidth: view.bounds.width, sensitivity: CGFloat(Settings.trackpadCameraSensitivity), at: CACurrentMediaTime())
                pending.add(travel, at: CACurrentMediaTime())
                pendingPan = pending
                show()
            }
        case .ended:
            if pendingPan != nil {
                pendingPan?.end(at: CACurrentMediaTime())
                pendingPanEnded = true
            } else if inFront {
                view.trackpadPanEnded()
            }
            panBroughtCanvas = false
        }
    }

    /// A four-finger gesture bound to something else fired mid-drag: the pan stops where it is, without
    /// coasting, and the gesture's command goes ahead.
    func cancelTrackpadPan(preserveOrigin: Bool = false) {
        if NSApp.isActive && activeProxy == nil && pendingPan == nil { view.trackpadPanCancelled() }
        pendingPan = nil
        pendingPanEnded = false
        if !preserveOrigin { panBroughtCanvas = false }
    }

    /// See Everything, from the four-finger tap or a flick (or the Mission Control key): from a window,
    /// the canvas with everything fitted; done again on the canvas, back into the window it came from.
    func seeAll() {
        Log.note("Pan: See All")
        // A flick was a drag until this moment: the pan stops where it is, without coasting.
        if NSApp.isActive && activeProxy == nil && pendingPan == nil { view.trackpadPanCancelled() }
        pendingPan = nil
        pendingPanEnded = false
        let fromWindow = panBroughtCanvas
        panBroughtCanvas = false
        guard addingWidgets == nil, !isSetupShowing else { return }   // the desktop is in edit mode; Done comes back
        // A flick from a window has already brought the canvas (its drag did): it still means See
        // All, not back again. On the canvas, either gesture again goes back into the last window.
        if fromWindow || !NSApp.isActive { showCanvas(fitAll: true) } else { toggle() }
    }

    // MARK: Show Desktop

    var isShowingDesktop: Bool { desktopShown != nil }

    /// F11, the four-finger spread, Window › Show Desktop: the camera flies to Finder's desktop at 1:1
    /// and everything over it dims, the files lit above the dim, as Show Desktop slides the windows away.
    /// Asked again, the dim lifts and the camera flies back to where it was. From a window, the canvas
    /// comes back first.
    func showDesktop() {
        guard addingWidgets == nil else { return }   // the desktop is in edit mode; Done comes back
        if !NSApp.isActive || activeProxy != nil {
            pendingShowDesktop = true
            pendingFitAll = false
            show()
            return
        }
        if desktopShown != nil {
            endShowDesktop(flyBack: true)
        } else {
            beginShowDesktop()
        }
    }

    private func beginShowDesktop() {
        guard desktopShown == nil else { return }
        closeSwitcher(clearHighlight: true)
        desktopShown = view.targetCamera ?? view.camera
        Log.note("Desktop: showing the desktop\(desktopFloor.windowID == nil ? " (no floor: Finder isn't drawing the desktop)" : "")")
        view.setShowsDesktop(true)
        // The minimap sits over the desktop's bottom-right corner, where Finder's icons start: it steps
        // out with `desktopShown` set (`updateMinimap`).
        // The files at 1:1, in the middle of the screen; the screen at 1:1 while Finder isn't drawing them.
        if desktopFloor.windowID != nil {
            let files = desktopFloor.worldRect
            view.animateCamera(to: Camera(center: CGPoint(x: files.midX, y: files.midY), zoom: 1, viewSize: view.bounds.size))
        } else {
            view.animateCamera(to: homeCamera)
        }
    }

    /// `flyBack`: the camera goes back to where it was before; otherwise it stays (a click on a window,
    /// entering one).
    func endShowDesktop(flyBack: Bool) {
        guard let before = desktopShown else { return }
        desktopShown = nil
        Log.note("Desktop: back from the desktop")
        view.setShowsDesktop(false)
        if flyBack { view.animateCamera(to: before) }
    }

    // MARK: Where the desktop sits

    /// Settings › Canvas › Desktop, as last read.
    private var filesPlacement = Settings.desktopFilesPlacement
    private var widgetsPlacement = Settings.widgetsPlacement

    /// The canvas is starting, or (`changed`) a dot was moved in Settings: the files and widgets go
    /// where the settings say, gliding there when changed.
    private func desktopPlacementChanged(animated changed: Bool) {
        filesPlacement = Settings.desktopFilesPlacement
        widgetsPlacement = Settings.widgetsPlacement
        if changed { Log.note("Desktop: files \(filesPlacement.title) (\(filesPlacement.stored)), widgets \(widgetsPlacement.title) (\(widgetsPlacement.stored))") }
        arrangeDesktop(animated: changed, force: true)
        minimap.redraw()
    }

    /// A widget's own spot: its card where it is on the desktop, seen at 1:1.
    private func desktopRect(of p: WindowProxy) -> CGRect {
        p.lastRealFrame.insetBy(dx: p.inset, dy: p.inset)
    }

    /// The files and the widgets where their dots put them around the windows. From each listing, so
    /// they follow the windows as they settle; `animated`, they glide there, and wait while anything
    /// else is on the move (a drag, a pan, a glide) unless `force`d.
    private func arrangeDesktop(animated: Bool, force: Bool = false) {
        guard addingWidgets == nil, force || !animated || view.isStill else { return }
        let floorShown = desktopFloor.isEnabled && desktopFloor.windowID != nil
        let widgets = view.proxies.filter { $0.kind == .widget }
        let duration = animated ? CanvasController.desktopGlide : nil

        // One block for the widgets, as they sit on the desktop together, and one for the files.
        let widgetsBlock = widgets.map(desktopRect(of:)).reduce(CGRect.null) { $0.union($1) }
        guard !widgets.isEmpty || floorShown else { return }
        let placed = DesktopPlacement.rects(widgets: widgets.isEmpty ? nil : (widgetsBlock.size, widgetsPlacement),
                                            files: floorShown ? (desktopFloor.contentRect.size, filesPlacement) : nil,
                                            around: windowsBounds)
        if let o = placed.widgets?.origin {
            let moves = widgets.map { p -> (proxy: WindowProxy, to: CGPoint) in
                let r = desktopRect(of: p)
                return (p, CGPoint(x: o.x + r.minX - widgetsBlock.minX, y: o.y + r.minY - widgetsBlock.minY))
            }
            if animated, view.isStill {
                view.glide(moves, duration: CanvasController.desktopGlide)
            } else {
                for (p, to) in moves { p.place(at: to) }
            }
        }
        if let files = placed.files { desktopFloor.move(to: files, duration: duration) }
        minimap.redraw()
    }

    /// What the desktop's spots are relative to: every window, or the screen at 1:1, where the canvas
    /// starts, while there are none.
    private var windowsBounds: CGRect {
        let windows = view.proxies.filter { $0.kind == .window }.map(\.worldRect).reduce(CGRect.null) { $0.union($1) }
        return windows.isNull ? display.frame : windows
    }

    /// What the map in Settings › Canvas › Desktop draws: the windows' bounds (or the screen's, with no
    /// windows), every window, and the widgets' and files' blocks where they are, in world points.
    var desktopMap: DesktopMapSnapshot {
        let widgets = view.proxies.filter { $0.kind == .widget }.map(\.worldRect).reduce(CGRect.null) { $0.union($1) }
        let floorShown = desktopFloor.isEnabled && desktopFloor.windowID != nil
        return DesktopMapSnapshot(bounds: windowsBounds,
                                  windows: view.proxies.filter { $0.kind == .window }.map(\.worldRect),
                                  widgets: widgets.isNull ? nil : widgets,
                                  files: floorShown ? desktopFloor.worldRect : nil)
    }

    /// How long the files and widgets take to glide to a new place around the windows.
    static let desktopGlide: CFTimeInterval = 0.35

    // MARK: Desktop files

    var isDesktopFloorShown: Bool { Settings.showDesktopFloor }

    /// Sunlight › Desktop Files: Finder's desktop under the windows, or not.
    func toggleDesktopFloor() {
        let shown = !Settings.showDesktopFloor
        Settings.showDesktopFloor = shown
        Log.note("Desktop: the floor is \(shown ? "on" : "off")")
        for c in deskCanvases {
            c.desktopFloor.isEnabled = shown
            if shown { c.scheduleDiff() }
        }
    }

    /// A press on a file on the floor, or on its empty ground, selects as on the desktop.
    private func floorClick(_ icon: DesktopIcon?, modifiers: NSEvent.ModifierFlags, released: Bool) {
        let selection = desktopFloor.selection
        guard let icon else {
            if !selection.isEmpty, !released { desktopFloor.select([]) }
            return
        }
        guard let keys = DesktopFiles.click(on: icon.key, in: selection.map(\.key), command: modifiers.contains(.command),
                                            shift: modifiers.contains(.shift), released: released) else { return }
        let byKey = Dictionary((selection + [icon]).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        desktopFloor.select(keys.compactMap { byKey[$0] })
    }

    private func floorCommand(_ command: DesktopFiles.Command) {
        let files = desktopFloor.selection
        switch command {
        case .open: openFiles(files)
        case .trash: trash(files.compactMap(\.url))
        case .copy: copy(files.compactMap(\.url))
        case .rename: if files.count == 1, let url = files[0].url { rename(url) }
        case .selectAll: desktopFloor.select(desktopFloor.icons)
        case .deselect: desktopFloor.select([])
        }
    }

    /// Finder's desktop menus, done by Sunlight: a file's (the selection's, once it's selected), or the
    /// items the empty ground adds to the canvas's own menu.
    private func floorMenu(for icon: DesktopIcon?) -> NSMenu? {
        let actions = MenuActions()
        floorMenuActions = actions
        let menu = NSMenu()
        guard let icon else {
            menu.addItem(actions.item("New Folder") { [weak self] in self?.newFolder() })
            return menu
        }
        if !desktopFloor.selection.contains(where: { $0.key == icon.key }) { desktopFloor.select([icon]) }
        let files = desktopFloor.selection.isEmpty ? [icon] : desktopFloor.selection
        let urls = files.compactMap(\.url)
        guard !urls.isEmpty else { return nil }
        menu.addItem(actions.item("Open") { [weak self] in self?.openFiles(files) })
        if urls.count == 1, let openWith = openWithMenu(for: urls[0], actions: actions) {
            let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            item.submenu = openWith
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actions.item("Move to Trash") { [weak self] in self?.trash(urls) })
        menu.addItem(.separator())
        if urls.count == 1 { menu.addItem(actions.item("Rename…") { [weak self] in self?.rename(urls[0]) }) }
        menu.addItem(actions.item(urls.count == 1 ? "Copy “\(icon.name)”" : "Copy \(urls.count) Items") { [weak self] in
            self?.copy(urls)
        })
        menu.addItem(actions.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
        return menu
    }

    /// The apps that open a file, its default first, as in Finder's Open With.
    private func openWithMenu(for url: URL, actions: MenuActions) -> NSMenu? {
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != preferred }
        if let preferred { apps.insert(preferred, at: 0) }
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        for (i, app) in apps.enumerated() {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let item = actions.item(i == 0 ? "\(name) (default)" : name) { [weak self] in self?.openFiles([url], with: app) }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if i == 0, apps.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    private func openFiles(_ files: [DesktopIcon]) {
        openFiles(files.compactMap(\.url))
    }

    /// Opened as launches from the canvas are: without activating, so the windows come up behind the
    /// canvas and pop onto it where the user is looking (`expectArrival`).
    private func openFiles(_ urls: [URL], with app: URL? = nil) {
        guard !urls.isEmpty else { return }
        endShowDesktop(flyBack: false)
        Log.note("Desktop: opening \(urls.map(\.lastPathComponent).joined(separator: ", "))\(app.map { " with \($0.lastPathComponent)" } ?? "")")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let arrived: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] running, error in
            if let error { Log.note("Desktop: couldn't open — \(error.localizedDescription)") }
            guard let running else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.expectArrival(of: running) }
            }
        }
        if let app {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration, completionHandler: arrived)
        } else {
            for url in urls { NSWorkspace.shared.open(url, configuration: configuration, completionHandler: arrived) }
        }
    }

    /// To the Trash, with ⌘Z putting them back.
    private func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error { Log.note("Desktop: couldn't move to the Trash — \(error.localizedDescription)") }
                    let moves = trashed.map { (from: $0.key, to: $0.value) }   // original → in the Trash
                    if !moves.isEmpty {
                        Log.note("Desktop: moved \(moves.count) item\(moves.count == 1 ? "" : "s") to the Trash")
                        self.registerFileUndo(moves, name: "Move to Trash")
                    }
                    self.desktopFloor.select([])
                }
            }
        }
    }

    private func copy(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Finder's rename, as a sheet: the name without its extension comes selected.
    private func rename(_ url: URL) {
        let old = url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename “\(old)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = old
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn,
                      let name = DesktopFiles.validRename(field.stringValue, from: old) else { return }
                let target = url.deletingLastPathComponent().appendingPathComponent(name)
                do {
                    try FileManager.default.moveItem(at: url, to: target)
                    Log.note("Desktop: renamed \(old) to \(name)")
                    self.registerFileUndo([(from: url, to: target)], name: "Rename")
                    self.desktopFloor.select(urls: [target])
                } catch {
                    Log.note("Desktop: couldn't rename \(old) — \(error.localizedDescription)")
                    NSAlert(error: error).beginSheetModal(for: self.window, completionHandler: nil)
                }
            }
        }
        DispatchQueue.main.async {
            let stem = (old as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? old : stem).utf16.count)
        }
    }

    /// A new folder on the desktop, named as Finder names one, then straight into its rename.
    private func newFolder() {
        let folder = DesktopFiles.folder
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let url = folder.appendingPathComponent(DesktopFiles.untitledFolderName(existing: existing))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            Log.note("Desktop: new folder \(url.lastPathComponent)")
            desktopFloor.select(urls: [url])
            rename(url)
        } catch {
            Log.note("Desktop: couldn't make a folder — \(error.localizedDescription)")
            NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// ⌘Z moves the files back where they were; ⌘⇧Z does it again.
    private func registerFileUndo(_ moves: [(from: URL, to: URL)], name: String) {
        guard let undo = window.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                var undone: [(from: URL, to: URL)] = []
                for move in moves {
                    do {
                        try FileManager.default.moveItem(at: move.to, to: move.from)
                        undone.append((from: move.to, to: move.from))
                    } catch {
                        Log.note("Desktop: couldn't undo \(name) of \(move.from.lastPathComponent) — \(error.localizedDescription)")
                    }
                }
                controller.registerFileUndo(undone, name: name)
                controller.desktopFloor.select(urls: undone.map(\.to))
            }
        }
        undo.setActionName(name)
    }

    // MARK: Dragging files into windows

    /// Files dragged off the floor held over a window: it's entered where it is, and once it's in front
    /// the canvas lets the pointer through, so the drop lands in the real window. macOS doesn't reorder
    /// windows during a drag, so the window can't come above the canvas until the drop; stepping aside
    /// is what gets the drop to it (measured on 27.2).
    private func springInto(_ p: WindowProxy, around point: CGPoint) {
        Log.note("Desktop: the dragged files open \(p.appName) — \(p.title)")
        springDrag = true
        handoff(to: p, placement: .inPlace(around: point))
    }

    private func fileDragEnded() {
        guard springDrag else { return }
        springDrag = false
        window.ignoresMouseEvents = false
        // The activation held back by the drag lands now: give it its half second from here.
        if let p = activeProxy, expectedActivationPID == p.pid { expectActivation(of: p.pid) }
    }

    // MARK: Minimap

    var isMinimapShown: Bool { Settings.showMinimap }

    func toggleMinimap() {
        let shown = !Settings.showMinimap
        Settings.showMinimap = shown
        for c in deskCanvases { c.updateMinimap() }
    }

    /// What the minimap card was last asked to be: shown or not.
    private var minimapUp = false

    /// The minimap is canvas chrome: it pops in when the canvas is what you're looking at and out when
    /// you go into a window (from the moment the flight in starts), another app comes in front, Show
    /// Desktop clears the screen, or Sunlight is off. Called whenever any of those changes.
    func updateMinimap(animated: Bool = true) {
        let up = MinimapPanel.belongs(setting: Settings.showMinimap, inCanvas: NSApp.isActive && activeProxy == nil && !handingOff,
                                      showingDesktop: desktopShown != nil, paused: paused)
        guard up != minimapUp else { return }
        minimapUp = up
        if up { minimap.redraw() }
        minimap.setShown(up, animated: animated && window.isVisible)
    }

    /// Bottom-right, inside the Dock when it's showing.
    /// Bottom right, or out of the ⌘Tab strip's way while it shows.
    private func placeMinimap(animated: Bool = false) {
        let v = visibleTopLeft
        let s = MinimapPanel.size
        var frame = CGRect(x: v.maxX - MinimapPanel.margin - s.width, y: v.maxY - MinimapPanel.margin - s.height,
                           width: s.width, height: s.height)
        if let strip = switcherHUD.activeLayout { frame = strip.clearing(frame) }
        guard frame != minimap.frame else { return }
        if animated && !minimap.isHidden {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                minimap.animator().frame = frame
            }
        } else {
            minimap.frame = frame
        }
    }

    private func cameraChanged() {
        lastCameraMotion = CACurrentMediaTime()
        settledSinceMotion = false
        updateRealWindows()
        minimap.redraw()
    }

    // MARK: Sunlight off

    /// The menu bar's Sunlight switch, off: the canvas goes away, every window is left where it is at
    /// 1:1 (the lock-screen path hands them back and stops the streams and the listing), and the
    /// switch's other half, the keys and gestures, is the app delegate's. Nothing restarts and the Dock
    /// add-on stays loaded, so on again (`show`) is a moment. The dormancy monitor is kept out of it
    /// meanwhile: asleep is asleep either way, and waking must not bring the canvas back.
    private(set) var paused = false

    /// `showing`: back on, the canvas comes forward (the desk brings the other displays' with the lead's).
    func setPaused(_ paused: Bool, showing: Bool = true) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused {
            Log.note("Sunlight: off")
            view.cancelAnimation()
            closeSwitcher(clearHighlight: true)
            if isShowingDesktop { endShowDesktop(flyBack: false) }
            if activeProxy != nil { leaveEntered(reconcile: true) }
            dormancyChanged(true)
            updateMinimap(animated: false)
            window.orderOut(nil)
            // The next app forward takes the focus; the canvas is out, so unhiding (`applicationDidHide`
            // under takeover) shows nothing.
            if NSApp.isActive { NSApp.hide(nil) }
        } else {
            Log.note("Sunlight: on")
            NSApp.unhideWithoutActivation()
            dormancyChanged(dormancy.asleep)
            if showing { show() }
            updateMinimap()
        }
    }

    /// Quitting.
    func shutdown() {
        // Windows their apps closed that the canvas moved off the screen go back where they were, so the
        // app shows them there when it reopens them. One still on screen (kept ordered in) stays put:
        // back where it was, it would show, closed, over the desktop.
        for (id, entry) in closedByApp where !WindowList.isOnScreen(id) { bringHome(id, entry.home) }
        configuringRenderer = true
        rendererRevision += 1
        liveTimer?.invalidate(); liveTimer = nil
        liveRecoveryTimer?.invalidate(); liveRecoveryTimer = nil
        resetPipShapes()   // before the lease ends: a tile left on show keeps the window's own corners
        suspendRealWindows()
        lowerOnShow()
    }

    // MARK: Keeping the canvas in agreement with the real desktop

    /// Two sources, one job each. The window server's list (`WindowList`, about a millisecond) is
    /// the truth for which windows exist and where they are: every second, and whenever the system
    /// says something changed, it removes the proxies of windows gone and moves the rest. ScreenCaptureKit's
    /// enumeration (`syncShareableContent`, tens of milliseconds and a daemon round trip) is asked
    /// only when a new window needs a proxy, because an `SCWindow` is the one thing a stream is built
    /// from — and once in a while to freshen the handles.
    private var syncing = false
    /// A ScreenCaptureKit enumeration for the widgets' handles, in live mode (`streamWidgets`).
    private var fetchingWidgetHandles = false
    private var widgetHandlesFetchedAt: CFTimeInterval = -.infinity
    /// Without live capture, when a widget's still was last renewed in live mode, and whose turn is next.
    private var widgetStillAt: CFTimeInterval = -.infinity
    private var widgetStillCursor = 0
    private var listing = false
    /// Counts listings, so one still in flight when a newer one has landed (`listNow`) is dropped: an
    /// older list lacks the window just found, and reconciling to it would hand that window back.
    private var listingGeneration = 0
    /// While a new window is expected (`windowServerCreated`): a listing every frame until then.
    private var arrivalWatchUntil: CFTimeInterval = 0
    private var arrivalTimer: Timer?
    private var diffScheduled = false
    private var diffTimer: Timer?
    private var heartbeatTimer: Timer?
    /// What the last listing wanted on the canvas; a full sync creates only within it.
    private var lastWantedIDs: Set<CGWindowID> = []
    /// Windows the list shows but ScreenCaptureKit doesn't return, with how often it was asked: a
    /// few tries, then they're left alone until they go away (or the heartbeat asks again).
    private var unstreamable: [CGWindowID: Int] = [:]
    private var fullSyncRequested: Set<CGWindowID> = []
    private var fullSyncPending = false
    private var bundleIDs: [pid_t: String] = [:]
    private var comparedSources = false
    /// The first proxies are up: things that should wait for the canvas to be populated go now.
    var onFirstSync: (() -> Void)?

    /// Looks at the desktop soon. Immediate requests coalesce to one per run-loop turn.
    func scheduleDiff(after delay: TimeInterval = 0) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.runDiff() }
            }
            return
        }
        guard !diffScheduled else { return }
        diffScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.diffScheduled = false
                self.runDiff()
            }
        }
    }

    /// Never during a handoff: the window server can lag the AX move by a beat, and reconciling to
    /// the stale frame would yank the proxy away from the real window at the seam. Nor while adding
    /// widgets: edit mode takes every window off the screen, and a listing would drop all their proxies.
    /// Nor with a window entered: the real desktop is the truth for that one, and the canvas isn't up.
    private func runDiff() {
        guard !configuringRenderer, !listing, !asleep, isUp, activeProxy == nil, !handingOff, addingWidgets == nil, !deskEditing else { return }
        listing = true
        listingGeneration += 1
        let generation = listingGeneration
        WindowList.queue.async { [weak self] in
            let list = WindowList.onScreen()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.listing = false
                    guard generation == self.listingGeneration else { return }
                    self.reconcile(with: list)
                }
            }
        }
    }

    /// A listing now, waited for on the main thread (about a millisecond): for a window that just
    /// appeared, which shows at full size until its first frame scales it.
    private func listNow() {
        guard !configuringRenderer, !asleep, isUp, activeProxy == nil, !handingOff, addingWidgets == nil, !deskEditing else { return }
        listingGeneration += 1
        reconcile(with: Watchdog.during("the window list (WindowList.onScreen)") { WindowList.queue.sync { WindowList.onScreen() } })
    }

    /// The window server says a window appeared. On the live canvas it is listed at once, and then every frame
    /// for a little while: one still ordering in, or fading in from nothing, isn't on the listing (or
    /// isn't canvas material) the moment it's announced. The first listing that has it pops it in, and
    /// the add-on scales it in the same breath.
    /// A window closed, was minimized or hidden, or moved to another Space: the listing says which.
    func windowServerRemoved() {
        guard isUp, activeProxy == nil, !asleep else { return }
        scheduleDiff()
    }

    func windowServerCreated(_ id: CGWindowID) {
        if id != 0, proxies[id] != nil { return }
        if id != 0, announced[id] == nil {
            announced[id] = CACurrentMediaTime()
            if announced.count > 64 { announced = announced.filter { CACurrentMediaTime() - $0.value < 10 } }
            let state = renderer != .realWindows ? "capture mode" : !NSApp.isActive ? "the canvas isn't active"
                : activeProxy != nil ? "a window is entered" : asleep ? "asleep" : "the live canvas"
            Log.note("Window events: window \(id) announced on \(state)")
        }
        if id != 0, activeProxy != nil || pendingAbsorbPID != 0, !NSApp.isActive, takesInFront {
            hideArrival(id)
            return takeInFront(id)
        }
        // Born under the canvas (sunlight-27) while the canvas is away and not the canvas's to take: a
        // window of the app in front shows at once, lifted above the canvas where the app put it.
        if id != 0, !NSApp.isActive, renderer == .realWindows, additionNumber >= 27 { liftIfFront(id) }
        guard renderer == .realWindows, isUp, activeProxy == nil, !asleep else { return }
        listNow()
        arrivalWatchUntil = CACurrentMediaTime() + CanvasController.arrivalWatch
        if id != 0 { arrivalsExpected.insert(id) } else { arrivalsUnknown = true }
        guard arrivalTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard CACurrentMediaTime() < self.arrivalWatchUntil, self.isUp, self.activeProxy == nil else {
                    self.arrivalTimer?.invalidate()
                    self.arrivalTimer = nil
                    self.arrivalsExpected = []
                    self.arrivalsUnknown = false
                    return
                }
                self.arrivalTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        arrivalTimer = t
    }

    /// Windows the window server announced that aren't on the canvas yet; `arrivalsUnknown` when one
    /// was announced without an id. A frame's tick asks the window server about each by id (a fraction
    /// of a millisecond) and lists everything only once one of them is on screen: 48 lookups a window
    /// instead of 48 listings. A window on screen but not yet canvas material (fading in from nothing)
    /// is listed each frame until it is, as before.
    private var arrivalsExpected: Set<CGWindowID> = []
    private var arrivalsUnknown = false

    private func arrivalTick() {
        arrivalsExpected = arrivalsExpected.filter { proxies[$0] == nil }
        if arrivalsExpected.isEmpty, !arrivalsUnknown { return }
        guard arrivalsUnknown || arrivalsExpected.contains(where: { WindowList.onScreen($0) != nil }) else { return }
        listNow()
    }

    /// How long after the window server announces a window the canvas keeps looking for it every frame.
    static let arrivalWatch: CFTimeInterval = 0.4
    /// TEMP diagnostics: when the window server announced each window not yet on the canvas.
    private var announced: [CGWindowID: CFTimeInterval] = [:]

    private func reconcile(with list: [WindowInfo]) {
        guard !configuringRenderer, isUp, activeProxy == nil, !handingOff, addingWidgets == nil, !deskEditing else { return }
        // The last entered window survives going native-fullscreen, which puts it on another Space
        // and off this list — as long as it still exists at all.
        var keep = lastActiveProxy?.windowID
        if let k = keep, !WindowList.exists(k) { keep = nil }
        // Finder's desktop is never a window on the canvas (it's below layer 0); it's the floor.
        // Finder draws one per display: this canvas's is the one on its display.
        desktopFloor.update(desktop: list.first { $0.layer == DesktopFloor.iconLevel && DesktopFloor.isDesktop($0, bundleID: bundleID(of: $0.pid))
                                                  && display.frame.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) },
                     visibleWorld: view.camera.toWorld(CGRect(origin: .zero, size: view.bounds.size)),
                     zoom: view.camera.zoom)
        recheckClosedByApp(listed: list)
        sweepFrontApp()
        let wanted = list.filter {
            if closedByApp[$0.id] != nil { return false }
            if renderer == .realWindows, let p = proxies[$0.id], p.pid == $0.pid { return true }
            // Each window is on one display's canvas (`Desk.owner`).
            return (isCanvasMaterial($0) || isWidget($0)) && (desk?.canvas(forWindow: $0.id, frame: $0.bounds) ?? self) === self
        }
        let wantedIDs = Set(wanted.map(\.id))
        lastWantedIDs = wantedIDs
        realWindowListReady = true
        checkAssertedOrder(against: list)

        // Hidden and minimized windows on screen again take their place, as they left it (popping in
        // on a canvas that is up; the launch sync's are simply there).
        for (id, p) in away where wantedIDs.contains(id) { comeBack(p, arriving: didInitialFit) }
        // A window seen minimizing that never left (its app refused after all) is forgotten as such,
        // and takes hover again.
        let now = CACurrentMediaTime()
        for (id, since) in minimizing where now - since >= CanvasController.minimizingLapse {
            minimizing[id] = nil
            proxies[id]?.leaving = false
        }
        var gone = 0
        for (id, p) in proxies where !wantedIDs.contains(id) {
            // Closed as far as its app is concerned, whatever the window server still lists: not away,
            // and not the last entered window kept for full screen either.
            if closedByApp[id] == nil, p.kind == .window, let why = knownAway(p) {
                putAway(p, why)
                continue
            }
            if id == keep, closedByApp[id] == nil {
                if askedKept != id {
                    askedKept = id
                    askMinimized(p)
                }
                continue
            }
            // Still there but off screen: minimized, or on another Space. Accessibility says which.
            if p.kind == .window, closedByApp[id] == nil, WindowList.exists(id) {
                putAway(p, nil)
                continue
            }
            proxies[id] = nil
            detach(p)
            view.remove(p)
            view.release(p)   // closed: out of its group, which may fall into pieces
            if lastActiveProxy === p { lastActiveProxy = nil }
            desk?.forget(id)
            gone += 1
        }
        reviewAway()
        mru.removeAll { !wantedIDs.contains($0) && $0 != keep && away[$0] == nil && !(desk?.isElsewhere($0, than: self) ?? false) }
        unstreamable = unstreamable.filter { wantedIDs.contains($0.key) }

        // Frames and titles come from here and nowhere else, so two sources never disagree by a
        // fraction of a point and re-anchor a proxy. What a frame may change is the owner's call
        // (`WindowSync.verdict`): only a window the user could have moved takes a position from here.
        let snapshot = FrameSnapshot(list: list, camera: globalCamera)
        var moved: [String] = []
        for w in wanted {
            guard let p = proxies[w.id] else { continue }
            p.retitle(w.title ?? "")
            switch WindowSync.verdict(owner: p.owner, isWidget: p.kind == .widget, capturing: renderer == .capture,
                                      transformed: renderer == .realWindows && realWindowsPresented,
                                      listed: w.bounds, last: p.lastRealFrame, sizeHeld: p.sizeHeld) {
            case .keep:
                continue
            case .size:
                p.placedNatively(at: w.bounds)
            case .move:
                let before = p.worldRect.origin
                // A widget's own spot is where it is on the desktop at 1:1 (`arrangeDesktop` takes it from there).
                p.movedByUser(to: w.bounds, seenThrough: p.kind == .widget ? Camera() : snapshot.camera)
                moved.append("\(p.appName) (\(Int(before.x)), \(Int(before.y))) → (\(Int(p.worldRect.minX)), \(Int(p.worldRect.minY)))")
                movedForReal(p, from: before)
                noteAttachmentOffset(p)
            }
        }

        // Read once: whoever was in front has been looked at, and the canvas owns every place again.
        if NSApp.isActive, activeProxy == nil {
            for p in proxies.values where p.owner == .user { p.owner = .canvas }
        }

        let new = wantedIDs.subtracting(proxies.keys).subtracting(unstreamable.keys)
        if gone > 0 || !moved.isEmpty || !new.isEmpty {
            Log.note("Sync: \(list.count) on screen, \(wanted.count) wanted, +\(new.count) −\(gone), \(moved.count) moved\(moved.isEmpty ? "" : " (\(moved.joined(separator: "; ")))")\(new.isEmpty || renderer == .realWindows ? "" : " → asking ScreenCaptureKit")")
        }
        if renderer == .realWindows {
            var created: [WindowProxy] = []
            let arriving = didInitialFit   // the launch sync's windows are simply there; later ones pop in
            for w in wanted.reversed() where proxies[w.id] == nil {
                let widget = isWidget(w)
                let p = register(WindowProxy(info: w, kind: widget ? .widget : .window,
                                             camera: widget ? Camera() : globalCamera, scale: scale))
                p.usesRealWindow = p.kind == .window
                proxies[w.id] = p
                view.add(p, arriving: arriving)
                if p.kind == .widget { resolveWidget(p) }
                created.append(p)
            }
            // A sheet or prompt that opened over one of its app's windows hangs from it; the rest get
            // places of their own.
            attachNewWindows(created, in: snapshot)
            let free = created.filter { $0.attachedTo == nil }
            if arriving { for p in created where p.attachedTo != nil { view.setArrival(of: p, context: WindowEffect.Context(attached: true)) } }
            let placed = placeRemembered(free)
            if created.contains(where: { $0.kind == .widget }) { arrangeDesktop(animated: false) }
            noteStripArrivals(free, arriving: arriving)
            if arriving, !NSApp.isActive || activeProxy != nil { noteArrived(free) }
            placeNewWindows(free, arriving: arriving)
            if !didInitialFit, !proxies.isEmpty {
                didInitialFit = true
                if placed, let camera = remembered?.camera(for: display.uuid, lead: isLead, viewSize: view.bounds.size) {
                    view.animateCamera(to: camera)
                } else { view.fitAll(animated: true) }
                onFirstSync?()
            } else if pendingFitAll, !proxies.isEmpty {
                pendingFitAll = false
                view.fitAll(animated: true)
            }
            // The new window is on screen at full size until a frame takes it: this one, not the pass's
            // or the entrance's next tick.
            for p in created where p.kind == .window {
                if let t = announced.removeValue(forKey: p.windowID) {
                    Log.note("Sync: window \(p.windowID) (\(p.appName)) taken \(Int((CACurrentMediaTime() - t) * 1000)) ms after its announcement")
                } else {
                    Log.note("Sync: window \(p.windowID) (\(p.appName)) taken without an announcement")
                }
            }
            if arriving, created.contains(where: { $0.kind == .window }) { updateRealWindows() }
        } else if !new.isEmpty {
            requestFullSync(for: new)
        } else if pendingFitAll, !proxies.isEmpty {
            pendingFitAll = false
            view.fitAll(animated: true)
        }
        layoutStripWhenIdle()
        runPendingPlacement()
        arrangeDesktop(animated: true)
        scheduleCapturePass()
        if gone > 0 || !moved.isEmpty { remember() }
    }

    /// The placement asked for from inside a real window, now that the canvas is up with its windows.
    private func runPendingPlacement() {
        guard NSApp.isActive, !proxies.isEmpty, let run = pendingPlacement else { return }
        pendingPlacement = nil
        run()
    }

    /// The listing is front to back; the last full frame put the leased windows in the canvas's order,
    /// bottom to top. An app that raised a window of its own meanwhile shows as a difference, and the
    /// next frame asserts the order again. (The add-on used to do this on a clock, every second.)
    private func checkAssertedOrder(against list: [WindowInfo]) {
        guard renderer == .realWindows, realWindowsPresented, additionNumber >= 8, !lastFullIDs.isEmpty else { return }
        let leased = Set(lastFullIDs)
        let listed = list.lazy.map(\.id).filter { leased.contains($0) }
        guard !listed.elementsEqual(lastFullIDs.reversed()) else {
            orderMismatches = 0
            return
        }
        orderMismatches += 1
        if orderMismatches == 5 {
            Log.note("Rendering: the window server's order keeps differing from the one asserted; reasserting it with every listing")
        }
        fullFrameNeeded = true
        updateRealWindows()
    }

    /// A listing and, if it finds new windows, the enumeration, awaited: for a caller that needs the
    /// canvas current before going on (a layout restore).
    func syncNow() async {
        guard NSApp.isActive, activeProxy == nil, !handingOff, addingWidgets == nil else { return }
        let list = await withCheckedContinuation { (c: CheckedContinuation<[WindowInfo], Never>) in
            WindowList.queue.async { c.resume(returning: WindowList.onScreen()) }
        }
        reconcile(with: list)
        if !fullSyncRequested.isEmpty || syncing { await syncShareableContent() }
    }

    private func requestFullSync(for ids: Set<CGWindowID>, after delay: TimeInterval = 0) {
        guard renderer == .capture, !configuringRenderer else { return }
        fullSyncRequested.formUnion(ids)
        if syncing {   // queued, not dropped: it runs again as soon as this one is done
            fullSyncPending = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in await self?.syncShareableContent() }
        }
    }

    /// The heavyweight enumeration, for the proxies the listing asked for. It never removes or moves
    /// anything (the window list does that), only creates, and freshens the handles of the rest.
    func syncShareableContent() async {
        guard renderer == .capture, !configuringRenderer else { return }
        let revision = rendererRevision
        guard !syncing, !handingOff, addingWidgets == nil else {
            fullSyncPending = true
            return
        }
        syncing = true
        defer { syncing = false }
        let requested = fullSyncRequested
        fullSyncRequested = []

        let content: SCShareableContent
        do {
            // On-screen only: the entered window on another Space already has its proxy, which the
            // listing keeps, and nothing here needs it.
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            Log.note("Sync: shareable content failed — Screen Recording permission? (\(error))")
            fullSyncRequested.formUnion(requested)
            return
        }
        guard revision == rendererRevision, renderer == .capture, !handingOff, addingWidgets == nil else {
            fullSyncRequested.formUnion(requested)
            fullSyncPending = true
            return
        }

        // SCShareableContent lists windows front to back; walk it backwards so new proxies stack correctly.
        // Widgets are at the very back, so they start out under every window, as on the desktop.
        var found = Set<CGWindowID>()
        var created = 0
        var createdProxies: [WindowProxy] = []
        let arriving = didInitialFit   // the launch sync's windows are simply there; later ones pop in
        for w in content.windows.reversed() {
            guard let app = w.owningApplication, app.processID != myPID else { continue }
            if let p = proxies[w.windowID] {
                p.window = w   // a fresh handle; its frame and title are the listing's business
                found.insert(w.windowID)
                continue
            }
            // Only what the listing wants right now: a window that closed meanwhile is skipped.
            guard requested.contains(w.windowID), lastWantedIDs.contains(w.windowID),
                  isCanvasMaterial(w) || Widgets.isWidget(w) else { continue }
            let p = makeProxy(for: w, camera: globalCamera)
            proxies[w.windowID] = p
            view.add(p, arriving: arriving)
            // A window that just appeared may not repaint for a long while, and its stream delivers
            // nothing until it does: a one-shot gives the arrival something to show right away.
            if arriving { p.refresh() }
            found.insert(w.windowID)
            created += 1
            createdProxies.append(p)
        }
        let missing = requested.subtracting(found)
        for id in missing { unstreamable[id, default: 0] += 1 }
        let retry = missing.filter { unstreamable[$0, default: 0] < 3 }
        if created > 0 || !missing.isEmpty {
            Log.note("Sync: ScreenCaptureKit lists \(content.windows.count), created \(created), missing \(missing.count)\(retry.isEmpty ? "" : ", asking again")")
        }
        // ScreenCaptureKit lags window creation by a beat: ask again shortly, a few times, then let it be.
        if !retry.isEmpty { requestFullSync(for: retry, after: 0.5) }
        compareSourcesOnce(content)
        // Sheets and prompts hang from their windows here too (the launch sync, and capture mode);
        // an attached window has no place of its own to remember or find. Child and parent are both
        // read from the window server, as everywhere else: ScreenCaptureKit's frames at launch put the
        // prompt at its window's corner for a moment.
        if createdProxies.contains(where: { $0.kind == .window }) { attachNewWindows(createdProxies, in: snapshot()) }
        let free = createdProxies.filter { $0.attachedTo == nil }
        if arriving { for p in createdProxies where p.attachedTo != nil { view.setArrival(of: p, context: WindowEffect.Context(attached: true)) } }
        let placed = placeRemembered(free)
        if createdProxies.contains(where: { $0.kind == .widget }) { arrangeDesktop(animated: false) }
        noteStripArrivals(free, arriving: arriving)
        if arriving, !NSApp.isActive || activeProxy != nil { noteArrived(free) }
        placeNewWindows(free, arriving: arriving)
        if created > 0 { layoutStripWhenIdle() }
        if !didInitialFit, !proxies.isEmpty {
            didInitialFit = true
            if placed, let camera = remembered?.camera(for: display.uuid, lead: isLead, viewSize: view.bounds.size) {
                // The canvas as it was last run, seen as it was.
                view.animateCamera(to: camera)
            } else {
                // First sync: the canvas is the desktop at 1:1. Pull back a little so it reads as a canvas.
                view.fitAll(animated: true)
            }
            onFirstSync?()
        } else if pendingFitAll, !proxies.isEmpty {
            pendingFitAll = false
            view.fitAll(animated: true)
        }
        runPendingPlacement()
        // Streams are the capture pass's call: what's in view, at what detail, and whose windows are
        // in front. After the fit, so the first pass already sees where the camera is going.
        scheduleCapturePass()
        remember()
        if fullSyncPending {
            fullSyncPending = false
            // On the next turn, once `syncing` is cleared (the defer): asked for now, the request would
            // only be parked again, and the windows it was for would wait for the next listing.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.fullSyncRequested.isEmpty else { return }
                    self.requestFullSync(for: [])
                }
            }
        }
    }

    /// Once, the two sources against each other: what the listing wants that ScreenCaptureKit doesn't
    /// have, and the reverse. Both should be empty on a normal desktop; anything else is a filter
    /// to look at.
    private func compareSourcesOnce(_ content: SCShareableContent) {
        guard !comparedSources, !lastWantedIDs.isEmpty else { return }
        comparedSources = true
        let sck = Set(content.windows.filter { w in
            guard let app = w.owningApplication, app.processID != myPID else { return false }
            return (isCanvasMaterial(w) || Widgets.isWidget(w)) && w.isOnScreen
        }.map(\.windowID))
        let listOnly = lastWantedIDs.subtracting(sck), sckOnly = sck.subtracting(lastWantedIDs)
        if !listOnly.isEmpty || !sckOnly.isEmpty {
            Log.note("Sync: sources differ — window list only: \(listOnly.sorted()), ScreenCaptureKit only: \(sckOnly.sorted())")
        }
    }

    /// Looks again shortly, a few times: something just changed on the real desktop that the 1 s
    /// listing would be slow to notice, and the window server may take a beat to reflect it.
    private func resync(after delays: [TimeInterval]) {
        for delay in delays { scheduleDiff(after: delay) }
    }

    private func isCanvasMaterial(_ w: SCWindow) -> Bool {
        w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80
            && !SystemUI.owns(w.owningApplication?.bundleIdentifier)
    }

    /// The same test on the window server's listing. An invisible window (alpha 0) isn't on the
    /// desktop as far as the eye is concerned; another Canvas's full-screen window would cover the
    /// canvas with itself. The Mac's own interface isn't a window to put on the canvas (`SystemUI`).
    private func isCanvasMaterial(_ w: WindowInfo) -> Bool {
        guard w.layer == 0, w.alpha > 0, w.bounds.width >= 120, w.bounds.height >= 80, w.pid != myPID else { return false }
        let b = bundleID(of: w.pid)
        return b != Bundle.main.bundleIdentifier && !SystemUI.owns(b)
    }

    private func isWidget(_ w: WindowInfo) -> Bool {
        Widgets.isWidget(w, bundleID: bundleID(of: w.pid))
    }

    /// Cached per process: the listing's owner name is localised, the bundle ID isn't.
    private func bundleID(of pid: pid_t) -> String? {
        if let b = bundleIDs[pid] { return b.isEmpty ? nil : b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundleIDs[pid] = b
        return b.isEmpty ? nil : b
    }

    /// A new proxy where the real window (or widget) is, seen through the camera. A widget is looked up
    /// in Notification Center's Accessibility tree once, for its name, its card and its controls —
    /// off the main thread; until then it's "Widget" with the usual margin.
    private func makeProxy(for w: SCWindow, camera: Camera) -> WindowProxy {
        guard Widgets.isWidget(w) else { return register(WindowProxy(window: w, camera: camera, scale: scale)) }
        // Where it is on the desktop at 1:1, whatever the camera: `arrangeDesktop` takes it from there.
        let p = register(WindowProxy(window: w, kind: .widget, widget: nil, camera: Camera(), scale: scale))
        resolveWidget(p)
        return p
    }

    /// Every proxy reports a stream that ended on its own, so the pass can look at it again.
    // MARK: Attached windows

    /// The window a just-opened one hangs from, if any: a window of the same app already on the canvas
    /// that it opened over, most of it inside that window and smaller than it, as a sheet, an alert, a
    /// prompt or an update dialog is. A new document window isn't: it opens the size of the last one,
    /// a little offset, and gets a place of its own. The window server tells no parent, and Accessibility
    /// often hasn't seen a new window yet, so the frames decide. The entered window wins a tie.
    /// A window that has just closed is still on the canvas until the next listing drops it, so each
    /// candidate is checked against the window server; two covering the child equally (a project window
    /// and the chooser it replaced) go to the one in front on the canvas, the newer one.
    private func attachmentParent(for native: CGRect, pid: pid_t, excluding id: CGWindowID,
                                  in snapshot: FrameSnapshot? = nil) -> (proxy: WindowProxy, frame: CGRect)? {
        var best: (proxy: WindowProxy, frame: CGRect, score: CGFloat)?
        for (index, q) in view.proxies.enumerated() where q.pid == pid && q.windowID != id && q.standsAlone && q.away == nil && !q.leaving {
            let parent = unscaledFrame(of: q, listed: snapshot?[q.windowID] ?? q.lastRealFrame)
            let shared = parent.intersection(native)
            guard !shared.isNull else { continue }
            let covered = shared.width * shared.height / max(native.width * native.height, 1)
            guard covered >= 0.5, native.width * native.height < parent.width * parent.height * 0.9 else { continue }
            // Still on screen: by the snapshot in hand, else by asking.
            guard snapshot?.has(q.windowID) ?? WindowList.isOnScreen(q.windowID) else { continue }
            let score = covered + (q === activeProxy ? 1 : 0) + CGFloat(index) / CGFloat(max(view.proxies.count, 1)) * 0.01
            if best == nil || score > best!.score { best = (q, parent, score) }
        }
        guard let best else { return nil }
        return (best.proxy, best.frame)
    }

    /// A window's frame as its app has it, for hanging a child from it. A window drawn scaled is listed by
    /// the window server through its transform, at the size it's drawn, but its app places a sheet, a menu
    /// or a popup from its own unscaled frame. The listed frame is then smaller than the window is in
    /// world units, which are points at 1:1, and the frame the app means comes from one of two places
    /// (`WindowSync.appFrameSource`). On a canvas that is simply zoomed out it's the frame the canvas
    /// keeps (`lastRealFrame`, which a listing through the transforms never changes). Asking Accessibility
    /// there, as this did for every window at first, was two round trips on the main thread per window of
    /// the app at every listing that found a new one, and an app that has just launched answers only at
    /// the timeout: a second window of OrbStack's opening as the canvas came back held the canvas for
    /// half a second. Accessibility is asked only for an app in use where it's drawn
    /// (`Settings.useScaledWindows`), which has the front and answers at once (public issue #11: Chrome's
    /// omnibar list, read against the scaled frame, hung from nothing and stood alone, up and to the left
    /// of the omnibar), and for a window whose kept frame isn't its unscaled one either.
    private func unscaledFrame(of q: WindowProxy, listed: CGRect) -> CGRect {
        let usedWhereDrawn = usedScaledPIDs.contains(q.pid) || passingThrough?.pid == q.pid
        switch WindowSync.appFrameSource(listed: listed, kept: q.lastRealFrame, worldSize: q.worldRect.size,
                                         usedWhereDrawn: usedWhereDrawn) {
        case .listed: return listed
        case .kept: return q.lastRealFrame
        case .accessibility:
            guard let real = q.ax?.frame, real.width > listed.width else { return listed }
            return real
        }
    }

    /// Hangs `child` from `parent` where the app put it: at its offset from the parent's native frame
    /// (`parentNative`, unscaled: as `attachmentParent` measured it), which is where the parent is on the
    /// canvas plus that offset. From now it rides with the parent.
    private func attach(_ child: WindowProxy, to parent: WindowProxy, native: CGRect, parentNative: CGRect) {
        child.attachedTo = parent.windowID
        child.attachmentOffset = CGPoint(x: native.minX - parentNative.minX, y: native.minY - parentNative.minY)
        child.place(at: CGPoint(x: parent.worldRect.minX + child.attachmentOffset.x, y: parent.worldRect.minY + child.attachmentOffset.y))
        parent.attachedChildren.append(child)
        if view.isClosing(parent) { view.cancelExit(parent) }   // "save changes?": the app kept it
        view.bringToFront(parent)   // the child above it
        Log.note("Attached: \(child.appName) — \(child.title) hangs from \(parent.title) at offset (\(Int(child.attachmentOffset.x)), \(Int(child.attachmentOffset.y)))")
    }

    /// Among windows that just showed up, the ones that hang from a window of their app (`attachmentParent`),
    /// child and parent both read from the one snapshot.
    private func attachNewWindows(_ created: [WindowProxy], in snapshot: FrameSnapshot) {
        for p in created where p.kind == .window {
            guard let native = snapshot[p.windowID],
                  let parent = attachmentParent(for: native, pid: p.pid, excluding: p.windowID, in: snapshot) else { continue }
            attach(p, to: parent.proxy, native: native, parentNative: parent.frame)
        }
    }

    /// Tries to hang a window that just opened in front (`takeInFront`, `ensureProxy`) from its parent.
    /// True when it did: the window then needs no place of its own.
    @discardableResult
    private func attachIfChild(_ p: WindowProxy, native: CGRect) -> Bool {
        guard p.kind == .window, p.attachedTo == nil,
              let parent = attachmentParent(for: native, pid: p.pid, excluding: p.windowID) else { return false }
        attach(p, to: parent.proxy, native: native, parentNative: parent.frame)
        return true
    }

    /// An attached window that moved for real (the app put its sheet elsewhere): its offset follows.
    private func noteAttachmentOffset(_ p: WindowProxy) {
        guard let parent = parentOf(p) else { return }
        p.attachmentOffset = CGPoint(x: p.worldRect.minX - parent.worldRect.minX, y: p.worldRect.minY - parent.worldRect.minY)
    }

    /// The window `p` hangs from, while both are on the canvas.
    private func parentOf(_ p: WindowProxy) -> WindowProxy? {
        p.attachedTo.flatMap { proxies[$0] }
    }

    /// A window leaving the canvas: out of its parent's care. Its own children look for another window
    /// of the app to hang from (a prompt that outlives the window it opened over: the project window
    /// under it), and stand alone where they are if there is none.
    private func detach(_ p: WindowProxy) {
        if let parent = parentOf(p) { parent.attachedChildren.removeAll { $0 === p } }
        p.attachedTo = nil
        let children = p.attachedChildren
        p.attachedChildren = []
        for c in children {
            c.attachedTo = nil
            // Drawn scaled with the window it hung from, it's measured unscaled, as its new parent is.
            let native = unscaledFrame(of: c, listed: c.lastRealFrame)
            if let parent = attachmentParent(for: native, pid: c.pid, excluding: c.windowID) {
                attach(c, to: parent.proxy, native: native, parentNative: parent.frame)
            } else {
                Log.note("Attached: \(c.appName) — \(c.title) stands alone now that \(p.title) is gone")
            }
        }
    }

    private func register(_ p: WindowProxy) -> WindowProxy {
        p.onCaptureEnded = { [weak self] in self?.scheduleCapturePass(after: 0.05) }
        p.onGeometryChanged = { [weak self] in self?.scheduleCapturePass() }
        p.usesRealWindow = renderer == .realWindows && p.kind == .window
        // Every window arrives ⊕: with nothing flipped, polarity is magnetism as it was (`Polarity`).
        p.polarity = p.kind == .window ? .plus : nil
        return p
    }

    // MARK: Magnetic polarity

    /// The window's pole flips: its ⊕/⊖ button, Flip Polarity in its menu, or P over it. ⌘Z flips it
    /// back.
    func flipPolarity(of p: WindowProxy) {
        guard let pole = p.polarity else { return }
        setPolarity(pole.flipped, of: p)
    }

    /// A bonded window flipped leaves its group first: with its pole turned it would push its neighbours,
    /// not hold them. Undo turns it back and puts the groups back as they were (`restoring`).
    private func setPolarity(_ pole: Polarity, of p: WindowProxy, restoring: Grouping? = nil) {
        guard let was = p.polarity, was != pole else { return }
        let groupingBefore = view.grouping
        p.polarity = pole
        if let restoring { view.restoreGrouping(restoring) } else { view.release(p) }
        Log.note("Polarity: \(p.appName) — \(p.title) is now \(pole.glyph)")
        minimap.redraw()
        rememberSoon()
        if let undo = window.undoManager {
            undo.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated {
                    guard controller.proxies[p.windowID] === p || controller.away[p.windowID] === p else { return }
                    controller.setPolarity(was, of: p, restoring: groupingBefore)
                }
            }
            undo.setActionName("Flip Polarity")
        }
    }

    /// Right-click › Ungroup: the window's whole group goes free. ⌘Z bonds them again.
    func ungroup(_ p: WindowProxy) {
        let before = view.grouping
        view.dissolve(groupOf: p)
        registerGroupingUndo(before, name: "Ungroup")
        rememberSoon()
    }

    private func registerGroupingUndo(_ before: Grouping, name: String) {
        guard let undo = window.undoManager, before != view.grouping else { return }
        let after = view.grouping
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.view.restoreGrouping(before)
                controller.registerGroupingUndo(after, name: name)
                controller.rememberSoon()
            }
        }
        undo.setActionName(name)
    }

    /// A saved pole goes back on the window it was saved for (`Layout.Entry.polarity`).
    private func applyPolarity(of entry: Layout.Entry, to p: WindowProxy) {
        guard p.kind == .window, let saved = entry.polarity, let pole = Polarity(rawValue: saved) else { return }
        p.polarity = pole
    }

    /// A saved tile goes back on the window it was saved for (`Layout.Entry.pip`), kept on this screen;
    /// a layout without one ends the window's Picture in Picture.
    private func applyPip(of entry: Layout.Entry, to p: WindowProxy) {
        guard p.kind == .window else { return }
        guard let saved = entry.pip else {
            if p.pip != nil { endPip(p) }
            return
        }
        let size = entry.frame.size, visible = visibleTopLeft
        var frame = PictureInPicture.clamped(PipFrame(origin: CGPoint(x: saved.x, y: saved.y), scale: saved.scale), size: size, visible: visible)
        let tucked = saved.tucked.flatMap(PictureInPicture.Side.init(rawValue:))
        if let tucked { frame = PictureInPicture.tucked(frame, behind: tucked, size: size, visible: visible) }
        guard frame != p.pip || tucked != p.pipTucked else { return }
        view.cancelPipFlight(p)
        p.pipShown = nil
        p.pipTucked = tucked
        p.lastPipCorner = PictureInPicture.corner(of: frame, size: size, visible: visible)
        if p.pip == nil { pipOrder.append(p.windowID) }
        p.pip = frame
        p.tile = nil
        view.release(p)
        view.pipChanged(p)
    }

    /// The real window moved while it was the one in front (the user dragged it, or its app moved it),
    /// and its proxy has followed. A bonded window that has gone more than a tile gap from where its
    /// group had it leaves the group, rather than dragging the others along behind the canvas.
    private func movedForReal(_ p: WindowProxy, from before: CGPoint) {
        guard !view.groupMembers(of: p).isEmpty else { return }
        let distance = hypot(p.worldRect.minX - before.x, p.worldRect.minY - before.y)
        guard distance > Settings.tileGap else { return }
        Log.note("Polarity: \(p.appName) — \(p.title) moved \(Int(distance)) pt for real; it leaves its group")
        view.release(p)
        rememberSoon()
    }

    /// Settings › Windows › Magnetic polarity was switched: every window's pill and label follow.
    private func polaritySettingChanged() {
        for p in proxies.values { p.refreshPolarity() }
        for p in away.values { p.refreshPolarity() }
        minimap.redraw()
    }

    // MARK: Accessibility, off the main thread

    private var resolvingAX: Set<CGWindowID> = []

    /// Looks the window up in its app's Accessibility tree ahead of time (hovering it is the usual
    /// prelude to a click), so a handoff finds the handle ready and its own three calls are all that's
    /// left on the click path.
    private func prefetchAX(_ p: WindowProxy) {
        // The window's handle, and where its own buttons are for the canvas's to sit over them; each
        // asked for once.
        guard p.kind == .window, p.ax == nil || p.trafficLights == nil, !resolvingAX.contains(p.windowID),
              AXIsProcessTrusted() else { return }
        resolvingAX.insert(p.windowID)
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let lights = ax?.trafficLights
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolvingAX.remove(id)
                    guard let p = self.proxies[id] else { return }
                    if p.ax == nil { p.ax = ax }
                    // A window without them keeps the standard place, and isn't asked again.
                    if p.trafficLights == nil, ax != nil { p.trafficLights = lights ?? .standard }
                }
            }
        }
    }

    /// Notification Center's handle on a widget: a walk of its Accessibility tree, in the background.
    private func resolveWidget(_ p: WindowProxy) {
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame
        AXQueue.background.async { [weak self] in
            let widget = AXWidget.find(windowID: id, pid: pid, approximateFrame: approx)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let p = self.proxies[id], p.kind == .widget else { return }
                    if let widget { p.adopt(widget: widget) }
                    Log.note("Widget: \(p.appName) — \(p.title) at \(p.lastRealFrame.integral)\(widget.map { " (\($0.identifier))" } ?? ", no Accessibility")")
                }
            }
        }
    }

    /// The window the user is on the way into gets a fresh frame every tick, so the seam is current;
    /// each is a seam frame.
    /// The one the user is in gets one twice a second: when the canvas comes back, its stream starts
    /// and delivers a current frame within a frame or two anyway, so photographing the window the user
    /// is working in four times a second was mostly wasted work. Its siblings in front, and the windows
    /// on the canvas shown as stills (`WindowProxy.capped`), take turns once a second, and only the ones
    /// in view. A window behind the canvas whose stream is off is simply out of sight.
    private func refreshTick() {
        refreshTicks &+= 1
        let primary = handoffTarget ?? activeProxy
        // On the way in, every frame of the target is a seam frame (`OneShotCapture.capture`): the last
        // one before the real window comes forward is what shows at 1:1, and SkyLight's came back framed
        // differently from the window, so the window looked re-laid-out until the swap.
        if let p = primary, p.inFront, !p.isStreaming, handoffTarget != nil || refreshTicks % 2 == 0 {
            p.refresh(seam: handoffTarget === p)
        }
        guard refreshTicks % 4 == 0 else { return }
        let others = view.proxies.filter { ($0.inFront || $0.capped) && !$0.isStreaming && $0 !== primary && $0.isInView }
        guard !others.isEmpty else { ensureRefreshTimer(); return }
        refreshCursor = (refreshCursor + 1) % others.count
        others[refreshCursor].refresh()
    }

    /// The app's windows are about to be (or already are) in front of the canvas: no streams on them.
    private func stopStreams(of pid: pid_t) {
        for q in proxies.values where q.pid == pid { q.stopCapture() }
    }

    /// Creates the proxy for a window that appeared since the last sync (ScreenCaptureKit lags window
    /// creation by a beat, hence the retries). Nil if the window isn't canvas material. No stream: this
    /// is the absorb path, and the window is in front.
    private func ensureProxy(windowID: CGWindowID, pid: pid_t, camera viewCamera: Camera) async -> WindowProxy? {
        let camera = global(viewCamera)
        if let p = away[windowID] { return comeBack(p) }
        if renderer == .realWindows {
            if let p = proxies[windowID] { return p }
            guard let w = WindowList.onScreen().first(where: { $0.id == windowID && $0.pid == pid }),
                  isCanvasMaterial(w) else { return nil }
            let p = register(WindowProxy(info: w, camera: camera, scale: scale))
            proxies[windowID] = p
            view.add(p)
            if !attachIfChild(p, native: w.bounds) { noteArrived([p]) }
            return p
        }
        for attempt in 0..<3 {
            if let p = proxies[windowID] { return p }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
                return nil
            }
            if let w = content.windows.first(where: { $0.windowID == windowID }) {
                guard isCanvasMaterial(w) else { return nil }
                let p = register(WindowProxy(window: w, camera: camera, scale: scale))
                proxies[windowID] = p
                view.add(p)
                noteArrived([p])
                return p
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        return nil
    }

    // MARK: Closing

    /// The ✕ in a hovered proxy's floating controls: press the real window's close button while it sits
    /// behind the canvas. The app decides what happens next (close, or a "save changes?" sheet).
    /// A widget's ✕ takes it off the desktop.
    func close(_ p: WindowProxy) {
        if p.kind == .widget {
            removeWidget(p)
            return
        }
        Log.note("Close: \(p.appName) — \(p.title)")
        guard !view.isClosing(p) else { return }
        if NSApp.isActive, activeProxy == nil { quietAfterCloseUntil = Date().addingTimeInterval(CanvasController.closeQuiet) }
        // The closing effect first, then the press: once the app has closed the window there is nothing
        // left to animate. Should the app keep it ("save changes?", a refusal), it opens again.
        let id = p.windowID
        view.dropHover(of: p)
        if p.pip != nil { endPip(p) }   // the close plays at its home
        view.beginExit(p, context: WindowEffect.Context(attached: p.attachedTo != nil)) { [weak self] in
            self?.pressClose(p)
        }
        // Still here well after the press: the app kept it, with a sheet or none.
        // Unless the app no longer names it: closed, though the window server still has it (Music's last
        // window, Calendar's main one), and it goes as a closed window does (`closeForApp`).
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.closeKeptAfter) { [weak self] in
            guard let self, let q = self.proxies[id], q === p, self.view.isClosing(q) else { return }
            let pid = q.pid, handle = q.ax
            CanvasController.sweepQueue.async { [weak self] in
                // The handle the ✕ was pressed through, dead, and the app naming the window no more: both,
                // so an app answering with an empty list never takes a window still asking "save changes?".
                let dead = handle?.isDestroyed ?? true
                let named = dead ? AXWindow.names(windowID: id, pid: pid) : true
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let q = self.proxies[id], q === p, self.view.isClosing(q) else { return }
                        if named == false { return self.closeForApp(q) }
                        Log.note("Close: \(p.appName) — \(p.title) is still open; bringing it back")
                        self.view.cancelExit(q)
                    }
                }
            }
        }
    }

    /// How long after a close from the canvas a window still listed is taken to have been kept by its
    /// app: past the last resync after the press (`resync(after:)`), with the effect's own time on top.
    static let closeKeptAfter: TimeInterval = 2.5

    /// The press itself, off the main thread: it may not return until the app has put up its sheet.
    private func pressClose(_ p: WindowProxy) {
        let known = p.ax, id = p.windowID, pid = p.pid, approx = p.lastRealFrame, name = p.appName, title = p.title
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let closed = ax?.close() ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let ax, let p = self.proxies[id], p.ax == nil { p.ax = ax }
                    guard ax != nil, closed else {
                        Log.note(ax == nil ? "Close: no AX window for \(name) — Accessibility granted?"
                                        : "Close: \(name) — \(title) has no close button, or the app refused")
                        if let p = self.proxies[id] { self.view.cancelExit(p) }
                        return
                    }
                    if self.lastActiveProxy?.windowID == id { self.lastActiveProxy = nil }
                    // The proxy lingers until a listing sees the window gone; don't leave a dead one up for a second.
                    self.resync(after: [0.2, 0.7, 1.5])
                }
            }
        }
    }

    /// After a close from the canvas, until when an app coming forward is the close's doing (`foreignActivation`).
    private var quietAfterCloseUntil = Date.distantPast
    static let closeQuiet: TimeInterval = 1

    // MARK: Hidden and minimized windows

    /// The – on a window, or right-click › Minimize: into the Dock, as ⌘M would. Its place is kept.
    ///
    /// The window stays on the canvas, leased and scaled, until the listing finds it gone: the Dock
    /// animates the window itself, in place, and it leaves the screen only as the animation ends (about
    /// 270 ms; measured 2026-10-28). Put away at once, the next frame left it out, the add-on put it
    /// back at its own level under the backdrop, and the animation vanished behind the canvas. Meanwhile
    /// it takes no hover and no controls (`WindowProxy.leaving`).
    func minimize(_ p: WindowProxy) {
        guard p.kind == .window, proxies[p.windowID] === p, !p.leaving else { return }
        Log.note("Minimize: \(p.appName) — \(p.title)")
        let known = p.ax, id = p.windowID, pid = p.pid, approx = p.lastRealFrame, name = p.appName
        p.leaving = true
        view.dropHover(of: p)
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let done = ax?.minimize() ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard done else {
                        Log.note("Minimize: \(name) refused, or no AX window — Accessibility granted?")
                        self.proxies[id]?.leaving = false
                        return
                    }
                    self.minimizing[id] = CACurrentMediaTime()
                    // The window server says when it has left the screen; these are the fallback.
                    self.resync(after: [0.4, 1.0])
                }
            }
        }
    }

    /// Right-click › Hide: the window's app, as ⌘H would. Its windows keep their places.
    func hideApp(of p: WindowProxy) {
        Log.note("Hide: \(p.appName)")
        NSRunningApplication(processIdentifier: p.pid)?.hide()
        resync(after: [0.2, 0.7])
    }

    /// Why a window gone from the screen is away, when that's known without asking anyone: its app is
    /// hidden, or it was seen minimizing. Nil if it takes asking.
    private func knownAway(_ p: WindowProxy) -> WindowProxy.Away? {
        if NSRunningApplication(processIdentifier: p.pid)?.isHidden == true { return .hidden }
        if minimizing.removeValue(forKey: p.windowID) != nil { return .minimized }
        return nil
    }

    /// Off the canvas, its proxy kept where it is. `why` nil: Accessibility is asked whether it's minimized,
    /// and if it isn't (another Space), it goes for good.
    private func putAway(_ p: WindowProxy, _ why: WindowProxy.Away?) {
        let id = p.windowID
        if p.pip != nil { endPip(p) }   // away, a window goes home: it comes back to its place on the canvas
        proxies[id] = nil
        p.hovered = false
        p.leaving = false
        view.remove(p)
        p.away = why
        away[id] = p
        if let why { Log.note("Away: \(p.appName) — \(p.title) \(why)") } else { askMinimized(p) }
        showAway()
    }

    /// The window's proxy, one away taken back onto the canvas: the window is in front again (restored
    /// from the Dock, its app unhidden).
    private func proxyReturning(_ id: CGWindowID) -> WindowProxy? {
        if let p = proxies[id] { return p }
        return away[id].map { comeBack($0) }
    }

    /// A window away is on screen again: its proxy, where it was. Returns it. `arriving`: it pops in,
    /// as a new window does (a window restored onto the canvas); not for one about to be entered.
    @discardableResult
    private func comeBack(_ p: WindowProxy, arriving: Bool = false) -> WindowProxy {
        let id = p.windowID
        away[id] = nil
        minimizing[id] = nil
        let was = p.away
        p.away = nil
        p.leaving = false
        proxies[id] = p
        view.add(p, arriving: arriving)
        if let was { Log.note("Away: \(p.appName) — \(p.title) back from \(was)") }
        showAway()
        if revealOnReturn == id {
            revealOnReturn = nil
            reveal(p)
        }
        return p
    }

    /// The camera over to a window put back on the canvas whose place isn't in view: it was brought back
    /// for a click (the Dock), and nothing showed for it. The zoom stays; in view already, nothing moves.
    private func reveal(_ p: WindowProxy) {
        guard NSApp.isActive, activeProxy == nil, !handingOff else { return }
        let visible = view.camera.toWorld(visibleTopLeft)
        let shown = visible.intersection(p.worldRect)
        let mostlyIn = !shown.isNull && shown.width * shown.height >= p.worldRect.width * p.worldRect.height / 2
        guard !mostlyIn else { return }
        Log.note("Away: \(p.appName) — \(p.title) is back out of view — over to it")
        view.fly(to: camera(centring: CGPoint(x: p.worldRect.midX, y: p.worldRect.midY)))
    }

    /// Every window away, looked at again: closed meanwhile (or its app quit), or its app hidden or shown.
    private func reviewAway() {
        var changed = false
        for (id, p) in away {
            guard WindowList.exists(id) else {
                away[id] = nil
                view.release(p)   // closed while away: out of its group
                mru.removeAll { $0 == id }
                changed = true
                continue
            }
            let hidden = NSRunningApplication(processIdentifier: p.pid)?.isHidden == true
            if hidden, p.away != .hidden {
                p.away = .hidden
                changed = true
            } else if !hidden, p.away == .hidden {
                // Its app is back but this window isn't: minimized too, or on another Space.
                p.away = nil
                askMinimized(p)
                changed = true
            }
        }
        if changed { showAway() }
    }

    /// Asks the window's app, off the main thread, whether the window is in the Dock, and the window
    /// server whether it's on a full-screen app's Space (macOS's own full screen). Accessibility may not
    /// find a window on another Space at all, so the window server's word counts too.
    private func askMinimized(_ p: WindowProxy) {
        let id = p.windowID, pid = p.pid, known = p.ax, approx = p.lastRealFrame
        guard askingMinimized.insert(id).inserted else { return }
        AXQueue.background.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let minimized = ax?.isMinimized == true
            let fullScreen = !minimized && (ax?.isFullScreen == true || Spaces.isInFullScreenSpace(id))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.askingMinimized.remove(id)
                    self.answered(id, why: minimized ? .minimized : fullScreen ? .fullScreen : nil)
                }
            }
        }
    }

    /// `why`: minimized, in full screen, or neither (on another Space some other way: off the canvas).
    private func answered(_ id: CGWindowID, why: WindowProxy.Away?) {
        if let p = away[id], p.away == nil {
            if let why {
                p.away = why
                Log.note("Away: \(p.appName) — \(p.title) \(why == .fullScreen ? "in full screen, on a Space of its own" : "minimized")")
                showAway()
            } else {
                away[id] = nil   // on another Space: off the canvas, as before
                mru.removeAll { $0 == id }
            }
        } else if let why, let p = proxies[id], p !== activeProxy, !handingOff {
            putAway(p, why)   // the last entered window, kept: minimized, or gone into full screen
        }
    }

    /// What's away, for the minimap's dashed outlines and the switcher.
    private func showAway() {
        view.away = away.values.filter { $0.away != nil }.sorted { $0.windowID < $1.windowID }
        minimap.redraw()
    }

    /// A hidden or minimized window back where it was on the canvas, and entered: its app unhidden, or
    /// the window taken out of the Dock (a click on its dashed outline in the minimap, the switcher, the Mission Control key).
    func bringBack(_ p: WindowProxy) {
        guard away[p.windowID] === p, let why = p.away, NSApp.isActive, activeProxy == nil, !handingOff else { return }
        Log.note("Away: bringing back \(p.appName) — \(p.title) from \(why)")
        let id = p.windowID, pid = p.pid, known = p.ax, approx = p.lastRealFrame
        switch why {
        case .fullScreen:
            // Over to its Space, as the Dock would: the window raised in its app, the app in front. It
            // stays in full screen; leaving full screen is what brings it back to its place here.
            AXQueue.interactive.async {
                let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
                ax?.raise()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
                        if !app.activate(from: .current, options: []), !app.activate(options: []) { _ = forceAppFront(pid) }
                    }
                }
            }
            return
        case .hidden:
            NSRunningApplication(processIdentifier: pid)?.unhide()
        case .minimized:
            AXQueue.interactive.async {
                let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
                ax?.unminimize()
            }
        }
        enterWhenBack(p, tries: 15)
    }

    /// The window takes a moment to come back (the Dock's animation): entered once it's on screen, or
    /// after a second and a half regardless.
    private func enterWhenBack(_ p: WindowProxy, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive, self.activeProxy == nil, !self.handingOff else { return }
                let id = p.windowID
                let onScreen = WindowList.onScreen().contains { $0.id == id }
                if self.away[id] === p, onScreen || tries <= 1 { self.comeBack(p) }
                guard self.proxies[id] === p else {
                    if tries > 1, self.away[id] === p { self.enterWhenBack(p, tries: tries - 1) }
                    return
                }
                self.handoff(to: p, spatial: true)
            }
        }
    }

    // MARK: Widgets

    /// Live mode's capture pass, for the widgets alone: the real windows are shown as they are, but a
    /// widget never is (see `CanvasView.hostWidgets`), so it streams as in capture mode, at the zoom's
    /// level of detail. Its proxy came from the window list, so its ScreenCaptureKit handle is looked up
    /// first. Widgets are under every window, so they stream whoever is in front, until the Mac sleeps.
    private func streamWidgets() {
        guard renderer == .realWindows, !configuringRenderer else { return }
        let widgets = view.proxies.filter { $0.kind == .widget }
        guard !widgets.isEmpty else { return }
        if widgets.contains(where: { $0.window == nil }) { fetchWidgetHandles() }
        guard Settings.screenCapture else {
            // Stills: one widget renewed a second, in turn, among those in view; every five seconds
            // once the camera has rested a minute. This runs on every pass and live tick.
            for p in widgets { p.stopCapture() }
            let now = CACurrentMediaTime()
            let interval: CFTimeInterval = now - lastCameraMotion > 60 ? 5 : 1
            guard !asleep, addingWidgets == nil, NSApp.isActive, now - widgetStillAt >= interval else { return }
            let viewRect = CGRect(origin: .zero, size: view.bounds.size)
            let shown = widgets.filter { view.camera.toScreen($0.worldRect).intersects(viewRect) }
            guard !shown.isEmpty else { return }
            widgetStillAt = now
            widgetStillCursor = (widgetStillCursor + 1) % shown.count
            shown[widgetStillCursor].refresh()
            return
        }
        let applied = CanvasController.level(forZoom: max(view.camera.zoom, view.targetCamera?.zoom ?? 0), current: lod.applied)
        lod.applied = applied
        for p in widgets {
            guard !asleep, addingWidgets == nil else {
                p.stopCapture()
                continue
            }
            let k = min(applied, p.maxCaptureLevel)
            let level = WindowCapture.Level(factor: CanvasController.factor(forLevel: k), fps: CanvasController.fps(forLevel: k))
            if p.isStreaming {
                p.setCaptureLevel(level)
            } else {
                p.startCapture(level: level)   // no-op without a handle, or while backing off
            }
        }
    }

    /// The enumeration is heavyweight and the live timer asks twice a second: a widget it doesn't list
    /// is asked about again every few seconds, not every tick.
    private func fetchWidgetHandles() {
        let now = CACurrentMediaTime()
        guard !fetchingWidgetHandles, now - widgetHandlesFetchedAt >= 5 else { return }
        fetchingWidgetHandles = true
        widgetHandlesFetchedAt = now
        Task { @MainActor [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let self else { return }
            self.fetchingWidgetHandles = false
            guard let content else {
                Log.note("Widgets: no ScreenCaptureKit handles — Screen Recording permission?")
                return
            }
            var found = 0
            for w in content.windows where Widgets.isWidget(w) {
                guard let p = self.proxies[w.windowID], p.kind == .widget, p.window == nil else { continue }
                p.window = w
                p.refresh()   // a widget that doesn't change sends its stream nothing
                found += 1
            }
            if found > 0 { Log.note("Widgets: streaming \(found) on the live-windows backdrop") }
            self.streamWidgets()
        }
    }

    /// Notification Center's widget for a proxy, looked up again if it wasn't found when the proxy was
    /// made (Accessibility granted since).
    private func axWidget(for p: WindowProxy) -> AXWidget? {
        if p.widget == nil {
            p.widget = AXWidget.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame)
        }
        return p.widget
    }

    /// A click on a widget does what the same click on the desktop would. A button or toggle under the
    /// pointer is pressed through Accessibility, in place. Anywhere else (or ⏎, with no point) opens the
    /// widget's app, which is where a widget leads — unless it deep-links somewhere more specific, which
    /// Accessibility doesn't tell us. With takeover running, the app is absorbed like any other launch.
    func press(_ p: WindowProxy, at worldPoint: CGPoint?) {
        guard p.kind == .widget else { return }
        let widget = axWidget(for: p)
        if let worldPoint, let widget, widget.press(at: p.realPoint(forWorld: worldPoint)) {
            Log.note("Widget: pressed a control in \(p.appName) — \(p.title)")
            return
        }
        // A widget's container app may be a stub with nothing to show — Batteries is tagged hidden, like
        // a container app on iOS — or a background helper. Then there's nowhere to go.
        guard let id = widget?.appBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url),
              (bundle.object(forInfoDictionaryKey: "SBAppTags") as? [String])?.contains("hidden") != true,
              bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
              bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else {
            Log.note("Widget: \(p.appName) — \(p.title) has no app to open\(widget == nil ? " (Accessibility granted?)" : "")")
            return
        }
        Log.note("Widget: \(p.appName) — \(p.title) opens \(url.lastPathComponent)")
        open(appAt: url, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Takes the widget off the desktop through its context menu. The proxy goes when a sync sees the
    /// widget's window gone.
    private func removeWidget(_ p: WindowProxy) {
        guard let widget = axWidget(for: p) else {
            Log.note("Close: no Accessibility element for widget \(p.appName) — Accessibility granted?")
            return
        }
        Log.note("Close: widget \(p.appName) — \(p.title)")
        widget.remove { [weak self] removed in
            guard removed else {
                Log.note("Close: no “Remove Widget” in the menu of \(p.appName) — \(p.title)")
                return
            }
            self?.resync(after: [0.2, 0.7, 1.5])
        }
    }

    var isAddingWidgets: Bool { addingWidgets != nil }

    /// "Add Widgets…": opens Notification Center's widget gallery, from a widget's context menu or, with
    /// no widget yet, Finder's desktop menu (see `WidgetGallery`). The desktop's edit mode then takes every
    /// window off the screen, the canvas included, so the real desktop is there to drop a widget on. Done
    /// puts them all back, the canvas in front, and a sync brings the new widget in where it was dropped,
    /// seen through the camera: on the canvas it sits on screen where it was let go.
    func addWidgets() {
        guard addingWidgets == nil else { return }
        guard AXIsProcessTrusted() else {
            Log.note("Widgets: adding widgets needs Accessibility")
            NSSound.beep()
            return
        }
        closeSwitcher(clearHighlight: true)
        let widget = proxies.values.lazy.filter { $0.kind == .widget }.compactMap { self.axWidget(for: $0) }.first
        Log.note("Widgets: opening the gallery from \(widget.map { "the \($0.name) widget's menu" } ?? "Finder's desktop menu")")
        // Syncing stops from here: once edit mode clears the screen, a sync would drop every window's proxy.
        addingWidgets = AddingWidgets()
        suspendRealWindows()
        WidgetGallery.open(from: widget) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                Log.note("Widgets: couldn't open the gallery — no widget on the desktop to ask, and Finder isn't drawing the desktop")
                self.addingWidgets = nil
                NSSound.beep()
                return
            }
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.addingWidgetsTick() }
            }
            t.tolerance = 0.05
            self.addingWidgetsTimer = t
        }
    }

    /// Edit mode is seen through the canvas's own window going off the screen and coming back: Done puts
    /// every window back at once (then the gallery slides away). The gallery itself is watched for the
    /// case where the canvas had to be ordered out, and to know the menu worked.
    /// Notification Center is asked on the Accessibility queue: finding the gallery walks its windows, and
    /// it may be slow to answer while the gallery animates in.
    private func addingWidgetsTick() {
        guard let state = addingWidgets, !state.probing else { return }
        addingWidgets?.probing = true
        let known = state.gallery
        let started = state.started
        AXQueue.interactive.async { [weak self] in
            let gallery = known ?? WidgetGallery.window()
            let up = gallery.map(WidgetGallery.isShowing) ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.addingWidgets?.started == started else { return }
                    self.addingWidgets?.probing = false
                    self.addingWidgetsProbed(gallery: gallery, up: up)
                }
            }
        }
    }

    private func addingWidgetsProbed(gallery: AXUIElement?, up galleryUp: Bool) {
        guard var state = addingWidgets else { return }
        if state.gallery == nil { state.gallery = gallery }
        if galleryUp && state.galleryShown == nil {
            state.galleryShown = Date()
            Log.note("Widgets: gallery up")
        }
        let canvasUp = WidgetGallery.isOnScreen(CGWindowID(window.windowNumber))
        if !canvasUp && !state.orderedOut { state.canvasHidden = true }
        addingWidgets = state

        if state.canvasHidden && canvasUp {
            finishAddingWidgets("edit mode ended")
        } else if state.galleryShown != nil, !galleryUp, !state.canvasHidden {
            finishAddingWidgets("the gallery closed")
        } else if state.galleryShown == nil, !state.canvasHidden, -state.started.timeIntervalSinceNow > 3 {
            finishAddingWidgets("the gallery never came up")
        } else if let shown = state.galleryShown, galleryUp, canvasUp, !state.orderedOut, -shown.timeIntervalSinceNow > 1 {
            // Edit mode is meant to clear the screen. If the canvas is still covering the desktop, step aside.
            Log.note("Widgets: edit mode left the canvas up — ordering it out")
            addingWidgets?.orderedOut = true
            window.orderOut(nil)
        }
    }

    private func finishAddingWidgets(_ reason: String) {
        Log.note("Widgets: back from the gallery (\(reason))")
        addingWidgetsTimer?.invalidate()
        addingWidgetsTimer = nil
        addingWidgets = nil
        // Edit mode may have taken activation elsewhere (the gallery, Finder for a click on the desktop).
        show()
        // New widgets take a beat to show up in ScreenCaptureKit.
        resync(after: [0.1, 0.6, 1.5])
    }

    // MARK: Layouts

    var isRestoringLayout: Bool { restoring != nil }

    /// Writes the canvas down for the next launch: every window and widget on it, the camera, and last
    /// run's windows that haven't shown up again yet. Not before the first sync has put last run's back,
    /// which would write over them.
    func remember() {
        desk?.remember()
    }

    /// This canvas's part of the remembered canvas: its windows and widgets, bottom to top, with their
    /// groups; nil until the first sync has put last run's back, which it would write over.
    var rememberedPart: (proxies: [WindowProxy], groups: [CGWindowID: Int])? {
        guard didInitialFit, addingWidgets == nil else { return nil }
        let all = (view.proxies + view.away).filter { $0.attachedTo == nil }
        return (all, view.grouping.saved(for: all.map(\.windowID)))
    }

    /// After a drop: once the window has settled onto the grid.
    private func rememberSoon() {
        rememberWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.remember() }
        rememberWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Windows that were on the canvas last run go back where they were as they show up: at launch, and at
    /// login while apps reopen theirs. Only where they were; the real window's size is the truth. Only
    /// proxies made behind the canvas: one made for a window in front (absorbed) has to stay under it.
    private func placeRemembered(_ created: [WindowProxy]) -> Bool {
        rememberedClaimed = []
        guard !unclaimed.isEmpty, !created.isEmpty, restoring == nil else { return false }
        guard Date() < rememberedUntil else {
            unclaimed = []
            return false
        }
        let pairs = Layout.match(unclaimed, created)
        guard !pairs.isEmpty else { return false }
        for (i, p) in pairs {
            p.place(at: unclaimed[i].frame.origin)
            p.layout(zoom: view.camera.zoom)
            applyPolarity(of: unclaimed[i], to: p)
            applyPip(of: unclaimed[i], to: p)
            if let g = unclaimed[i].group { view.adopt(group: g, for: p, remap: &rememberedGroups) }
        }
        let claimed = Set(pairs.map(\.entry))
        rememberedClaimed = Set(pairs.map(\.proxy.windowID))
        unclaimed = unclaimed.indices.filter { !claimed.contains($0) }.map { unclaimed[$0] }
        Log.note("Layout: \(pairs.count) back where they were last run, \(unclaimed.count) still to come")
        return true
    }

    /// Windows that just opened with the canvas in front go to the middle of the view, or beside the
    /// windows in the way, as near the middle as there's room (`NewWindowSpot`). Before their first
    /// frame, so they pop in at the new spot. Not the launch sync's, a layout's or the last run's (they
    /// have their places), and not on the strip (it lays them out).
    /// Open Here…'s window goes to its spot instead, even one the last run had a place for.
    /// With windows pushing each other, the last run's place is kept only while it's free: taken since,
    /// the window goes to the free spot nearest it (one bonded to others stays with them).
    private func placeNewWindows(_ created: [WindowProxy], arriving: Bool) {
        guard arriving, restoring == nil, !Settings.stripMode else { return }
        var targets: [CGWindowID: CGPoint] = [:]
        for p in created { targets[p.windowID] = openHereSpot(for: p) }
        let arrivals = created.filter { $0.kind == .window && (!rememberedClaimed.contains($0.windowID) || targets[$0.windowID] != nil) }
        let returning = !Settings.magnetism ? [] : created.filter {
            $0.kind == .window && rememberedClaimed.contains($0.windowID) && targets[$0.windowID] == nil
                && !view.grouping.isGrouped($0.windowID)
        }
        guard !arrivals.isEmpty || !returning.isEmpty else { return }
        let fresh = Set((arrivals + returning).map(\.windowID))
        let settled = view.proxies.filter { $0.standsAlone && !fresh.contains($0.windowID) } + Array(away.values)
        var others = settled.map(\.worldRect)
        // The windows on show a new one can be placed beside: Dealt brings it out from behind the one it went to.
        var beside = view.proxies.filter { $0.standsAlone && !fresh.contains($0.windowID) }
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        for p in returning {
            let spot = NewWindowSpot.free(p.worldRect, avoiding: others, gap: gap)
            if spot.origin != p.worldRect.origin {
                Log.note("New window: \(p.appName) — \(p.title)'s place from last run is taken, \(p.worldRect.origin) → \(spot.origin)")
                p.place(at: spot.origin)
                p.layout(zoom: view.camera.zoom)
                rememberSoon()
            }
            others.append(spot)
        }
        let visible = view.camera.toWorld(visibleTopLeft)
        var shown = CGRect.null
        for p in arrivals {
            let spot = NewWindowSpot.spot(size: p.worldRect.size, avoiding: others, view: visible, gap: gap,
                                          target: targets[p.windowID])
            if spot.origin != p.worldRect.origin {
                Log.note("New window: \(p.appName) — \(p.title) placed, \(p.worldRect.origin) → \(spot.origin)")
                p.place(at: spot.origin)
                p.layout(zoom: view.camera.zoom)
                alignNatively(p)
            }
            // How it opens: out of the spot it was asked for (Open Here…), else out from behind the window
            // it was placed against, else on its own.
            var context = WindowEffect.Context(source: targets[p.windowID])
            var neighbour: WindowProxy?
            if context.source == nil, let i = NewWindowSpot.neighbour(of: spot, among: beside.map(\.worldRect), gap: gap) {
                neighbour = beside[i]
                context.neighbour = beside[i].worldRect
            }
            view.setArrival(of: p, context: context, neighbour: neighbour)
            beside.append(p)
            others.append(spot)
            shown = shown.union(spot)
        }
        // Somewhere off screen was the only room: the camera slides just far enough to show it. Not
        // from inside a window: the camera there is the one that lines it up with the real window.
        guard !shown.isNull, !visible.contains(shown), view.isStill, activeProxy == nil else { return }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if shown.width <= visible.width {
            dx = shown.minX < visible.minX ? shown.minX - visible.minX : max(0, shown.maxX - visible.maxX)
        }
        if shown.height <= visible.height {
            dy = shown.minY < visible.minY ? shown.minY - visible.minY : max(0, shown.maxY - visible.maxY)
        }
        if dx == 0, dy == 0 {
            view.fit(view.camera.toWorld(visibleTopLeft).union(shown), animated: true)
            return
        }
        var target = view.camera
        target.origin.x += dx
        target.origin.y += dy
        view.animateCamera(to: target)
    }

    /// Layouts › Save Layout…: the canvas as it is now, under a name. Each window's document is looked up
    /// too, so a restore can reopen it: off the main thread, so a busy app can't freeze the canvas, and
    /// the layout is written once every app has answered (`saved` then runs). False if cancelled.
    @discardableResult
    func saveLayout(saved: (() -> Void)? = nil) -> Bool {
        guard addingWidgets == nil, restoring == nil else { return false }
        closeSwitcher(clearHighlight: true)
        guard let choice = LayoutPrompt.name(existing: LayoutStore.layouts.map(\.name)) else { return false }
        save(layoutNamed: choice.name, withBackground: choice.withBackground, saved: saved)
        return true
    }

    private func save(layoutNamed name: String, withBackground: Bool, saved: (() -> Void)?) {
        // The canvas as it is the moment the name is given, not when the apps have answered.
        let proxies = view.proxies, camera = view.camera, viewSize = view.bounds.size
        let groups = view.grouping.saved(for: proxies.map(\.windowID))
        let spec = withBackground ? background.spec : nil
        Task { @MainActor in
            let documents = await self.lookUpDocuments(of: proxies)
            var layout = Layout(name: name, proxies: proxies, camera: camera, viewSize: viewSize, documents: documents, groups: groups)
            layout.background = spec
            LayoutStore.save(layout)
            Log.note("Layout: saved “\(name)” — \(layout.entries.count) windows and widgets, \(documents.count) with a document")
            saved?()
        }
    }

    /// The Accessibility handle of every window that has none yet, and the file each window shows, asked
    /// of the apps on the Accessibility queue rather than the main thread: each app may take up to the
    /// timeout to answer. The handles are kept on the proxies for the clicks and resizes that follow.
    private func lookUpDocuments(of candidates: [WindowProxy]) async -> [CGWindowID: String] {
        let windows = candidates.filter { $0.kind == .window }
        guard !windows.isEmpty, AXIsProcessTrusted() else { return [:] }
        let asks = windows.map { (id: $0.windowID, pid: $0.pid, approx: $0.lastRealFrame, known: $0.ax) }
        let answers = await withCheckedContinuation { (c: CheckedContinuation<[(CGWindowID, AXWindow?, String?)], Never>) in
            AXQueue.interactive.async {
                c.resume(returning: asks.map { a in
                    let ax = a.known ?? AXWindow.find(windowID: a.id, pid: a.pid, approximateFrame: a.approx)
                    return (a.id, ax, ax?.document?.absoluteString)
                })
            }
        }
        var documents: [CGWindowID: String] = [:]
        for (id, ax, document) in answers {
            if let ax, let p = self.proxies[id], p.ax == nil { p.ax = ax }
            if let document { documents[id] = document }
        }
        return documents
    }

    /// Layouts › a layout: every window and widget goes back where the layout has it, windows at its size,
    /// stacked as they were, and the camera with them. What's missing is opened behind the canvas and takes
    /// its place as it shows up. Windows on the canvas that aren't in the layout are left, moved aside or
    /// closed, as the user chooses (`Settings.otherWindows`).
    func restoreLayout(named name: String) {
        guard let layout = LayoutStore.layouts.first(where: { $0.name == name }) else {
            Log.note("Layout: no layout named “\(name)” to restore")
            return
        }
        // From the menu bar icon over another app: the canvas comes forward first.
        guard NSApp.isActive else {
            Log.note("Layout: “\(name)” waits for the canvas to come forward")
            pendingPlacement = { [weak self] in self?.restoreLayout(named: name) }
            show()
            return
        }
        guard restoring == nil, addingWidgets == nil, !handingOff, activeProxy == nil else {
            Log.note("Layout: can't restore “\(name)” now — restoring \(restoring != nil), adding widgets \(addingWidgets != nil), handing off \(handingOff), in a window \(activeProxy != nil)")
            return
        }
        closeSwitcher(clearHighlight: true)
        let started = Date()
        Task { @MainActor in
            // The canvas as the real desktop has it right now, before deciding what's missing.
            await self.syncNow()
            let synced = Date()
            let documents = await self.lookUpDocuments(of: self.view.proxies)
            Log.note("Layout: “\(name)” — synced in \(Int(synced.timeIntervalSince(started) * 1000)) ms, documents in \(Int(Date().timeIntervalSince(synced) * 1000)) ms")
            self.restore(layout, documents: documents)
        }
    }

    /// `policy` overrides the user's choice for the other windows.
    /// `documents` is what `lookUpDocuments` found, asked for beforehand so no app is asked anything here.
    private func restore(_ layout: Layout, documents: [CGWindowID: String] = [:], policy override: Settings.OtherWindows? = nil) {
        guard restoring == nil, addingWidgets == nil, !handingOff else {
            Log.note("Layout: “\(layout.name)” dropped — restoring \(restoring != nil), adding widgets \(addingWidgets != nil), handing off \(handingOff)")
            return
        }
        let pairs = Layout.match(layout.entries, view.proxies, document: { documents[$0.windowID] })
        let inLayout = Set(pairs.map(\.proxy.windowID))
        let others = view.proxies.filter { $0.kind == .window && !inLayout.contains($0.windowID) }
        var policy = override ?? Settings.otherWindows
        if policy == .ask, !others.isEmpty {
            guard let choice = LayoutPrompt.otherWindows(others.count, layout: layout.name) else {
                Log.note("Layout: “\(layout.name)” cancelled at the other-windows prompt")
                return
            }
            policy = choice
        }
        Log.note("Layout: restoring “\(layout.name)” — \(pairs.count) of \(layout.entries.count) on the canvas, \(others.count) other windows (\(policy))")

        // Stacked as saved, above whatever else stays.
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        var groups: [Int: Int] = [:]
        for (i, p) in pairs.sorted(by: { $0.entry < $1.entry }) {
            let entry = layout.entries[i]
            resize(p, to: entry.frame.size)
            view.bringToFront(p)
            applyPolarity(of: entry, to: p)
            applyPip(of: entry, to: p)
            // The layout's groups replace whatever it was bonded to.
            view.release(p)
            if let g = entry.group { view.adopt(group: g, for: p, remap: &groups) }
            moves.append((p, entry.frame.origin))
        }
        var parkX = (layout.bounds?.maxX ?? 0) + Settings.gridSize
        switch policy {
        case .moveAside: moves += park(others, x: &parkX, beside: layout)
        case .close: for p in others { close(p) }
        case .ask, .leave: break
        }
        view.animateCamera(to: layout.camera(viewSize: view.bounds.size), duration: CanvasController.restoreDuration,
                           moving: moves)
        // A layout that remembers its background brings it along, cross-faded with the move.
        if let spec = layout.background { background.set(spec, animated: true, undoable: false) }

        let claimed = Set(pairs.map(\.entry))
        let missing = layout.entries.indices.filter { !claimed.contains($0) }
        let apps = open(missing.map { layout.entries[$0] })
        let pending = missing.filter { layout.entries[$0].kind == .window && apps.contains(layout.entries[$0].bundleID ?? "") }
        guard !pending.isEmpty else {
            foldRestoredIntoStrip()
            rememberSoon()
            return
        }
        restoring = RestoringLayout(layout: layout, pending: pending, policy: policy, apps: apps,
                                    known: Set(view.proxies.map(\.windowID)), parkX: parkX, groups: groups,
                                    deadline: Date().addingTimeInterval(CanvasController.restoreWait))
        restoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoringTick() }
        }
    }

    /// A window takes the size it has in a layout. The real one is resized behind the canvas, where it can't
    /// be seen; the app may hold it to a size of its own.
    private func resize(_ p: WindowProxy, to size: CGSize) {
        guard p.kind == .window,
              abs(p.worldRect.width - size.width) > 0.5 || abs(p.worldRect.height - size.height) > 0.5 else { return }
        // The proxy takes the size asked for now, so the layout goes on from it; the app is asked on the
        // Accessibility queue (finding the window, sizing it and reading back what it allowed are three
        // round trips each, and a layout of a dozen windows made on the main thread held the canvas for
        // every one of them). The proxy takes the size the app allowed when the answer comes, and the
        // listing puts it right in any case once the hold on its size lifts (`WindowProxy.sizeHeld`).
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax
        let name = "\(p.appName) — \(p.title)"
        p.resized(toReal: CGRect(origin: approx.origin, size: size))
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            var real: CGRect?
            var fullScreen = false
            if let ax {
                fullScreen = ax.isFullScreen
                if !fullScreen {
                    ax.setSize(size)
                    real = ax.frame
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let p = self.proxies[id] ?? self.away[id]
                    if let p, p.ax == nil { p.ax = ax }
                    guard ax != nil, !fullScreen else {
                        Log.note("Layout: can't resize \(name)\(ax == nil ? " (Accessibility granted?)" : ": it's full screen")")
                        return
                    }
                    guard let p, let real else { return }
                    if abs(real.width - size.width) > 0.5 || abs(real.height - size.height) > 0.5 {
                        Log.note("Layout: \(name) is \(Int(real.width))×\(Int(real.height)), not \(Int(size.width))×\(Int(size.height)): the app's own limits")
                    }
                    // The app's answer stands, unless the proxy has been given another size meanwhile.
                    if abs(p.worldRect.width - size.width) <= 0.5, abs(p.worldRect.height - size.height) <= 0.5 { p.resized(toReal: real) }
                }
            }
        }
    }

    // MARK: Tiling

    /// What a tiling shortcut acts on, on the canvas: the window under the pointer, or else the one used
    /// last.
    private var tileTarget: WindowProxy? {
        if let p = view.hoveredWindow { return p }
        if let p = mru.lazy.compactMap({ self.proxies[$0] }).first(where: { $0.kind == .window }) { return p }
        return view.proxies.last { $0.kind == .window }
    }

    /// The area a window is tiled in on the canvas. At 1:1 it's the screen you're looking at, if the
    /// window is on it; otherwise the area it was tiled in before, or the page it's on.
    private func tileArea(for p: WindowProxy) -> CGRect {
        let centre = CGPoint(x: p.worldRect.midX, y: p.worldRect.midY)
        if abs(view.camera.zoom - 1) < 0.01 {
            let onScreen = view.camera.toWorld(visibleTopLeft)
            if onScreen.contains(centre) { return onScreen }
        }
        if let area = p.tile?.area, area.contains(centre) { return area }
        return Tiling.page(containing: centre, screen: homeVisible)
    }

    /// The area a tiled window is still in, screen-sized, for entering it lined up with the area.
    private func tiledArea(of p: WindowProxy) -> CGRect? {
        guard let area = p.tile?.area, area.insetBy(dx: -2, dy: -2).contains(p.worldRect),
              abs(area.width - visibleTopLeft.width) < 1, abs(area.height - visibleTopLeft.height) < 1 else { return nil }
        return area
    }

    /// Pressing a slot again on a window already there steps to the next width (`Preset.next`).
    private func cycled(_ preset: Tiling.Preset, for p: WindowProxy?) -> Tiling.Preset {
        guard let last = p?.tile?.preset, last.cycleRoot == preset else { return preset }
        return last.next
    }

    /// A tiling shortcut or the Window menu. On the canvas it tiles the window under the pointer (or the
    /// last one used) in its area. In a real window it tiles that window on the screen, with macOS's
    /// own tiling where macOS has the slot.
    func tile(_ preset: Tiling.Preset) {
        // Strip mode: the arrows step along the strip; the other slots have no meaning on it.
        if Settings.stripMode {
            switch preset {
            case .leftHalf: stepStrip(.left)
            case .rightHalf: stepStrip(.right)
            case .topHalf: stepStrip(.up)
            case .bottomHalf: stepStrip(.down)
            default: Log.note("Tile: \(preset.title) is off in strip mode")
            }
            return
        }
        if NSApp.isActive {
            guard let p = tileTarget else { return }
            tile(p, preset)
        } else {
            tileFrontWindow(preset)
        }
    }

    /// A window takes a slot in its area on the canvas. The real window is resized behind the canvas
    /// and the proxy glides there; an app that won't take the exact size keeps to the slot's outer edges.
    /// ⌘Z puts it back as it was.
    func tile(_ p: WindowProxy, _ requested: Tiling.Preset) {
        guard p.kind == .window, restoring == nil, addingWidgets == nil, !handingOff, !Settings.stripMode else { return }
        let preset = cycled(requested, for: p)
        let area = tileArea(for: p)
        let rect = Tiling.rect(preset, size: p.worldRect.size, in: area, gap: Settings.tileGap)
        Log.note("Tile: \(p.appName) — \(p.title) → \(preset.title)")
        let before = placementState(of: [p])
        view.bringToFront(p)
        view.release(p)   // placed on its own: it leaves its group
        let move = placement(p, in: rect, anchor: Tiling.anchor(for: preset.unit))
        p.tile = Tiling.Tile(area: area, preset: preset)
        registerPlacementUndo(from: before, to: placementState(of: [p], landing: [move]), name: "Move & Resize")
        view.glide([move])
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    /// Where each window filled by its green button was before, so a second click puts it back.
    private var unzoomed: [CGWindowID: CGRect] = [:]

    /// A window's green button, clicked: it fills its area, as macOS's zoom; clicked again while it
    /// still fills it, it goes back to where it was. ⌘Z undoes either.
    func zoom(_ p: WindowProxy) {
        guard p.kind == .window, restoring == nil, addingWidgets == nil, !handingOff, !Settings.stripMode else { return }
        if p.tile?.preset == .full, let back = unzoomed.removeValue(forKey: p.windowID) {
            Log.note("Tile: \(p.appName) — \(p.title) → back from Full")
            let before = placementState(of: [p])
            view.bringToFront(p)
            let move = placement(p, in: back, anchor: .zero)
            p.tile = nil
            registerPlacementUndo(from: before, to: placementState(of: [p], landing: [move]), name: "Move & Resize")
            view.glide([move])
            minimap.redraw()
            scheduleCapturePass()
            rememberSoon()
            return
        }
        let from = p.worldRect, wasFull = p.tile?.preset == .full
        tile(p, .full)
        if !wasFull, p.tile?.preset == .full { unzoomed[p.windowID] = from }
    }

    /// A choice in a window's green-button popover.
    func tileChoice(_ p: WindowProxy, _ choice: TilePopover.Choice) {
        switch choice {
        case .tile(let preset): tile(p, preset)
        case .share(let share): self.share(p, share)
        case .fullScreen:
            // Filling its area, then entered there: the window at 1:1 over the whole screen.
            tile(p, .full)
            DispatchQueue.main.asyncAfter(deadline: .now() + CanvasView.snapDuration + 0.05) { [weak self, weak p] in
                guard let self, let p, self.view.proxies.contains(where: { $0 === p }) else { return }
                self.handoff(to: p)
            }
        }
    }

    /// Fill & Arrange: the window shares its area with the windows used just before it, each taking a
    /// cell of `share` (the window itself the first), wherever on the canvas they were. With too few
    /// windows the cells left over stay empty. ⌘Z puts them all back.
    func share(_ p: WindowProxy, _ share: Tiling.Share) {
        guard p.kind == .window, restoring == nil, addingWidgets == nil, !handingOff, !Settings.stripMode else { return }
        let area = tileArea(for: p)
        let onCanvas = view.proxies.filter { $0.kind == .window && $0 !== p }
        // Most recently used first; any never used yet, frontmost first.
        var partners = mru.compactMap { id in onCanvas.first { $0.windowID == id } }
        partners += onCanvas.reversed().filter { q in !partners.contains { $0 === q } }
        let placed = [p] + partners.prefix(share.cells.count - 1)
        Log.note("Tile: \(p.appName) — \(p.title) → \(share.title) with \(placed.count - 1) other(s)")
        let before = placementState(of: placed)
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        for (cell, q) in zip(share.cells, placed) {
            view.bringToFront(q)
            view.release(q)   // placed on its own: it leaves its group
            moves.append(placement(q, in: Tiling.rect(cell, in: area, gap: Settings.tileGap), anchor: Tiling.anchor(for: cell)))
            q.tile = Tiling.Tile(area: area, preset: q === p ? share.preset : nil)
            unzoomed[q.windowID] = nil
        }
        view.bringToFront(p)
        registerPlacementUndo(from: before, to: placementState(of: placed, landing: moves), name: "Move & Resize")
        view.glide(moves)
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    /// The screen a placement command works in: that of `around` when given (a right-click menu's
    /// window), else the window under the pointer's, else the screen you're looking at at 1:1, else the
    /// page in the middle of the view.
    private func placementScreen(around: WindowProxy? = nil) -> CGRect {
        if let p = around ?? view.hoveredWindow { return tileArea(for: p) }
        if abs(view.camera.zoom - 1) < 0.01 { return view.camera.toWorld(visibleTopLeft) }
        return Tiling.page(containing: view.camera.center(viewSize: view.bounds.size), screen: homeVisible)
    }

    /// Arrange (Window › Arrange, ⌃⌥ 2 3 4): the windows on one screen laid out in `columns` × `rows`, in
    /// reading order of where they sit now; see `placementScreen` for which screen. Windows beyond the
    /// cells stay where they are. ⌘Z puts them back. From inside a real window the canvas comes forward
    /// first.
    func arrange(columns: Int, rows: Int, around: WindowProxy? = nil) {
        guard Settings.arranging, restoring == nil, addingWidgets == nil, !handingOff, !Settings.stripMode else { return }
        guard NSApp.isActive else {
            pendingPlacement = { [weak self] in self?.arrange(columns: columns, rows: rows) }
            show()
            return
        }
        let area = placementScreen(around: around)
        func centre(_ p: WindowProxy) -> CGPoint { CGPoint(x: p.worldRect.midX, y: p.worldRect.midY) }
        let windows = view.proxies.filter { $0.standsAlone && area.contains(centre($0)) }
        guard !windows.isEmpty else { return }
        let order = Tiling.arrangeOrder(windows.map(\.worldRect), rows: rows)
        Log.note("Tile: arranging \(min(order.count, columns * rows)) windows in \(columns)×\(rows)")
        let placed = order.prefix(columns * rows).map { windows[$0] }
        let before = placementState(of: placed)
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        for (cell, i) in zip(Tiling.cells(columns: columns, rows: rows), order) {
            let p = windows[i]
            let rect = Tiling.rect(cell, in: area, gap: Settings.tileGap)
            moves.append(placement(p, in: rect, anchor: Tiling.anchor(for: cell)))
            p.tile = Tiling.Tile(area: area, preset: nil)
            view.release(p)   // laid out on its own: it leaves its group
        }
        registerPlacementUndo(from: before, to: placementState(of: placed, landing: moves), name: "Arrange")
        view.glide(moves)
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    // MARK: Tell Sunlight

    /// A window as Tell Sunlight's canvas tools describe it to the model (`CanvasTools`).
    struct AgentWindow {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let title: String
        /// Where it sits on the canvas: world points, top-left origin.
        let rect: CGRect
        /// "on canvas", "entered", "minimized" or "hidden".
        let state: String
        /// The slot it was last tiled to, if it still holds it (`Tiling.Preset.rawValue`).
        let slot: String?
    }

    /// Every app window of this canvas, those minimized or hidden included, bottom to top.
    var agentWindows: [AgentWindow] {
        let onCanvas = view.proxies.filter(\.standsAlone).map { p in
            AgentWindow(id: p.windowID, pid: p.pid, app: p.appName, title: p.title, rect: p.worldRect,
                        state: p === activeProxy ? "entered" : "on canvas", slot: p.tile?.preset?.rawValue)
        }
        let gone = away.values.filter(\.standsAlone).sorted { $0.windowID < $1.windowID }.map { p in
            AgentWindow(id: p.windowID, pid: p.pid, app: p.appName, title: p.title, rect: p.worldRect,
                        state: p.away == .minimized ? "minimized" : p.away == .fullScreen ? "full screen" : "hidden", slot: nil)
        }
        return onCanvas + gone
    }

    /// What the camera shows now, and the size of a screen: world points, top-left origin.
    var agentView: (visible: CGRect, screen: CGRect) {
        (view.camera.toWorld(view.bounds), homeVisible)
    }

    /// No glide or camera flight under way: windows are where they'll stay.
    var agentSettled: Bool { !view.isBusy }

    /// Holds the window: on the canvas, or away with its place kept.
    func agentHolds(_ id: CGWindowID) -> Bool { proxies[id] != nil || away[id] != nil }

    /// Where a window of this canvas is drawn this frame, for Tell Sunlight's pointer (`AgentPresence`):
    /// global points (top-left origin), the zoom it's drawn at, and its display's frame. Mid-glide and
    /// mid-flight included, since the proxy and the camera move every frame. Nil for a window that's away
    /// or not on this canvas.
    func agentDrawn(_ id: CGWindowID) -> (rect: CGRect, zoom: CGFloat, display: CGRect)? {
        guard let p = proxies[id] else { return nil }
        let drawn = toGlobal(view.camera.toScreen(p.apparentRect))
        // The window's own scale: the camera's, or a Picture in Picture tile's.
        return (drawn, drawn.width / max(1, p.worldRect.width), display.frame)
    }

    /// Why the canvas can't take a command now, if it can't: what the guards on its own commands check.
    var agentBusy: String? {
        if paused { return "Sunlight is switched off in the menu bar" }
        if Settings.stripMode { return "strip mode is on, which arranges the windows itself" }
        if restoring != nil { return "a layout is still being restored" }
        if addingWidgets != nil { return "widgets are being added" }
        if handingOff { return "a window is being entered" }
        return nil
    }

    /// The window glides to `origin`, its size kept. ⌘Z puts it back.
    func agentMove(_ id: CGWindowID, to origin: CGPoint) -> Bool {
        guard agentBusy == nil, let p = view.proxies.first(where: { $0.windowID == id }), p.standsAlone else { return false }
        Log.note("Tell Sunlight: move \(p.appName) — \(p.title)")
        let before = placementState(of: [p])
        view.bringToFront(p)
        view.release(p)
        p.tile = nil
        unzoomed[p.windowID] = nil
        let move = (proxy: p, to: origin)
        registerPlacementUndo(from: before, to: placementState(of: [p], landing: [move]), name: "Move")
        view.glide([move])
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
        return true
    }

    /// The window takes `size` (the app may hold it to a size of its own), its top-left kept. ⌘Z undoes it.
    func agentResize(_ id: CGWindowID, to size: CGSize) -> Bool {
        guard agentBusy == nil, let p = view.proxies.first(where: { $0.windowID == id }), p.standsAlone else { return false }
        Log.note("Tell Sunlight: resize \(p.appName) — \(p.title)")
        let before = placementState(of: [p])
        view.bringToFront(p)
        view.release(p)
        p.tile = nil
        unzoomed[p.windowID] = nil
        let move = placement(p, in: CGRect(origin: p.worldRect.origin, size: size), anchor: .zero)
        registerPlacementUndo(from: before, to: placementState(of: [p], landing: [move]), name: "Move & Resize")
        view.glide([move])
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
        return true
    }

    /// A tiling slot in the window's area, as the ⌃⌥ keys give it, without their cycling.
    func agentTile(_ id: CGWindowID, _ preset: Tiling.Preset) -> Bool {
        guard agentBusy == nil, let p = view.proxies.first(where: { $0.windowID == id }), p.standsAlone else { return false }
        // The keys cycle a slot pressed twice (halves to thirds); the model asked for this one.
        if p.tile?.preset == preset { return true }
        tile(p, preset)
        return p.tile?.preset == preset
    }

    /// Into the window at 1:1, as a click on it does.
    func agentEnter(_ id: CGWindowID) -> Bool {
        guard agentBusy == nil, let p = view.proxies.first(where: { $0.windowID == id }), p.standsAlone else { return false }
        handoff(to: p)
        return true
    }

    /// The camera frames these windows, or every window with none given. Ids none of which are on this
    /// canvas (another display's, or minimized) leave the camera where it is.
    func agentLook(at ids: [CGWindowID]) {
        guard !ids.isEmpty else { return view.fitAll(animated: true) }
        let rects = view.proxies.filter { ids.contains($0.windowID) }.map(\.worldRect)
        guard let first = rects.first else { return }
        view.fit(rects.dropFirst().reduce(first) { $0.union($1) }, animated: true)
    }

    func agentMinimize(_ id: CGWindowID) -> Bool {
        guard agentBusy == nil, let p = proxies[id], p.standsAlone else { return false }
        minimize(p)
        return true
    }

    func agentClose(_ id: CGWindowID) -> Bool {
        guard agentBusy == nil, let p = proxies[id], p.standsAlone else { return false }
        close(p)
        return true
    }

    func agentBringBack(_ id: CGWindowID) -> Bool {
        guard agentBusy == nil, let p = away[id] else { return false }
        bringBack(p)
        return true
    }

    /// Opens the app behind the canvas, as Open Here does, and waits up to `wait` for a window of it to
    /// land: the first new one, else one it already had. Nil if none came.
    func agentOpen(_ app: AppEntry, wait: TimeInterval = 6) async -> CGWindowID? {
        let bundleID = Bundle(url: app.url)?.bundleIdentifier
        let known = Set(proxies.keys)
        open(appAt: app.url, name: app.name)
        let start = Date()
        while Date().timeIntervalSince(start) < wait {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return nil }
            let mine = view.proxies.filter { $0.standsAlone && $0.matches(bundleID: bundleID, pid: nil) }
            if let fresh = mine.last(where: { !known.contains($0.windowID) }) { return fresh.windowID }
            // Already running with windows and nothing new after a moment: it opened none.
            if !mine.isEmpty, Date().timeIntervalSince(start) > 2 { return mine.last?.windowID }
        }
        return nil
    }

    /// Layouts › Save Layout… under a name given, not asked for: the background isn't saved with it.
    func agentSaveLayout(named name: String, saved: (() -> Void)? = nil) -> Bool {
        guard addingWidgets == nil, restoring == nil else { return false }
        save(layoutNamed: name, withBackground: false, saved: saved)
        return true
    }

    // MARK: Strip mode

    /// The free canvas as it was when strip mode came on, to put back when it goes off. Only for this
    /// run: a strip that was on at launch goes off leaving the windows where the strip had them.
    private var freeArrangement: PlacementState?
    /// A window was let go in the strip: its new place becomes the order, once, after the drop.
    private var stripDropped: WindowProxy?
    /// Windows that `placeRemembered` put back where the last run had them: not new arrivals.
    private var rememberedClaimed: Set<CGWindowID> = []

    var isStripMode: Bool { Settings.stripMode }

    /// Window › Strip Mode, ⌃⌥S.
    func toggleStripMode() { setStripMode(!Settings.stripMode) }

    /// Strip mode on lays every window out on the strip, the camera framing the start of it; off puts the
    /// free canvas back as it was, when it's known. ⌘Z switches back. From inside a real window the
    /// canvas comes forward first.
    func setStripMode(_ on: Bool) {
        guard on != Settings.stripMode, !on || Settings.stripModeEnabled, restoring == nil, addingWidgets == nil, !handingOff else { return }
        guard NSApp.isActive else {
            pendingPlacement = { [weak self] in self?.setStripMode(on) }
            show()
            return
        }
        let befores = deskCanvases.map { ($0, $0.placementState(of: $0.stripWindows)) }
        Settings.stripMode = on
        Log.note("Strip: \(on ? "on" : "off"), \(stripWindows.count) windows")
        // Polarity rests while the strip rules, and wakes after: its chrome follows.
        NotificationCenter.default.post(name: Settings.magneticPolarityDidChange, object: nil)
        // Every display's canvas has a strip of its own.
        for (c, before) in befores {
            if on {
                c.freeArrangement = before
                for p in c.stripWindows { p.tile = nil }
                c.layoutStrip(animated: true, framing: true)
            } else if let free = c.freeArrangement {
                c.freeArrangement = nil
                c.restorePlacement(free)
            }
        }
        if let undo = window.undoManager {
            undo.registerUndo(withTarget: self) { controller in
                MainActor.assumeIsolated { controller.setStripMode(!on) }
            }
            undo.setActionName("Strip Mode")
        }
        rememberSoon()
    }

    /// Every window on the strip: those on the canvas, bottom to top, then the hidden and minimized.
    private var stripWindows: [WindowProxy] {
        (view.proxies + view.away).filter { $0.kind == .window }
    }

    private func stripItems(_ windows: [WindowProxy]) -> [Strip.Item] {
        windows.map { p in
            Strip.Item(rect: p.worldRect, app: p.bundleID ?? p.appName, recency: mru.firstIndex(of: p.windowID),
                       away: p.away != nil)
        }
    }

    /// The first window's top-left: the screen you start on, a gap in from its visible area's corner,
    /// so the strip begins where the desktop is at 1:1.
    private var stripOrigin: CGPoint {
        let v = homeVisible, gap = stripGap
        return CGPoint(x: v.minX + gap, y: v.minY + gap)
    }

    /// Between columns and between the windows stacked in one: Tidy's Normal spacing, so it follows
    /// Settings › Windows › Tiling › Gap.
    private var stripGap: CGFloat { Tidy.Spacing.normal.points(gap: Settings.tileGap) }

    /// Every window to its slot on the strip (`Strip`), in the order of the recency list. Windows away
    /// from the canvas take theirs at once; the rest glide. `framing`: the camera frames the start of the
    /// strip in the same motion. `following`: the camera moves with that window, so it stays where it is
    /// on screen and the strip rearranges around it. Nothing happens unless strip mode is on.
    private func layoutStrip(animated: Bool, framing: Bool = false, following: WindowProxy? = nil) {
        guard Settings.stripMode, restoring == nil, addingWidgets == nil, !handingOff else { return }
        let windows = stripWindows
        guard !windows.isEmpty else { return }
        let placed = Strip.layout(stripItems(windows), origin: stripOrigin, gap: stripGap)
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        var placedAtOnce = 0
        for (p, rect) in zip(windows, placed.rects) where p.worldRect.origin != rect.origin {
            p.tile = nil
            if p.away != nil || !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                p.place(at: rect.origin)
                placedAtOnce += 1
            } else {
                moves.append((p, rect.origin))
            }
        }
        var camera: Camera?
        if framing {
            // The start of the strip, not all of it: an endless strip framed whole is too small to read.
            let start = placed.bounds.intersection(CGRect(x: placed.bounds.minX, y: placed.bounds.minY,
                                                          width: visibleTopLeft.width * 2, height: placed.bounds.height))
            camera = view.framing(start.isNull ? placed.bounds : start)
        } else if let p = following, let move = moves.first(where: { $0.proxy === p }) {
            var c = view.camera
            c.origin.x += move.to.x - p.worldRect.minX
            c.origin.y += move.to.y - p.worldRect.minY
            camera = c
        }
        if let camera {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !animated {
                for (p, to) in moves { p.place(at: to) }
                view.set(camera: camera)
            } else {
                view.animateCamera(to: camera, duration: CanvasView.cameraDuration, moving: moves)
            }
        } else if !moves.isEmpty {
            view.glide(moves, duration: CanvasView.cameraDuration)
        }
        guard framing || !moves.isEmpty || placedAtOnce > 0 else { return }
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    /// The listing found the canvas changed (windows opened, closed, resized by their apps): the strip
    /// closes up or makes room, once nothing is moving.
    private func layoutStripWhenIdle() {
        guard Settings.stripMode, NSApp.isActive, activeProxy == nil, !view.isBusy else { return }
        layoutStrip(animated: true)
    }

    /// Windows that showed up after launch are the most recent: each takes the front of the strip, its
    /// app's column moving to the left end with it on top. Windows the last run had, coming back to where
    /// they were, and those a layout restore is waiting for, aren't new.
    private func noteStripArrivals(_ created: [WindowProxy], arriving: Bool) {
        guard Settings.stripMode, arriving, restoring == nil else { return }
        for p in created.reversed() where p.kind == .window && !rememberedClaimed.contains(p.windowID) {
            mru.removeAll { $0 == p.windowID }
            mru.insert(p.windowID, at: 0)
        }
    }

    /// The order the strip shows, written into the recency list, so the next layout keeps it: every
    /// window, column by column, top to bottom.
    private func adoptStripOrder(_ columns: [[Int]], of windows: [WindowProxy]) {
        let ids = columns.flatMap { $0 }.map { windows[$0].windowID }
        mru = ids + mru.filter { !ids.contains($0) }
    }

    /// A window let go on the strip: its column goes where it was dropped, past a neighbour once its
    /// middle is past that neighbour's, and it takes its place in the column. That order is the strip's
    /// from now on, until the next window is used.
    private func stripWindowDropped(_ p: WindowProxy) {
        guard Settings.stripMode else { return }
        let first = stripDropped == nil
        stripDropped = p
        guard first else { return }
        // One reorder per drop, after the view has finished with it (and with any undo it replays).
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.stripDropped else { return }
            self.stripDropped = nil
            let windows = self.stripWindows
            guard let dropped = windows.firstIndex(where: { $0 === p }) else { return }
            let items = self.stripItems(windows)
            let current = Strip.layout(items, origin: self.stripOrigin, gap: self.stripGap)
            var rects = current.rects
            rects[dropped] = p.worldRect   // everything else as it sits in the strip, this where it was let go
            let order = Strip.reordered(current.columns, rects: rects, dropped: dropped)
            self.adoptStripOrder(order, of: windows)
            self.layoutStrip(animated: true)
        }
    }

    /// The strip in the order the windows sit now, left to right (a layout restored, put on the strip).
    private func adoptStripOrderFromPositions() {
        let windows = stripWindows
        adoptStripOrder(Strip.columns(stripItems(windows), usingRecency: false), of: windows)
    }

    /// ⌃⌥ arrows in strip mode: into the window beside the one in use (or, on the canvas, the one under
    /// the pointer or used last), ← → the next app's column, ↑ ↓ along the column. From inside a real
    /// window the canvas comes forward first and the strip keeps its order while you step, so ⌃⌥→ twice
    /// goes two columns along; it reorders the next time you come back to the canvas yourself.
    func stepStrip(_ direction: Strip.Direction) {
        guard restoring == nil, addingWidgets == nil, !handingOff else { return }
        guard NSApp.isActive else {
            let from = activeProxy?.windowID ?? lastActiveProxy?.windowID
            pendingPlacement = { [weak self] in self?.stepStrip(direction, from: from) }
            show()
            return
        }
        stepStrip(direction, from: nil)
    }

    private func stepStrip(_ direction: Strip.Direction, from id: CGWindowID?) {
        let windows = stripWindows
        let items = stripItems(windows)
        let columns = Strip.columns(items)
        let start = id.flatMap { id in windows.firstIndex { $0.windowID == id && $0.away == nil } }
            ?? view.hoveredWindow.flatMap { p in windows.firstIndex { $0 === p } }
            ?? mru.lazy.compactMap { id in windows.firstIndex { $0.windowID == id && $0.away == nil } }.first
        guard let start else {
            // Nothing used yet: the first window on the strip.
            if let first = columns.lazy.compactMap({ column in column.first { i in !items[i].away } }).first {
                handoff(to: windows[first])
            }
            return
        }
        guard let next = Strip.neighbour(of: start, in: columns, away: items.map(\.away), direction: direction) else {
            NSSound.beep()
            return
        }
        Log.note("Strip: \(direction) to \(windows[next].appName) — \(windows[next].title)")
        handoff(to: windows[next])
    }

    // MARK: Tidy

    /// Window › Tidy By › an order: by it from now on, and now.
    func tidy(by order: Tidy.Order) {
        Settings.tidyOrder = order
        tidy()
    }

    /// Tidy (Window › Tidy, ⌃⌥A): every window on the canvas on one grid (`Tidy`), from the top-left of
    /// the screen in view, the camera framing the result in the same motion. Groups go as blocks;
    /// widgets stay; hidden and minimized windows take a cell after the rest. ⌘Z puts everything back,
    /// sizes included. From inside a real window the canvas comes forward first.
    func tidy() {
        guard Settings.arranging, restoring == nil, addingWidgets == nil, !handingOff, !Settings.stripMode else { return }
        guard NSApp.isActive else {
            pendingPlacement = { [weak self] in self?.tidy() }
            show()
            return
        }
        let screen = placementScreen()
        let options = Settings.tidyOptions
        // One item per window, or per bonded group, keyed by the member met first (the canvas is bottom
        // to top, then the hidden and minimized).
        var items: [Tidy.Item] = []
        var blocks: [[WindowProxy]] = []
        var seen = Set<CGWindowID>()
        for p in view.proxies + view.away where p.standsAlone && !seen.contains(p.windowID) {
            let members = [p] + view.groupMembers(of: p)
            for m in members { seen.insert(m.windowID) }
            let outline = members.dropFirst().reduce(p.worldRect) { $0.union($1.worldRect) }
            let recency = members.compactMap { m in mru.firstIndex(of: m.windowID) }.min()
            items.append(Tidy.Item(rect: outline, recency: recency, app: p.bundleID ?? p.appName,
                                   away: members.allSatisfy { $0.away != nil }, isGroup: members.count > 1))
            blocks.append(members)
        }
        guard !items.isEmpty else { return }
        let placed = Tidy.layout(items, options: options, screen: screen)
        let how = options.sizing == .keep ? "sizes kept" : "same size"
        Log.note("Tidy: \(items.count) windows and groups, \(how), by \(options.order.title)")
        let all = blocks.flatMap { $0 }
        let before = placementState(of: all)
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        var resized = false
        for (i, block) in blocks.enumerated() {
            let target = placed.rects[i]
            if block.count == 1, let p = block.first {
                if options.sizing == .same, p.away == nil, abs(p.worldRect.width - target.width) > 0.5 || abs(p.worldRect.height - target.height) > 0.5 {
                    resize(p, to: target.size)
                    resized = true
                }
                p.tile = placed.screens[i].map { Tiling.Tile(area: $0, preset: nil) }
                moves.append((p, Resizing.place(p.worldRect.size, in: target, anchor: .zero).origin))
            } else {
                let dx = target.minX - items[i].rect.minX, dy = target.minY - items[i].rect.minY
                for m in block {
                    m.tile = nil
                    moves.append((m, CGPoint(x: m.worldRect.minX + dx, y: m.worldRect.minY + dy)))
                }
            }
        }
        let changed = resized || moves.contains { $0.proxy.worldRect.origin != $0.to }
        if changed { registerPlacementUndo(from: before, to: placementState(of: all, landing: moves), name: "Tidy") }
        // Windows away from the canvas aren't drawn: they take their places at once.
        for (p, to) in moves where p.away != nil { p.place(at: to) }
        let gliding = moves.filter { $0.proxy.away == nil }
        let frame = view.framing(placed.bounds)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (p, to) in gliding { p.place(at: to) }
            view.set(camera: frame)
        } else {
            view.animateCamera(to: frame, moving: gliding)
        }
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    // MARK: Undo for placements

    /// What Move & Resize, Arrange and Tidy change, for ⌘Z: each window's rect and tiled area, and the groups.
    private struct PlacementState {
        var entries: [(proxy: WindowProxy, rect: CGRect, tile: Tiling.Tile?)]
        var grouping: Grouping
    }

    /// The windows as they are, or, with `landing`, where the moves in flight will put them (a glide
    /// hasn't moved anything yet when the undo is registered; a resize has).
    private func placementState(of windows: [WindowProxy], landing: [(proxy: WindowProxy, to: CGPoint)] = []) -> PlacementState {
        let entries = windows.map { p -> (proxy: WindowProxy, rect: CGRect, tile: Tiling.Tile?) in
            var rect = p.worldRect
            if let move = landing.first(where: { $0.proxy === p }) { rect.origin = move.to }
            return (p, rect, p.tile)
        }
        return PlacementState(entries: entries, grouping: view.grouping)
    }

    /// ⌘Z after a placement glides every window it touched back to its size and place (the real window
    /// resized behind the canvas), its tiled area and the groups as they were; ⇧⌘Z does the placement again.
    private func registerPlacementUndo(from before: PlacementState, to after: PlacementState, name: String) {
        guard let undo = window.undoManager else { return }
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.restorePlacement(before)
                controller.registerPlacementUndo(from: after, to: before, name: name)
            }
        }
        undo.setActionName(name)
    }

    private func restorePlacement(_ state: PlacementState) {
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        for entry in state.entries {
            let p = entry.proxy
            let onCanvas = proxies[p.windowID] === p
            guard onCanvas || away[p.windowID] === p else { continue }
            if onCanvas { resize(p, to: entry.rect.size) }
            p.tile = entry.tile
            if onCanvas { moves.append((p, entry.rect.origin)) } else { p.place(at: entry.rect.origin) }
        }
        view.restoreGrouping(state.grouping)
        view.glide(moves)
        minimap.redraw()
        scheduleCapturePass()
        rememberSoon()
    }

    /// The real window takes the rect's size behind the canvas; where the proxy goes for the size it got.
    private func placement(_ p: WindowProxy, in rect: CGRect, anchor: CGPoint) -> (proxy: WindowProxy, to: CGPoint) {
        resize(p, to: rect.size)
        return (p, Resizing.place(p.worldRect.size, in: rect, anchor: anchor).origin)
    }

    /// A tiling shortcut while a real window is in front (entered, or any app with takeover off): macOS
    /// tiles it if it has the slot, else Sunlight sets the frame on the screen itself.
    private func tileFrontWindow(_ requested: Tiling.Preset) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPID else { return }
        let pid = app.processIdentifier
        let entered = activeProxy?.pid == pid ? activeProxy : nil
        let preset = cycled(requested, for: entered)
        let screen = homeVisible, gap = Settings.tileGap, area = view.camera.toWorld(visibleTopLeft)
        let displays = deskCanvases.map(\.display)
        AXQueue.interactive.async { [weak self] in
            var done = NativeTiling.supports(preset) && NativeTiling.tile(pid: pid, preset)
            if done {
                Log.note("Tile: \(app.localizedName ?? "?") → \(preset.title) (macOS tiling)")
            } else if let ax = AXWindow.focusedWindow(pid: pid), !ax.isFullScreen, let frame = ax.frame {
                let screen = Display.index(for: frame, in: displays).map { displays[$0].visible } ?? screen
                let rect = Tiling.rect(preset, size: frame.size, in: screen, gap: gap)
                // Size, move, size again: a window can't grow past the screen edge it's still near.
                ax.setSize(rect.size)
                ax.setPosition(rect.origin)
                ax.setSize(rect.size)
                if let landed = ax.frame {
                    let fit = Resizing.place(landed.size, in: rect, anchor: Tiling.anchor(for: preset.unit))
                    if fit.origin != landed.origin { ax.setPosition(fit.origin) }
                }
                done = true
                Log.note("Tile: \(app.localizedName ?? "?") → \(preset.title)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard done, let self, let p = entered, self.activeProxy === p else { return }
                    // The canvas takes the real window's new frame when it's back in front.
                    p.tile = Tiling.Tile(area: area, preset: preset)
                }
            }
        }
    }

    // MARK: Resizing on the canvas

    /// The real window's resize in flight, and the one the canvas wants next. An edge being dragged asks
    /// many times a frame and each ask is a round trip to the app, so only the latest waits its turn.
    private var resizeInFlight = false
    private var pendingResize: (id: CGWindowID, size: CGSize, anchor: CGPoint, finished: Bool)?

    /// An edge of a proxy was dragged (`finished` once it's let go): the real window takes the new size
    /// behind the canvas, where it can't be seen, following the pointer as closely as the app keeps up.
    /// Once let go, the proxy takes the size the app actually allowed, against the edges that didn't move.
    private func canvasResized(_ p: WindowProxy, anchor: CGPoint, finished: Bool) {
        guard p.kind == .window else { return }
        pendingResize = (p.windowID, p.worldRect.size, anchor, finished)
        pumpResize()
        if finished { rememberSoon() }
    }

    private func pumpResize() {
        guard !resizeInFlight, let next = pendingResize else { return }
        pendingResize = nil
        guard let p = proxies[next.id] else { return pumpResize() }
        resizeInFlight = true
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax
        let size = next.size, anchor = next.anchor, finished = next.finished
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            var real: CGRect?
            if let ax, !ax.isFullScreen {
                ax.setSize(size)
                real = ax.frame
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resizeInFlight = false
                    defer { self.pumpResize() }
                    guard let p = self.proxies[id] else { return }
                    if p.ax == nil { p.ax = ax }
                    guard let real else {
                        if finished {
                            Log.note("Resize: can't resize \(p.appName) — \(p.title)\(ax == nil ? " (Accessibility granted?)" : ": it's full screen")")
                            // The proxy goes back to the size the real window still has.
                            p.resized(toReal: p.lastRealFrame, anchor: anchor)
                        }
                        return
                    }
                    guard finished else {
                        p.noteResize(toReal: real)
                        return
                    }
                    if abs(real.width - size.width) > 0.5 || abs(real.height - size.height) > 0.5 {
                        Log.note("Resize: \(p.appName) — \(p.title) is \(Int(real.width))×\(Int(real.height)), not \(Int(size.width))×\(Int(size.height)): the app's own limits")
                    }
                    p.resized(toReal: real, anchor: anchor)
                    self.minimap.redraw()
                    self.scheduleCapturePass()
                }
            }
        }
    }

    /// Move Aside: windows that aren't in the layout line up in a row to its right, top-aligned, on the
    /// grid and a grid step apart, left to right as they were. `x` is where the next one goes.
    private func park(_ ps: [WindowProxy], x: inout CGFloat, beside layout: Layout) -> [(proxy: WindowProxy, to: CGPoint)] {
        let step = Settings.gridSize
        let top = ((layout.bounds?.minY ?? 0) / step).rounded() * step
        return ps.sorted { $0.worldRect.minX < $1.worldRect.minX }.map { p in
            view.release(p)   // moved aside on its own: it leaves its group
            let spot = CGPoint(x: (x / step).rounded(.up) * step, y: top)
            x = spot.x + p.worldRect.width + step
            return (p, spot)
        }
    }

    /// Opens what a layout has that isn't on the canvas, without activating anything, so it comes up
    /// behind the canvas: the documents its windows showed, and apps that aren't running. A running app with
    /// no window open is asked to reopen, which gives most apps a fresh one. Anything else (a browser's
    /// second window, a widget since removed) can't be brought back from here. Returns the apps it opened.
    private func open(_ entries: [Layout.Entry]) -> Set<String> {
        for e in entries where e.kind == .widget {
            Log.note("Layout: the \(e.appName) widget isn't on the desktop — Add Widgets… puts it back")
        }
        var opened: Set<String> = []
        let windows = entries.filter { $0.kind == .window }
        for (bundleID, wanted) in Dictionary(grouping: windows, by: { $0.bundleID ?? "" }) {
            let name = wanted[0].appName
            guard !bundleID.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.note("Layout: \(name) isn't installed")
                continue
            }
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            let hasWindows = proxies.values.contains { $0.kind == .window && $0.bundleID == bundleID }
            // A file or folder that's still there, or a setup's web address.
            let documents = wanted.compactMap(\.documentURL)
                .filter { !$0.isFileURL || FileManager.default.fileExists(atPath: $0.path) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            if !documents.isEmpty {
                Log.note("Layout: opening \(documents.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }.joined(separator: ", ")) in \(name)")
                NSWorkspace.shared.open(documents, withApplicationAt: app, configuration: configuration) { _, error in
                    if let error { Log.note("Layout: \(name) couldn't open its documents — \(error.localizedDescription)") }
                }
                opened.insert(bundleID)
            } else if !running || !hasWindows {
                Log.note("Layout: \(running ? "reopening" : "launching") \(name)")
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                    if let error { Log.note("Layout: \(name) didn't open — \(error.localizedDescription)") }
                }
                opened.insert(bundleID)
            } else {
                Log.note("Layout: can't reopen \(wanted.count) window(s) of \(name) from here: no document to open")
            }
        }
        return opened
    }

    private func restoringTick() {
        guard let state = restoring else { return }
        guard Date() < state.deadline else {
            finishRestoring()
            return
        }
        // An app that activated itself as it launched has its windows over the canvas: put it back in front.
        if !NSApp.isActive, activeProxy == nil,
           let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, state.apps.contains(front) {
            Log.note("Layout: \(front) came to the front as it launched — bringing the canvas back")
            show()
            return
        }
        guard NSApp.isActive, activeProxy == nil else { return }
        Task { @MainActor in
            await self.syncNow()
            await self.placeArrivals()
        }
    }

    /// Windows the restore opened, as they show up: each takes its place in the layout where it appears
    /// (no glide: the camera may still be on its way there). With Move Aside, the apps' other new windows
    /// (an app reopening more than the layout has) are parked with the rest.
    private func placeArrivals() async {
        guard let before = restoring else { return }
        let arrived = view.proxies.filter { !before.known.contains($0.windowID) }
        guard !arrived.isEmpty else { return }
        let documents = await lookUpDocuments(of: arrived)
        // The same restore still, and only what another tick hasn't placed meanwhile.
        guard var state = restoring, state.deadline == before.deadline else { return }
        let fresh = arrived.filter { !state.known.contains($0.windowID) && proxies[$0.windowID] === $0 }
        guard !fresh.isEmpty else { return }
        state.known.formUnion(fresh.map(\.windowID))
        let entries = state.pending.map { state.layout.entries[$0] }
        let pairs = Layout.match(entries, fresh, document: { documents[$0.windowID] })
        for (k, p) in pairs {
            resize(p, to: entries[k].frame.size)
            p.place(at: entries[k].frame.origin)
            p.layout(zoom: view.camera.zoom)
            applyPolarity(of: entries[k], to: p)
            applyPip(of: entries[k], to: p)
            if let g = entries[k].group { view.adopt(group: g, for: p, remap: &state.groups) }
            Log.note("Layout: \(p.appName) — \(p.title) is back")
        }
        let claimed = Set(pairs.map { state.pending[$0.entry] })
        state.pending.removeAll { claimed.contains($0) }
        if state.policy == .moveAside {
            let placed = Set(pairs.map(\.proxy.windowID))
            let extras = fresh.filter { $0.kind == .window && !placed.contains($0.windowID) && state.apps.contains($0.bundleID ?? "") }
            for (p, spot) in park(extras, x: &state.parkX, beside: state.layout) {
                p.place(at: spot)
                p.layout(zoom: view.camera.zoom)
            }
        }
        restoring = state
        if state.pending.isEmpty { finishRestoring() }
    }

    private func finishRestoring() {
        restoringTimer?.invalidate()
        restoringTimer = nil
        if let state = restoring {
            let missing = state.pending.map { state.layout.entries[$0] }.map { $0.title.isEmpty ? $0.appName : "\($0.appName) — \($0.title)" }
            Log.note("Layout: “\(state.layout.name)” restored\(missing.isEmpty ? "" : "; never showed up: \(missing.joined(separator: ", "))")")
        }
        restoring = nil
        foldRestoredIntoStrip()
        rememberSoon()
    }

    /// Strip mode: a restored layout's windows go onto the strip in the layout's order, left to right,
    /// once they've glided to where the layout has them.
    private func foldRestoredIntoStrip() {
        guard Settings.stripMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.restoreDuration + 0.05) { [weak self] in
            guard let self, Settings.stripMode, self.restoring == nil else { return }
            self.adoptStripOrderFromPositions()
            self.layoutStrip(animated: true)
        }
    }

    // MARK: Handoff

    /// How a window is entered (`Handoff.Placement`).
    typealias Placement = Handoff.Placement

    /// Keep the canvas in front during the double-click interval so a second click can redirect
    /// the entrance instead of reaching the real window.
    private static var clickEntryDuration: CFTimeInterval {
        max(NSEvent.doubleClickInterval, CanvasView.cameraDuration)
    }

    /// `spatial`: travel there across the canvas (the switcher's pan-and-zoom flight) rather than the
    /// straight zoom-in a click or ⏎ gets. `gliding`: the window is drawn there now (where it opened, at
    /// 1:1 in front of everything) and glides to its place on the canvas as the camera goes to it.
    func handoff(to p: WindowProxy, placement: Placement = .centered, spatial: Bool = false,
                 gliding from: CGPoint? = nil, click: Bool = false) {
        guard !handingOff, p.kind == .window else { return letGo(p) }
        // A sheet or prompt is entered through its parent; preserve the clicked spot and timing.
        if let parent = parentOf(p) {
            var placement = placement
            if case .clicked(let at, let offset) = placement {
                placement = .clicked(at: at, offset: CGPoint(x: offset.x + p.attachmentOffset.x, y: offset.y + p.attachmentOffset.y))
            }
            return handoff(to: parent, placement: placement, spatial: spatial, click: click)
        }
        // A window in Picture in Picture returns to 1:1 where its tile is; the camera stays (`returnFromPip`).
        if p.pip != nil { return returnFromPip(p) }
        // Straight after the canvas came back (a quick ⌘Tab tap, ⌘ up before the canvas was), its first
        // listing may not have landed, and none lands during a handoff: the live windows were never
        // presented, so the flight played with nothing on screen following it and the window jumped
        // into place at the seam. One now, before the handoff starts, so the flight carries them.
        if renderer == .realWindows, !realWindowListReady { listNow() }
        handingOff = true
        endShowDesktop(flyBack: false)
        handoffTarget = p   // before the camera moves: the pass must not restart its stream mid-flight
        Log.note("Handoff: → \(p.appName) — \(p.title)")
        closeSwitcher(clearHighlight: true)
        view.bringToFront(p)
        // Stop streaming the app now, not at the seam: the pill takes a moment to clear, and the flight
        // covers it. The proxies hold their last frame; the refresh timer keeps the target one current.
        // The target's last streamed frame was sized for the zoom it was seen at; a full one-shot,
        // asked for before the stream stops (they're served independently), replaces it while the
        // proxy is still small on screen, well before the seam.
        p.refresh(seam: true)
        stopStreams(of: p.pid)

        // Its app's front and main window from now, so the activation at the seam brings this window
        // and no other. Done now, while it's still on the canvas: an inactive app's raise puts the
        // window just under the active app's key window, the canvas, which is where the front canvas
        // window is anyway. Done at the seam, after the add-on has put it in front of the canvas, it
        // pulled the window back under the canvas for the frames before the activation landed. On the
        // live canvas it goes through the Accessibility queue: the handle (when the pointer never
        // rested on the window) and the raises are round trips to the app, which on the main thread held
        // the flight's first frames for as long as the app took to answer; they land well within the
        // flight for any app that answers at all.
        if renderer == .realWindows {
            raiseForHandoff(p)
        } else if p.ax == nil {
            p.ax = AXWindow.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame)
            if p.ax == nil { Log.note("Handoff: no AX window for \(p.appName) — Accessibility granted?") }
        }

        // Where the real window will sit at 1:1 (pixel-aligned, below the menu bar) and the camera that
        // puts it there: the camera goes to the window, not the window to the camera.
        let plan = Handoff.plan(placement, rect: p.worldRect, camera: view.camera, visible: visibleTopLeft, scale: scale,
                                tiledArea: tiledArea(of: p))
        let origin = plan.origin
        let clicked = plan.clicked

        if renderer == .realWindows {
            // The native window stays put throughout the flight. Only its live surface follows the
            // camera. Commit the final position and reset the transform together inside Dock.
            let target = plan.camera
            let destination = nativeOrigin(of: p, at: target)
            // At 1:1, in place, there's nowhere to fly: a few frames and it's in use.
            var duration = view.camera.isClose(to: target) ? CanvasController.stayingDuration : CanvasView.cameraDuration
            if click { duration = max(duration, CanvasController.clickEntryDuration) }
            // A window gliding from where it opened needs at least a camera flight.
            let glides = from.map { $0 != p.worldRect.origin } ?? false
            if glides { duration = max(duration, CanvasView.cameraDuration) }
            shadowFlight = (p.windowID, CACurrentMediaTime(), duration)
            let complete: () -> Void = { [weak self] in
                guard let self, self.handoffTarget === p, self.renderer == .realWindows else { self?.letGo(p); p.heldBack = false; return }
                p.heldBack = false   // the seam takes it from where it is, leased or not
                self.parkedOffScreen.removeValue(forKey: p.windowID)   // the seam's transaction moved it to the spot
                // Both looks the active one at the seam; the standard pair again once the activation has landed.
                let shadow = LiveWindowsWire.shadow(p.windowID, inactiveWeight: 1, activeWeight: 1)
                self.shadowFlight = nil
                let kept = self.keptOnShow(entering: p)
                // A sheet or prompt on the entered window stays on top of it: the add-on puts the handoff's
                // window in front and the kept ones under it, so the topmost child takes the front spot and
                // the parent is kept just under it. Raising the parent alone would put it over its prompt.
                var front = (p.windowID, destination)
                var keeping = kept.map { ($0.proxy.windowID, $0.at.origin) }
                if let top = kept.lastIndex(where: { $0.proxy.attachedTo == p.windowID }) {
                    front = (kept[top].proxy.windowID, kept[top].at.origin)
                    keeping.remove(at: top)
                    keeping.append((p.windowID, destination))
                }
                guard self.realWindows.restore(handoff: front,
                                               overlay: CGWindowID(self.window.windowNumber),
                                               backdrop: self.backdrop.map { CGWindowID($0.windowNumber) } ?? 0,
                                               shadow: shadow,
                                               keeping: keeping,
                                               top: self.toGlobal(CGPoint(x: 0, y: self.visibleTopLeft.minY)).y,
                                               pinned: self.pipIDs(except: p)) else {
                    self.handingOff = false
                    self.handoffTarget = nil
                    self.fallBackFromRealWindows("Could not restore the entered window (\(self.realWindows.lastRestoreFailure ?? "?"))")
                    return
                }
                // The window is in front of the canvas now, and the ones in view around it with it (an
                // add-on from sunlight-10 keeps them; an older one puts them back with the rest). Each is
                // natively where it is drawn: that is where it lives from now, as for the entered window,
                // so the listing sees no move. The canvas keeps its live look behind them (see
                // `suspendRealWindows`), so nothing on screen changes but the windows out of view leaving.
                // Where each really went (macOS keeps a window's top below the menu bar), not where it was
                // asked to: the listing reads a difference as the window moved, and moved it on the canvas.
                // The window server is the one source of native frames on the live canvas, here as in
                // the listing: Accessibility's frame can differ by a fraction, and may not exist at all.
                let listed = self.snapshot()
                if self.realWindows.lastRestoreKept {
                    for (q, at) in kept { q.placedNatively(at: listed[q.windowID] ?? at) }
                    let own = kept.filter { $0.proxy.pid == p.pid }.count
                    Log.note("Handoff: \(kept.count - own) other window(s) in view stay on show, \(own) of its app's where the canvas has them")
                }
                self.realWindowsPresented = false
                // An add-on before sunlight-10 doesn't keep windows: its app's others go through Accessibility.
                self.alignSiblings(of: p, except: self.realWindows.lastRestoreKept ? Set(kept.map(\.proxy.windowID)) : [])
                let landed = listed[p.windowID] ?? p.ax?.frame ?? CGRect(origin: destination, size: p.worldRect.size)
                self.checkPlacement(of: [p] + kept.map(\.proxy) + self.proxies.values.filter { $0.pid == p.pid && $0 !== p },
                                    in: listed, at: "seam")
                self.enter(p, realFrame: landed, activateApp: true)
            }
            if let from, from != p.worldRect.origin {
                // Drawn where it opened until the flight starts; the flight carries it to its place.
                let spot = p.worldRect.origin
                p.place(at: from)
                p.layout(zoom: view.camera.zoom)
                view.animateCamera(to: target, duration: duration, moving: [(p, spot)], completion: complete)
            } else if !clicked, spatial || view.isFlying { view.fly(to: target, completion: complete) }
            else { view.animateCamera(to: target, duration: duration, completion: complete) }
            return
        }

        // Move the real window now, while it's still hidden behind the canvas, then read back where it
        // actually went (apps can refuse or clamp) and aim the camera at *that*. Without Accessibility the
        // camera goes to the window instead of the window coming to the camera. A native-fullscreen
        // window can't be moved at all; activating its app switches to its Space.
        let real: CGRect
        if let ax = p.ax, !ax.isFullScreen {
            ax.setPosition(toGlobal(origin))
            real = ax.frame ?? CGRect(origin: toGlobal(origin), size: p.worldRect.size)
        } else {
            real = p.ax?.frame ?? p.lastRealFrame
        }
        p.placedNatively(at: real)

        var aligned = cameraAligning(p, with: real)
        // In place, a window whose top would be above the menu bar lands right under it, where it was
        // asked to go (`Handoff.plan` clamps): the camera settles on it there, and the window keeps its
        // place on the canvas, as with live windows (the canvas shifts by the difference, not the
        // window). One the app put elsewhere (its own limits) eases to where it landed instead, and
        // nothing else on the canvas moves.
        var move: CGPoint?
        if let target = plan.inPlace {
            let landed = target.toWorld(toView(real.origin))
            let asked = toGlobal(plan.origin)
            let clampedOnly = plan.origin.y > plan.inPlaceOrigin.y
                && abs(real.origin.x - asked.x) <= 1 && abs(real.origin.y - asked.y) <= 1
            if clampedOnly {
                aligned = plan.camera
            } else {
                aligned = target
                if landed != p.worldRect.origin { move = landed }
                if hypot(landed.x - p.worldRect.minX, landed.y - p.worldRect.minY) > 1 {
                    Log.note("Handoff: \(p.appName) can't sit where it is, moved by (\(Int(landed.x - p.worldRect.minX)), \(Int(landed.y - p.worldRect.minY))): the app's own limits")
                }
            }
        }
        let complete: () -> Void = { [weak self] in self?.enter(p, realFrame: real, activateApp: true) }
        if plan.inPlace == nil, spatial || view.isFlying {
            // A flight already under way carries its momentum into the seam.
            view.fly(to: aligned, completion: complete)
        } else {
            var duration = move == nil && view.camera.isClose(to: aligned) ? CanvasController.stayingDuration : CanvasView.cameraDuration
            if click { duration = max(duration, CanvasController.clickEntryDuration) }
            view.animateCamera(to: aligned, duration: duration, moving: move.map { [(p, $0)] } ?? [], completion: complete)
            // One more full frame timed to land just before the seam.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - 0.09)) { [weak self, weak p] in
                guard let self, let p, self.handoffTarget === p else { return }
                p.refresh(seam: true)
            }
        }
    }

    // MARK: Picture in Picture

    /// The windows in Picture in Picture and leased, for the add-on to leave on show (`RealWindowDriver.restore`).
    private func pipIDs(except p: WindowProxy? = nil) -> [CGWindowID] {
        view.proxies.filter { $0.pip != nil && $0 !== p && $0.kind == .window && lastWantedIDs.contains($0.windowID) }.map(\.windowID)
    }

    /// The windows in PiP in the order they went in: the oldest gives up its corner when all four are taken.
    private var pipOrder: [CGWindowID] = []
    /// The corner the last tile went to: where the next one starts, unless its window remembers its own.
    private var lastPipCorner: PictureInPicture.Corner = .bottomRight

    /// The chrome over each tile (`PipChrome`): the home button, the tab, a click (the window returns to
    /// 1:1 where the tile is) and a drag of the tile. They work however the canvas stands; with the canvas
    /// away they bring it back first (`pendingPip`).
    private lazy var pipChrome: PipChrome = {
        let chrome = PipChrome(display: display)
        chrome.onClose = { [weak self] id in
            guard let self, let p = self.proxies[id] else { return }
            if self.isOnCanvas { self.endPip(p, animated: true) } else { self.pendingPip = (id, .end); self.show() }
        }
        chrome.onReturn = { [weak self] id in
            guard let self, let p = self.proxies[id] else { return }
            if self.isOnCanvas { self.returnFromPip(p) } else { self.pendingPip = (id, .back); self.show() }
        }
        chrome.onUntuck = { [weak self] id in
            guard let self, let p = self.proxies[id] else { return }
            if self.isOnCanvas { self.view.untuckPip(p) } else { self.pendingPip = (id, .untuck); self.show() }
        }
        chrome.onDragBegan = { [weak self] id, point in
            guard let self, self.isOnCanvas, let p = self.proxies[id], p.pip != nil, p.pipTucked == nil else { return false }
            self.view.beginPipDrag(p, at: point)
            return true
        }
        chrome.onDragMoved = { [weak self] point, t in self?.view.movePipDrag(to: point, timestamp: t) }
        chrome.onDragEnded = { [weak self] t, freely in self?.view.endPipDrag(timestamp: t, freely: freely) }
        return chrome
    }()

    /// The canvas is up and nothing is entered: a tile can be moved and its buttons act at once.
    private var isOnCanvas: Bool { NSApp.isActive && activeProxy == nil && !handingOff && !paused }

    /// The chrome panels follow the tiles, and the windows' shapes their scale: called whenever a tile is
    /// drawn somewhere new.
    private func updatePipChrome() {
        let tiles = view.proxies.compactMap { p -> PipChrome.Tile? in
            guard p.pip != nil, p.kind == .window, !p.leaving, !p.closing, let r = view.pipRect(of: p) else { return nil }
            return PipChrome.Tile(id: p.windowID, rect: r, tucked: p.pipTucked, title: p.title, pid: p.pid, flying: p.pipShown != nil)
        }
        pipChrome.update(tiles)
        updatePipShapes()
    }

    /// The corner radius last asked of the add-on for each window shaped as a tile (`LiveWindowsWire.shape`),
    /// in the window's own points; 0 is never kept.
    private var sentPipRadius: [CGWindowID: Float] = [:]
    /// Tiles on their way home (`endPip`): their windows get their own corners back before the flight.
    private var pipEnding: Set<CGWindowID> = []

    /// Every tile's window shaped to show `PictureInPicture.Reference.cornerRadius` at its scale, as a
    /// video's tile is, through the add-on (sunlight-47); its own corners back once it is used at 1:1, on
    /// its way home, or out of Picture in Picture. Only what changed is sent. With pictures, or an older
    /// add-on, windows keep their corners.
    private func updatePipShapes() {
        guard renderer == .realWindows, additionNumber >= LiveWindowsWire.shapesFrom else { return }
        var wanted: [CGWindowID: Float] = [:]
        for p in view.proxies where p.kind == .window {
            guard let f = p.pip else { continue }
            if activeProxy === p || pipEnding.contains(p.windowID) { continue }
            // On its way back to 1:1: as it is until the seam, which puts its own corners back (`returnFromPip`).
            if handoffTarget === p { if let kept = sentPipRadius[p.windowID] { wanted[p.windowID] = kept }; continue }
            let radius = Float(PictureInPicture.nativeCornerRadius(scale: f.scale))
            if radius > 0 { wanted[p.windowID] = radius }
        }
        for (id, radius) in wanted where sentPipRadius[id] != radius { sendPipShape(id, radius: radius) }
        for id in sentPipRadius.keys where wanted[id] == nil { sendPipShape(id, radius: 0) }
    }

    private func sendPipShape(_ id: CGWindowID, radius: Float) {
        sentPipRadius[id] = radius > 0 ? radius : nil
        realWindows.shape(id, radius: radius)
    }

    /// Every shaped window's own corners back: live windows let go, the canvas closing.
    private func resetPipShapes() {
        for id in sentPipRadius.keys { sendPipShape(id, radius: 0) }
    }

    /// Right-click › Picture in Picture, or ⌃⌥P over a window on the canvas: the window flies into a
    /// corner as a tile; already a tile, it flies back to its home.
    func togglePip(_ p: WindowProxy) {
        guard p.kind == .window, proxies[p.windowID] === p, !p.leaving, p.away == nil else { return }
        if p.pip != nil { return endPip(p, animated: true) }
        guard p.standsAlone else { return }   // a sheet or prompt rides on its window
        startPip(p, flying: true)
    }

    /// The corner a new tile goes to: the one asked for, or the nearest free one; with all four taken
    /// the oldest tile goes home and gives up its corner.
    private func freeCorner(preferring preferred: PictureInPicture.Corner) -> PictureInPicture.Corner {
        let taken = Set(view.proxies.compactMap { p -> PictureInPicture.Corner? in
            guard let f = p.pip, p.pipTucked == nil else { return nil }
            return PictureInPicture.corner(of: f, size: p.worldRect.size, visible: visibleTopLeft)
        })
        if !taken.contains(preferred) { return preferred }
        if let free = preferred.fallbacks.first(where: { !taken.contains($0) }) { return free }
        if let oldest = pipOrder.first, let p = proxies[oldest] { endPip(p, animated: true) }
        return preferred
    }

    /// The window goes into Picture in Picture: a tile in a corner at the default size, flown there from
    /// where the camera shows it (`flying`), or placed there to be flown by whoever asked (a return from
    /// 1:1, `leaveEntered`).
    private func startPip(_ p: WindowProxy, flying: Bool) {
        let size = p.worldRect.size, visible = visibleTopLeft
        let corner = freeCorner(preferring: p.lastPipCorner ?? lastPipCorner)
        let scale = PictureInPicture.defaultScale(size: size, visible: visible)
        let target = PictureInPicture.frame(in: corner, scale: scale, size: size, visible: visible)
        Log.note("PiP: \(p.appName) — \(p.title) into \(corner) ×\(String(format: "%.2f", scale))")
        p.lastPipCorner = corner
        lastPipCorner = corner
        p.pipTucked = nil
        p.tile = nil
        view.release(p)   // out of its group: a tile is on the screen, a group on the canvas
        view.cancelPipFlight(p)
        pipOrder.removeAll { $0 == p.windowID }
        pipOrder.append(p.windowID)
        if flying {
            p.pipShown = PipFrame(origin: view.camera.toScreen(p.worldRect).origin, scale: view.camera.zoom)
            p.pip = target
            view.pipChanged(p)
            view.flyPip(p, to: target, response: PictureInPicture.Reference.enterResponse,
                        damping: PictureInPicture.Reference.enterDamping) { [weak self, weak p] in
                guard let self, let p else { return }
                p.pipShown = nil
                self.view.pipChanged(p)
            }
        } else {
            p.pip = target
            view.pipChanged(p)
        }
        rememberSoon()
    }

    /// Picture in Picture ends: the tile flies back to the window's home on the canvas (`animated`), or
    /// the window is just drawn there again (a close, a move to another display, a layout).
    private func endPip(_ p: WindowProxy, animated: Bool = false) {
        guard p.pip != nil else { return }
        Log.note("PiP: \(p.appName) — \(p.title) out")
        pipOrder.removeAll { $0 == p.windowID }
        p.pipTucked = nil
        if animated, !handingOff, NSApp.isActive {
            let home = PipFrame(origin: view.camera.toScreen(p.worldRect).origin, scale: view.camera.zoom)
            pipEnding.insert(p.windowID)   // its own corners back before it flies home
            view.flyPip(p, to: home, response: PictureInPicture.Reference.leaveResponse,
                        damping: PictureInPicture.Reference.leaveDamping) { [weak self, weak p] in
                guard let self, let p else { return }
                self.pipEnding.remove(p.windowID)
                p.pip = nil
                p.pipShown = nil
                self.view.pipChanged(p)
                self.rememberSoon()
            }
            updatePipChrome()
            return
        }
        view.cancelPipFlight(p)
        p.pip = nil
        p.pipShown = nil
        view.pipChanged(p)
        rememberSoon()
    }

    /// ⌃⌥P (and Window › Picture in Picture): on the canvas, the window under the pointer or the one used
    /// last; in a window, that window, which shrinks from 1:1 into its corner as the canvas comes back
    /// (`leaveEntered`), or goes home if it was a tile.
    func togglePipCommand() {
        guard addingWidgets == nil, !isSetupShowing, !paused else { return }
        if NSApp.isActive, activeProxy == nil {
            guard let p = tileTarget else { return }
            togglePip(p)
            return
        }
        guard let p = activeProxy else { return }
        pendingPip = (p.windowID, .toggle)
        show()
    }

    /// Something asked of a tile while the canvas was away, done once it's back (`returnedToCanvas`).
    private enum PipRequest { case toggle, end, back, untuck }
    private var pendingPip: (id: CGWindowID, request: PipRequest)?

    /// The canvas is coming back from the window `wasIn`, which asked to become a tile: it becomes one
    /// now, so `leaveEntered` flies it from 1:1 into its corner instead of back to its home.
    private func beginPendingPip(leaving wasIn: WindowProxy?) {
        guard let pending = pendingPip, pending.request == .toggle, let p = proxies[pending.id], p === wasIn,
              p.kind == .window, p.pip == nil, p.standsAlone else { return }
        pendingPip = nil
        startPip(p, flying: false)
    }

    private func applyPendingPip() {
        guard let pending = pendingPip else { return }
        pendingPip = nil
        guard let p = proxies[pending.id], p.kind == .window else { return }
        switch pending.request {
        case .toggle:
            if p.pip != nil { endPip(p, animated: true) } else if p.standsAlone { startPip(p, flying: true) }
        case .end:
            endPip(p, animated: true)
        case .back:
            if p.pip != nil { returnFromPip(p) }
        case .untuck:
            view.untuckPip(p)
        }
    }

    /// A tile returns to 1:1 (the return button, a double-click, ⌘Tab onto it): it grows about its tile
    /// (`PictureInPicture.returnRect`), the camera staying where it is, and shrinks back into its corner
    /// when the canvas comes back (`leaveEntered`). Live windows only: with pictures the real window has
    /// to be moved under the camera, so PiP ends and the window is entered as any window is.
    private func returnFromPip(_ p: WindowProxy) {
        guard !handingOff, let f = p.drawnPip else { return }
        guard renderer == .realWindows else {
            endPip(p)
            return handoff(to: p)
        }
        if !realWindowListReady { listNow() }
        view.cancelPipFlight(p)
        handingOff = true
        endShowDesktop(flyBack: false)
        handoffTarget = p
        Log.note("Handoff: → \(p.appName) — \(p.title), from its tile")
        closeSwitcher(clearHighlight: true)
        p.refresh(seam: true)
        stopStreams(of: p.pid)
        if p.ax == nil {
            p.ax = AXWindow.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame)
            if p.ax == nil { Log.note("Handoff: no AX window for \(p.appName) — Accessibility granted?") }
        }
        p.ax?.raise(); raiseAttachedChildren(of: p)
        let rect = PictureInPicture.returnRect(f, size: p.worldRect.size, visible: visibleTopLeft, scale: scale)
        let destination = toGlobal(rect.origin)
        let duration = TimeInterval(PictureInPicture.Reference.enterResponse)
        shadowFlight = (p.windowID, CACurrentMediaTime(), duration)
        updatePipChrome()   // flying: no chrome over the way out
        let complete: () -> Void = { [weak self] in
            guard let self, self.handoffTarget === p, self.renderer == .realWindows else {
                p.pipShown = nil
                self?.view.pipChanged(p)
                self?.letGo(p)
                return
            }
            p.heldBack = false
            self.parkedOffScreen.removeValue(forKey: p.windowID)
            let shadow = LiveWindowsWire.shadow(p.windowID, inactiveWeight: 1, activeWeight: 1)
            self.shadowFlight = nil
            // Its own corners back, just before the handoff lands it at 1:1 (the requests go in order).
            if self.sentPipRadius[p.windowID] != nil { self.sendPipShape(p.windowID, radius: 0) }
            // Nothing is kept on show around it: the camera isn't at 1:1, so nothing else is where it would be.
            guard self.realWindows.restore(handoff: (p.windowID, destination),
                                           overlay: CGWindowID(self.window.windowNumber),
                                           backdrop: self.backdrop.map { CGWindowID($0.windowNumber) } ?? 0,
                                           shadow: shadow,
                                           keeping: [],
                                           top: self.toGlobal(CGPoint(x: 0, y: self.visibleTopLeft.minY)).y,
                                           pinned: self.pipIDs(except: p)) else {
                self.handingOff = false
                self.handoffTarget = nil
                p.pipShown = nil
                self.view.pipChanged(p)
                self.fallBackFromRealWindows("Could not restore the entered window (\(self.realWindows.lastRestoreFailure ?? "?"))")
                return
            }
            let listed = self.snapshot()
            self.realWindowsPresented = false
            let landed = listed[p.windowID] ?? p.ax?.frame ?? CGRect(origin: destination, size: p.worldRect.size)
            self.enter(p, realFrame: landed, activateApp: true)
        }
        view.flyPip(p, to: PipFrame(origin: rect.origin, scale: 1), response: PictureInPicture.Reference.enterResponse,
                    damping: PictureInPicture.Reference.enterDamping, completion: complete)
    }

    /// A four-finger release favours a neighbour in the direction of travel; other gestures
    /// use the nearby snap. Both use the same placement plan as handoff.
    private func snapToWindow(pan: (Camera, CGVector)? = nil, requireCenterInside: Bool = false,
                              releaseStart: Camera? = nil) -> Bool {
        guard (Settings.snapToWindows || pan != nil), !handingOff, NSApp.isActive, activeProxy == nil, switcher == nil,
              !isShowingDesktop, addingWidgets == nil, !isSetupShowing else { return false }
        let windows = view.proxies.filter { $0.kind == .window && $0.away == nil && !$0.leaving && $0.pip == nil }
        let visible = visibleTopLeft
        let spots = windows.map { p -> WindowSnap.Window in
            // Where `handoff` puts it, centred: the same spot, so the handoff after the nudge doesn't move.
            let spot = Handoff.plan(.centered, rect: p.worldRect, camera: view.camera, visible: visible, scale: scale,
                                    tiledArea: tiledArea(of: p)).origin
            return WindowSnap.Window(rect: p.worldRect, spot: spot)
        }
        let strength: WindowSnap.Strength = Settings.windowSnapStrength == .normal ? .normal : .strong
        let sensitivity = CGFloat(Settings.windowCenteringSensitivity)
        let preferred = lastActiveProxy.flatMap { active in windows.firstIndex { $0 === active } }
        let selected: (index: Int, camera: Camera, directional: Bool)?
        if requireCenterInside {
            selected = WindowSnap.releaseTarget(camera: view.camera, viewSize: view.bounds.size, visible: visible,
                                                windows: spots, strength: strength, sensitivity: sensitivity,
                                                panStart: releaseStart, direction: pan?.1, preferredIndex: preferred,
                                                allowFallback: Settings.snapToWindows)
        } else {
            selected = WindowSnap.target(camera: view.camera, viewSize: view.bounds.size, visible: visible,
                                         windows: spots, strength: strength, sensitivity: sensitivity)
                .map { ($0.index, $0.camera, false) }
        }
        guard let hit = selected else { return false }
        let p = windows[hit.index]
        Log.note("Snap: onto \(p.appName) — \(p.title)")
        if hit.directional {
            handoff(to: p)
            return true
        }
        view.snap(to: hit.camera) { [weak self, weak p] in
            guard let self, let p, self.proxies[p.windowID] === p else { return }
            self.handoff(to: p)
        }
        return true
    }

    /// The windows that stay on show as `p` is entered with live windows: every other window the view
    /// shows at 1:1 now, the camera having arrived, bottom to top, with the screen rect each is drawn at
    /// (pixel-aligned), which is where it goes natively. They stay in front of the canvas under the
    /// entered window, real windows to be used as they are; a click on one enters it where it is (its
    /// app activates, `foreignActivation`). Windows out of view are left out, put back under the
    /// backdrop as before, and so are parked ones, which are out of view by definition; but for the
    /// entered app's own, which go off screen.
    private func keptOnShow(entering p: WindowProxy) -> [(proxy: WindowProxy, at: CGRect)] {
        let camera = view.camera
        guard abs(camera.zoom - 1) < 0.001 else { return [] }
        let screenRect = CGRect(origin: .zero, size: view.bounds.size)
        var kept: [(proxy: WindowProxy, at: CGRect)] = []
        for q in view.proxies where q !== p && q.kind == .window && q.away == nil && q.pip == nil && lastWantedIDs.contains(q.windowID) {
            let r = camera.toScreen(q.worldRect.insetBy(dx: -q.inset, dy: -q.inset))
            // The app's other windows too, out of view or not: its activation raises them all, and natively
            // they could be anywhere (one Accessibility can't see yet, just made, never moved): this puts
            // them where the canvas has them, off screen if that's out of view, in the handoff's one update.
            guard q.pid == p.pid || (r.intersects(screenRect) && !r.intersection(screenRect).isEmpty) else { continue }
            // Where the canvas draws it: the add-on keeps the native place under the menu bar itself
            // (sunlight-28) and draws the window there from it.
            kept.append((q, CGRect(origin: nativeOrigin(of: q, at: camera, clamped: false), size: r.size)))
        }
        return Array(kept.suffix(LiveWindowsWire.maxKept))
    }

    // MARK: Using a window at 1:1

    /// A press on a window at 1:1, on its way to the real window: held until the window is entered, then
    /// posted where it was made, the release with it if that came first.
    private struct PassedPress {
        let windowID: CGWindowID
        let location: CGPoint   // global, top-left origin, as CGEvent has it
        let clickState: Int64
        var posted = false
        var released = false
    }
    private var passedPress: PassedPress?

    /// At 1:1 the window on the canvas is the real one, so a press on it is the window's own: it's entered
    /// where it is (nothing moves) and the press goes on to it, as a click on an inactive window does on
    /// the desktop.
    private func use(_ p: WindowProxy, around point: CGPoint, press: NSEvent) {
        passedPress = nil
        guard let cg = press.cgEvent else { return handoff(to: p, placement: .inPlace(around: point)) }
        passedPress = PassedPress(windowID: p.windowID, location: cg.location,
                                  clickState: cg.getIntegerValueField(.mouseEventClickState))
        handoff(to: p, placement: .inPlace(around: point))
        if handoffTarget !== p, activeProxy !== p { passedPress = nil }   // another handoff was under way
    }

    /// What follows of a passed-on press while it still comes to the canvas: before the window is entered
    /// only the release counts; after, the window server may keep sending the drag here, so it's passed on too.
    private func followPress(_ event: NSEvent) {
        guard var press = passedPress else { return }
        let up = event.type == .leftMouseUp
        if !press.posted {
            if up { press.released = true }
            passedPress = press
            return
        }
        guard let location = event.cgEvent?.location else { return }
        postMouse(up ? .leftMouseUp : .leftMouseDragged, at: location, clickState: press.clickState)
        if up { passedPress = nil }
    }

    /// Posts the press once the app is in front, so it lands as a click in an active window, not the click
    /// that activates it (which many apps swallow). Half a second at most: an app that won't come forward
    /// gets the press anyway.
    private func deliver(_ press: PassedPress, to pid: pid_t) {
        whenFrontmost(pid) { [weak self] in self?.post(press) }
    }

    /// Runs `then` once `pid` is the frontmost app, or after half a second regardless.
    private func whenFrontmost(_ pid: pid_t, waited: TimeInterval = 0, then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, waited < 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.whenFrontmost(pid, waited: waited + 0.01, then: then)
            }
            return
        }
        then()
    }

    private func post(_ press: PassedPress) {
        guard var current = passedPress, current.windowID == press.windowID, !current.posted else { return }
        postMouse(.leftMouseDown, at: current.location, clickState: current.clickState)
        if current.released {
            postMouse(.leftMouseUp, at: current.location, clickState: current.clickState)
            passedPress = nil
        } else {
            current.posted = true
            passedPress = current
        }
    }

    private func postMouse(_ type: CGEventType, at location: CGPoint, clickState: Int64) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState)
        e.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
        e.post(tap: .cghidEventTap)
    }

    /// A scroll over a window at 1:1, on its way to the real window: what comes before the window is
    /// entered waits, then all of it goes, and what follows goes straight on.
    private struct PassedScroll {
        let windowID: CGWindowID
        let pid: pid_t
        var waiting: [CGEvent]
        var delivered = false
    }
    private var passedScroll: PassedScroll?

    /// At 1:1 a scroll over a window is the window's, as on the desktop: it's entered where it is and the
    /// scroll goes on to it.
    private func useScroll(_ p: WindowProxy, around point: CGPoint, scroll: NSEvent) {
        passedScroll = nil
        guard let cg = scroll.cgEvent?.copy() else { return view.endScrollingOn() }
        passedScroll = PassedScroll(windowID: p.windowID, pid: p.pid, waiting: [cg])
        handoff(to: p, placement: .inPlace(around: point))
        if handoffTarget !== p, activeProxy !== p {   // another handoff was under way
            passedScroll = nil
            view.endScrollingOn()
        }
    }

    private func followScroll(_ event: NSEvent) {
        guard var scroll = passedScroll, let cg = event.cgEvent?.copy() else { return }
        if scroll.delivered {
            postScroll(cg, to: scroll)
        } else {
            scroll.waiting.append(cg)
            passedScroll = scroll
        }
    }

    private func deliverScroll(to windowID: CGWindowID) {
        guard var scroll = passedScroll, scroll.windowID == windowID, !scroll.delivered else { return }
        for e in scroll.waiting { postScroll(e, to: scroll) }
        scroll.waiting = []
        scroll.delivered = true
        passedScroll = scroll
    }

    /// Straight to the app, addressed to the window: the window server may still be sending the gesture
    /// to the canvas, which started it, so a copy posted for it to route could come back here.
    private func postScroll(_ e: CGEvent, to scroll: PassedScroll) {
        e.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(scroll.windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(scroll.windowID))
        e.postToPid(scroll.pid)
    }

    // MARK: Shadows at the seam

    /// This tick's shadow request for the window being flown into: its inactive look eased over the
    /// flight's duration, to the active look in full at the seam.
    private var flightShadow: Data? {
        guard let f = shadowFlight, handoffTarget?.windowID == f.id else { return nil }
        let t = Float(min(1, max(0, (CACurrentMediaTime() - f.start) / f.duration)))
        return LiveWindowsWire.shadow(f.id, inactiveWeight: t * t * (3 - 2 * t), activeWeight: 1)
    }

    /// The window's standard pair of looks again, once the other look is the one shown: after the
    /// activation has landed at a seam (`entered`: no frame follows, the lease is given up), and once the
    /// canvas is in front after easing back.
    private func restoreShadowLooks(of id: CGWindowID, entered: Bool) {
        guard renderer == .realWindows else { return }
        realWindows.ease(shadows: [LiveWindowsWire.shadow(id, inactiveWeight: 0, activeWeight: 1)], interval: 0, releasing: entered) {}
    }

    /// A handoff whose camera is already where it's going (a press at 1:1): just long enough for the frames
    /// the seam needs.
    private static let stayingDuration: CFTimeInterval = 0.05

    /// Every window on screen as the window server has it right now, read against `camera` (the view's
    /// camera unless given): the one source native frames come from on the live canvas, so no two
    /// readings disagree by a fraction, and no frame is read against a camera other than the one it
    /// belongs with (`FrameSnapshot`). About a millisecond, on the main thread.
    private func snapshot(at camera: Camera? = nil) -> FrameSnapshot {
        FrameSnapshot(list: Watchdog.during("the window list (WindowList.onScreen)") { WindowList.queue.sync { WindowList.onScreen() } },
                      camera: global(camera ?? view.camera))
    }

    /// Where a window sits natively when the canvas is at `camera`, in global points: its canvas place
    /// through the camera, to the pixel, and no higher than the menu bar lets it (`Handoff.nativeOrigin`).
    /// The one answer for the seam, the windows kept on show, the entered app's siblings and the check below.
    private func nativeOrigin(of p: WindowProxy, at camera: Camera, clamped: Bool = true) -> CGPoint {
        toGlobal(Handoff.nativeOrigin(of: CGPoint(x: p.worldRect.minX - p.inset, y: p.worldRect.minY - p.inset),
                                      at: camera, scale: scale, top: visibleTopLeft.minY, clamped: clamped))
    }

    /// The invariant a seam has to leave true: each of these windows sits natively where the canvas
    /// draws it at the snapshot's camera, so that nothing reading native frames back later (the listing,
    /// the return) finds a move the user never made. A miss is logged with both places, so a drift shows
    /// up in the log on the first switch rather than in a screen recording.
    private func checkPlacement(of windows: [WindowProxy], in snapshot: FrameSnapshot, at moment: String) {
        let camera = snapshot.camera.inView(viewOrigin: display.origin)
        for q in windows where q.kind == .window && q.away == nil {
            guard let native = snapshot[q.windowID] else { continue }
            // The listing's bounds are drawn ones: the canvas place as sent, clamped only for the entered
            // window (its native place, where it is drawn); a kept window above the menu bar is drawn at
            // its place from a native one under it (sunlight-28).
            let expected = nativeOrigin(of: q, at: camera, clamped: q === activeProxy || q === handoffTarget)
            let dx = native.minX - expected.x, dy = native.minY - expected.y
            guard abs(dx) > 1 || abs(dy) > 1 else { continue }
            Log.note("Placement: \(q.appName) — \(q.title) is (\(Int(dx.rounded())), \(Int(dy.rounded()))) pt off its canvas place at the \(moment): natively (\(Int(native.minX)), \(Int(native.minY))), canvas (\(Int(expected.x)), \(Int(expected.y)))")
        }
    }

    /// The sheets and prompts on a window being entered, raised after it so they end up in front of it
    /// as the app had them (a raise makes the window its app's front one). Accessibility may not see a
    /// prompt at all; the seam's window order (`handoff`) covers that in live mode.
    private func raiseAttachedChildren(of p: WindowProxy) {
        for c in p.attachedChildren where c.away == nil && proxies[c.windowID] === c {
            if c.ax == nil { c.ax = AXWindow.find(windowID: c.windowID, pid: c.pid, approximateFrame: c.lastRealFrame) }
            c.ax?.raise()
        }
    }

    /// The same for the live canvas, on the Accessibility queue: the window found (if it never was) and
    /// raised, its sheets and prompts after it, and the handles kept once they're back on main.
    private func raiseForHandoff(_ p: WindowProxy) {
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax, name = p.appName
        let children = p.attachedChildren.filter { $0.away == nil && proxies[$0.windowID] === $0 }
            .map { (id: $0.windowID, pid: $0.pid, approx: $0.lastRealFrame, known: $0.ax) }
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            ax?.raise()
            var found: [(CGWindowID, AXWindow)] = []
            for c in children {
                let child = c.known ?? AXWindow.find(windowID: c.id, pid: c.pid, approximateFrame: c.approx)
                child?.raise()
                if c.known == nil, let child { found.append((c.id, child)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if ax == nil, known == nil { Log.note("Handoff: no AX window for \(name) — Accessibility granted?") }
                    if let p = self.proxies[id], p.ax == nil { p.ax = ax }
                    for (childID, child) in found { if let c = self.proxies[childID], c.ax == nil { c.ax = child } }
                }
            }
        }
    }

    /// The entered window's app's other windows, moved natively to where they are on the canvas at the
    /// camera it's entered at, before the app is activated: activating it brings all its windows forward,
    /// and one left where it last was natively (in the middle of the screen, where it was in use) showed
    /// up behind the window just entered. Out of view they go off screen, as far as macOS lets them, and
    /// their native place keeps following the canvas, so nothing that reads it back (the listing, ⌘`)
    /// moves them on it. The ones kept on show (`except`) are already where they're drawn.
    private func alignSiblings(of p: WindowProxy, except kept: Set<CGWindowID>) {
        guard renderer == .realWindows, abs(view.camera.zoom - 1) < 0.001 else { return }
        let camera = view.camera
        for q in proxies.values where q.pid == p.pid && q !== p && q.kind == .window && q.away == nil && q.pip == nil
            && !kept.contains(q.windowID) && lastWantedIDs.contains(q.windowID) {   // a tile of its app stays as it is
            // The add-on's stock move needs no word from the app (`moveNativelyNow` asks it only where
            // the add-on isn't answering): asked first, at the seam, for every sibling, the app's
            // handle and full-screen state were two round trips a window on the main thread.
            let origin = nativeOrigin(of: q, at: camera, clamped: clampsNatively)
            guard hypot(origin.x - q.lastRealFrame.minX, origin.y - q.lastRealFrame.minY) > 1 else { continue }
            if !moveNativelyNow(q, to: origin) { continue }
            q.placedNatively(at: CGRect(origin: origin, size: q.lastRealFrame.size))
            Log.note("Handoff: \(q.appName) — \(q.title) natively to its place on the canvas, \(q.lastRealFrame.integral.origin)")
        }
    }

    /// The 1:1 camera at which the proxy sits exactly where the real window is on screen.
    private func cameraAligning(_ p: WindowProxy, with real: CGRect) -> Camera {
        Handoff.cameraAligning(p.worldRect, with: toView(real))
    }

    /// The moment a real window is in front of the canvas, pixel-matched to its proxy. Shared by the
    /// canvas-initiated handoff (which activates the app) and takeover's absorb (the app is already active).
    private func enter(_ p: WindowProxy, realFrame: CGRect, activateApp: Bool) {
        clearLaunches()   // the user chose a window; a launch still in flight is then absorbed as before
        activeProxy = p
        lastActiveProxy = p
        handingOff = false
        handoffTarget = nil
        enteredCamera = view.camera
        if p.pip == nil { lastOneToOne = view.camera }   // a return from a tile leaves the camera where it was, zoomed out or not
        scheduleCapturePass()
        p.hovered = false
        p.placedNatively(at: realFrame)
        mru.removeAll { $0 == p.windowID }
        if p.attachedTo == nil { mru.insert(p.windowID, at: 0) }
        // Its app is in front: from now until the canvas reads them back, its windows are the user's to move.
        for q in proxies.values where q.pid == p.pid { q.owner = .user }
        arrivedAt[p.windowID] = nil
        passOnHeldKeys(entering: p)
        desk?.entered(from: self)
        // Activating an app raises *all* its windows; every seam needs our shadow off, and no stream.
        for q in proxies.values where q.pid == p.pid { q.revealed = true }
        stopStreams(of: p.pid)

        wantsFrontUntil = 0   // the canvas yields on purpose: nothing brings it back but the user
        if activateApp {
            if renderer != .realWindows { p.ax?.raise(); raiseAttachedChildren(of: p) }   // live: raised when the handoff began
            if let app = NSRunningApplication(processIdentifier: p.pid) {
                expectActivation(of: p.pid)
                // Cooperative activation: we're frontmost, so we're allowed to yield to the target app.
                let yielded = app.activate(from: .current, options: [])
                let forced = yielded ? true : app.activate(options: [])
                // Neither taken (Sunlight isn't the front app, so it has nothing to yield: a window
                // entered by ⌘Tab while another was in use where it's drawn): the way that can't be refused.
                let carbon = forced ? noErr : forceAppFront(p.pid)
                Log.note("Handoff: activate \(p.appName) — yielded \(yielded), fallback \(forced)\(forced ? "" : ", SetFrontProcess \(carbon == noErr ? "ok" : "failed (\(carbon))")"), we were active: \(NSApp.isActive)")
            }
        }

        if let press = passedPress {
            if press.windowID == p.windowID { deliver(press, to: p.pid) } else { passedPress = nil }
        }
        if let scroll = passedScroll {
            if scroll.windowID == p.windowID {
                whenFrontmost(p.pid) { [weak self] in self?.deliverScroll(to: scroll.windowID) }
            } else {
                passedScroll = nil
                view.endScrollingOn()
            }
        }

        if let env {
            env.watcher.observe(pid: p.pid, window: p.ax?.element)
            env.keyTap.update(entered: true)
            readGreenButton(of: p)
            updateNewWindowKey(for: p.pid)
            startEnteredTimer()
        }
        if springDrag {
            window.ignoresMouseEvents = true
            Log.note("Desktop: the canvas steps aside for the drop into \(p.appName)")
        }
    }

    private func expectActivation(of pid: pid_t, attempt: Int = 0) {
        expectedActivationPID = pid
        expectedActivationTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.expectedActivationPID == pid else { return }
            // Dragged files hold the activation back until they're dropped (`fileDragEnded`).
            if self.springDrag {
                self.expectActivation(of: pid, attempt: attempt)
                return
            }
            self.expectedActivationPID = 0
            // Still in front half a second later: the app refused to activate. Once more first: an app
            // raised by name a moment ago (Spotlight) and still opening a window of its own missed the
            // first activation. Then undo the handoff state.
            if NSApp.isActive, let p = self.activeProxy, p.pid == pid {
                if attempt == 0, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                    Log.note("Handoff: \(p.appName) hasn't come to the front — asking once more")
                    if !app.activate(options: []) { _ = forceAppFront(pid) }
                    self.expectActivation(of: pid, attempt: 1)
                    return
                }
                Log.note("Handoff: \(p.appName) did not activate — rolling back")
                self.leaveEntered(reconcile: false)
                self.applyPendingSwitcher()   // ⌘Tab pressed meanwhile was waiting for the canvas
            }
        }
        expectedActivationTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Leaves the entered state without bringing the canvas forward (another app took over, or a
    /// handoff failed). The proxy re-anchors to wherever the real window is now. Streams aren't
    /// restarted here: the app's windows may well still be in front of the canvas (they stay above it
    /// when another app takes over). The next sync, with the canvas in front, restarts them.
    private func leaveEntered(reconcile: Bool) {
        stopEnteredTimer()
        env?.keyTap.update(entered: false)
        guard let p = activeProxy else { return }
        activeProxy = nil
        for q in proxies.values where q.pid == p.pid { q.revealed = false }
        guard reconcile else { enteredCamera = nil; return scheduleCapturePass() }
        // The windows are read against the camera they were placed at, not the camera now: the canvas
        // may already be on its way somewhere else (See All zooming out), and a frame read against that
        // camera lands the window where it never was. Read now, before anything else moves.
        let placedAt = enteredCamera ?? view.camera
        enteredCamera = nil
        if !placedAt.isClose(to: view.camera) {
            Log.note("Placement: the canvas is back at a camera other than the one \(p.appName) was entered at (zoom \(view.camera.zoom) at (\(Int(view.camera.origin.x)), \(Int(view.camera.origin.y))) vs 1 at (\(Int(placedAt.origin.x)), \(Int(placedAt.origin.y)))); its windows are read at the entry camera")
        }
        // On the live canvas the window server is the one source of native frames, as in the listing;
        // Accessibility only when there's no listing to read (capture mode), or it has no entry for the
        // window (Calendar's, at times, has none either way). The snapshot is taken at the entry camera,
        // so every frame in it is read against the camera the windows were placed at.
        let live = renderer == .realWindows
        let listed = live || p.ax == nil ? snapshot(at: placedAt) : FrameSnapshot(frames: [:], camera: global(placedAt))
        let frame = live ? listed[p.windowID] ?? p.ax?.frame : p.ax?.frame ?? listed[p.windowID]
        if let resting = p.pip {
            // A tile, returned to 1:1 and used there (or a window that asked to become one, `beginPendingPip`):
            // its home on the canvas stands, whatever the camera. It shrinks from where it is into its corner.
            if let f = frame, FrameSnapshot.hasSize(f) {
                p.placedNatively(at: f)
                if NSApp.isActive {
                    p.pipShown = PipFrame(origin: toView(f.origin), scale: 1)
                    view.pipChanged(p)
                    view.flyPip(p, to: resting, response: PictureInPicture.Reference.enterResponse,
                                damping: PictureInPicture.Reference.enterDamping) { [weak self, weak p] in
                        guard let self, let p else { return }
                        p.pipShown = nil
                        self.view.pipChanged(p)
                    }
                } else {
                    view.pipChanged(p)
                }
            }
            for q in proxies.values where q.pid == p.pid { q.owner = .canvas }
            scheduleCapturePass()
            return
        }
        if let f = frame, FrameSnapshot.hasSize(f) {
            if let other = desk?.canvas(holding: f), other !== self {
                // Moved to another display while in use: it lives on that display's canvas from now.
                desk?.move(p.windowID, from: self, to: other)
            } else {
                // Wherever the real window is now is where it lives on the canvas (the user may have moved it).
                let before = p.worldRect.origin
                p.movedByUser(to: f, seenThrough: listed.camera)
                movedForReal(p, from: before)
                noteAttachmentOffset(p)
            }
        }
        if live {
            // Its app's other windows likewise; the listing then has nothing of this app's left to read.
            for q in proxies.values where q.pid == p.pid && q !== p && q.kind == .window && q.away == nil && q.pip == nil {
                guard let f = listed[q.windowID], FrameSnapshot.hasSize(f), !f.isClose(to: q.lastRealFrame), !q.sizeHeld else { continue }
                let before = q.worldRect.origin
                q.movedByUser(to: f, seenThrough: listed.camera)
                movedForReal(q, from: before)
                noteAttachmentOffset(q)
            }
        }
        // Read back: the canvas owns every place of the app's again.
        for q in proxies.values where q.pid == p.pid { q.owner = .canvas }
        scheduleCapturePass()
    }

    private func returnedToCanvas() {
        Log.note("Sunlight: active (was in \(activeProxy.map { "\($0.appName) — \($0.title)" } ?? "nothing"))")
        let wasIn = activeProxy
        if let id = shadowEasedBack {
            shadowEasedBack = nil
            restoreShadowLooks(of: id, entered: false)
        }
        clearPending()
        passedScroll = nil
        view.endScrollingOn()
        env?.watcher.stopObserving()
        beginPendingPip(leaving: wasIn)
        leaveEntered(reconcile: true)
        applyPendingPip()
        desktopFloor.noteReturn()
        // Strip mode: the window you were in, and its app's column, go to the left end of the strip. The
        // camera moves with it, so it stays where it is on screen and the strip rearranges around it. Not
        // while something asked from the window is about to move the camera (the switcher, a pan, Show
        // Desktop, a ⌃⌥ arrow step): the strip keeps its order for that, and reorders on the next return.
        if Settings.stripMode, pendingSwitcherMoves.isEmpty, !pendingSwitcherCommit, pendingPan == nil,
           !pendingShowDesktop, pendingPlacement == nil {
            layoutStrip(animated: true, following: wasIn)
        }
        applyPendingSwitcher()
        if let pending = pendingPan {
            pendingPan = nil
            view.trackpadPan(by: pending.travel, preservingVelocity: pending.velocity)
            if pendingPanEnded {
                pendingPanEnded = false
                view.trackpadPanEnded(releaseVelocity: pending.releaseVelocity)
            }
        }
        if pendingShowDesktop {
            pendingShowDesktop = false
            beginShowDesktop()
        }
        scheduleDiff()   // fits everything afterwards if asked to (`pendingFitAll`)
    }

    /// The display's visible part (below the menu bar, beside the Dock) in view coordinates.
    private var visibleTopLeft: CGRect { display.visibleInView }

    /// The display's visible part in the world: where it is at 1:1, the camera at home.
    private var homeVisible: CGRect { display.visible }

    /// The camera that shows the display at 1:1, the world where the screen is.
    private var homeCamera: Camera { .home(viewOrigin: display.origin) }

    /// The camera as seen from global coordinates: what real windows, Accessibility, posted events and the
    /// Dock add-on go through. The view's own camera on the primary display.
    private var globalCamera: Camera { global(view.camera) }

    private func global(_ camera: Camera) -> Camera { camera.global(viewOrigin: display.origin) }

    /// View point or rect to global, and back.
    private func toGlobal(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + display.origin.x, y: p.y + display.origin.y) }
    private func toGlobal(_ r: CGRect) -> CGRect { r.offsetBy(dx: display.origin.x, dy: display.origin.y) }
    private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - display.origin.x, y: p.y - display.origin.y) }
    private func toView(_ r: CGRect) -> CGRect { r.offsetBy(dx: -display.origin.x, dy: -display.origin.y) }

    // MARK: Capture policy

    /// Runs the capture pass soon: coalesced to one per run-loop turn at no delay (a scroll gesture
    /// asks many times a frame), or at the earliest of the delays asked for.
    func scheduleCapturePass(after delay: TimeInterval = 0) {
        if delay > 0 {
            if let t = passTimer, t.isValid, t.fireDate.timeIntervalSinceNow <= delay { return }
            passTimer?.invalidate()
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.capturePass() }
            }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            passTimer = t
            return
        }
        guard !passScheduled else { return }
        passScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.passScheduled = false
                self.capturePass()
            }
        }
    }

    /// Levels of detail: half-octave steps, so the texture is never more than √2 larger than the proxy
    /// on screen (linear minification stays clean) and a full zoom range costs nine steps, not many.
    static let maxLevel = 8
    static func factor(forLevel k: Int) -> CGFloat { pow(2, -CGFloat(k) / 2) }
    /// A small proxy doesn't need 30 frames a second to look live.
    static func fps(forLevel k: Int) -> Int32 { k <= 3 ? 30 : k <= 6 ? 15 : 10 }

    /// At most this many windows stream at once. Each stream holds a pool of frames the size of the
    /// window at the zoom (tens of MB for a large window at half size) and is work for the window server
    /// on every change; beyond a handful, the windows drawn largest are the ones worth it, and the rest
    /// are stills renewed by the refresh timer. Widgets don't count: they're small and always stream.
    /// None at all without screen capture mode or preview mode (`Settings.capturesStream`): the capture
    /// renderer is then only the stand-in while live windows come back, and every window and widget is a
    /// still.
    static var maxStreams: Int { Settings.capturesStream ? 8 : 0 }
    /// A streaming window keeps its stream against a newcomer until the newcomer is this much larger on
    /// screen, so a pan doesn't stop and start streams back and forth.
    static let streamHysteresis: CGFloat = 1.5

    /// Which of the windows that want a stream get one: all of them up to `maxStreams`, else the largest
    /// on screen, streaming ones favoured. While the camera moves, no new stream starts for a window
    /// that was capped (starting a stream is the expensive part); they're ranked again once it rests.
    static func streamed(_ candidates: [(id: ObjectIdentifier, area: CGFloat, streaming: Bool, capped: Bool)],
                         moving: Bool, limit: Int) -> Set<ObjectIdentifier> {
        guard candidates.count > limit else { return Set(candidates.map(\.id)) }
        let ranked = candidates
            .filter { !(moving && $0.capped && !$0.streaming) }
            .sorted { ($0.streaming ? $0.area * streamHysteresis : $0.area) > ($1.streaming ? $1.area * streamHysteresis : $1.area) }
        return Set(ranked.prefix(limit).map(\.id))
    }

    /// The level a zoom asks for, with hysteresis: more detail the moment the zoom crosses a step (a
    /// texture must never be smaller than the proxy), less only once it is 15 % past the step down.
    static func level(forZoom zoom: CGFloat, current: Int) -> Int {
        let up = min(maxLevel, max(0, Int(floor(-2 * log2(zoom)))))
        let down = min(maxLevel, max(0, Int(floor(-2 * log2(zoom / 0.85)))))
        if up < current { return up }
        if down > current { return down }
        return current
    }

    /// The one place streams start, stop and change detail. From the camera (and where it is going),
    /// who is in front, and what can be seen, it decides for every proxy:
    ///
    /// * **In front** (its app entered, being handed off to, or absorbed): no stream; the pill would show.
    /// * **Out of sight** (past a wide margin around the viewport for a while, under the entered
    ///   window, or the canvas itself hidden): a quarter-size stream at 2 fps, stopped after 30 s.
    /// * **In sight**: a stream sized to the zoom, so a window drawn small is captured small.
    ///
    /// Changes that depend only on time (a level settling, a proxy drifting out of sight) re-arm the
    /// pass for when they are due, so they land without the camera having to move again.
    private func capturePass() {
        passTimer?.invalidate()
        passTimer = nil
        guard !configuringRenderer else { return }
        if renderer == .realWindows {
            updateRealWindows()
            streamWidgets()
            return
        }
        let now = CACurrentMediaTime()
        let camera = view.camera
        let target = view.targetCamera
        var due: CFTimeInterval?
        func wake(at t: CFTimeInterval) { due = min(due ?? t, t) }

        // The level is one number for every stream: world units are real points, so every proxy is
        // drawn at `zoom` times its real size. More detail comes at once when the camera is on its way
        // somewhere (the handoff target must be sharp at the seam), else once a gesture pauses; less
        // detail waits for the camera to rest.
        if camera != lod.lastCamera {
            lod.lastCamera = camera
            lod.lastCameraChange = now
        }
        let wanted = CanvasController.level(forZoom: max(camera.zoom, target?.zoom ?? 0), current: lod.applied)
        if wanted != lod.wanted {
            lod.wanted = wanted
            lod.wantedSince = now
        }
        if wanted != lod.applied {
            let at: CFTimeInterval = wanted < lod.applied
                ? (target != nil ? now : min(lod.lastCameraChange + 0.1, lod.wantedSince + 0.3))
                : lod.lastCameraChange + 0.5
            if at <= now { lod.applied = wanted } else { wake(at: at) }
        }

        // Whose windows are in front of the canvas, or about to be. With the canvas not active, the
        // frontmost app's are, whoever brought it there.
        var frontPIDs = Set<pid_t>()
        if let p = activeProxy { frontPIDs.insert(p.pid) }
        if let p = handoffTarget { frontPIDs.insert(p.pid) }
        if pendingAbsorbPID != 0 { frontPIDs.insert(pendingAbsorbPID) }
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != myPID {
            frontPIDs.insert(front)
        }
        // Streams start only with the canvas in front (a previously entered app's windows stay above
        // it when another app takes over); widgets are below every window, so theirs always can.
        let canStart = NSApp.isActive && activeProxy == nil && !asleep

        let size = view.bounds.size
        let enterRect = CGRect(origin: .zero, size: size).insetBy(dx: -size.width * 0.25, dy: -size.height * 0.25)
        let leaveRect = CGRect(origin: .zero, size: size).insetBy(dx: -size.width * 0.5, dy: -size.height * 0.5)
        let cover = activeProxy.map { camera.toScreen($0.worldRect) }   // under the real window: unseen

        // First where everything is: in front, or how far from the viewport.
        for p in view.proxies {
            if p.kind == .window && frontPIDs.contains(p.pid) {
                p.inFront = true
                continue
            }
            p.inFront = false

            // In sight the moment it nears the viewport (now, or where the flight ends); out only after
            // a while past a wider margin, so a pan back and forth doesn't flap.
            let r = camera.toScreen(p.worldRect)
            let rt = target.map { $0.toScreen(p.worldRect) }
            let seen = !canvasOccluded && !asleep && !(cover?.contains(r) ?? false)
            let near = seen && (r.intersects(enterRect) || rt?.intersects(enterRect) == true)
            let within = seen && (r.intersects(leaveRect) || rt?.intersects(leaveRect) == true)
            switch p.viewport {
            case .active:
                if !within { p.viewport = .leaving(since: now) }
            case .leaving(let since):
                if near { p.viewport = .active }
                else if now - since >= 0.4 { p.viewport = .far(since: now) }
                else { wake(at: since + 0.4) }
            case .far(let since):
                if near { p.viewport = .active }
                else if within { p.viewport = .leaving(since: now) }
                else if p.kind == .window, p.isStreaming, now - since < 30 { wake(at: since + 30) }
            }
        }

        // Then which of the windows in sight may stream. A window counts by the part of it on screen;
        // one the camera is flying to counts at its size there.
        let viewRect = CGRect(origin: .zero, size: size)
        let moving = target != nil || now - lod.lastCameraChange < 0.3
        func onScreen(_ r: CGRect) -> CGFloat {
            let v = r.intersection(viewRect)
            return v.isNull ? 0 : v.width * v.height
        }
        let candidates = view.proxies.compactMap { p -> (id: ObjectIdentifier, area: CGFloat, streaming: Bool, capped: Bool)? in
            guard p.kind == .window, !p.inFront else { return nil }
            if case .far = p.viewport { return nil }
            let area = max(onScreen(camera.toScreen(p.worldRect)), target.map { onScreen($0.toScreen(p.worldRect)) } ?? 0)
            return (ObjectIdentifier(p), area, p.isStreaming, p.capped)
        }
        let mayStream = CanvasController.streamed(candidates, moving: moving, limit: CanvasController.maxStreams)
        let streams = Settings.capturesStream
        if moving, candidates.count > CanvasController.maxStreams { wake(at: lod.lastCameraChange + 0.3) }

        var streaming = 0, far = 0, front = 0, capped = 0
        for p in view.proxies {
            if p.inFront {
                p.capped = false
                p.stopCapture()
                front += 1
                continue
            }
            let k = min(lod.applied, p.maxCaptureLevel)
            var level = WindowCapture.Level(factor: CanvasController.factor(forLevel: k), fps: CanvasController.fps(forLevel: k))
            var stop = asleep
            var isFar = false
            if case .far(let since) = p.viewport {
                far += 1
                isFar = true
                level = WindowCapture.Level(factor: min(level.factor, 0.25), fps: 2)
                if p.kind == .window, now - since >= 30 { stop = true }
            }
            let wasCapped = p.capped
            p.capped = !stop && !isFar && (p.kind == .window || !streams) && !mayStream.contains(ObjectIdentifier(p))
            if p.capped {
                // A still instead: the stream's last frame stays up, and one fresh one is taken now.
                p.stopCapture()
                if !wasCapped || !p.hasFrame, canStart { p.refresh() }
                capped += 1
            } else if stop || !streams {
                // Without live capture, a window far off the viewport keeps the last still it had.
                p.stopCapture()
            } else if p.isStreaming {
                p.setCaptureLevel(level)
            } else if canStart || (p.kind == .widget && !asleep) {
                p.startCapture(level: level)
                if !p.isStreaming { wake(at: p.retryAfter) }   // backing off after a failure
            }
            if p.isStreaming { streaming += 1 }
        }

        let summary = "Capture: \(view.proxies.count) proxies, \(streaming) streaming at level \(lod.applied) (×\(String(format: "%.3f", CanvasController.factor(forLevel: lod.applied)))), \(capped) stills, \(far) far, \(front) in front\(asleep ? ", asleep" : "")\(canvasOccluded ? ", canvas hidden" : "")"
        if summary != lastCaptureSummary {
            lastCaptureSummary = summary
            Log.note(summary)
        }
        if let due { scheduleCapturePass(after: max(0.01, due - now)) }
        ensureRefreshTimer()
    }

    // MARK: Launches that stay on the canvas

    /// A window of the app is expected behind the canvas: look for it sooner than the 1 s listing, and
    /// answer the app's own activations meanwhile by bringing the canvas back.
    private func expectArrival(of app: NSRunningApplication, name: String? = nil) {
        let name = name ?? app.localizedName ?? "pid \(app.processIdentifier)"
        launches[app.processIdentifier] = Launch(name: name, deadline: Date().addingTimeInterval(CanvasController.launchWait))
        resync(after: [0.3, 1, 2])
        guard launchTimer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.launchTick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        launchTimer = t
    }

    /// The app came to the front while the canvas was up, with no window the canvas knows: a launch. The
    /// canvas comes straight back, so the window lands behind it, and the listing pops it onto the canvas
    /// at the current zoom — the camera stays where the user left it.
    private func keepOnCanvas(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "pid \(app.processIdentifier)"
        Log.note("Launch: \(name) opens on the canvas")
        expectArrival(of: app, name: name)
        show()
    }

    /// Four times a second while a launch is in flight: its first window on the canvas marks it arrived
    /// (and a moment later it's an app like any other, so a Dock click enters it); the canvas is brought
    /// back if the app took the front; and the listing is asked for the window sooner than every second.
    private func launchTick() {
        let now = Date()
        for (pid, var l) in launches {
            if l.arrived == nil, proxies.values.contains(where: { $0.pid == pid && $0.kind == .window }) {
                l.arrived = now
                launches[pid] = l
                Log.note("Launch: \(l.name) is on the canvas")
            }
            if l.arrived == nil, now >= l.deadline {
                Log.note("Launch: \(l.name) showed no window for the canvas in \(Int(CanvasController.launchWait)) s — no longer held behind it")
                if !NSApp.isActive { liftWindows(of: pid) }
                windowlessApps.insert(pid)
                launches[pid] = nil
            } else if now >= l.deadline || l.arrived.map({ now >= $0.addingTimeInterval(CanvasController.launchSettle) }) == true {
                launches[pid] = nil
            }
        }
        guard !launches.isEmpty else {
            clearLaunches()
            return
        }
        guard activeProxy == nil else { return }   // the user entered something meanwhile: leave it
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, launches[front] != nil {
            show()   // the launching app took the front again
        } else if NSApp.isActive, launches.values.contains(where: { $0.arrived == nil }) {
            scheduleDiff()
        }
    }

    private func clearLaunches() {
        launches = [:]
        launchTimer?.invalidate()
        launchTimer = nil
    }

    // MARK: New windows in front

    /// When each window that opened in front of the canvas (from inside a window, or with another app in
    /// front) showed up. It's placed as it's taken in (`placeInFront`) if that's soon after. Ones that open
    /// with the canvas in front are placed as they arrive (`placeNewWindows`).
    private var arrivedAt: [CGWindowID: CFTimeInterval] = [:]
    /// How long after it showed up a window still counts as just opened.
    static let arrivalWindow: CFTimeInterval = 3

    private func noteArrived(_ created: [WindowProxy]) {
        let now = CACurrentMediaTime()
        arrivedAt = arrivedAt.filter { now - $0.value < CanvasController.arrivalWindow }
        for p in created where p.kind == .window { arrivedAt[p.windowID] = now }
    }

    /// Whether `p` just opened and hasn't been placed or entered since. Asking takes the answer: it's
    /// placed once.
    private func takeArrival(_ p: WindowProxy) -> Bool {
        guard let t = arrivedAt.removeValue(forKey: p.windowID) else { return false }
        return CACurrentMediaTime() - t < CanvasController.arrivalWindow
    }

    /// The window used last, if it's on screen at the current camera: what a window opened from inside
    /// it stays near.
    private var lastInView: WindowProxy? {
        guard let p = lastActiveProxy, proxies[p.windowID] === p,
              view.camera.toWorld(visibleTopLeft).intersects(p.worldRect) else { return nil }
        return p
    }

    /// A window that just opened in front at 1:1 (a link that opens one, an app opened from inside a
    /// window; ⌘N is caught before it, `newWindowBeside`), with windows pushing each other: it doesn't
    /// stay on top of the ones it covers (`NewWindowSpot.inFront`). The canvas comes forward with it at
    /// the free spot nearest `near` and enters it there: where it is on screen if the spot is on screen,
    /// otherwise going over to it. `real`: its frame on screen. True when the canvas takes it: the
    /// caller then doesn't enter it.
    private func placeInFront(_ p: WindowProxy, real: CGRect, near: WindowProxy?) -> Bool {
        // On its way there already (its app focusing it meanwhile): the canvas enters it.
        if heldKeys?.windowID == p.windowID { return true }
        // Not while the canvas presents the live windows: their native frames aren't where they're drawn.
        // The arrival is taken last: a placement put off for a moment (a handoff ending) is still to come.
        guard Settings.magnetism, !Settings.stripMode, p.standsAlone, restoring == nil,
              addingWidgets == nil, !handingOff, !(renderer == .realWindows && realWindowsPresented),
              abs(view.camera.zoom - 1) < 0.001, takeArrival(p) else { return false }
        let camera = view.camera
        let opened = CGRect(origin: camera.toWorld(toView(real).origin), size: real.size)
        let others = (view.proxies.filter { $0.standsAlone && $0 !== p } + Array(away.values)).map(\.worldRect)
        let target = near.flatMap { $0 === p ? nil : CGPoint(x: $0.worldRect.midX, y: $0.worldRect.midY) }
            ?? CGPoint(x: opened.midX, y: opened.midY)
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        let spot: CGRect, onScreen: Bool
        switch NewWindowSpot.inFront(opened, avoiding: others, view: camera.toWorld(visibleTopLeft), gap: gap, near: target) {
        case .stay:
            // Where it really is: the listing may have placed the proxy for the canvas meanwhile.
            p.place(at: opened.origin)
            return false
        case .move(let r): (spot, onScreen) = (r, true)
        case .slide(let r): (spot, onScreen) = (r, false)
        }
        // The canvas's from here (its app is in front, but the canvas chose this spot). On the live canvas
        // the real window goes to the spot natively now, the moment it is taken in: it opened over the
        // window in use and sat there, full-size, until the canvas had come forward and gone to the spot
        // with it; moved at once it is at its spot (off the screen, for one the canvas goes over to)
        // within a frame or two of opening, and the canvas then comes forward and goes to it, so the
        // camera arrives at a window that is already there. Where the move can't be made, it glides
        // from where it opened to the spot with the camera instead.
        p.place(at: spot.origin)
        p.layout(zoom: camera.zoom)
        var native = real
        if renderer == .realWindows {
            let origin = nativeOrigin(of: p, at: camera)
            if !NSApp.isActive, additionNumber >= 15 {
                // The canvas is away (a window is in use), so the spot is on the screen at 1x: parked off
                // the screen until the seam, whose transaction moves it to the spot as it lifts it. Moved
                // to the spot now it showed there, full-size beside the window in use, for the 80 ms
                // before the canvas came forward.
                let parked = CGPoint(x: origin.x, y: display.frame.maxY + 4000)
                if moveNativelyNow(p, to: parked) {
                    native.origin = parked
                    parkedOffScreen[p.windowID] = origin
                    Log.note("New window: \(p.appName) — \(p.title) parked off the screen until the seam, spot \(origin)")
                }
            } else if moveNativelyNow(p, to: origin) {
                native.origin = origin
                Log.note("New window: \(p.appName) — \(p.title) natively to its spot at once, \(origin)")
            }
        }
        p.placedNatively(at: native)
        slide(into: p, onScreen: onScreen, from: native.origin == real.origin ? opened.origin : nil)
        return true
    }

    /// A window placed on the live canvas while the canvas is up goes natively to its spot through the
    /// 1:1 camera a window was last entered at (the home camera before any was): where macOS opened it
    /// was over the window in use, and its canvas place is beside it; raised by name later, or entered,
    /// it is then already where the canvas has it. Under the backdrop, so nothing shows.
    private func alignNatively(_ p: WindowProxy) {
        guard renderer == .realWindows, p.kind == .window, p.away == nil else { return }
        let camera = lastOneToOne ?? homeCamera
        let origin = nativeOrigin(of: p, at: camera, clamped: clampsNatively)
        guard hypot(origin.x - p.lastRealFrame.minX, origin.y - p.lastRealFrame.minY) > 1 else { return }
        if moveNativelyNow(p, to: origin) {
            p.placedNatively(at: CGRect(origin: origin, size: p.lastRealFrame.size))
            Log.note("New window: \(p.appName) — \(p.title) natively to its place at the last 1:1 camera, \(origin)")
        }
    }

    /// The real window to `origin` (global), now: through the add-on's stock move, which needs no lease
    /// and is done by the time it returns, or through Accessibility where the add-on isn't answering.
    /// True when it went.
    private func moveNativelyNow(_ p: WindowProxy, to origin: CGPoint) -> Bool {
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) < 1e6, abs(origin.y) < 1e6 else { return false }
        if LiveWindowsConnection.command(LiveWindowsWire.move(p.windowID, x: Int32(origin.x.rounded()), y: Int32(origin.y.rounded()))) {
            return true
        }
        // Only here, with the add-on not answering, is the app asked anything: a native-fullscreen
        // window can't be moved, and finding the window and asking are round trips to the app.
        if p.ax == nil { p.ax = AXWindow.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame) }
        guard let ax = p.ax, !ax.isFullScreen else { return false }
        return ax.setPosition(origin)
    }

    /// The canvas comes forward, the new window already at its spot beside the one in use (which takes
    /// it out from on top of it), and enters it: in place when the spot is on screen, otherwise going over
    /// to it as ⌘Tab to a window off screen would. Keys typed on the way are held for it.
    /// `from`: where the window is drawn now, in the world (where it opened), so that on the live canvas
    /// it glides from there to its spot with the camera's flight rather than jumping to the spot (off the
    /// screen, for one over to it) the moment the canvas comes forward, and sliding in from there.
    /// `known`: a window already on the canvas (brought forward by the Dock, Spotlight, ⌘`), drawn at its
    /// place all the way there rather than held back or gliding in, as a new window is.
    private func slide(into p: WindowProxy, onScreen: Bool, from: CGPoint? = nil, known: Bool = false) {
        Log.note("New window: \(p.appName) — \(p.title) opened over others — to \(p.worldRect.origin)\(onScreen ? ", on screen" : ", over to it")")
        holdKeys(for: p)
        // One sliding in at a time: one before it whose placement this replaces shows where it is.
        if let earlier = slidingIn, earlier !== p { letGo(earlier) }
        slidingIn = p
        // Under the canvas until the pan lands (live windows, sunlight-27): drawn at its spot the moment
        // the canvas came forward, it showed beside the window in use for the frames before the pan.
        // A window the canvas already showed stays drawn where it is: held back, it was missing from its
        // place for the whole pan and showed up only as the camera landed on it.
        p.heldBack = !known && renderer == .realWindows && additionNumber >= 27
        let asked = CACurrentMediaTime()
        // Whatever becomes of the placement (replaced by a tidy or a layout, a handoff already under way,
        // the canvas never coming forward), the window isn't left held back and parked off the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.keyHoldLimit + 0.5) { [weak self, weak p] in
            guard let self, let p, p !== self.handoffTarget, p !== self.activeProxy else { return }
            self.letGo(p)
        }
        pendingPlacement = { [weak self, weak p] in
            guard let self else { return }
            // Only on the way: a canvas that took longer than that to come forward doesn't go there later.
            guard let p, self.proxies[p.windowID] === p,
                  CACurrentMediaTime() - asked < CanvasController.keyHoldLimit else {
                p?.heldBack = false
                if let p { self.unpark(p) }
                return self.dropHeldKeys()
            }
            let gliding = self.renderer == .realWindows && !known ? from : nil
            if onScreen {
                self.handoff(to: p, placement: .inPlace(around: self.view.camera.toScreen(CGPoint(x: p.worldRect.midX, y: p.worldRect.midY))), gliding: gliding)
            } else {
                self.handoff(to: p, placement: .centered, gliding: gliding)
            }
        }
        show()
    }

    /// Whether a window announced with another app in front is the canvas's to take in (`takeInFront`).
    private var takesInFront: Bool { Settings.magnetism && !Settings.stripMode && renderer == .realWindows }

    /// The window server announced a window while one is entered (or while an app opened from inside one
    /// shows its first): a new window of the app in front is taken in at once, not when Accessibility
    /// gets round to saying it's focused, which took up to most of a second while it sat on top. It may
    /// not be on the listing yet: looked for every frame for a moment.
    private func takeInFront(_ id: CGWindowID, until deadline: CFTimeInterval? = nil) {
        guard takesInFront, proxies[id] == nil, away[id] == nil,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              front == activeProxy?.pid || front == pendingAbsorbPID else { return unhideArrival(id) }
        let deadline = deadline ?? CACurrentMediaTime() + CanvasController.arrivalWatch
        // Not listed yet, or listed but still invisible: Chrome puts a new window on screen at alpha 0
        // for a few frames before it shows (public issue #9), and taken as it is, it would fail
        // `isCanvasMaterial` and be lifted above the canvas for good. Looked at again next frame.
        guard let listed = WindowList.onScreen(id), listed.alpha > 0 || CACurrentMediaTime() >= deadline else {
            guard CACurrentMediaTime() < deadline else { return unhideArrival(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                MainActor.assumeIsolated { self?.takeInFront(id, until: deadline) }
            }
            return
        }
        // As the app opened it, if it was hidden at the announcement (`hideArrival`): where it is now is off the screen.
        let hidden = hiddenArrivals.removeValue(forKey: id)
        let real = hidden ?? listed.bounds
        let w = WindowInfo(id: listed.id, pid: listed.pid, layer: listed.layer, bounds: real, title: listed.title, alpha: listed.alpha)
        guard w.pid == front, isCanvasMaterial(w), (desk?.canvas(forWindow: w.id, frame: w.bounds) ?? self) === self else {
            if hidden != nil { moveWindowNow(id, to: real.origin) }
            liftIfFront(id)
            return
        }
        let near = activeProxy ?? lastInView
        let p = register(WindowProxy(info: w, camera: globalCamera, scale: scale))
        proxies[id] = p
        view.add(p)
        // A sheet or prompt over one of the app's windows stays on it; nothing else moves.
        if attachIfChild(p, native: w.bounds) {
            if hidden != nil { moveWindowNow(id, to: real.origin) }
            liftIfFront(id)   // a sheet or prompt of the entered app shows at once, over it
            return
        }
        noteArrived([p])
        Log.note("New window: \(id) (\(p.appName)) taken in as it was announced\(hidden != nil ? ", hidden since" : "")")
        if placeInFront(p, real: w.bounds, near: near) {
            if pendingAbsorbPID == w.pid { clearPending() }
        } else {
            if hidden != nil { moveWindowNow(id, to: real.origin) }   // staying where the app opened it after all
            liftIfFront(id)
        }
    }

    /// A window of the app in front, born under the canvas (sunlight-27), lifted above it at once by the
    /// add-on, where the app put it. Nothing for an older add-on, which leaves the canvas under the apps.
    private func liftIfFront(_ id: CGWindowID) {
        // Only the entered app's: another app's first window (a launch by name, with the absorb still
        // on its way) stays hidden until the canvas has placed it, else it popped up full-size.
        guard renderer == .realWindows, additionNumber >= 27, !NSApp.isActive,
              let w = WindowList.onScreen(id), w.layer == 0, let entered = activeProxy, w.pid == entered.pid else { return }
        LiveWindowsConnection.command(LiveWindowsWire.level(id, LiveWindowsWire.frontLevel))
    }

    /// The window entered where it is (`adopt`) and the sheets and prompts on it, lifted above the canvas at
    /// once (sunlight-27); its app's other windows stay under the canvas, where they were, as after a handoff.
    private func liftWindow(_ p: WindowProxy) {
        guard renderer == .realWindows, additionNumber >= 27 else { return }
        for q in [p] + p.attachedChildren where q.away == nil {
            LiveWindowsConnection.command(LiveWindowsWire.level(q.windowID, LiveWindowsWire.frontLevel))
        }
    }

    /// Every on-screen window of `pid` at the normal level lifted above the canvas at once (sunlight-27): an
    /// app left in front with nothing for the canvas shows all of its windows.
    private func liftWindows(of pid: pid_t) {
        guard renderer == .realWindows, additionNumber >= 27, pid != myPID else { return }
        for w in WindowList.onScreen() where w.pid == pid && w.layer == 0 {
            LiveWindowsConnection.command(LiveWindowsWire.level(w.id, LiveWindowsWire.frontLevel))
        }
    }

    /// Other apps' windows found at the canvas's own levels (sunlight-27's `canvasLevel`, `frontLevel`)
    /// as live mode starts: left there by a Sunlight that quit without putting them back (a crash, a
    /// build swapped out mid-switch), they sat above everything, and the canvas never took them in,
    /// as it only takes windows at the normal level. Back to the normal level, where the listing sees
    /// them. Only at the start: later, windows at those levels are the canvas's own doing.
    private func lowerStrays() {
        // Once per launch: later, and from a second display's canvas, windows at those levels are the
        // canvases' own doing (a window entered on the other display).
        guard additionNumber >= 27, !CanvasController.straysLowered else { return }
        CanvasController.straysLowered = true
        var lowered: [String] = []
        for w in WindowList.onScreen() where (w.layer == Int(LiveWindowsWire.canvasLevel) || w.layer == Int(LiveWindowsWire.frontLevel) || w.layer == Int(LiveWindowsWire.pinnedLevel))
            && w.pid != myPID && bundleID(of: w.pid) != Bundle.main.bundleIdentifier {
            if LiveWindowsConnection.command(LiveWindowsWire.level(w.id, 0)) { lowered.append("\(w.id) (\(NSRunningApplication(processIdentifier: w.pid)?.localizedName ?? "pid \(w.pid)"))") }
        }
        if !lowered.isEmpty { Log.note("Rendering: \(lowered.count) window(s) left at the canvas's levels put back to the normal level: \(lowered.joined(separator: ", "))") }
    }

    private static var straysLowered = false

    /// The window `slide(into:)` last held back, until it is entered or let go.
    private weak var slidingIn: WindowProxy?

    /// A window held back and parked for a slide that won't happen (`slide(into:)`): drawn on the canvas
    /// again, and natively at its spot.
    private func letGo(_ p: WindowProxy) {
        if slidingIn === p { slidingIn = nil }
        guard p.heldBack || parkedOffScreen[p.windowID] != nil else { return }
        p.heldBack = false
        unpark(p)
    }

    /// This canvas's windows on show above it (the entered one and the ones kept with it, at the front
    /// level since sunlight-27), back to the normal level as live mode ends here (a fall back to capture,
    /// a quit): no lease holds them any more, so nothing else would, and they stayed above every window.
    private func lowerOnShow() {
        guard additionNumber >= 27 else { return }
        for w in WindowList.onScreen() where (w.layer == Int(LiveWindowsWire.frontLevel) || w.layer == Int(LiveWindowsWire.pinnedLevel)) && proxies[w.id] != nil {
            LiveWindowsConnection.command(LiveWindowsWire.level(w.id, 0))
        }
    }

    /// Windows hidden the instant the window server announced them (`hideArrival`), by their bounds then.
    private var hiddenArrivals: [CGWindowID: CGRect] = [:]

    /// New windows parked off the screen (`placeInFront`) until the seam moves them to their spot, by it.
    private var parkedOffScreen: [CGWindowID: CGPoint] = [:]

    /// A parked window the seam won't be moving after all (the canvas never came forward): to its spot
    /// natively now, and on show where the app in front is its own.
    private func unpark(_ p: WindowProxy) {
        guard let spot = parkedOffScreen.removeValue(forKey: p.windowID) else { return }
        if moveNativelyNow(p, to: spot) {
            p.placedNatively(at: CGRect(origin: spot, size: p.lastRealFrame.size))
            Log.note("New window: \(p.appName) — \(p.title) unparked to its spot, \(spot)")
        }
        liftIfFront(p.windowID)
    }

    /// A window of the app in front, announced while the canvas is away, goes off the screen at once,
    /// through the add-on's stock move, before its first composite where it can be helped: as the app
    /// opened it, it sat over the window in use for a frame (its shadow at least) until the canvas had
    /// listed it and taken it to its spot. Its bounds are kept for the take-in, and a window not taken
    /// after all goes back where it was.
    private func hideArrival(_ id: CGWindowID) {
        guard renderer == .realWindows, hiddenArrivals[id] == nil, proxies[id] == nil, away[id] == nil,
              let w = WindowList.onScreen(id), isCanvasMaterial(w),
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, w.pid == front,
              moveWindowNow(id, to: CGPoint(x: w.bounds.minX, y: display.frame.maxY + 4000)) else { return }
        hiddenArrivals[id] = w.bounds
    }

    private func unhideArrival(_ id: CGWindowID) {
        guard let b = hiddenArrivals.removeValue(forKey: id) else { return }
        moveWindowNow(id, to: b.origin)
        liftIfFront(id)
    }

    /// A window to `origin` (global), natively, through the add-on's stock move. True when it went.
    @discardableResult
    private func moveWindowNow(_ id: CGWindowID, to origin: CGPoint) -> Bool {
        LiveWindowsConnection.command(LiveWindowsWire.move(id, x: Int32(origin.x.rounded()), y: Int32(origin.y.rounded())))
    }

    /// Keys typed while the canvas goes over to a new window (`slide(into:)`), for that window.
    /// No window: the next one of the app's that's entered (⌘N's, not made yet when the keys came).
    private var heldKeys: (windowID: CGWindowID?, pid: pid_t, events: [CGEvent])?
    /// The longest keys are held: a slide that never lands (the user went elsewhere) lets them go.
    static let keyHoldLimit: TimeInterval = 3

    private func holdKeys(for p: WindowProxy) { holdKeys(window: p.windowID, pid: p.pid) }

    private func holdKeys(window id: CGWindowID?, pid: pid_t, for limit: TimeInterval = CanvasController.keyHoldLimit) {
        heldKeys = (id, pid, [])
        holdKeysGeneration += 1
        let generation = holdKeysGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.heldKeys != nil, self.holdKeysGeneration == generation { self.dropHeldKeys() }
            }
        }
    }

    /// Which hold a drop timer belongs to: a second ⌘N's hold isn't let go by the first one's timer.
    private var holdKeysGeneration = 0

    private func dropHeldKeys() {
        if let n = heldKeys?.events.count, n > 0 { Log.note("New window: \(n) key event(s) held for it dropped") }
        heldKeys = nil
    }

    /// The canvas view's keys while some are held: kept, in order, not acted on.
    private func holdKey(_ event: NSEvent) -> Bool {
        guard heldKeys != nil, let e = event.cgEvent?.copy() else { return false }
        heldKeys?.events.append(e)
        return true
    }

    /// A window is entered: if keys were held for it, they go on to it once its app is in front;
    /// held for another, they're dropped.
    private func passOnHeldKeys(entering p: WindowProxy) {
        guard let held = heldKeys else { return }
        heldKeys = nil
        guard held.windowID.map({ $0 == p.windowID }) ?? (held.pid == p.pid) else {
            if !held.events.isEmpty { Log.note("New window: \(held.events.count) key event(s) held for it dropped") }
            return
        }
        guard !held.events.isEmpty else { return }
        Log.note("New window: \(held.events.count) key event(s) typed on the way passed on to \(p.appName)")
        whenFrontmost(held.pid) {
            for e in held.events {
                e.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
                e.postToPid(held.pid)
            }
        }
    }

    // MARK: ⌘N inside a window

    /// Whether each app's ⌘N made a window (`NewWindowMenu.commandNMakesWindow`) when last asked.
    private var commandNMakesWindow: [pid_t: Bool] = [:]

    /// Tells the key tap whether ⌘N in the window just entered is the canvas's (`newWindowBeside`). The
    /// app's menu is read off the main thread each time; until the first answer ⌘N goes to the app as ever.
    private func updateNewWindowKey(for pid: pid_t) {
        guard let env else { return }
        guard Settings.magnetism, !Settings.stripMode else { return env.keyTap.update(placesNewWindow: false) }
        // What it was last time at once, then asked again: a menu can change (a sheet up disables New Window).
        env.keyTap.update(placesNewWindow: commandNMakesWindow[pid] ?? false)
        AXQueue.background.async { [weak self] in
            let makes = NewWindowMenu.commandNMakesWindow(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let before = self.commandNMakesWindow.updateValue(makes, forKey: pid)
                    if before != makes { Log.note("New window: pid \(pid)'s ⌘N \(makes ? "makes a window — the canvas places it" : "isn't a window's — left to the app")") }
                    if self.activeProxy?.pid == pid { self.env?.keyTap.update(placesNewWindow: makes) }
                }
            }
        }
    }

    /// ⌘N in a window whose app's ⌘N makes a window, with windows pushing each other (the key tap kept
    /// the key for this): the canvas comes forward and goes to the free spot beside the window first,
    /// and only then asks the app for the window, through that same ⌘N item. Made with the canvas in
    /// front, the window is born behind it, pops in at the spot (`openingHere`) and is entered; keys
    /// typed meanwhile are held for it. If none comes, it's back into the window it was asked from.
    private func newWindowBeside() {
        guard let a = activeProxy, placesNewWindows, a.kind == .window else { return passOnCommandN() }
        let middle = spotBeside(a)
        Log.note("New window: ⌘N in \(a.appName) — \(a.title); over to \(middle) first")
        let pid = a.pid
        holdKeys(window: nil, pid: pid)
        let asked = CACurrentMediaTime()
        pendingPlacement = { [weak self, weak a] in
            guard let self else { return }
            guard let a, CACurrentMediaTime() - asked < CanvasController.keyHoldLimit else { return self.dropHeldKeys() }
            self.openBeside(a, at: middle)
        }
        show()
    }

    /// Whether the canvas places windows that open from inside a window itself (`newWindowBeside`,
    /// `openFromWindow`): with windows pushing each other, and nothing else laying the canvas out.
    private var placesNewWindows: Bool {
        Settings.magnetism && !Settings.stripMode && restoring == nil && addingWidgets == nil && !handingOff
    }

    /// The free spot beside `a` for a window the size of `a` (a new window's size isn't known until it's
    /// made: most apps make it the size of their last one): its middle, in the world.
    private func spotBeside(_ a: WindowProxy) -> CGPoint {
        let others = (view.proxies.filter { $0.kind == .window } + Array(away.values)).map(\.worldRect)
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        let spot = NewWindowSpot.spot(size: a.worldRect.size, avoiding: others, view: view.camera.toWorld(visibleTopLeft),
                                      gap: gap, target: CGPoint(x: a.worldRect.midX, y: a.worldRect.midY))
        return CGPoint(x: spot.midX, y: spot.midY)
    }

    /// The camera, at the zoom it has, with `middle` (world) in the middle of the visible area.
    private func camera(centring middle: CGPoint) -> Camera {
        var target = view.camera
        let visible = visibleTopLeft
        target.origin = CGPoint(x: middle.x - visible.midX / target.zoom, y: middle.y - visible.midY / target.zoom)
        return target
    }

    /// Launching, or launched a moment ago: its first window may still be on its way.
    private func isLaunching(_ app: NSRunningApplication) -> Bool {
        !app.isFinishedLaunching || app.launchDate.map { Date().timeIntervalSince($0) < 2 } ?? true
    }

    /// Whether any window of the app is on this canvas, in view or away.
    func hasWindows(of pid: pid_t) -> Bool {
        (Array(proxies.values) + Array(away.values)).contains { $0.pid == pid && $0.kind == .window }
    }

    /// The canvas's Desktop is in front again after a full-screen app's Space, with `app` in front: the
    /// app left full screen (its window is on its way back to its place here, and is entered there, as
    /// any window its app brings forward is), or the person stepped back with ⌃← and the app is still
    /// the front one. Asked a moment later, once the window has landed: Accessibility still says full
    /// screen while macOS animates it back.
    /// Only for an app with a window coming back from full screen (being pulled back, or away in full
    /// screen): after ⌃← the app macOS puts in front is otherwise left as it is.
    func leftFullScreenSpace(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPID, !NSApp.isActive, pid != activeProxy?.pid,
              away.values.contains(where: { $0.pid == pid && $0.away == .fullScreen })
                || pullingBack.contains(where: { (proxies[$0] ?? away[$0])?.pid == pid }) else { return }
        whenOutOfFullScreen(app, tries: 10)
    }

    /// `foreignActivation` for `app` once its focused window has left full screen (Accessibility says so
    /// up to a second after the Space changed, while macOS animates it home): asked every quarter second.
    private func whenOutOfFullScreen(_ app: NSRunningApplication, tries: Int) {
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !NSApp.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      pid != self.activeProxy?.pid else { return }
                AXQueue.interactive.async { [weak self] in
                    let still = AXWindow.focusedWindow(pid: pid)?.isFullScreen == true
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if still, tries > 1 { return self.whenOutOfFullScreen(app, tries: tries - 1) }
                            guard !still else { return }
                            Log.note("Full screen: back on the canvas's Desktop with \(app.localizedName ?? "pid \(pid)") in front")
                            if self.pendingAbsorbPID == pid { self.clearPending() }
                            self.foreignActivation(app)
                        }
                    }
                }
            }
        }
    }

    /// An app launched from inside a window, with no window yet (its Dock icon, Spotlight, Launchpad): one
    /// is on its way. With windows pushing each other, the canvas comes forward first
    /// and goes to the free spot beside the window it was in, so the app's window is made behind the canvas,
    /// pops in there and is entered (`openingHere`), as ⌘N's is (`newWindowBeside`). None in a moment
    /// (an app with nothing to show): back into the window it came from.
    private func openFromWindow(_ app: NSRunningApplication, from: WindowProxy) {
        let pid = app.processIdentifier
        let middle = spotBeside(from)
        let name = app.localizedName ?? from.appName
        Log.note("New window: \(name) came forward from \(from.appName) with no window yet; over to \(middle) first")
        holdKeys(window: nil, pid: pid, for: CanvasController.launchWait)
        let known = Set((Array(proxies.values) + Array(away.values)).filter { $0.pid == pid }.map(\.windowID))
        openingHere = OpenHere(name: name, bundleID: app.bundleIdentifier, pid: pid, spot: middle, enter: true, known: known,
                               deadline: Date().addingTimeInterval(CanvasController.launchWait), returnTo: from)
        // Its taking the front again as the window shows brings the canvas straight back (`foreignActivation`).
        expectArrival(of: app, name: name)
        let wait = isLaunching(app) ? CanvasController.launchWait : CanvasController.openHereNewWindowWait
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.openHereFallback(pid: pid) }
        }
        let asked = CACurrentMediaTime()
        pendingPlacement = { [weak self] in
            guard let self, CACurrentMediaTime() - asked < CanvasController.launchWait,
                  self.openingHere?.pid == pid, self.openingHere?.placedAt == nil else { return }
            self.view.animateCamera(to: self.camera(centring: middle))
        }
        show()
    }

    /// The canvas is in front: the camera goes to `middle` (world), then the app is asked for its window.
    private func openBeside(_ from: WindowProxy, at middle: CGPoint) {
        let pid = from.pid
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return dropHeldKeys() }
        view.animateCamera(to: camera(centring: middle)) { [weak self] in
            guard let self, NSApp.isActive, self.activeProxy == nil else { return self?.dropHeldKeys() ?? () }
            let known = Set((Array(self.proxies.values) + Array(self.away.values)).filter { $0.pid == pid }.map(\.windowID))
            self.openingHere = OpenHere(name: from.appName, bundleID: running.bundleIdentifier, pid: pid, spot: middle,
                                        enter: true, known: known, deadline: Date().addingTimeInterval(CanvasController.launchWait),
                                        returnTo: from)
            AXQueue.interactive.async { [weak self] in
                let pressed = NewWindowMenu.press(pid: pid, pick: NewWindowMenu.windowCommandN)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.openingHere?.pid == pid, self.openingHere?.placedAt == nil else { return }
                        guard pressed else { return self.openHereFallback(pid: pid) }
                        self.expectArrival(of: running, name: from.appName)
                        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasController.openHereNewWindowWait) { [weak self] in
                            MainActor.assumeIsolated { self?.openHereFallback(pid: pid) }
                        }
                    }
                }
            }
        }
    }

    /// ⌘N the key tap kept for the canvas, when the canvas can't do it after all: on to the app in front.
    private func passOnCommandN() {
        guard let pid = activeProxy?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != myPID else { return }
        for down in [true, false] {
            // 45: the N key.
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: down) else { continue }
            e.flags = .maskCommand
            e.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(("n" as Unicode.Scalar).value)])
            e.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
            e.postToPid(pid)
        }
    }

    // MARK: Takeover — absorbing activations that happened outside the canvas

    /// The Dock icon of the app in front clicked while the canvas is up over it: its windows used
    /// where they're drawn (a click into one at a zoom, focus following the pointer), the app has the
    /// front with the canvas still up, so macOS has no activation to report and the click went
    /// nowhere; the camera stayed where it was. It is taken as the activation it would have been from
    /// anywhere else: over to the app's window.
    func dockClickOnFrontApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPID, activeProxy == nil, !paused, hasWindows(of: pid) else { return }
        Log.note("Dock: \(app.localizedName ?? "pid \(pid)") clicked in the Dock while in front over the canvas — over to its window")
        foreignActivation(app, dockClick: true)
    }

    /// `dockClick`: the user clicked the app's Dock icon (`dockClickOnFrontApp`), whatever was closed,
    /// asked or hovered just before.
    func foreignActivation(_ app: NSRunningApplication, dockClick: Bool = false) {
        let pid = app.processIdentifier
        guard pid != myPID else { return }   // our own: `returnedToCanvas` handles it
        // Its windows become the user's to move only once one is entered (`enter`), not here: an app
        // sent straight back, or one the canvas goes over to, was never used, and its windows marked
        // the user's had their native frames read back by the next listing, through whatever camera
        // the canvas was at, which moved their canvas places onto one another until a drag by hand
        // made them the canvas's again.
        if pid == expectedActivationPID {
            expectedActivationPID = 0
            expectedActivationTimeout?.cancel()
            if let p = activeProxy, p.pid == pid { restoreShadowLooks(of: p.windowID, entered: true) }
            return
        }
        guard let env, app.activationPolicy == .regular, Date() >= env.ignoreActivationsUntil else { return }
        // A click on the desktop while adding widgets activates Finder; that's part of editing them.
        // With setup up, the System Settings a step opened is meant to be in front.
        guard addingWidgets == nil, !isSetupShowing else { return }
        // A window just closed from the canvas: its app (or the next one macOS picks) coming forward isn't
        // the user going anywhere; the canvas stays as it was, camera and all.
        // Not with the pointer on the Dock: that's the user clicking an app there, close or no close.
        if activeProxy == nil, Date() < quietAfterCloseUntil, !dockClick, !WindowList.pointerOverDock() {
            Log.note("Close: \(app.localizedName ?? "pid \(pid)") came forward after the close — the canvas stays")
            show()
            return
        }
        // An app whose window a Desktop merge just brought over (`Spaces.fold`): macOS brings it forward as
        // the window arrives. The window is placed on the canvas like any new one, and not entered.
        if activeProxy == nil, Spaces.justFolded(pid) {
            Log.note("Spaces: \(app.localizedName ?? "pid \(pid)") came forward as its window came over from another Desktop — the canvas stays")
            show()
            return
        }
        // An app a layout restore opened, activating itself as it launches: its windows belong behind the
        // canvas, and the restore brings the canvas back in front.
        if let restoring, let id = app.bundleIdentifier, restoring.apps.contains(id) { return }
        // A launch being kept on the canvas came to the front again (apps activate themselves as their
        // first window appears): straight back, as for a restore.
        if activeProxy == nil, let launch = launches[pid], Date() < launch.deadline {
            Log.note("Launch: \(launch.name) came to the front as it launched — bringing the canvas back")
            show()
            return
        }
        guard pid != activeProxy?.pid, pid != pendingAbsorbPID else { return }
        // A click in a window used where it's drawn (`usingScaledWindow`) brought its app forward: the
        // canvas stays as it is, and nothing is entered.
        // Only this activation counts, not having used the app that way earlier: brought forward by a
        // Dock click, Spotlight or the app itself, it's a way over to its window like any other app's,
        // and the canvas goes there. (Kept while any app used where it's drawn had the front, the Dock
        // click went nowhere; so did one with the pointer still taken for the window behind the Dock.)
        if activeProxy == nil, !dockClick, isScaledUseActivation(pid) {
            usedScaledPIDs.insert(pid)
            wantsFrontUntil = 0   // the canvas stays up behind the app, by design; nothing brings it forward
            Log.note("Scaled use: \(app.localizedName ?? "pid \(pid)") came forward from its window on the canvas — the canvas stays")
            reassertCanvasOver(usedScaledApp: pid)
            return
        }
        usedScaledPIDs.remove(pid)

        let onCanvas = activeProxy == nil   // before `leaveEntered` clears it
        view.cancelAnimation()   // also clears `handingOff`, so a stale handoff can't land later
        closeSwitcher(clearHighlight: true)
        // The user went to this app: whatever was waiting for the canvas to come forward (a pan, Show
        // Desktop, See All, a placement, the wish for the front itself) is off, or it would bring the
        // canvas back over the app the moment it was in front.
        dropPendingCanvasWork()
        leaveEntered(reconcile: true)
        // The app's focused window, asked off the main thread: an app slow to answer Accessibility
        // (one still launching, one that is busy) held up the canvas here. What comes back is used only
        // if nothing else has activated meanwhile (`enteredTick` asks again for a missed one).
        foreignGeneration += 1
        let generation = foreignGeneration
        AXQueue.interactive.async { [weak self] in
            let focused = AXWindow.focusedWindow(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.foreignGeneration,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.absorbForeign(app, focused: focused, onCanvas: onCanvas)
                }
            }
        }
    }

    private var foreignGeneration = 0

    /// Everything waiting on the canvas coming forward, dropped: the user is going somewhere else.
    private func dropPendingCanvasWork() {
        wantsFrontUntil = 0
        pendingPan = nil
        pendingShowDesktop = false
        pendingFitAll = false
        pendingPlacement = nil
    }

    /// From the canvas, an app whose focused window the canvas doesn't know is a launch (or a running
    /// app's new window): it stays on the canvas. One it knows is entered where it is. From inside a
    /// window, the new window is entered either way, at 1:1 — that is the current scale there.
    private func absorbForeign(_ app: NSRunningApplication, focused: AXWindow?, onCanvas: Bool) {
        let pid = app.processIdentifier
        if let focused, let id = focused.windowID, let other = desk?.canvas(forWindow: id, frame: focused.frame), other !== self {
            other.absorbForeign(app, focused: focused, onCanvas: onCanvas)
            return
        }
        // A tile's app brought forward through the tile (a click on it while the canvas is away: a video
        // paused, a call answered): it's used where it is, in its corner; nothing moves.
        if let id = focused?.windowID, let p = proxies[id], p.pip != nil {
            Log.note("Absorb: \(p.appName) — \(p.title) is in Picture in Picture; used at its tile")
            stepDownForForeignApp()
            return
        }
        // Accessibility names no window the canvas can go to — none at all (an app busy or slow to answer:
        // an Electron app takes seconds; one whose focus sits on a panel), or one that could never be on
        // the canvas — though the app has a window the canvas knows in front on the screen: the window
        // server's word is taken instead. The Dock click (⌘Tab, Spotlight) brought the app's windows
        // forward, and the frontmost one of them is the one to go to. Taken for a launch, as it was,
        // the canvas came straight back and the camera never moved; waited on, nothing moved for as
        // long as the app kept quiet.
        if !focusedNamesCanvasWindow(focused), let found = frontKnownWindow(of: pid) {
            Log.note("Absorb: \(app.localizedName ?? "pid \(pid)") names no focused window the canvas can use; \(found.proxy.appName) — \(found.proxy.title) is in front on screen — taking the window server's word")
            if found.proxy.pip != nil {
                Log.note("Absorb: \(found.proxy.appName) — \(found.proxy.title) is in Picture in Picture; used at its tile")
                stepDownForForeignApp()
                return
            }
            if found.canvas !== self {
                clearPending()
                found.canvas.absorbKnown(found.proxy, ax: found.proxy.ax, real: found.info.bounds)
            } else {
                absorbKnown(found.proxy, ax: found.proxy.ax, real: found.info.bounds)
            }
            return
        }
        stepDownForForeignApp()
        // From the canvas, a window taken out of the Dock (its tile clicked, the app's icon) goes back to
        // its place on the canvas, as on any Mac it goes back where it was: the canvas comes straight
        // back, the listing finds the window on screen and puts its proxy back, and the frame scales it
        // in, brought into view if its place isn't (`revealOnReturn`). From inside a window it is
        // entered, as any window brought to the front from there is.
        // The app's focused window may not be readable yet while the Dock is still animating the window
        // out (it is off the screen until then), so with none named a minimized window of the app's
        // counts too — only with none named: an app with a window on the canvas and another in the
        // Dock, its icon clicked, named the one on the canvas, and was sent back to its place instead
        // of entered.
        if onCanvas, let p = focused?.windowID.flatMap({ away[$0] })
            ?? (focused == nil ? away.values.first(where: { $0.pid == pid && $0.away == .minimized }) : nil),
           p.away == .minimized {
            Log.note("Away: \(p.appName) — \(p.title) restored from the Dock; back to its place on the canvas")
            revealOnReturn = p.windowID
            show()
            return
        }
        // A window in macOS's own full screen stays away, on its Space: `absorb` leaves it there.
        let focusedFullScreen = focused?.isFullScreen == true
        let known = focusedFullScreen ? nil : focused?.windowID.flatMap { proxyReturning($0) }
        if onCanvas, known == nil, !focusedFullScreen, mayHoldBehindCanvas(pid: pid, focused: focused) {
            keepOnCanvas(app)
            return
        }
        // From inside a window, an app launching, with no window yet and none on the canvas (one that does
        // have some may just be slow to say which is focused): a window is on its way, and goes beside this
        // one. A running app with no window is just brought forward: it's used from its menus (⌘O) as it is.
        if !onCanvas, focused == nil, isLaunching(app), let from = lastActiveProxy, proxies[from.windowID] === from,
           placesNewWindows, desk?.canvases.contains(where: { $0 !== self && $0.hasWindows(of: pid) }) != true,
           !hasWindows(of: pid) {
            return openFromWindow(app, from: from)
        }
        if let focused { absorb(window: focused) } else { waitForWindow(of: pid) }
    }

    /// Whether an app activated from the canvas, with no window the canvas knows, is a launch to keep
    /// behind it. Not when its focused window is on screen and could never be on the canvas (a panel, an
    /// overlay, an invisible or tiny window), nor when an earlier launch of it never showed one: holding
    /// it there would only take it back from the user every time, as no window ever arrives to end it.
    private func mayHoldBehindCanvas(pid: pid_t, focused: AXWindow?) -> Bool {
        if windowlessApps.contains(pid) {
            guard proxies.values.contains(where: { $0.pid == pid && $0.kind == .window }) else { return false }
            windowlessApps.remove(pid)   // it has a canvas window after all: an app like any other
        }
        guard let id = focused?.windowID, let w = WindowList.onScreen().first(where: { $0.id == id }) else { return true }
        if isCanvasMaterial(w) || isWidget(w) { return true }
        Log.note("Launch: pid \(pid)'s window \(id) isn't one for the canvas — leaving it in front")
        liftWindows(of: pid)
        return false
    }

    /// Whether the window Accessibility names as focused is one the canvas can go to: one it knows (on
    /// any display, in view or away), or one it has never seen that isn't on the screen yet (a new
    /// window on its way) or is and could be on the canvas. A panel, an overlay or an invisible window
    /// named as focused isn't, nor is no window at all.
    private func focusedNamesCanvasWindow(_ focused: AXWindow?) -> Bool {
        guard let id = focused?.windowID else { return false }
        if lookup(id) != nil { return true }
        // Not on the screen yet, or there but still invisible (Chrome shows a new window at alpha 0 for
        // a few frames): a window on its way, waited for as before.
        guard let w = WindowList.onScreen(id), w.alpha > 0 else { return true }
        return isCanvasMaterial(w) || isWidget(w)
    }

    /// The app's frontmost window on the screen that some canvas knows (on it, or away from it and
    /// back on the screen), in the window server's front-to-back order: after a Dock click or ⌘Tab
    /// that is the window the activation brought forward, whatever Accessibility says.
    /// At whatever level the window is just then: the normal one, or one of the canvas's own (the
    /// listing made as the app's windows were lifted over the canvas, sunlight-27).
    private func frontKnownWindow(of pid: pid_t) -> (canvas: CanvasController, proxy: WindowProxy, info: WindowInfo)? {
        for w in WindowList.onScreen() where w.pid == pid && w.alpha > 0 {
            if let found = lookup(w.id), found.proxy.kind == .window { return (found.canvas, found.proxy, w) }
        }
        return nil
    }

    /// A window put back onto the canvas from the Dock (`absorbForeign`), to bring into view as the
    /// listing puts it back (`comeBack`) if its place on the canvas isn't: restored to a place off the
    /// edge of the screen, nothing showed for the click.
    private var revealOnReturn: CGWindowID?

    /// The app is in front but has nothing we can show yet; absorb it as soon as it opens a window.
    /// Never steal activation back here: the user is meant to end up in that window, and one created
    /// while we're active would land below the canvas (from the canvas, `keepOnCanvas` wants just that).
    private func waitForWindow(of pid: pid_t) {
        if pendingAbsorbPID != pid {
            Log.note("Absorb: pid \(pid) has no window yet, waiting")
            pendingSince = CACurrentMediaTime()
        }
        pendingAbsorbPID = pid
        env?.watcher.observe(pid: pid, window: nil)
        takeListedWindow(of: pid)
        // Accessibility notifications don't flow from an app that is still launching; poll as well.
        if pendingTimer == nil { schedulePendingTick() }
    }

    private var pendingSince: CFTimeInterval = 0

    /// Four times a second at first, once a second after 10 s, and not at all after a minute: by then
    /// the observer has long since registered, and an app with no window isn't about to show one.
    private func schedulePendingTick() {
        let waited = CACurrentMediaTime() - pendingSince
        guard waited < 60 else {
            Log.note("Absorb: pid \(pendingAbsorbPID) showed no window in a minute — no longer waiting")
            if !NSApp.isActive { liftWindows(of: pendingAbsorbPID) }
            clearPending()
            return
        }
        let t = Timer.scheduledTimer(withTimeInterval: waited < 10 ? 0.25 : 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTimer = nil
                self.pendingTick()
                if self.pendingAbsorbPID != 0, self.pendingTimer == nil { self.schedulePendingTick() }
            }
        }
        t.tolerance = 0.05
        pendingTimer = t
    }

    private func clearPending() {
        pendingAbsorbPID = 0
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    /// A tick's question to the app is out and not yet answered: the next tick asks nothing. One at a
    /// time, off the main thread: an app that is launching answers Accessibility late or not at all,
    /// and asked four times a second on the main thread it froze the canvas for the whole launch.
    private var pendingAsking = false

    private func pendingTick() {
        let pid = pendingAbsorbPID
        guard pid != 0 else { clearPending(); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            // The user (or we) moved on; stop waiting for this one.
            clearPending()
            return
        }
        guard !pendingAsking else { return }
        pendingAsking = true
        AXQueue.interactive.async { [weak self] in
            let focused = AXWindow.focusedWindow(pid: pid)
            let read = focused.map { AXReading(frame: $0.frame, fullScreen: $0.isFullScreen) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingAsking = false
                    guard self.pendingAbsorbPID == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    if let focused {
                        self.absorb(window: focused, read: read)
                    } else if let found = self.frontKnownWindow(of: pid), found.proxy.pip == nil {
                        // Accessibility still names nothing, and a window the canvas knows is in front on
                        // the screen (one that came up after the activation): the window server's word.
                        Log.note("Absorb: pid \(pid) still names no focused window; \(found.proxy.appName) — \(found.proxy.title) is in front on screen — taking the window server's word")
                        self.clearPending()
                        found.canvas.absorbKnown(found.proxy, ax: found.proxy.ax, real: found.info.bounds)
                    } else {
                        self.takeListedWindow(of: pid)
                    }
                }
            }
        }
    }

    /// The window server's answer when Accessibility has none yet (an Electron app takes seconds to
    /// say which window is focused, sunlight-27): the app's newest window on screen that isn't on the
    /// canvas is taken in as an announced one would be. Born under the canvas, it would otherwise stay
    /// hidden for as long as Accessibility kept quiet.
    private func takeListedWindow(of pid: pid_t) {
        guard renderer == .realWindows, additionNumber >= 27, !NSApp.isActive else { return }
        let fresh = WindowList.onScreen().filter { $0.pid == pid && isCanvasMaterial($0) && proxies[$0.id] == nil && away[$0.id] == nil }
        guard let w = fresh.first else { return }
        Log.note("Absorb: pid \(pid)'s window \(w.id) is on screen though Accessibility names none — taking it in")
        hideArrival(w.id)   // off the screen at once, as at an announcement: it sat over the window in use
        takeInFront(w.id)
    }

    /// What `absorb` needs to know of a window, read off the main thread first (`absorbAfterReading`):
    /// the frame and full-screen state are each a round trip to the app, which may be launching or busy.
    private struct AXReading {
        let frame: CGRect?
        let fullScreen: Bool
    }

    /// `absorb(window:)`, its reads of the app done on the Accessibility queue first, so a slow app holds
    /// up nothing on the main thread. The window is absorbed only if it is still wanted when the reads
    /// come back: the app still waited on, or the entered one.
    private func absorbAfterReading(_ ax: AXWindow) {
        let pid = ax.pid
        AXQueue.interactive.async { [weak self] in
            let read = AXReading(frame: ax.frame, fullScreen: ax.isFullScreen)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pendingAbsorbPID == pid || self.activeProxy?.pid == pid else { return }
                    self.absorb(window: ax, read: read)
                }
            }
        }
    }

    private func absorb(window ax: AXWindow, read: AXReading? = nil) {
        let fullScreen = read?.fullScreen ?? ax.isFullScreen
        let frame: CGRect?
        if let read { frame = read.frame } else { frame = ax.frame }
        // In macOS's own full screen, on a Space of its own: there's nothing to go to on the canvas, and
        // nothing to wait for (waited on, the canvas asked the app four times a second for a minute). Its
        // proxy, if it has one, is away and keeps its place; leaving full screen brings it back
        // (`leftFullScreenSpace`).
        if fullScreen {
            Log.note("Absorb: pid \(ax.pid)'s window is in full screen, on a Space of its own")
            clearPending()
            stepDownForForeignApp()
            if let id = ax.windowID, agentHolds(id) {
                if away[id]?.away == .fullScreen { return }
                if away[id] != nil || proxies[id] !== activeProxy {
                    // Taken back out for Sunlight's full screen (`pullBackFromFullScreen`); left there, it's away.
                    pullBackFromFullScreen(ax, id: id)
                }
            }
            return
        }
        guard let id = ax.windowID, let listedReal = frame else {
            waitForWindow(of: ax.pid)
            return
        }
        var real = listedReal
        // Closed by its app and now in front again, named by it: reopened (Music's window, from the Dock),
        // and back where it was if the canvas had moved it off the screen.
        if let entry = closedByApp.removeValue(forKey: id) {
            Log.note("Closed: window \(id) is in front again, named by its app — taken back")
            if let home = entry.home, bringHome(id, home) { real.origin = home }
        }
        if let other = desk?.canvas(forWindow: id, frame: real), other !== self {
            clearPending()
            other.absorb(window: ax, read: AXReading(frame: real, fullScreen: false))
            return
        }
        if let p = proxyReturning(id) { return absorbKnown(p, ax: ax, real: real) }
        stepDownForForeignApp()
        // A window we've never seen, opened from inside a window (from the canvas it would have been
        // kept there, see `keepOnCanvas`): snap to 1:1 around where the user was looking and put the new
        // proxy under the real window there.
        clearPending()
        let target = Camera(center: view.camera.center(viewSize: view.bounds.size), zoom: 1, viewSize: view.bounds.size)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stillFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == ax.pid }
            guard let p = await self.ensureProxy(windowID: id, pid: ax.pid, camera: target) else {
                if stillFront() { self.waitForWindow(of: ax.pid) }
                return
            }
            // The world may have moved on while we waited.
            guard stillFront(), let real = ax.frame else { return }
            self.view.set(camera: target)
            if self.placeInFront(p, real: real, near: self.lastInView) { return }
            self.adopt(p, ax: ax, real: real)
        }
    }

    /// A window the canvas knows (one it shows, or one away and back on the screen), in front at `real`:
    /// entered where it is, or gone over to. `ax` is the app's handle for it where Accessibility gave
    /// one; the window server's frame stands in for the app's word where it gave none (`frontKnownWindow`),
    /// and the handle is found off the main thread for what later needs it (`fetchHandle`).
    private func absorbKnown(_ p: WindowProxy, ax: AXWindow?, real: CGRect) {
        let p = proxyReturning(p.windowID) ?? p   // one away (hidden, minimized) is back on the canvas first
        stepDownForForeignApp()
        if placeInFront(p, real: real, near: lastInView) { return clearPending() }
        // Brought to the front by name (Spotlight, the Dock) on the live canvas, natively somewhere
        // other than where the canvas has it: windows were never moved natively while on the canvas,
        // so several of them sat stacked where macOS last had them, and entering one there stacked
        // the real ones the same way. Its place on the canvas is the truth: the canvas goes over to
        // it there, the window drawn at its place all the way (`known`), as it was before the click.
        // Likewise one that is where the canvas has it but mostly off the screen (the canvas has it
        // a screen away from the window the user was in): entered where it is, it stayed off the screen.
        let screen = toGlobal(visibleTopLeft)
        let shown = screen.intersection(real)
        let mostlyOff = shown.isNull || shown.width * shown.height < real.width * real.height / 2
        if renderer == .realWindows, placesNewWindows, p.standsAlone, p.kind == .window, !sitsWhereCanvasHasIt(p, real: real) || mostlyOff {
            Log.note("Absorb: \(p.appName) — \(p.title) came up at \(real.integral.origin), \(mostlyOff ? "mostly off the screen" : "not where the canvas has it") — over to it")
            if let ax { p.ax = ax }
            p.owner = .canvas
            clearPending()
            return slide(into: p, onScreen: false, known: true)
        }
        adopt(p, ax: ax, real: real)
    }

    /// The app's handle for an entered window taken in on the window server's word alone, found off the
    /// main thread (the app was slow to answer; it may answer by now) and kept for what needs it: the
    /// watch on its closing, a raise. Nothing waits for it.
    private func fetchHandle(for p: WindowProxy) {
        guard p.ax == nil else { return }
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame
        AXQueue.interactive.async { [weak self] in
            guard let ax = AXWindow.find(windowID: id, pid: pid, approximateFrame: approx) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let q = self.proxies[id] ?? self.away[id], q === p, q.ax == nil else { return }
                    q.ax = ax
                    if self.activeProxy === q { self.env?.watcher.observe(pid: pid, window: ax.element) }
                }
            }
        }
    }

    /// Whether a window in front at 1:1 sits natively where the canvas draws it at the camera now: the
    /// canvas at 1:1 (zoomed out, nothing is where the canvas has it) and the native origin within a
    /// couple of points of the canvas place.
    private func sitsWhereCanvasHasIt(_ p: WindowProxy, real: CGRect) -> Bool {
        guard abs(view.camera.zoom - 1) < 0.001 else { return false }
        let expected = nativeOrigin(of: p, at: view.camera, clamped: clampsNatively)
        return abs(expected.x - real.minX) <= 2 && abs(expected.y - real.minY) <= 2
    }

    private func adopt(_ p: WindowProxy, ax: AXWindow?, real: CGRect) {
        Log.note("Absorb: \(p.appName) — \(p.title) at \(real.integral)")
        clearPending()
        liftWindow(p)
        view.bringToFront(p)
        if let ax { p.ax = ax }
        p.placedNatively(at: real)
        // Instant, not animated: the real window already covers its proxy.
        view.set(camera: cameraAligning(p, with: real))
        enter(p, realFrame: real, activateApp: false)
        if p.ax == nil { fetchHandle(for: p) }
    }

    /// Focus moved to another window of the entered app (⌘`, a click on a sibling, ⌘N): it becomes
    /// the entered window. The camera stays at 1:1, so the proxy just re-anchors under the real window.
    func focusedWindowChanged(pid: pid_t, element: AXUIElement) {
        let ax = AXWindow(element: element, pid: pid)
        if pid == pendingAbsorbPID {
            absorbAfterReading(ax)
            return
        }
        guard pid == activeProxy?.pid, let id = ax.windowID, id != activeProxy?.windowID else { return }
        // The window's frame and state come from the app, off the main thread; the switch goes ahead
        // only if the app is still the entered one, on another window, when they come back.
        AXQueue.interactive.async { [weak self] in
            let read = AXReading(frame: ax.frame, fullScreen: ax.isFullScreen)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.activeProxy?.pid == pid, self.activeProxy?.windowID != id else { return }
                    self.focusedWindowChanged(to: ax, id: id, read: read)
                }
            }
        }
    }

    private func focusedWindowChanged(to ax: AXWindow, id: CGWindowID, read: AXReading) {
        let pid = ax.pid
        guard !read.fullScreen, let real = read.frame else { return }
        if let other = desk?.canvas(forWindow: id, frame: real), other !== self {
            // A window of the app on another display: it's entered there, this canvas left.
            leaveEntered(reconcile: true)
            other.absorb(window: ax)
            return
        }
        if let p = proxies[id] {
            adoptSibling(p, ax: ax, real: real)
        } else {
            let camera = view.camera
            Task { @MainActor [weak self] in
                guard let self, let p = await self.ensureProxy(windowID: id, pid: pid, camera: camera) else { return }
                guard self.activeProxy?.pid == pid, let real = ax.frame else { return }
                self.adoptSibling(p, ax: ax, real: real)
            }
        }
    }

    private func adoptSibling(_ p: WindowProxy, ax: AXWindow, real: CGRect) {
        if placeInFront(p, real: real, near: activeProxy) { return }
        // Still where `alignSiblings` put it, out of view (⌘` to it): its place on the canvas is the truth,
        // and the canvas goes over to it there rather than taking it in off the edge of the screen.
        let screen = toGlobal(visibleTopLeft)
        let shown = screen.intersection(real)
        let mostlyOff = shown.isNull || shown.width * shown.height < real.width * real.height / 2
        if renderer == .realWindows, real.isClose(to: p.lastRealFrame), mostlyOff, placesNewWindows {
            p.ax = ax
            p.owner = .canvas   // its place on the canvas is the truth; the canvas goes over to it
            Log.note("Absorb: sibling \(p.appName) — \(p.title) is off screen where the canvas has it — over to it")
            return slide(into: p, onScreen: false, known: true)
        }
        Log.note("Absorb: sibling \(p.appName) — \(p.title) at \(real.integral)")
        liftWindow(p)
        p.ax = ax
        let before = p.worldRect.origin
        p.movedByUser(to: real, seenThrough: globalCamera)
        noteAttachmentOffset(p)
        movedForReal(p, from: before)
        view.bringToFront(p)
        enter(p, realFrame: real, activateApp: false)
    }

    func windowCreated(pid: pid_t, element: AXUIElement) {
        guard pid == pendingAbsorbPID else { return }
        // Prefer whatever the app focuses; fall back to the window that just appeared. Asked off the
        // main thread: the app has just made a window and is often busy with it.
        let created = AXWindow(element: element, pid: pid)
        AXQueue.interactive.async { [weak self] in
            let ax = AXWindow.focusedWindow(pid: pid) ?? created
            let read = AXReading(frame: ax.frame, fullScreen: ax.isFullScreen)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pendingAbsorbPID == pid else { return }
                    self.absorb(window: ax, read: read)
                }
            }
        }
    }

    /// The entered window closed. Apps usually focus a sibling first (handled above); if nothing is
    /// focused after a beat, the canvas comes back. The app is asked off the main thread: one closing
    /// a window (saving, quitting) can be slow to answer.
    ///
    /// The app is asked, too, whether the entered window is still one of its windows. One it no longer
    /// names but the window server still has on screen (Music hides its last window that way) is closed
    /// all the same (`closeForApp`): otherwise its proxy stays on the canvas and in ⌘Tab for good.
    func enteredWindowDestroyed(pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let entered = self.activeProxy, entered.pid == pid, !NSApp.isActive else { return }
            let id = entered.windowID
            AXQueue.interactive.async { [weak self] in
                let focused = AXWindow.focusedWindow(pid: pid)
                let named = AXWindow.names(windowID: id, pid: pid)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if named == false, let p = self.proxies[id], p.pid == pid { self.closeForApp(p) }
                        else if named != false { self.confirmClosed(id, pid: pid, attempt: 1) }
                        guard self.activeProxy?.pid == pid, !NSApp.isActive, focused == nil else { return }
                        Log.note("Entered window closed, nothing else focused — back to the canvas")
                        self.showCanvas(fitAll: false)
                    }
                }
            }
        }
    }

    /// The entered window's app still named it, or didn't answer, a moment after it was destroyed: asked
    /// again a few times over the next seconds, as an app can take a beat to drop it from its list.
    private func confirmClosed(_ id: CGWindowID, pid: pid_t, attempt: Int) {
        guard attempt <= 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(attempt)) { [weak self] in
            MainActor.assumeIsolated { self?.askClosed(id, pid: pid, attempt: attempt) }
        }
    }

    private func askClosed(_ id: CGWindowID, pid: pid_t, attempt: Int) {
        guard closedByApp[id] == nil, let p = proxies[id], p.pid == pid, WindowList.exists(id) else { return }
        AXQueue.background.async { [weak self] in
            let named = AXWindow.names(windowID: id, pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if named == false, let p = self.proxies[id], p.pid == pid { self.closeForApp(p) }
                    else if named != true { self.confirmClosed(id, pid: pid, attempt: attempt + 1) }
                }
            }
        }
    }

    /// A window its app says it closed, though the window server still has it on screen: off the canvas
    /// at the next listing, as a closed window is (`closedByApp`). The real window goes off the screen
    /// first, natively, so that once the canvas lets go of it nothing of it shows over the desktop.
    private func closeForApp(_ p: WindowProxy) {
        let id = p.windowID
        guard closedByApp[id] == nil, WindowList.exists(id) else { return }
        if lastActiveProxy === p, askedKept == id { askedKept = nil }
        let listed = WindowList.onScreen(id)
        var parked = listed == nil ? ", already off the screen" : ""
        var home: CGPoint?
        if let listed, renderer == .realWindows, additionNumber >= 15 {
            let origin = CGPoint(x: listed.bounds.minX, y: display.frame.maxY + 4000)
            if moveNativelyNow(p, to: origin) {
                home = listed.bounds.origin
                parked = ", moved off the screen from \(listed.bounds.origin)"
            }
        }
        closedByApp[id] = (p.pid, CACurrentMediaTime(), home)
        Log.note("Closed: \(p.appName) — \(p.title) (window \(id)) is no longer one of its app's windows, though the window server still has it — off the canvas\(parked)")
        scheduleDiff()
    }

    /// A window `closeForApp` moved off the screen, natively back where it was. True if it moved.
    @discardableResult
    private func bringHome(_ id: CGWindowID, _ home: CGPoint?) -> Bool {
        guard let home, WindowList.exists(id),
              LiveWindowsConnection.command(LiveWindowsWire.move(id, x: Int32(home.x.rounded()), y: Int32(home.y.rounded()))) else { return false }
        Log.note("Closed: window \(id) back on the screen natively at \(home)")
        return true
    }

    /// The app in front, looked over every `frontSweepInterval` for windows on the canvas it has closed
    /// without the canvas hearing of it: closed with ⌘W while used where it's drawn at a zoom (nothing
    /// watches its windows then), by the app itself, or a window other than the one entered. A window
    /// that leaves the screen is caught by the listing; one its app keeps on screen, or keeps alive off
    /// it, is caught here. Only windows the app once named are looked at, and only the handle the canvas
    /// already has is asked about: the app is asked for its windows only when one of those handles has
    /// gone dead (`isDestroyed`), which is the app's own word that the window is no more. A window gone
    /// native full screen keeps its handle, so it is never taken for one closed.
    private func sweepFrontApp() {
        let now = CACurrentMediaTime()
        guard !frontSweeping, now - frontSweptAt >= CanvasController.frontSweepInterval,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != myPID else { return }
        if sweep(front) { frontSweptAt = now }
    }

    /// An app that just lost the front (to the canvas, or to another app) is looked over once more: a
    /// window of it closed within the last `frontSweepInterval` would otherwise never be, the sweep
    /// only ever looking at the app in front.
    func appDeactivated(_ pid: pid_t, attempt: Int = 0) {
        guard pid != myPID, attempt < 4 else { return }
        // Its last word on the way out (a window closing as it went) is in by a beat later. A look at
        // another app still under way: this one waits its turn rather than being dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.frontSweeping else { _ = self?.sweep(pid); return }
                self.appDeactivated(pid, attempt: attempt + 1)
            }
        }
    }

    /// One look over `pid`'s windows on the canvas (`sweepFrontApp`). False when there was nothing to
    /// look at, or a look is already under way.
    @discardableResult
    private func sweep(_ front: pid_t) -> Bool {
        guard !frontSweeping else { return false }
        let handles = proxies.values.filter { $0.pid == front && $0.kind == .window && closedByApp[$0.windowID] == nil }
            .compactMap { p in p.ax.map { (id: p.windowID, ax: $0) } }
        guard !handles.isEmpty else { return false }
        frontSweeping = true
        CanvasController.sweepQueue.async { [weak self] in
            let dead = handles.filter { $0.ax.isDestroyed }
            // A dead handle for a window the app still names (some apps make a new one for the same
            // window): the new handle is kept instead.
            let named = dead.isEmpty ? nil : AXWindow.windowsByID(pid: front)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frontSweeping = false
                    guard let named else { return }
                    for (id, _) in dead {
                        guard let p = self.proxies[id], p.pid == front else { continue }
                        if let fresh = named[id] {
                            p.ax = fresh
                        } else if p === self.activeProxy, !NSApp.isActive {
                            self.enteredWindowDestroyed(pid: front)   // closed, and the canvas may have to come back
                        } else {
                            self.closeForApp(p)
                        }
                    }
                }
            }
        }
        return true
    }

    /// Windows closed by their app but still kept by the window server, on screen or not: forgotten as
    /// such once the window server lets them go (a window that turns up again is new), or once the app
    /// names them again (reopened), asked off the main thread every `closedRecheck` seconds.
    private func recheckClosedByApp(listed list: [WindowInfo]) {
        guard !closedByApp.isEmpty else { return }
        let now = CACurrentMediaTime()
        for (id, entry) in closedByApp {
            guard list.contains(where: { $0.id == id }) || WindowList.exists(id) else {
                closedByApp[id] = nil
                continue
            }
            guard now - entry.asked >= CanvasController.closedRecheck, askingClosed.insert(id).inserted else { continue }
            let pid = entry.pid
            closedByApp[id] = (pid, now, entry.home)
            AXQueue.background.async { [weak self] in
                let named = AXWindow.names(windowID: id, pid: pid)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.askingClosed.remove(id)
                        guard named == true, let entry = self.closedByApp.removeValue(forKey: id) else { return }
                        Log.note("Closed: window \(id) is one of its app's windows again — back on the canvas")
                        self.bringHome(id, entry.home)
                        self.scheduleDiff()
                    }
                }
            }
        }
    }

    /// A window of the entered app went into the Dock (⌘M, the yellow button). It stays there, as on
    /// any Mac (takeover's Dock slides out at the screen edge), and keeps its place on the canvas (`away`):
    /// restored from the Dock, it comes back to that place. If it was the window being worked in, the
    /// canvas comes back — once the window has left the screen: the Dock animates it in place over the
    /// canvas's live look for about 270 ms (measured 2026-10-28), and the canvas, coming back at once,
    /// lifted its backdrop over the animation and swallowed it.
    func windowMiniaturized(pid: pid_t, element: AXUIElement) {
        guard let p = activeProxy, pid == p.pid else { return }
        let id = AXWindow(element: element, pid: pid).windowID
        if let id { minimizing[id] = CACurrentMediaTime() }
        guard id == nil || id == p.windowID else { return }
        Log.note("Entered window minimized — into the Dock, its place on the canvas kept")
        returnOnceOffScreen(p, until: CACurrentMediaTime() + CanvasController.genieWait)
    }

    /// The longest the canvas waits for a minimizing entered window to leave the screen before coming
    /// back regardless (the Dock's animation is well under half a second; a slow one, or a window the
    /// window server never reports gone, doesn't strand the user).
    static let genieWait: CFTimeInterval = 1.2

    /// A window of the entered app moved or was resized by hand, as the app says (`ForegroundWatcher`):
    /// the canvas's map follows at once, read from the window server against the camera the app was
    /// entered at, rather than on the way back to the canvas. So a window opened from the entered one
    /// goes beside where it is, not where it was, and the return read confirms rather than discovers.
    /// Only the one app in front is watched, and only its window is looked up: a single-window query,
    /// a fraction of a millisecond, in place of a listing of everything.
    func windowMoved(pid: pid_t, element: AXUIElement) {
        guard let entered = activeProxy, pid == entered.pid, !NSApp.isActive, !handingOff,
              let id = AXWindow(element: element, pid: pid).windowID, let p = proxies[id], p.kind == .window,
              let w = WindowList.onScreen(id), FrameSnapshot.hasSize(w.bounds), !w.bounds.isClose(to: p.lastRealFrame) else { return }
        // Onto another display: the return read moves it to that display's canvas; nothing to do here.
        if let other = desk?.canvas(holding: w.bounds), other !== self { return }
        if id == entered.windowID { env?.keyTap.update(greenButtonWindowAt: w.bounds, window: id) }
        let camera = global(enteredCamera ?? view.camera)
        let before = p.worldRect.origin
        p.movedByUser(to: w.bounds, seenThrough: camera)
        movedForReal(p, from: before)
        noteAttachmentOffset(p)
        minimap.redraw()
    }

    /// Brings the canvas back as soon as the entered window is off the screen, polling the window
    /// server every frame (a single-window query; a fraction of a millisecond), or at `until`.
    private func returnOnceOffScreen(_ p: WindowProxy, until deadline: CFTimeInterval) {
        guard activeProxy === p, !NSApp.isActive else { return }   // the user got there first
        if !WindowList.isOnScreen(p.windowID) || CACurrentMediaTime() >= deadline {
            showCanvas(fitAll: false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainActor.assumeIsolated { self?.returnOnceOffScreen(p, until: deadline) }
        }
    }

    /// The entered app hid or quit. macOS normally hands activation to us (everything else is below
    /// the canvas); if it went elsewhere, bring the canvas back ourselves.
    func appGone(pid: pid_t) {
        launches[pid] = nil
        if pid == pendingAbsorbPID {
            clearPending()
            env?.watcher.stopObserving()
        }
        guard pid == activeProxy?.pid else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !NSApp.isActive else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != self.activeProxy?.pid {
                Log.note("Entered app hid or quit — back to the canvas")
                self.showCanvas(fitAll: false)
            }
        }
    }

    private func startEnteredTimer() {
        enteredTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enteredTick() }
        }
        t.tolerance = 0.25
        enteredTimer = t
    }

    private func stopEnteredTimer() {
        enteredTimer?.invalidate()
        enteredTimer = nil
    }

    /// Fallback for apps whose Accessibility notifications never arrive. The window server knows
    /// whether the window still exists; the app itself is asked nothing unless it's gone, and then
    /// only off the main thread.
    private func enteredTick() {
        guard let p = activeProxy, !NSApp.isActive, !handingOff else { return }
        sweepFrontApp()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != p.pid, front.processIdentifier != myPID {
            foreignActivation(front)   // a missed activation
            return
        }
        guard !WindowList.isOnScreen(p.windowID) else { return }
        let pid = p.pid
        AXQueue.interactive.async { [weak self] in
            let focused = AXWindow.focusedWindow(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.activeProxy?.pid == pid, !NSApp.isActive else { return }
                    if let focused {
                        self.focusedWindowChanged(pid: pid, element: focused.element)
                    } else {
                        self.showCanvas(fitAll: false)
                    }
                }
            }
        }
    }

    // MARK: Takeover — keys

    func handle(_ command: KeyTap.Command) {
        Log.note("Key: \(command)")
        guard addingWidgets == nil, !isSetupShowing else { return }   // the desktop is in edit mode; Done comes back
        switch command {
        case .appSwitchBegin(let reverse): beginSwitcher(reverse: reverse)
        case .appSwitchStep(let reverse): moveSwitcher(.app(reverse ? -1 : 1))
        case .appSwitchWindowStep(let reverse): moveSwitcher(.window(reverse ? -1 : 1))
        case .appSwitchCommit: commitSwitcher()
        case .appSwitchCancel: closeSwitcher(clearHighlight: true)
        // The canvas stands in for Mission Control, so its key toggles it as the Mac's does: pressed again
        // on the canvas, it goes back into the last window.
        case .missionControl where NSApp.isActive: toggle()
        case .missionControl: showCanvas(fitAll: true)
        case .missionControlUp: break   // the desk's (`MissionControlHold`)
        case .showDesktop: showDesktop()
        case .newWindow: newWindowBeside()
        case .howToUse: onHowToUse?()
        case .fillAndEnter: fillAndEnter()
        }
    }

    /// The Mission Control key held on the canvas: everything fitted, to pick from (`MissionControlHold`).
    func seeAllHeld() {
        guard addingWidgets == nil, !isSetupShowing, !paused, switcher == nil else { return }
        showCanvas(fitAll: true)
    }

    /// The Mission Control key let go after a hold: into the window under the pointer, brought to the
    /// middle at 1:1 as a double-click does. Over empty canvas, a widget or a Picture in Picture tile,
    /// See All stays as it is.
    func enterUnderPointer() {
        guard addingWidgets == nil, !isSetupShowing, !paused, switcher == nil, !handingOff,
              let global = CGEvent(source: nil)?.location else { return }
        // Global coordinates are top-left, as the view's points are from its display's corner.
        let point = CGPoint(x: global.x - display.frame.minX, y: global.y - display.frame.minY)
        guard let p = view.proxy(at: view.camera.toWorld(point)), p.kind == .window, p.pip == nil else {
            return Log.note("Key: Mission Control key let go over no window; See All stays")
        }
        Log.note("Key: Mission Control key let go over \(p.appName) — \(p.title), entering it")
        view.highlight(nil)
        handoff(to: p)
    }

    /// The entered window's green button, read from its app off the main thread, for the key tap: a
    /// click on it is Sunlight's full screen (`fillAndEnter`) instead of a Space of its own. Not in strip
    /// mode, where there's no area to fill, nor for a window Accessibility shows no green button on.
    /// A greyed button (a window that can't be resized) isn't taken. Read again once, half a second on,
    /// when the app gives nothing (mid-animation as it comes forward).
    private func readGreenButton(of p: WindowProxy, retry: Bool = true) {
        env?.keyTap.update(greenButton: nil)   // the window entered before this one's isn't this one's
        guard env != nil, p.kind == .window, !Settings.stripMode, let ax = p.ax else { return }
        let id = p.windowID
        AXQueue.background.async { [weak self] in
            let lights = ax.trafficLights, frame = ax.frame, enabled = ax.zoomButtonEnabled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let a = self.activeProxy, a.windowID == id, let env = self.env else { return }
                    guard let lights, lights.centres.count >= 3, let frame else {
                        if retry {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak a] in
                                MainActor.assumeIsolated {
                                    guard let self, let a, self.activeProxy === a else { return }
                                    self.readGreenButton(of: a, retry: false)
                                }
                            }
                        }
                        return
                    }
                    guard enabled else { return }
                    env.keyTap.update(greenButton: KeyTap.GreenButton(window: id, centre: lights.centres[2],
                                                                      diameter: lights.diameter, windowFrame: frame))
                }
            }
        }
    }

    /// Windows being taken out of macOS's full screen (`pullBackFromFullScreen`), and when each was lately,
    /// so an app that goes straight back in is left there rather than fought.
    private var pullingBack: Set<CGWindowID> = []
    private var pulledBack: [CGWindowID: [Date]] = [:]

    /// A window of this canvas went into macOS's own full screen some way the key tap doesn't take (View ›
    /// Enter Full Screen, the green button's menu, the app itself): it's taken back out, and once it's
    /// back on the canvas's Desktop and entered, it fills its area there, as ⌃⌘F and the green button do.
    /// Twice in half a minute and it's left in full screen: the app wants it (a game, a presentation),
    /// and it stays away on the canvas, its place kept, until it leaves.
    /// A window already away in full screen (left there, or the person going over to it on purpose:
    /// ⌘Tab, the minimap, ⌃→) isn't taken out again.
    func pullBackFromFullScreen(_ ax: AXWindow, id: CGWindowID) {
        guard !Settings.stripMode, agentHolds(id), away[id]?.away != .fullScreen, !pullingBack.contains(id) else { return }
        let now = Date()
        pulledBack = pulledBack.compactMapValues { times in
            let recent = times.filter { now.timeIntervalSince($0) < 30 }
            return recent.isEmpty ? nil : recent
        }
        let recent = pulledBack[id] ?? []
        guard recent.count < 2 else {
            Log.note("Full screen: window \(id) keeps going back into full screen — left there")
            if let p = proxies[id], p !== activeProxy, !handingOff { putAway(p, .fullScreen) }
            else if let p = away[id] { p.away = .fullScreen; showAway() }
            return
        }
        pullingBack.insert(id)
        pulledBack[id] = recent + [now]
        Log.note("Full screen: window \(id) went into macOS's full screen — taking it out for Sunlight's")
        AXQueue.interactive.async { [weak self] in
            let done = ax.exitFullScreen()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard done else {
                        self.pullingBack.remove(id)
                        return Log.note("Full screen: window \(id)'s app wouldn't leave full screen — left there")
                    }
                    self.fillWhenBack(id, tries: 40)
                }
            }
        }
    }

    /// The window back from full screen (macOS animates it home, about a second) and entered — it was, or
    /// its app's activation enters it (`leftFullScreenSpace`) — then filled. Gives up after `tries` tenths.
    private func fillWhenBack(_ id: CGWindowID, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if WindowList.onScreen(id) != nil, !Spaces.isInFullScreenSpace(id) {
                    if self.activeProxy?.windowID == id {
                        self.pullingBack.remove(id)
                        return self.fillAndEnter()
                    }
                    // Another window of its app is the one in use (whose app's activation enters nothing new):
                    // the canvas comes forward, and this one fills its area and is entered there.
                    if let a = self.activeProxy, let p = self.proxies[id] ?? self.away[id], a.pid == p.pid {
                        self.pullingBack.remove(id)
                        if self.away[id] === p { self.comeBack(p) }
                        Log.note("Full screen: \(p.appName) — \(p.title) is back; filling it")
                        self.pendingPlacement = { [weak self, weak p] in
                            guard let self, let p, self.view.proxies.contains(where: { $0 === p }) else { return }
                            self.tileChoice(p, .fullScreen)
                        }
                        return self.show()
                    }
                }
                guard tries > 1 else {
                    self.pullingBack.remove(id)
                    return Log.note("Full screen: window \(id) didn't come back from full screen in time")
                }
                self.fillWhenBack(id, tries: tries - 1)
            }
        }
    }

    /// ⌃⌘F in a window: the green button's Full Screen (`tileChoice`), so the window fills its area and is
    /// entered there instead of going off to a Space of its own. The canvas comes forward for it first.
    private func fillAndEnter() {
        guard let a = activeProxy, a.kind == .window else { return }
        guard !Settings.stripMode else { return Log.note("Full screen: ⌃⌘F is off in strip mode") }
        Log.note("Full screen: ⌃⌘F in \(a.appName) — \(a.title)")
        pendingPlacement = { [weak self, weak a] in
            guard let self, let a, self.view.proxies.contains(where: { $0 === a }) else { return }
            self.tileChoice(a, .fullScreen)
        }
        show()
    }

    /// ⌘Tab, like the Mac's, with an icon strip (`SwitcherHUD`) at the edge Settings › Canvas says.
    /// Tab walks apps, ⌘` walks the highlighted app's windows (`SwitcherCycle`), and releasing ⌘
    /// enters the highlighted window. The camera flies to every step, and the strip moves on the same
    /// spring. From a window, the first Tab lands on the app before it; from the canvas, on the most
    /// recent app. The canvas itself isn't a stop. From a window the canvas has to come to the front
    /// before anything can move, so steps wait for `returnedToCanvas`. Widgets can't be entered, so
    /// they aren't in the cycle.
    private func beginSwitcher(reverse: Bool) {
        let current = activeProxy
        // Hidden and minimized windows too, as the Mac's switcher lists hidden apps: picking one brings it back.
        let windows = deskCanvases.flatMap { $0.view.proxies + $0.view.away }.filter { $0.standsAlone }
            .map { SwitcherCycle.Window(id: $0.windowID, pid: $0.pid, position: CGPoint(x: $0.worldRect.midX, y: $0.worldRect.midY)) }
        let cycle = SwitcherCycle(windows: windows, recent: mru, current: current?.windowID)
        pendingSwitcherMoves = []
        pendingSwitcherCommit = false
        guard !cycle.isEmpty else {
            switcher = nil
            Log.note("Switcher: nothing on the canvas to switch to")
            return
        }
        switcher = cycle
        Log.note("Switcher: from \(current.map { "\($0.appName) — \($0.title)" } ?? "canvas"), \(cycle.apps.count) apps, \(windows.count) windows")
        showSwitcherHUD()
        if current == nil && !reverse {
            applySwitcherSelection()   // from the canvas the first app is the destination already
        } else {
            moveSwitcher(.app(reverse ? -1 : 1))
        }
        // Not `showCanvas`: right after a handoff the app can still read as active while the other
        // app's activation lands, and the early return there would leave the canvas behind. From
        // behind another app with nothing entered (a launch left in front, a dialog), the canvas comes
        // forward too; not from behind a window used where it's drawn, where it's up already.
        if current != nil || (!NSApp.isActive && !usingScaledWindow) { show() }
    }

    /// The strip, laid out for this cycle, its first selection at rest. Not with the strip turned off
    /// (`Settings.switcherOn`): the switching works the same without it.
    private func showSwitcherHUD() {
        guard let s = switcher, Settings.switcherOn else { return }
        let entries = s.apps.map { app -> SwitcherHUD.Entry in
            let running = NSRunningApplication(processIdentifier: app.pid)
            let first = app.windows.first.flatMap { lookup($0)?.proxy }
            return SwitcherHUD.Entry(
                name: running?.localizedName ?? first?.appName ?? "?",
                icon: running?.icon ?? NSWorkspace.shared.icon(for: .application),
                windows: app.windows.map { lookup($0)?.proxy.title ?? "" })
        }
        switcherHUD.show(entries, app: s.appIndex, window: s.windowIndex, edge: Settings.switcherEdge,
                         area: visibleTopLeft, in: overlay)
        placeMinimap(animated: true)
        placePreviewBadge(animated: true)
    }

    /// A step through the cycle: across apps (Tab, ⌘← ⌘→) or along an app's windows (⌘`, ⌘↑ ⌘↓).
    private enum SwitcherMove {
        case app(Int)
        case window(Int)
    }

    /// The canvas is in front again: play the switcher input that was waiting for it.
    private func applyPendingSwitcher() {
        guard switcher != nil else { return }
        let moves = pendingSwitcherMoves
        pendingSwitcherMoves = []
        for move in moves { moveSwitcher(move) }
        if pendingSwitcherCommit {
            pendingSwitcherCommit = false
            finishSwitcher()
        }
    }

    private func moveSwitcher(_ move: SwitcherMove) {
        guard switcher != nil else { return }
        // An entered window means the canvas isn't in front yet (or is on its way back): wait for it.
        guard activeProxy == nil else {
            pendingSwitcherMoves.append(move)
            return
        }
        guard var s = switcher else { return }
        s.keep(only: Set(deskCanvases.flatMap { Array($0.proxies.keys) + $0.view.away.map(\.windowID) }))
        switch move {
        case .app(let steps): s.stepApp(by: steps)
        case .window(let steps): s.stepWindow(by: steps)
        }
        switcher = s
        applySwitcherSelection()
    }

    /// The pointer on the strip: an icon (`window` nil) or one of the caption's window chips.
    private func pointSwitcher(app: Int, window: Int?) {
        guard var s = switcher, activeProxy == nil else { return }
        let before = (s.appIndex, s.windowIndex)
        if let window { s.select(app: app, window: window) } else { s.select(app: app) }
        guard (s.appIndex, s.windowIndex) != before else { return }
        switcher = s
        applySwitcherSelection()
    }

    /// A click on the strip: that app or window, entered now, ⌘ still down or not.
    private func pickSwitcher(app: Int, window: Int?) {
        guard var s = switcher else { return }
        if let window { s.select(app: app, window: window) } else { s.select(app: app) }
        switcher = s
        commitSwitcher()
    }

    /// Highlights the selected window, moves the strip to it and flies there. The strip's move plays
    /// out on the flight's spring (`CanvasView.onFlightProgress`).
    private func applySwitcherSelection() {
        guard let s = switcher else { return }
        guard let id = s.selectedWindow, let found = lookup(id) else {
            closeSwitcher(clearHighlight: true)   // everything left the canvas while ⌘ was down
            return
        }
        if switcherHUD.isActive, s.apps.count != switcherHUD.count { showSwitcherHUD() }
        switcherHUD.select(app: s.appIndex, window: s.windowIndex)
        // The window may be on another display: its canvas flies there, the others let go of the highlight.
        let canvas = found.canvas, target = found.proxy
        for c in deskCanvases where c !== canvas { c.view.highlight(nil) }
        canvas.view.highlight(target)
        canvas.view.fly(to: canvas.view.framing(target.worldRect))
    }

    private func commitSwitcher() {
        guard switcher != nil else { return }
        guard activeProxy == nil else {
            // A quick tap from a window: ⌘ was up before the canvas arrived. Finish once it has.
            pendingSwitcherCommit = true
            return
        }
        finishSwitcher()
    }

    private func finishSwitcher() {
        guard let s = switcher else { return }
        closeSwitcher(clearHighlight: false)
        if let id = s.selectedWindow, let found = lookup(id) {
            let canvas = found.canvas, p = found.proxy
            if canvas.proxies[id] === p {
                canvas.handoff(to: p, spatial: true)
            } else {
                canvas.view.highlight(nil)
                canvas.bringBack(p)
            }
        } else {
            view.highlight(nil)
        }
    }

    private func closeSwitcher(clearHighlight: Bool) {
        switcher = nil
        pendingSwitcherMoves = []
        pendingSwitcherCommit = false
        if switcherHUD.isActive {
            switcherHUD.hide()
            placeMinimap(animated: true)
            placePreviewBadge(animated: true)
        }
        if clearHighlight { for c in deskCanvases { c.view.highlight(nil) } }
    }

    // MARK: The other displays

    /// Every display's canvas, this one alone without a desk.
    private var deskCanvases: [CanvasController] { desk?.canvases ?? [self] }

    /// A window on any display's canvas, with that canvas.
    private func lookup(_ id: CGWindowID) -> (canvas: CanvasController, proxy: WindowProxy)? {
        for c in deskCanvases {
            if let p = c.proxies[id] ?? c.away[id] { return (c, p) }
        }
        return nil
    }

    /// The desktop is in edit mode for widgets (`addWidgets`, run by one canvas): every window is off the
    /// screen, and a listing on any display would drop their proxies.
    private var deskEditing: Bool { deskCanvases.contains { $0.addingWidgets != nil } }

    /// For the desk's routing: this canvas is waiting on the app (a handoff's activation, a launch kept on
    /// the canvas, an absorb, a layout restore) or is in one of its windows.
    func isExpecting(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if expectedActivationPID == pid || pendingAbsorbPID == pid || launches[pid] != nil || activeProxy?.pid == pid { return true }
        if let restoring, let id = app.bundleIdentifier, restoring.apps.contains(id) { return true }
        return false
    }

    /// The pid of the app whose window is entered from this canvas, or that it waits to absorb.
    func isFollowing(_ pid: pid_t) -> Bool { activeProxy?.pid == pid || pendingAbsorbPID == pid }

    /// A window is entered from this canvas.
    var isEntered: Bool { activeProxy != nil }

    /// Up in front of its display: Sunlight is the active app, or a window is entered on another display,
    /// whose canvas stands in for it on this one (listing, live windows) until Sunlight is back.
    private var isUp: Bool { NSApp.isActive || staysUp }

    /// A window is entered from another display's canvas, or a window is being used where it is drawn
    /// on this one (`usingScaledWindow`).
    private var staysUp: Bool {
        usingScaledWindow || (desk?.canvases.contains { $0 !== self && $0.isEntered } ?? false)
    }

    // MARK: Using windows at any zoom

    /// The window the canvas has stepped aside for: the pointer is over its content and goes straight
    /// through to it (`Settings.useScaledWindows`). The window server hit-tests through the window's
    /// scale, so a press, scroll or drag there reaches the app at the right spot with nothing mapped.
    private var passingThrough: WindowProxy? {
        didSet {
            if oldValue !== passingThrough { syncPressTapFocus() }
            if (oldValue == nil) != (passingThrough == nil) {
                pressTap.setClickIsCanvas(Settings.scaledClickZooms)
                pressTap.setScrollIsApp(Settings.scaledHoverScroll)
                pressTap.setActive(passingThrough != nil)
            }
        }
    }
    /// The window in use where it's drawn: clicked into (or focused by its title strip, or by hover)
    /// since the canvas was last in front. Its presses and drags are the app's; any other window's
    /// drag moves it on the canvas.
    private var focusedScaledID: CGWindowID? {
        didSet { if oldValue != focusedScaledID { syncPressTapFocus() } }
    }

    private func syncPressTapFocus() {
        guard let p = passingThrough else { return }
        pressTap.setFocused(p.windowID == focusedScaledID)
    }
    private var passThroughTimer: Timer?
    /// Watches the presses that go through to the window, so a drag can still move it (`PressTap`).
    private lazy var pressTap: PressTap = {
        let tap = PressTap { [weak self] command in self?.handle(press: command) }
        tap.start()
        return tap
    }()

    /// The press tap's view of a press on the window the pointer is through to.
    private func handle(press command: PressTap.Command) {
        let viewPoint: (CGPoint) -> CGPoint = { [display] g in CGPoint(x: g.x - display.frame.minX, y: g.y - display.frame.minY) }
        switch command {
        case .pressed(let global, _):
            guard let p = passingThrough else { return pressTap.decide(.inert) }
            // The spot's role, asked of the app off the main thread: where it is natively, from where it's
            // drawn (the real window is 1:1 in world units). The tap decides on its own if this is slow.
            let world = view.camera.toWorld(viewPoint(global))
            let local = CGPoint(x: world.x - p.worldRect.minX, y: world.y - p.worldRect.minY)
            let pid = p.pid, ax = p.ax
            AXQueue.interactive.async { [weak self] in
                let role: PressTap.Role
                if let native = ax?.frame,
                   let element = AXUIElement.element(at: CGPoint(x: native.minX + local.x, y: native.minY + local.y), pid: pid) {
                    role = element.isDraggedControl ? .control : .inert
                } else {
                    role = .inert
                }
                self?.pressTap.decide(role)
            }
        case .doubleClick:
            // Anywhere on the window: to the middle, at 1:1, as a double-click on its title strip; with
            // the clicks swapped, focus it where it is instead.
            guard let p = passingThrough else { return }
            if Settings.scaledClickZooms { focusInPlace(p) } else { handoff(to: p) }
        case .clicked:
            guard let p = passingThrough else { return }
            focusedScaledID = p.windowID
        case .singleClick(let global):
            // The clicks swapped: in at 1:1 around the clicked spot, as a click on the canvas enters.
            guard let p = passingThrough else { return }
            let point = viewPoint(global)
            let world = view.camera.toWorld(point)
            preClickCamera = view.camera
            view.noteClickEntering(p)
            handoff(to: p, placement: .clicked(at: point, offset: CGPoint(x: world.x - p.worldRect.minX, y: world.y - p.worldRect.minY)), click: true)
        case .dragBegin(let global):
            guard let p = passingThrough else { return }
            view.beginExternalDrag(p, at: viewPoint(global))
        case .dragMove(let global, let flags, let timestamp):
            view.moveExternalDrag(to: viewPoint(global), modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: timestamp)
        case .dragEnd(_, let flags, let timestamp):
            view.endExternalDrag(modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)), timestamp: timestamp)
        case .pinch(let magnification, let phase, let timestamp, let global):
            // A pinch over the window zooms the canvas around the fingers, as it does over empty canvas.
            view.externalPinch(magnification: magnification, phase: phase, timestamp: timestamp, at: viewPoint(global))
        case .scroll(let gesture):
            // A scroll over a window not in use pans the canvas, as over empty canvas.
            guard let event = NSEvent(cgEvent: gesture.event) else { return }
            view.externalScroll(event, at: viewPoint(gesture.event.location))
        case .rightClick(let global):
            // Sunlight's menu for the window, wherever on it the click was: the app's own menu is for 1:1.
            guard let p = passingThrough else { return }
            view.showTileMenu(for: p, atTopLeft: viewPoint(global))
        case .appGestureBegan(let global, let done):
            guard let p = passingThrough else { done.signal(); return }
            anchorNatively(p, under: global) { done.signal() }
        }
    }

    /// The window in use at a zoom is about to take a pinch or a scroll of its own: its real frame goes
    /// under the pointer first. The window server maps an event's location through the window's scale,
    /// so a click and a gesture's own point land where they're drawn; but `NSEvent.mouseLocation` and
    /// `mouseLocationOutsideOfEventStream` are the raw pointer, which an app reads against its real,
    /// unscaled frame (measured with a probe window on macOS 27.2). An app that zooms around those
    /// (Preview does) anchored wherever the pointer fell on the real frame: off by the drawn offset,
    /// and the farther from 1:1, the more. The real frame is moved so that the spot under the pointer
    /// on the drawn window is under the pointer on the real one too: the window's place at the 1:1
    /// camera that fixes the pointer. The add-on moves it and sets its transform again in one
    /// transaction (sunlight-56, `RealWindowDriver.anchor`): a plain move shifted the picture by the
    /// move. Kept under the menu bar like every native place (`clampsNatively`): put above it, the
    /// window's app moved it back down natively a moment later, which showed as the whole window
    /// shifting (seen with Preview); so the anchor is right across and, near the top of the screen at
    /// a small zoom, as close as it can be down. The proxy keeps its place and remembers the new frame
    /// at once, so a listing between the request and its answer sees no move either; the answer's
    /// landed frame replaces it. Only one point can agree while the scale isn't 1, and the fingers go
    /// nowhere far in a gesture. `AnchorUnclamped` in defaults lifts the clamp, for trying. A request
    /// the add-on doesn't confirm (no lease, declined, failed) left the window where it was, and its
    /// old frame goes back on record. `then` is called once whatever happens, when the window is where
    /// it will be: the tap holds the gesture's first event until then.
    private func anchorNatively(_ p: WindowProxy, under global: CGPoint, then: @escaping @MainActor () -> Void) {
        guard renderer == .realWindows, additionNumber >= LiveWindowsWire.anchorsFrom,
              p.kind == .window, p.away == nil, p.pip == nil else { return then() }
        let clamped = clampsNatively && !UserDefaults.standard.bool(forKey: "AnchorUnclamped")
        let origin = nativeOrigin(of: p, at: Handoff.cameraFixing(toView(global), at: view.camera), clamped: clamped)
        guard hypot(origin.x - p.lastRealFrame.minX, origin.y - p.lastRealFrame.minY) > 1 else { return then() }
        let old = p.lastRealFrame
        let size = old.size
        p.placedNatively(at: CGRect(origin: origin, size: size))
        realWindows.anchor(p.windowID, at: origin) { [weak p] landed in
            defer { then() }
            guard let p else { return }
            guard let landed else {
                // Not moved: the old frame stands, unless something has put the window elsewhere since.
                if p.lastRealFrame.origin == origin { p.placedNatively(at: old) }
                return
            }
            let elsewhere = hypot(landed.x - origin.x, landed.y - origin.y) > 1
            if elsewhere { p.placedNatively(at: CGRect(origin: landed, size: size)) }
            Log.note("Scaled use: \(p.appName) — \(p.title) natively under the pointer for its gesture, \(origin)\(elsewhere ? " — landed at \(landed)" : "")")
        }
    }
    /// The apps that came to the front while the pointer was through to one of their windows (a click
    /// in it activates the app), since Sunlight was last in front: the user using that window where it
    /// is. While one has the front the canvas stays up as it is, camera and live windows, instead of
    /// handing the windows back.
    private var usedScaledPIDs: Set<pid_t> = []

    /// The app `focusInPlace` just asked to come forward, until when its activation is still on the way.
    private var scaledFocusAsked: (pid: pid_t, until: CFTimeInterval)?

    /// Whether an app coming forward is the user using one of its windows where it's drawn: a click
    /// through into it (the pointer over its window, and not over the Dock, which sits in front of the
    /// canvas and leaves `passingThrough` on the window drawn behind it) or a focus the canvas just
    /// asked for (`focusInPlace`).
    private func isScaledUseActivation(_ pid: pid_t) -> Bool {
        if WindowList.pointerOverDock() { return false }   // a Dock click, whatever was asked or hovered just before
        if let asked = scaledFocusAsked, asked.pid == pid, CACurrentMediaTime() < asked.until { return true }
        return passingThrough?.pid == pid
    }

    private var usingScaledWindow: Bool {
        guard activeProxy == nil else { return false }
        if passingThrough != nil { return true }
        guard !usedScaledPIDs.isEmpty, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return usedScaledPIDs.contains(front)
    }

    /// The camera before a click's way in, to come back to when a second click makes it a double-click
    /// that focuses instead (`focusFromFlight`).
    private var preClickCamera: Camera?

    /// The second click of a double-click with the clicks swapped: the way in is dropped, the camera
    /// comes back to where it was, and the window is focused where it is.
    private func focusFromFlight(_ p: WindowProxy) {
        view.cancelAnimation()
        if let camera = preClickCamera { view.fly(to: camera) }
        preClickCamera = nil
        focusInPlace(p)
    }

    /// Focus follows the pointer (`Settings.scaledHoverFocus`): a window the pointer rests on for
    /// `hoverFocusDelay` is focused where it is. Sweeping across windows focuses none of them.
    private var hoverDwell: (id: CGWindowID, since: CFTimeInterval)?
    private var hoverFocusedID: CGWindowID?
    static let hoverFocusDelay: CFTimeInterval = 0.15

    private func considerHoverFocus(_ p: WindowProxy) {
        guard Settings.scaledHoverFocus else { return }
        let now = CACurrentMediaTime()
        guard let dwell = hoverDwell, dwell.id == p.windowID else {
            hoverDwell = (p.windowID, now)
            return
        }
        guard now - dwell.since >= Self.hoverFocusDelay, hoverFocusedID != p.windowID else { return }
        hoverFocusedID = p.windowID
        focusInPlace(p)
    }

    /// A click on a window's title strip, using windows at any zoom: the window becomes its app's main
    /// window and the app comes to the front, as a click in its content does natively. No zoom: the
    /// canvas stays as it is (`usingScaledWindow`), and the window is used where it's drawn.
    private func focusInPlace(_ p: WindowProxy) {
        guard Settings.useScaledWindows, canPassThrough else {
            let r = view.camera.toScreen(p.worldRect)
            return handoff(to: p, placement: .inPlace(around: CGPoint(x: r.midX, y: r.midY)))
        }
        let pid = p.pid, ax = p.ax
        usedScaledPIDs.insert(pid)
        scaledFocusAsked = (pid, CACurrentMediaTime() + 1)
        focusedScaledID = p.windowID
        wantsFrontUntil = 0   // the canvas yields on purpose
        AXQueue.interactive.async { [weak self] in
            ax?.raise()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let app = NSRunningApplication(processIdentifier: pid) else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
                    // Cooperative activation: from the front we may yield; from another app's window
                    // the plain request is the one that lands.
                    if !app.activate(from: .current, options: []) { _ = app.activate(options: []) }
                    self.reassertCanvasOver(usedScaledApp: pid)
                }
            }
        }
    }

    /// An app came to the front from a window used where it's drawn: the activation orders its front
    /// windows above the canvas, and a full frame puts them back between the backdrop and the canvas,
    /// so the title strip and ⌘ ⌥ drags stay the canvas's (a native drag would move the window under
    /// its picture).
    private func reassertCanvasOver(usedScaledApp pid: pid_t) {
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.usingScaledWindow else { return }
                    self.fullFrameNeeded = true
                    self.updateRealWindows()
                }
            }
        }
    }

    private var canPassThrough: Bool {
        renderer == .realWindows && realWindowsPresented && activeProxy == nil && !handingOff && !springDrag
    }

    private func passThrough(to p: WindowProxy) {
        guard passingThrough == nil, canPassThrough, !window.ignoresMouseEvents else { return }
        passingThrough = p
        window.ignoresMouseEvents = true
        considerHoverFocus(p)
        guard passThroughTimer == nil else { return }
        // With the canvas stepped aside, or with the used window's app in front, the canvas hears no
        // moves; the pointer is followed from here instead.
        passThroughTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPassThrough() }
        }
    }

    private func followPassThrough() {
        // A press under way stays with the window it started in (the window server sends it the drag and
        // the release whatever is over it); the canvas takes the pointer back once the button is up.
        if passingThrough != nil, NSEvent.pressedMouseButtons != 0 || view.isExternalDragging { return }
        if canPassThrough, let p = view.passThroughTarget() {
            if passingThrough == nil {
                guard !window.ignoresMouseEvents else { return }
                window.ignoresMouseEvents = true
            }
            passingThrough = p
            considerHoverFocus(p)
            return
        }
        hoverDwell = nil
        if passingThrough != nil {
            passingThrough = nil
            if !springDrag { window.ignoresMouseEvents = false }
        }
        // While a window used where it's drawn has the front, the canvas isn't key and gets no moves:
        // keep watching, so the pointer goes through to the next window it rests on too.
        if !(canPassThrough && !NSApp.isActive && usingScaledWindow) {
            passThroughTimer?.invalidate()
            passThroughTimer = nil
        }
    }

    /// A window was entered from another display's canvas: this one stays up, in front of its display,
    /// and goes on listing and showing its windows (live ones too, on an add-on with a lease per canvas).
    func standUp() {
        guard !paused, activeProxy == nil, !asleep else { return }
        if !realWindowsPresented { window.orderFrontRegardless() }
        scheduleDiff()
    }

    /// An app came forward by itself with a window on this display, while the canvas stood up for
    /// another display's: the live windows go back first, under that app's, as they do when Sunlight
    /// steps aside (`suspendRealWindows`).
    private func stepDownForForeignApp() {
        guard !NSApp.isActive, realWindowsPresented else { return }
        suspendRealWindows(keepingLook: true)
    }

    // MARK: Moving a window to another display

    /// The other displays' canvases, left to right as the displays are arranged.
    private var otherCanvases: [CanvasController] { (desk?.ordered ?? []).filter { $0 !== self } }

    /// Window › Move to Next Display (⌃⌥⇧→; ← for the previous one): on the canvas, the window under the
    /// pointer (or the one used last) goes to that display's canvas; in a window, that window goes.
    func moveToDisplay(step: Int) {
        guard let desk, desk.canvases.count > 1, addingWidgets == nil, !isSetupShowing, !paused else { return }
        if NSApp.isActive, activeProxy == nil {
            guard let p = tileTarget, let to = desk.neighbour(of: self, step: step) else { return }
            move(p, to: to)
        } else {
            moveFrontWindow(step: step, displays: desk.ordered.map(\.display))
        }
    }

    /// The window goes to the middle of `target`'s display and onto its canvas, where it turns up beside
    /// the windows in view there, as a new window does.
    func move(_ p: WindowProxy, to target: CanvasController) {
        guard p.kind == .window, target !== self, !handingOff, restoring == nil, addingWidgets == nil,
              proxies[p.windowID] === p else { return }
        Log.note("Displays: \(p.appName) — \(p.title) to \(target.display.name)")
        if p.pip != nil { endPip(p) }   // a tile is this screen's
        // A leased window goes back first: its transform places it in screen points, and a window moved
        // under it would be put back where it was when the lease let go of it.
        if realWindowsPresented { suspendRealWindows(keepingLook: true) }
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax
        let point = CanvasController.centred(p.lastRealFrame.size, in: target.display.visible)
        desk?.move(id, from: self, to: target, listing: false)
        AXQueue.interactive.async { [weak self, weak target] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            if ax?.setPosition(point) != true { Log.note("Displays: window \(id) didn't move (Accessibility granted?)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    target?.scheduleDiff()
                    self?.scheduleDiff()
                }
            }
        }
    }

    /// From inside a window: the front app's focused window to the next display, natively. The canvas it
    /// came from hands it over when it's left (`leaveEntered`).
    private func moveFrontWindow(step: Int, displays: [Display]) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPID else { return }
        let pid = app.processIdentifier
        AXQueue.interactive.async {
            guard let ax = AXWindow.focusedWindow(pid: pid), !ax.isFullScreen, let frame = ax.frame,
                  let i = Display.index(for: frame, in: displays) else { return }
            let to = displays[((i + step) % displays.count + displays.count) % displays.count]
            ax.setPosition(CanvasController.centred(frame.size, in: to.visible))
            Log.note("Displays: \(app.localizedName ?? "?")'s window to \(to.name)")
        }
    }

    /// Where a window of `size` sits in the middle of `area`, its top never above it.
    nonisolated static func centred(_ size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(x: (area.midX - size.width / 2).rounded(), y: max(area.minY, (area.midY - size.height / 2).rounded()))
    }

    /// A window was entered from another display's canvas: this one's isn't entered any more.
    func leaveForAnotherDisplay() {
        leaveEntered(reconcile: true)
    }

    /// ⌘Tab is under way from this canvas: its keys keep coming here wherever the pointer goes.
    var isSwitching: Bool { switcher != nil }

    /// The window last entered from this canvas, while it's still on it (the Mission Control key goes back into it).
    var lastEnteredID: CGWindowID? {
        guard let p = lastActiveProxy, proxies[p.windowID] === p || away[p.windowID] === p else { return nil }
        return p.windowID
    }

    /// The main display changed: every window is listed afresh, by where it is now, and the camera
    /// starts at home, the first listing framing what's there.
    func startOver() {
        for id in Array(proxies.keys) + Array(away.keys) { letGo(of: id) }
        lastActiveProxy = nil
        didInitialFit = false
        view.set(camera: homeCamera)
        scheduleDiff(after: 0.3)
    }

    /// The window went to another display's canvas (`Desk.move`): its proxy leaves this one.
    func letGo(of id: CGWindowID) {
        guard let p = proxies.removeValue(forKey: id) ?? away.removeValue(forKey: id) else { return }
        p.stopCapture()
        view.remove(p)
        view.release(p)
        parked[id] = nil
        if lastActiveProxy === p { lastActiveProxy = nil }
        if activeProxy === p { leaveEntered(reconcile: false) }
        showAway()
        minimap.redraw()
    }

    /// The display changed under the canvas (moved in the arrangement, a new resolution, the menu bar's
    /// height): the windows cover it again. If its origin moved, the real windows on it moved with it,
    /// so the proxies and the camera move by as much and nothing changes on screen.
    func adopt(_ new: Display) {
        let old = display
        guard new != old else { return }
        display = new
        if new.frame != old.frame { Log.note("Displays: \(new.name) is at \(new.frame) (was \(old.frame))") }
        window.setFrame(new.cocoaFrame, display: true)
        backdrop?.setFrame(new.cocoaFrame, display: false)
        pipChrome.move(to: new)
        view.topInset = new.topInset
        let dx = new.origin.x - old.origin.x, dy = new.origin.y - old.origin.y
        if dx != 0 || dy != 0 {
            for p in Array(proxies.values) + Array(away.values) {
                p.shift(by: dx, dy)
                p.tile = nil
            }
            var c = view.camera
            c.origin = CGPoint(x: c.origin.x + dx, y: c.origin.y + dy)
            view.set(camera: c)
        }
        lastFrame = nil
        parked.removeAll()
        placeMinimap()
        placePreviewBadge()
        scheduleDiff(after: 0.3)
    }

    /// The display went away: the canvas stops for good, its windows already on their way to another.
    func retire() {
        Log.note("Displays: \(display.name) is gone; its canvas closes")
        view.cancelAnimation()
        closeSwitcher(clearHighlight: true)
        leaveEntered(reconcile: false)
        paused = true
        dormancyChanged(true)
        shutdown()
        for p in Array(proxies.values) + Array(away.values) { p.stopCapture() }
        backdrop?.orderOut(nil)
        window.orderOut(nil)
        pipChrome.update([])
        resetPipShapes()
    }

    /// Live windows were let go of before the displays changed: the canvas shows pictures meanwhile.
    func suspendForDisplayChange() {
        suspendRealWindows()
        lowerOwnWindows()
    }
}
