import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Carbon's way of making a process frontmost. Deprecated since 10.9 and hidden from Swift, but still
/// exported by HIServices and not subject to cooperative activation. Used only as a fallback when
/// `NSApplication.activate()` is refused.
@_silgen_name("SetFrontProcessWithOptions")
private func SetFrontProcessWithOptions(_ psn: UnsafePointer<ProcessSerialNumber>, _ options: UInt32) -> OSStatus
private let kCurrentProcessPSN: UInt32 = 2          // kCurrentProcess
private let kFrontWindowOnly: UInt32 = 1 << 0       // kSetFrontProcessFrontWindowOnly

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
    private var desktopShown: Camera?
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
    /// The window we handed off to; nil while the canvas is in front.
    private var activeProxy: WindowProxy?
    private var lastActiveProxy: WindowProxy?
    private var handingOff = false
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
    private var pendingPan: CGVector?
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
        view.onDesktopDismissed = { [weak self] in self?.endShowDesktop(flyBack: false) }
        view.desktopFloor = desktopFloor
        view.onFloorClick = { [weak self] icon, modifiers, released in self?.floorClick(icon, modifiers: modifiers, released: released) }
        view.onFloorOpen = { [weak self] icon in self?.openFiles([icon]) }
        view.floorMenu = { [weak self] icon in self?.floorMenu(for: icon) }
        view.onFloorCommand = { [weak self] command in self?.floorCommand(command) }
        view.onSpring = { [weak self] proxy, point in self?.springInto(proxy, around: point) }
        view.onFileDragEnded = { [weak self] in self?.fileDragEnded() }
        view.onEnter = { [weak self] proxy, point in self?.handoff(to: proxy, placement: .inPlace(around: point)) }
        view.onClickEnter = { [weak self] proxy, point, offset in self?.handoff(to: proxy, placement: .clicked(at: point, offset: offset)) }
        view.onUse = { [weak self] proxy, point, press in self?.use(proxy, around: point, press: press) }
        view.onUseFollow = { [weak self] event in self?.followPress(event) }
        view.onUseScroll = { [weak self] proxy, point, scroll in self?.useScroll(proxy, around: point, scroll: scroll) }
        view.onUseScrollFollow = { [weak self] event in self?.followScroll(event) }
        view.onClose = { [weak self] proxy in self?.close(proxy) }
        view.onMinimize = { [weak self] proxy in self?.minimize(proxy) }
        view.onHideApp = { [weak self] proxy in self?.hideApp(of: proxy) }
        minimap.onBringBack = { [weak self] proxy in self?.bringBack(proxy) }
        view.onPress = { [weak self] proxy, point in self?.press(proxy, at: point) }
        view.onAddWidgets = { [weak self] in self?.addWidgets() }
        view.onOpenHere = { [weak self] point in self?.openHere(at: point) }
        view.onAnimationCancelled = { [weak self] in
            guard let self else { return }
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
        minimap.isHidden = !Settings.showMinimap
        placeMinimap()
        view.isCovered = { [weak overlay] in overlay?.covers($0) ?? false }
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
                self?.returnedToCanvas()
                self?.runPendingPlacement()
            }
        }
        // Another app came in front (the canvas was ⌘-tabbed away from, say): its windows must not
        // stream. Both fire whether or not takeover is on.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A window entered on another display: this one's canvas stays up as it is.
                if !self.staysUp { self.suspendRealWindows(keepingLook: true) }
                self.scheduleCapturePass()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
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
        let requested = asked == .realWindows && !isLead
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
                    NSLog("Rendering: scaled real windows (live-window protocol v1, add-on \(version ?? "?"))")
                    if self.additionOutdated {
                        // Still usable, with what it has (an older handoff can show a frame in between);
                        // the one in this build goes into the Dock once, with the password prompt if need be.
                        NSLog("Rendering: the Dock runs add-on \(version ?? "?"), this build carries \(LiveWindowsWire.additionVersion); reloading it")
                        self.reloadAddition()
                    }
                } else {
                    if requested == .realWindows { NSLog("Rendering: addition unavailable or incompatible; using capture proxies") }
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
        NSLog("Rendering: live-window connection failed — \(reason); restoring and falling back")
        view.cancelAnimation()
        handingOff = false
        handoffTarget = nil
        suspendRealWindows()
        lowerOwnWindows()   // whatever the lease's end did or didn't manage
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
        guard isLead, Settings.renderer == .realWindows, renderer != .realWindows else { return }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = LiveWindowsConnection.probe()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.rendererRevision == revision, Settings.renderer == .realWindows,
                          self.renderer != .realWindows else { return }
                    guard available else {
                        self.liveRecoveryAttempts += 1
                        self.scheduleLiveRecovery()
                        return
                    }
                    NSLog("Rendering: the live-window addition answers again; back to scaled real windows")
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
        if !interactive, Settings.previewMode || !SetupStatus.liveWindowsPossible() {
            NSLog("Rendering: not loading the live-window addition by itself (\(Settings.previewMode ? "preview mode" : "SIP or the boot argument isn't set"))")
            return
        }
        if interactive { _ = reloader.claimPrompt() }
        reloading = true
        NSLog("Rendering: loading the live-window addition into the Dock\(interactive ? " (administrator prompt)" : "")")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.reloader.reload(interactive: interactive, asked: interactive && asked)
            self.reloading = false
            NSLog("Rendering: reload \(outcome.description)")
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
            NSLog("Rendering: live windows loaded for the first time on this Mac; preview mode is over")
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
            _ = realWindows.restore(overlay: CGWindowID(window.windowNumber),
                                    backdrop: backdrop.map { CGWindowID($0.windowNumber) } ?? 0,
                                    above: NSApp.isActive || front == myPID ? 0 : front)
            lowerOwnWindows()
        }
        guard !keepingLook else { return }
        backdrop?.orderOut(nil)
        view.showsRealWindows = false
        view.hostBackground(in: nil)
        view.hostWidgets(in: nil)
    }

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
    /// The add-on's number (`LiveWindowsWire.additionNumber`) as it answered when the renderer was set up:
    /// from 8 a frame carries flags, and the canvas decides what is full (below).
    private(set) var additionNumber = 0
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

    private func updateRealWindows(keepalive: Bool = false) {
        guard renderer == .realWindows, !configuringRenderer else { return }
        guard !asleep, addingWidgets == nil else {
            suspendRealWindows()
            return
        }
        guard isUp, activeProxy == nil else {
            suspendRealWindows(keepingLook: true)
            return
        }
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
        for p in view.proxies where p.kind == .window && lastWantedIDs.contains(p.windowID) {
            let id = p.windowID
            ids.append(id)
            if flagged, p !== handoffTarget {
                let r = camera.toScreen(p.worldRect)
                let rt = target.map { $0.toScreen(p.worldRect) }
                let park = CanvasController.parks(wasParked: parked[id] != nil, rect: r, target: rt, view: size)
                if park, let parkedAt = parked[id] {
                    all.append(parkedAt)
                    continue
                }
                let window = LiveWindowsWire.Window(id: id, worldRect: p.worldRect, inset: p.inset, camera: wire, pop: p.entranceScale)
                if park {
                    parked[id] = window
                } else {
                    parked[id] = nil
                    near.append(window)
                }
                all.append(window)
            } else {
                let window = LiveWindowsWire.Window(id: id, worldRect: p.worldRect, inset: p.inset, camera: wire, pop: p.entranceScale)
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
        if !keepalive, !full, let last = lastFrame, last.windows == windows, last.shadow == shadow { return }
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
                               shadow: shadow, full: full)
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
        if !NSApp.isActive || activeProxy != nil { forceFront() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !NSApp.isActive else { return }
            NSLog("Sunlight: still not active 300 ms after show()")
            // ⌘Tab is waiting on the canvas; don't leave the user stranded in the window.
            if self.switcher != nil { self.forceFront() }
        }
    }

    private func forceFront() {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: kCurrentProcessPSN)
        let err = SetFrontProcessWithOptions(&psn, kFrontWindowOnly)
        window.orderFrontRegardless()
        if err != noErr { NSLog("Sunlight: SetFrontProcess failed (\(err))") }
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
            if let error { NSLog("Launch: \(name) failed — \(error.localizedDescription)") }
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
            NSLog("Open Here: \(running == nil ? "launching" : "reopening") \(app.name) at \(spot)")
            open(appAt: app.url, name: app.name)
            return
        }
        NSLog("Open Here: asking \(app.name) for a new window at \(spot)")
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
                        NSLog("Open Here: \(app.name) has no New Window item")
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
        let windows = view.proxies.filter { $0.kind == .window && $0.pid == pid }
        guard let p = mru.lazy.compactMap({ id in windows.first { $0.windowID == id } }).first ?? windows.last else {
            NSLog("Open Here: \(pending.name) has no window on the canvas to bring over")
            return
        }
        view.release(p)   // moved on its own: it leaves its group
        let others = view.proxies.filter { $0.kind == .window && $0 !== p }.map(\.worldRect) + away.values.map(\.worldRect)
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        let to = NewWindowSpot.spot(size: p.worldRect.size, avoiding: others, view: view.camera.toWorld(visibleTopLeft),
                                    gap: gap, target: pending.spot)
        NSLog("Open Here: no new window from \(pending.name) — bringing \(p.title) over, \(p.worldRect.origin) → \(to.origin)")
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
    /// the canvas comes to the front first, as with the Mission Control key, and the travel waits for it to arrive. A
    /// four-finger tap (or, by Settings › Trackpad, a quick flick up) is the Mission Control key: from a
    /// window, the canvas with everything fitted; done again on the canvas, back into the window it
    /// came from.
    func trackpadPan(_ phase: TrackpadPan.Phase) {
        let inFront = NSApp.isActive && activeProxy == nil
        switch phase {
        case .seeAll:
            NSLog("Pan: four-finger See All")
            // A flick was a drag until this moment: the pan stops where it is, without coasting.
            if inFront, pendingPan == nil { view.trackpadPanCancelled() }
            pendingPan = nil
            let fromWindow = panBroughtCanvas
            panBroughtCanvas = false
            guard addingWidgets == nil, !isSetupShowing else { return }   // the desktop is in edit mode; Done comes back
            // A flick from a window has already brought the canvas (its drag did): it still means See
            // All, not back again. On the canvas, either gesture again goes back into the last window.
            if fromWindow || !NSApp.isActive { showCanvas(fitAll: true) } else { toggle() }
        case .spread:
            NSLog("Pan: four-finger spread")
            showDesktop()
        case .began:
            NSLog("Pan: four-finger drag\(inFront ? "" : ", bringing the canvas back")")
            pendingPan = nil
            panBroughtCanvas = !inFront
            if !inFront {
                pendingPan = .zero
                show()
            }
        case .changed(let travel):
            if let pending = pendingPan {
                pendingPan = CGVector(dx: pending.dx + travel.dx, dy: pending.dy + travel.dy)
            } else if inFront {
                view.trackpadPan(by: travel)
            } else {
                // Something took the front mid-drag (typically the activation of a window just handed
                // off to, landing late). The drag still wants the canvas.
                NSLog("Pan: lost the front mid-drag, bringing the canvas back")
                pendingPan = travel
                show()
            }
        case .ended:
            if inFront, pendingPan == nil { view.trackpadPanEnded() }
            pendingPan = nil
            panBroughtCanvas = false
        }
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
        NSLog("Desktop: showing the desktop\(desktopFloor.windowID == nil ? " (no floor: Finder isn't drawing the desktop)" : "")")
        view.setShowsDesktop(true)
        // The minimap sits over the desktop's bottom-right corner, where Finder's icons start.
        if Settings.showMinimap { minimap.setShown(false) }
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
        NSLog("Desktop: back from the desktop")
        view.setShowsDesktop(false)
        if Settings.showMinimap {
            minimap.redraw()
            minimap.setShown(true)
        }
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
        if changed { NSLog("Desktop: files \(filesPlacement.title) (\(filesPlacement.stored)), widgets \(widgetsPlacement.title) (\(widgetsPlacement.stored))") }
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
                for (p, to) in moves { p.worldRect.origin = to }
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
        NSLog("Desktop: the floor is \(shown ? "on" : "off")")
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
        NSLog("Desktop: opening \(urls.map(\.lastPathComponent).joined(separator: ", "))\(app.map { " with \($0.lastPathComponent)" } ?? "")")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let arrived: @Sendable (NSRunningApplication?, Error?) -> Void = { [weak self] running, error in
            if let error { NSLog("Desktop: couldn't open — \(error.localizedDescription)") }
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
                    if let error { NSLog("Desktop: couldn't move to the Trash — \(error.localizedDescription)") }
                    let moves = trashed.map { (from: $0.key, to: $0.value) }   // original → in the Trash
                    if !moves.isEmpty {
                        NSLog("Desktop: moved \(moves.count) item\(moves.count == 1 ? "" : "s") to the Trash")
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
                    NSLog("Desktop: renamed \(old) to \(name)")
                    self.registerFileUndo([(from: url, to: target)], name: "Rename")
                    self.desktopFloor.select(urls: [target])
                } catch {
                    NSLog("Desktop: couldn't rename \(old) — \(error.localizedDescription)")
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
            NSLog("Desktop: new folder \(url.lastPathComponent)")
            desktopFloor.select(urls: [url])
            rename(url)
        } catch {
            NSLog("Desktop: couldn't make a folder — \(error.localizedDescription)")
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
                        NSLog("Desktop: couldn't undo \(name) of \(move.from.lastPathComponent) — \(error.localizedDescription)")
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
        NSLog("Desktop: the dragged files open \(p.appName) — \(p.title)")
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
        for c in deskCanvases {
            if shown { c.minimap.redraw() }
            c.minimap.setShown(shown)
        }
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
            NSLog("Sunlight: off")
            view.cancelAnimation()
            closeSwitcher(clearHighlight: true)
            if isShowingDesktop { endShowDesktop(flyBack: false) }
            if activeProxy != nil { leaveEntered(reconcile: true) }
            dormancyChanged(true)
            window.orderOut(nil)
            // The next app forward takes the focus; the canvas is out, so unhiding (`applicationDidHide`
            // under takeover) shows nothing.
            if NSApp.isActive { NSApp.hide(nil) }
        } else {
            NSLog("Sunlight: on")
            NSApp.unhideWithoutActivation()
            dormancyChanged(dormancy.asleep)
            if showing { show() }
        }
    }

    /// Quitting.
    func shutdown() {
        configuringRenderer = true
        rendererRevision += 1
        liveTimer?.invalidate(); liveTimer = nil
        liveRecoveryTimer?.invalidate(); liveRecoveryTimer = nil
        suspendRealWindows()
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
        reconcile(with: WindowList.queue.sync { WindowList.onScreen() })
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
            NSLog("Window events: window \(id) announced on \(state)")
        }
        guard renderer == .realWindows, isUp, activeProxy == nil, !asleep else { return }
        listNow()
        arrivalWatchUntil = CACurrentMediaTime() + CanvasController.arrivalWatch
        guard arrivalTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard CACurrentMediaTime() < self.arrivalWatchUntil, self.isUp, self.activeProxy == nil else {
                    self.arrivalTimer?.invalidate()
                    self.arrivalTimer = nil
                    return
                }
                self.listNow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        arrivalTimer = t
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
        let wanted = list.filter {
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
            if p.kind == .window, let why = knownAway(p) {
                putAway(p, why)
                continue
            }
            if id == keep {
                if askedKept != id {
                    askedKept = id
                    askMinimized(p)
                }
                continue
            }
            // Still there but off screen: minimized, or on another Space. Accessibility says which.
            if p.kind == .window, WindowList.exists(id) {
                putAway(p, nil)
                continue
            }
            proxies[id] = nil
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
        // fraction of a point and re-anchor a proxy.
        var moved = 0
        for w in wanted {
            guard let p = proxies[w.id] else { continue }
            // WindowServer may report the transformed rectangle. Never feed our own camera output
            // back into the world model. After release the native frame is reconciled normally.
            if renderer == .realWindows && realWindowsPresented { continue }
            let before = p.worldRect.origin
            // A widget's own spot is where it is on the desktop at 1:1 (`arrangeDesktop` takes it from there).
            if p.reconcile(title: w.title ?? "", realFrame: w.bounds, camera: p.kind == .widget ? Camera() : globalCamera) {
                moved += 1
                movedForReal(p, from: before)
            }
        }

        let new = wantedIDs.subtracting(proxies.keys).subtracting(unstreamable.keys)
        if gone > 0 || moved > 0 || !new.isEmpty {
            NSLog("Sync: \(list.count) on screen, \(wanted.count) wanted, +\(new.count) −\(gone), \(moved) moved\(new.isEmpty || renderer == .realWindows ? "" : " → asking ScreenCaptureKit")")
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
            let placed = placeRemembered(created)
            if created.contains(where: { $0.kind == .widget }) { arrangeDesktop(animated: false) }
            noteStripArrivals(created, arriving: arriving)
            placeNewWindows(created, arriving: arriving)
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
                    NSLog("Sync: window \(p.windowID) (\(p.appName)) taken \(Int((CACurrentMediaTime() - t) * 1000)) ms after its announcement")
                } else {
                    NSLog("Sync: window \(p.windowID) (\(p.appName)) taken without an announcement")
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
        if gone > 0 || moved > 0 { remember() }
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
            NSLog("Rendering: the window server's order keeps differing from the one asserted; reasserting it with every listing")
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
            NSLog("Sync: shareable content failed — Screen Recording permission? (\(error))")
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
            NSLog("Sync: ScreenCaptureKit lists \(content.windows.count), created \(created), missing \(missing.count)\(retry.isEmpty ? "" : ", asking again")")
        }
        // ScreenCaptureKit lags window creation by a beat: ask again shortly, a few times, then let it be.
        if !retry.isEmpty { requestFullSync(for: retry, after: 0.5) }
        compareSourcesOnce(content)
        let placed = placeRemembered(createdProxies)
        if createdProxies.contains(where: { $0.kind == .widget }) { arrangeDesktop(animated: false) }
        noteStripArrivals(createdProxies, arriving: arriving)
        placeNewWindows(createdProxies, arriving: arriving)
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
            NSLog("Sync: sources differ — window list only: \(listOnly.sorted()), ScreenCaptureKit only: \(sckOnly.sorted())")
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
        NSLog("Polarity: \(p.appName) — \(p.title) is now \(pole.glyph)")
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

    /// The real window moved while it was the one in front (the user dragged it, or its app moved it),
    /// and its proxy has followed. A bonded window that has gone more than a tile gap from where its
    /// group had it leaves the group, rather than dragging the others along behind the canvas.
    private func movedForReal(_ p: WindowProxy, from before: CGPoint) {
        guard !view.groupMembers(of: p).isEmpty else { return }
        let distance = hypot(p.worldRect.minX - before.x, p.worldRect.minY - before.y)
        guard distance > Settings.tileGap else { return }
        NSLog("Polarity: \(p.appName) — \(p.title) moved \(Int(distance)) pt for real; it leaves its group")
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
                    NSLog("Widget: \(p.appName) — \(p.title) at \(p.lastRealFrame.integral)\(widget.map { " (\($0.identifier))" } ?? ", no Accessibility")")
                }
            }
        }
    }

    /// The window the user is on the way into gets a fresh frame every tick, so the seam is current.
    /// The one the user is in gets one twice a second: when the canvas comes back, its stream starts
    /// and delivers a current frame within a frame or two anyway, so photographing the window the user
    /// is working in four times a second was mostly wasted work. Its siblings in front, and the windows
    /// on the canvas shown as stills (`WindowProxy.capped`), take turns once a second, and only the ones
    /// in view. A window behind the canvas whose stream is off is simply out of sight.
    private func refreshTick() {
        refreshTicks &+= 1
        let primary = handoffTarget ?? activeProxy
        if let p = primary, p.inFront, !p.isStreaming, handoffTarget != nil || refreshTicks % 2 == 0 { p.refresh() }
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
        NSLog("Close: \(p.appName) — \(p.title)")
        // Off the main thread: the press may not return until the app has put up its sheet.
        let known = p.ax, id = p.windowID, pid = p.pid, approx = p.lastRealFrame, name = p.appName, title = p.title
        AXQueue.interactive.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let closed = ax?.close() ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let ax, let p = self.proxies[id], p.ax == nil { p.ax = ax }
                    guard ax != nil else {
                        NSLog("Close: no AX window for \(name) — Accessibility granted?")
                        return
                    }
                    guard closed else {
                        NSLog("Close: \(name) — \(title) has no close button, or the app refused")
                        return
                    }
                    if self.lastActiveProxy?.windowID == id { self.lastActiveProxy = nil }
                    // The proxy lingers until a listing sees the window gone; don't leave a dead one up for a second.
                    self.resync(after: [0.2, 0.7, 1.5])
                }
            }
        }
    }

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
        NSLog("Minimize: \(p.appName) — \(p.title)")
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
                        NSLog("Minimize: \(name) refused, or no AX window — Accessibility granted?")
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
        NSLog("Hide: \(p.appName)")
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
        proxies[id] = nil
        p.hovered = false
        p.leaving = false
        view.remove(p)
        p.away = why
        away[id] = p
        if let why { NSLog("Away: \(p.appName) — \(p.title) \(why)") } else { askMinimized(p) }
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
        if let was { NSLog("Away: \(p.appName) — \(p.title) back from \(was)") }
        showAway()
        return p
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

    /// Asks the window's app, off the main thread, whether the window is in the Dock.
    private func askMinimized(_ p: WindowProxy) {
        let id = p.windowID, pid = p.pid, known = p.ax, approx = p.lastRealFrame
        guard askingMinimized.insert(id).inserted else { return }
        AXQueue.background.async { [weak self] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            let minimized = ax?.isMinimized == true
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.askingMinimized.remove(id)
                    self.answered(id, minimized: minimized)
                }
            }
        }
    }

    private func answered(_ id: CGWindowID, minimized: Bool) {
        if let p = away[id], p.away == nil {
            if minimized {
                p.away = .minimized
                NSLog("Away: \(p.appName) — \(p.title) minimized")
                showAway()
            } else {
                away[id] = nil   // on another Space: off the canvas, as before
                mru.removeAll { $0 == id }
            }
        } else if minimized, let p = proxies[id], p !== activeProxy, !handingOff {
            putAway(p, .minimized)   // the last entered window, kept: minimized, not full screen
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
        NSLog("Away: bringing back \(p.appName) — \(p.title) from \(why)")
        let id = p.windowID, pid = p.pid, known = p.ax, approx = p.lastRealFrame
        switch why {
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
                NSLog("Widgets: no ScreenCaptureKit handles — Screen Recording permission?")
                return
            }
            var found = 0
            for w in content.windows where Widgets.isWidget(w) {
                guard let p = self.proxies[w.windowID], p.kind == .widget, p.window == nil else { continue }
                p.window = w
                p.refresh()   // a widget that doesn't change sends its stream nothing
                found += 1
            }
            if found > 0 { NSLog("Widgets: streaming \(found) on the live-windows backdrop") }
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
            NSLog("Widget: pressed a control in \(p.appName) — \(p.title)")
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
            NSLog("Widget: \(p.appName) — \(p.title) has no app to open\(widget == nil ? " (Accessibility granted?)" : "")")
            return
        }
        NSLog("Widget: \(p.appName) — \(p.title) opens \(url.lastPathComponent)")
        open(appAt: url, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Takes the widget off the desktop through its context menu. The proxy goes when a sync sees the
    /// widget's window gone.
    private func removeWidget(_ p: WindowProxy) {
        guard let widget = axWidget(for: p) else {
            NSLog("Close: no Accessibility element for widget \(p.appName) — Accessibility granted?")
            return
        }
        NSLog("Close: widget \(p.appName) — \(p.title)")
        widget.remove { [weak self] removed in
            guard removed else {
                NSLog("Close: no “Remove Widget” in the menu of \(p.appName) — \(p.title)")
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
            NSLog("Widgets: adding widgets needs Accessibility")
            NSSound.beep()
            return
        }
        closeSwitcher(clearHighlight: true)
        let widget = proxies.values.lazy.filter { $0.kind == .widget }.compactMap { self.axWidget(for: $0) }.first
        NSLog("Widgets: opening the gallery from \(widget.map { "the \($0.name) widget's menu" } ?? "Finder's desktop menu")")
        // Syncing stops from here: once edit mode clears the screen, a sync would drop every window's proxy.
        addingWidgets = AddingWidgets()
        suspendRealWindows()
        WidgetGallery.open(from: widget) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                NSLog("Widgets: couldn't open the gallery — no widget on the desktop to ask, and Finder isn't drawing the desktop")
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
            NSLog("Widgets: gallery up")
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
            NSLog("Widgets: edit mode left the canvas up — ordering it out")
            addingWidgets?.orderedOut = true
            window.orderOut(nil)
        }
    }

    private func finishAddingWidgets(_ reason: String) {
        NSLog("Widgets: back from the gallery (\(reason))")
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
        let all = view.proxies + view.away
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
            p.worldRect.origin = unclaimed[i].frame.origin
            p.layout(zoom: view.camera.zoom)
            applyPolarity(of: unclaimed[i], to: p)
            if let g = unclaimed[i].group { view.adopt(group: g, for: p, remap: &rememberedGroups) }
        }
        let claimed = Set(pairs.map(\.entry))
        rememberedClaimed = Set(pairs.map(\.proxy.windowID))
        unclaimed = unclaimed.indices.filter { !claimed.contains($0) }.map { unclaimed[$0] }
        NSLog("Layout: \(pairs.count) back where they were last run, \(unclaimed.count) still to come")
        return true
    }

    /// Windows that just opened with the canvas in front go to the middle of the view, or beside the
    /// windows in the way, as near the middle as there's room (`NewWindowSpot`). Before their first
    /// frame, so they pop in at the new spot. Not the launch sync's, a layout's or the last run's (they
    /// have their places), and not on the strip (it lays them out).
    /// Open Here…'s window goes to its spot instead, even one the last run had a place for.
    private func placeNewWindows(_ created: [WindowProxy], arriving: Bool) {
        guard arriving, restoring == nil, !Settings.stripMode else { return }
        var targets: [CGWindowID: CGPoint] = [:]
        for p in created { targets[p.windowID] = openHereSpot(for: p) }
        let arrivals = created.filter { $0.kind == .window && (!rememberedClaimed.contains($0.windowID) || targets[$0.windowID] != nil) }
        guard !arrivals.isEmpty else { return }
        let fresh = Set(arrivals.map(\.windowID))
        let settled = view.proxies.filter { $0.kind == .window && !fresh.contains($0.windowID) } + Array(away.values)
        var others = settled.map(\.worldRect)
        let visible = view.camera.toWorld(visibleTopLeft)
        let gap = Tidy.Spacing.normal.points(gap: Settings.tileGap)
        var shown = CGRect.null
        for p in arrivals {
            let spot = NewWindowSpot.spot(size: p.worldRect.size, avoiding: others, view: visible, gap: gap,
                                          target: targets[p.windowID])
            if spot.origin != p.worldRect.origin {
                NSLog("New window: \(p.appName) — \(p.title) placed, \(p.worldRect.origin) → \(spot.origin)")
                p.worldRect.origin = spot.origin
                p.layout(zoom: view.camera.zoom)
            }
            others.append(spot)
            shown = shown.union(spot)
        }
        // Somewhere off screen was the only room: the camera slides just far enough to show it.
        guard !shown.isNull, !visible.contains(shown), view.isStill else { return }
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
        let name = choice.name
        // The canvas as it is the moment the name is given, not when the apps have answered.
        let proxies = view.proxies, camera = view.camera, viewSize = view.bounds.size
        let groups = view.grouping.saved(for: proxies.map(\.windowID))
        let spec = choice.withBackground ? background.spec : nil
        Task { @MainActor in
            let documents = await self.lookUpDocuments(of: proxies)
            var layout = Layout(name: name, proxies: proxies, camera: camera, viewSize: viewSize, documents: documents, groups: groups)
            layout.background = spec
            LayoutStore.save(layout)
            NSLog("Layout: saved “\(name)” — \(layout.entries.count) windows and widgets, \(documents.count) with a document")
            saved?()
        }
        return true
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
        guard let layout = LayoutStore.layouts.first(where: { $0.name == name }) else { return }
        // From the menu bar icon over another app: the canvas comes forward first.
        guard NSApp.isActive else {
            pendingPlacement = { [weak self] in self?.restoreLayout(named: name) }
            show()
            return
        }
        guard restoring == nil, addingWidgets == nil, !handingOff, NSApp.isActive, activeProxy == nil else { return }
        closeSwitcher(clearHighlight: true)
        Task { @MainActor in
            // The canvas as the real desktop has it right now, before deciding what's missing.
            await self.syncNow()
            let documents = await self.lookUpDocuments(of: self.view.proxies)
            self.restore(layout, documents: documents)
        }
    }

    /// `policy` overrides the user's choice for the other windows.
    /// `documents` is what `lookUpDocuments` found, asked for beforehand so no app is asked anything here.
    private func restore(_ layout: Layout, documents: [CGWindowID: String] = [:], policy override: Settings.OtherWindows? = nil) {
        guard restoring == nil, addingWidgets == nil, !handingOff else { return }
        let pairs = Layout.match(layout.entries, view.proxies, document: { documents[$0.windowID] })
        let inLayout = Set(pairs.map(\.proxy.windowID))
        let others = view.proxies.filter { $0.kind == .window && !inLayout.contains($0.windowID) }
        var policy = override ?? Settings.otherWindows
        if policy == .ask, !others.isEmpty {
            guard let choice = LayoutPrompt.otherWindows(others.count, layout: layout.name) else { return }
            policy = choice
        }
        NSLog("Layout: restoring “\(layout.name)” — \(pairs.count) of \(layout.entries.count) on the canvas, \(others.count) other windows (\(policy))")

        // Stacked as saved, above whatever else stays.
        var moves: [(proxy: WindowProxy, to: CGPoint)] = []
        var groups: [Int: Int] = [:]
        for (i, p) in pairs.sorted(by: { $0.entry < $1.entry }) {
            let entry = layout.entries[i]
            resize(p, to: entry.frame.size)
            view.bringToFront(p)
            applyPolarity(of: entry, to: p)
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
        if p.ax == nil {
            p.ax = AXWindow.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame)
        }
        guard let ax = p.ax, !ax.isFullScreen else {
            NSLog("Layout: can't resize \(p.appName) — \(p.title)\(p.ax == nil ? " (Accessibility granted?)" : ": it's full screen")")
            return
        }
        ax.setSize(size)
        guard let real = ax.frame else { return }
        if abs(real.width - size.width) > 0.5 || abs(real.height - size.height) > 0.5 {
            NSLog("Layout: \(p.appName) — \(p.title) is \(Int(real.width))×\(Int(real.height)), not \(Int(size.width))×\(Int(size.height)): the app's own limits")
        }
        p.resized(toReal: real)
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
            default: NSLog("Tile: \(preset.title) is off in strip mode")
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
        NSLog("Tile: \(p.appName) — \(p.title) → \(preset.title)")
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
            NSLog("Tile: \(p.appName) — \(p.title) → back from Full")
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
        NSLog("Tile: \(p.appName) — \(p.title) → \(share.title) with \(placed.count - 1) other(s)")
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
        let windows = view.proxies.filter { $0.kind == .window && area.contains(centre($0)) }
        guard !windows.isEmpty else { return }
        let order = Tiling.arrangeOrder(windows.map(\.worldRect), rows: rows)
        NSLog("Tile: arranging \(min(order.count, columns * rows)) windows in \(columns)×\(rows)")
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
        NSLog("Strip: \(on ? "on" : "off"), \(stripWindows.count) windows")
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
                p.worldRect.origin = rect.origin
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
                for (p, to) in moves { p.worldRect.origin = to }
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
        NSLog("Strip: \(direction) to \(windows[next].appName) — \(windows[next].title)")
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
        for p in view.proxies + view.away where p.kind == .window && !seen.contains(p.windowID) {
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
        NSLog("Tidy: \(items.count) windows and groups, \(how), by \(options.order.title)")
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
        for (p, to) in moves where p.away != nil { p.worldRect.origin = to }
        let gliding = moves.filter { $0.proxy.away == nil }
        let frame = view.framing(placed.bounds)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for (p, to) in gliding { p.worldRect.origin = to }
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
            if onCanvas { moves.append((p, entry.rect.origin)) } else { p.worldRect.origin = entry.rect.origin }
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
                NSLog("Tile: \(app.localizedName ?? "?") → \(preset.title) (macOS tiling)")
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
                NSLog("Tile: \(app.localizedName ?? "?") → \(preset.title)")
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
        p.holdFrame()
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
                            NSLog("Resize: can't resize \(p.appName) — \(p.title)\(ax == nil ? " (Accessibility granted?)" : ": it's full screen")")
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
                        NSLog("Resize: \(p.appName) — \(p.title) is \(Int(real.width))×\(Int(real.height)), not \(Int(size.width))×\(Int(size.height)): the app's own limits")
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
            NSLog("Layout: the \(e.appName) widget isn't on the desktop — Add Widgets… puts it back")
        }
        var opened: Set<String> = []
        let windows = entries.filter { $0.kind == .window }
        for (bundleID, wanted) in Dictionary(grouping: windows, by: { $0.bundleID ?? "" }) {
            let name = wanted[0].appName
            guard !bundleID.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("Layout: \(name) isn't installed")
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
                NSLog("Layout: opening \(documents.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }.joined(separator: ", ")) in \(name)")
                NSWorkspace.shared.open(documents, withApplicationAt: app, configuration: configuration) { _, error in
                    if let error { NSLog("Layout: \(name) couldn't open its documents — \(error.localizedDescription)") }
                }
                opened.insert(bundleID)
            } else if !running || !hasWindows {
                NSLog("Layout: \(running ? "reopening" : "launching") \(name)")
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                    if let error { NSLog("Layout: \(name) didn't open — \(error.localizedDescription)") }
                }
                opened.insert(bundleID)
            } else {
                NSLog("Layout: can't reopen \(wanted.count) window(s) of \(name) from here: no document to open")
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
            NSLog("Layout: \(front) came to the front as it launched — bringing the canvas back")
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
            p.worldRect.origin = entries[k].frame.origin
            p.layout(zoom: view.camera.zoom)
            applyPolarity(of: entries[k], to: p)
            if let g = entries[k].group { view.adopt(group: g, for: p, remap: &state.groups) }
            NSLog("Layout: \(p.appName) — \(p.title) is back")
        }
        let claimed = Set(pairs.map { state.pending[$0.entry] })
        state.pending.removeAll { claimed.contains($0) }
        if state.policy == .moveAside {
            let placed = Set(pairs.map(\.proxy.windowID))
            let extras = fresh.filter { $0.kind == .window && !placed.contains($0.windowID) && state.apps.contains($0.bundleID ?? "") }
            for (p, spot) in park(extras, x: &state.parkX, beside: state.layout) {
                p.worldRect.origin = spot
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
            NSLog("Layout: “\(state.layout.name)” restored\(missing.isEmpty ? "" : "; never showed up: \(missing.joined(separator: ", "))")")
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

    /// A click's way in lasts at least this long, so a second click (a double-click) still lands on the
    /// canvas, which re-aims it to the middle, and never on the real window as a click of its own.
    private static var clickEntryDuration: CFTimeInterval {
        min(max(NSEvent.doubleClickInterval, CanvasView.cameraDuration), 0.6)
    }

    /// `spatial`: travel there across the canvas (the switcher's pan-and-zoom flight) rather than the
    /// straight zoom-in a click or ⏎ gets.
    func handoff(to p: WindowProxy, placement: Placement = .centered, spatial: Bool = false) {
        guard !handingOff, p.kind == .window else { return }
        // Straight after the canvas came back (a quick ⌘Tab tap, ⌘ up before the canvas was), its first
        // listing may not have landed, and none lands during a handoff: the live windows were never
        // presented, so the flight played with nothing on screen following it and the window jumped
        // into place at the seam. One now, before the handoff starts, so the flight carries them.
        if renderer == .realWindows, !realWindowListReady { listNow() }
        handingOff = true
        endShowDesktop(flyBack: false)
        handoffTarget = p   // before the camera moves: the pass must not restart its stream mid-flight
        NSLog("Handoff: → \(p.appName) — \(p.title)")
        closeSwitcher(clearHighlight: true)
        view.bringToFront(p)
        // Stop streaming the app now, not at the seam: the pill takes a moment to clear, and the flight
        // covers it. The proxies hold their last frame; the refresh timer keeps the target one current.
        // The target's last streamed frame was sized for the zoom it was seen at; a full one-shot,
        // asked for before the stream stops (they're served independently), replaces it while the
        // proxy is still small on screen, well before the seam.
        p.refresh(seam: true)
        stopStreams(of: p.pid)

        if p.ax == nil {
            p.ax = AXWindow.find(windowID: p.windowID, pid: p.pid, approximateFrame: p.lastRealFrame)
            if p.ax == nil { NSLog("Handoff: no AX window for \(p.appName) — Accessibility granted?") }
        }
        // Its app's front and main window from now, so the activation at the seam brings this window
        // and no other. Done now, while it's still on the canvas: an inactive app's raise puts the
        // window just under the active app's key window, the canvas, which is where the front canvas
        // window is anyway. Done at the seam, after the add-on has put it in front of the canvas, it
        // pulled the window back under the canvas for the frames before the activation landed.
        if renderer == .realWindows { p.ax?.raise() }

        // Where the real window will sit at 1:1, pixel-aligned.
        let visible = visibleTopLeft
        var origin: CGPoint
        switch placement {
        case .centered:
            origin = centredOrigin(of: p)
        case .inPlace(let point):
            // The point's x stays under the pointer and the title bar stays at the height it is on screen
            // now: zoomed out, the window grows down from its top edge; at 1:1 nothing moves.
            origin = CGPoint(x: p.worldRect.minX - view.camera.toWorld(point).x + point.x,
                             y: view.camera.toScreen(p.worldRect.origin).y)
        case .clicked(let point, let offset):
            origin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
        }
        var keepsPlace = false
        var clicked = false
        switch placement {
        case .inPlace: keepsPlace = true
        case .clicked: keepsPlace = true; clicked = true
        case .centered: break
        }
        // A tiled window keeps its place in its area and the camera lines up with the area, so the
        // screen shows it as a tiled desktop, the neighbours where they are.
        if let area = tiledArea(of: p) {
            origin = CGPoint(x: visible.minX + p.worldRect.minX - area.minX, y: visible.minY + p.worldRect.minY - area.minY)
            keepsPlace = true
        }
        origin = CGPoint(x: (origin.x * scale).rounded() / scale, y: (origin.y * scale).rounded() / scale)
        // In place, the camera ends exactly there, wherever the real window manages to go.
        var inPlace: Camera?
        if keepsPlace {
            inPlace = Camera(origin: CGPoint(x: p.worldRect.minX - origin.x, y: p.worldRect.minY - origin.y), zoom: 1)
            // macOS keeps every window's top below the menu bar; asking for higher lands it right there.
            origin.y = max(visible.minY, origin.y)
        }

        if renderer == .realWindows {
            // The native window stays put throughout the flight. Only its live surface follows the
            // camera. Commit the final position and reset the transform together inside Dock.
            origin.y = max(visible.minY, origin.y)
            let target = Camera(origin: CGPoint(x: p.worldRect.minX - origin.x,
                                                 y: p.worldRect.minY - origin.y), zoom: 1)
            let destination = toGlobal(origin)
            // At 1:1, in place, there's nowhere to fly: a few frames and it's in use.
            var duration = view.camera.isClose(to: target) ? CanvasController.stayingDuration : CanvasView.cameraDuration
            if clicked { duration = max(duration, CanvasController.clickEntryDuration) }
            shadowFlight = (p.windowID, CACurrentMediaTime(), duration)
            let complete: () -> Void = { [weak self] in
                guard let self, self.handoffTarget === p, self.renderer == .realWindows else { return }
                // Both looks the active one at the seam; the standard pair again once the activation has landed.
                let shadow = LiveWindowsWire.shadow(p.windowID, inactiveWeight: 1, activeWeight: 1)
                self.shadowFlight = nil
                let kept = self.keptOnShow(entering: p)
                guard self.realWindows.restore(handoff: (p.windowID, destination),
                                               overlay: CGWindowID(self.window.windowNumber),
                                               backdrop: self.backdrop.map { CGWindowID($0.windowNumber) } ?? 0,
                                               shadow: shadow,
                                               keeping: kept.map { ($0.proxy.windowID, $0.at.origin) }) else {
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
                if self.realWindows.lastRestoreKept {
                    for (q, at) in kept { q.lastRealFrame = at }
                    NSLog("Handoff: \(kept.count) other window(s) in view stay on show")
                }
                self.realWindowsPresented = false
                let landed = p.ax?.frame ?? CGRect(origin: destination, size: p.worldRect.size)
                self.enter(p, realFrame: landed, activateApp: true)
            }
            if !clicked, spatial || view.isFlying { view.fly(to: target, completion: complete) }
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
        p.lastRealFrame = real
        if real.size != p.worldRect.size { p.worldRect.size = real.size }

        var aligned = cameraAligning(p, with: real)
        // In place, a window that couldn't go exactly where it was (its top would be under the menu bar,
        // or the app refused) eases to where it landed, and nothing else on the canvas moves.
        var move: CGPoint?
        if let target = inPlace {
            aligned = target
            let landed = target.toWorld(toView(real.origin))
            if landed != p.worldRect.origin { move = landed }
            if hypot(landed.x - p.worldRect.minX, landed.y - p.worldRect.minY) > 1 {
                NSLog("Handoff: \(p.appName) can't sit where it is, moved by (\(Int(landed.x - p.worldRect.minX)), \(Int(landed.y - p.worldRect.minY))): menu bar or the app's own limits")
            }
        }
        let complete: () -> Void = { [weak self] in self?.enter(p, realFrame: real, activateApp: true) }
        if inPlace == nil, spatial || view.isFlying {
            // A flight already under way carries its momentum into the seam.
            view.fly(to: aligned, completion: complete)
        } else {
            var duration = move == nil && view.camera.isClose(to: aligned) ? CanvasController.stayingDuration : CanvasView.cameraDuration
            if clicked { duration = max(duration, CanvasController.clickEntryDuration) }
            view.animateCamera(to: aligned, duration: duration, moving: move.map { [(p, $0)] } ?? [], completion: complete)
            // One more full frame timed to land just before the seam.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - 0.09)) { [weak self, weak p] in
                guard let self, let p, self.handoffTarget === p else { return }
                p.refresh(seam: true)
            }
        }
    }

    /// Where a window entered in the middle sits on screen (view coordinates): centred in the visible
    /// area, or at its top-left when it's bigger than that.
    private func centredOrigin(of p: WindowProxy) -> CGPoint {
        let visible = visibleTopLeft
        var origin = CGPoint(x: visible.midX - p.worldRect.width / 2, y: visible.midY - p.worldRect.height / 2)
        if p.worldRect.width > visible.width { origin.x = visible.minX }
        if p.worldRect.height > visible.height { origin.y = visible.minY }
        return origin
    }

    /// The camera came to rest after the user moved it: nearly on a screen-sized window (near 1:1, its
    /// edges nearly where they'd be on screen), it nudges the rest of the way on a quick spring and
    /// enters it in the middle, as a double-click would (`WindowSnap`). True when it did.
    private func snapToWindow() -> Bool {
        guard Settings.snapToWindows, !handingOff, NSApp.isActive, activeProxy == nil, switcher == nil,
              !isShowingDesktop, addingWidgets == nil, !isSetupShowing else { return false }
        let windows = view.proxies.filter { $0.kind == .window && $0.away == nil && !$0.leaving }
        let visible = visibleTopLeft
        let spots = windows.map { p -> WindowSnap.Window in
            // Where `handoff` puts it, centred: the same spot, so the handoff after the nudge doesn't move.
            var origin = centredOrigin(of: p)
            if let area = tiledArea(of: p) {
                origin = CGPoint(x: visible.minX + p.worldRect.minX - area.minX, y: visible.minY + p.worldRect.minY - area.minY)
            }
            origin = CGPoint(x: (origin.x * scale).rounded() / scale, y: max(visible.minY, (origin.y * scale).rounded() / scale))
            return WindowSnap.Window(rect: p.worldRect, spot: origin)
        }
        guard let hit = WindowSnap.target(camera: view.camera, viewSize: view.bounds.size, visible: visible, windows: spots) else {
            return false
        }
        let p = windows[hit.index]
        NSLog("Snap: onto \(p.appName) — \(p.title)")
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
    /// backdrop as before, and so are parked ones, which are out of view by definition. A window that
    /// covers the centre of the one being entered is left out too: a large neighbour just off the side
    /// would otherwise open across the middle of it.
    private func keptOnShow(entering p: WindowProxy) -> [(proxy: WindowProxy, at: CGRect)] {
        let camera = view.camera
        guard abs(camera.zoom - 1) < 0.001 else { return [] }
        let screenRect = CGRect(origin: .zero, size: view.bounds.size)
        let entered = camera.toScreen(p.worldRect.insetBy(dx: -p.inset, dy: -p.inset))
        let stack: [(item: WindowProxy, rect: CGRect)] = view.proxies.compactMap { q in
            guard q.kind == .window, q.away == nil, lastWantedIDs.contains(q.windowID) else { return nil }
            return (q, camera.toScreen(q.worldRect.insetBy(dx: -q.inset, dy: -q.inset)))
        }
        guard let enteringIndex = stack.firstIndex(where: { $0.item === p }) else { return [] }
        let chosen = CanvasController.neighboursKeptOnShow(stack, enteringIndex: enteringIndex, on: screenRect)
        let kept = chosen.suffix(LiveWindowsWire.maxKept).map { q -> (proxy: WindowProxy, at: CGRect) in
            var r = stack.first { $0.item === q }?.rect ?? .zero
            r.origin = CGPoint(x: (r.minX * scale).rounded() / scale, y: (r.minY * scale).rounded() / scale)
            return (q, toGlobal(r))
        }
        return Array(kept)
    }

    /// A neighbour stays on show when some of it is on screen and it does not cover the centre of the
    /// window being entered.
    static func keepsNeighbourOnShow(_ screenRect: CGRect, on screen: CGRect, clearOf centre: CGPoint) -> Bool {
        let visible = screenRect.intersection(screen)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return false }
        return !screenRect.contains(centre)
    }

    /// Stack order for the windows that stay up when `enteringIndex` is clicked into. `windows` is
    /// bottom to top, the canvas order. The entered window is left out, and so is any window that
    /// would cover its centre. The rest keep their order.
    static func neighboursKeptOnShow<T>(_ windows: [(item: T, rect: CGRect)], enteringIndex: Int, on screen: CGRect) -> [T] {
        guard windows.indices.contains(enteringIndex) else { return [] }
        let entered = windows[enteringIndex].rect
        let centre = CGPoint(x: entered.midX, y: entered.midY)
        return windows.enumerated().compactMap { index, window in
            guard index != enteringIndex, keepsNeighbourOnShow(window.rect, on: screen, clearOf: centre) else { return nil }
            return window.item
        }
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

    /// The 1:1 camera at which the proxy sits exactly where the real window is on screen.
    private func cameraAligning(_ p: WindowProxy, with real: CGRect) -> Camera {
        let v = toView(real)
        return Camera(origin: CGPoint(x: p.worldRect.minX - v.minX, y: p.worldRect.minY - v.minY), zoom: 1)
    }

    /// The moment a real window is in front of the canvas, pixel-matched to its proxy. Shared by the
    /// canvas-initiated handoff (which activates the app) and takeover's absorb (the app is already active).
    private func enter(_ p: WindowProxy, realFrame: CGRect, activateApp: Bool) {
        clearLaunches()   // the user chose a window; a launch still in flight is then absorbed as before
        activeProxy = p
        lastActiveProxy = p
        handingOff = false
        handoffTarget = nil
        scheduleCapturePass()
        p.hovered = false
        p.lastRealFrame = realFrame
        mru.removeAll { $0 == p.windowID }
        mru.insert(p.windowID, at: 0)
        desk?.entered(from: self)
        // Activating an app raises *all* its windows; every seam needs our shadow off, and no stream.
        for q in proxies.values where q.pid == p.pid { q.revealed = true }
        stopStreams(of: p.pid)

        if activateApp {
            if renderer != .realWindows { p.ax?.raise() }   // live: raised when the handoff began
            if let app = NSRunningApplication(processIdentifier: p.pid) {
                expectActivation(of: p.pid)
                // Cooperative activation: we're frontmost, so we're allowed to yield to the target app.
                let yielded = app.activate(from: .current, options: [])
                let forced = yielded ? true : app.activate(options: [])
                NSLog("Handoff: activate \(p.appName) — yielded \(yielded), fallback \(forced), we were active: \(NSApp.isActive)")
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
            startEnteredTimer()
        }
        if springDrag {
            window.ignoresMouseEvents = true
            NSLog("Desktop: the canvas steps aside for the drop into \(p.appName)")
        }
    }

    private func expectActivation(of pid: pid_t) {
        expectedActivationPID = pid
        expectedActivationTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.expectedActivationPID == pid else { return }
            // Dragged files hold the activation back until they're dropped (`fileDragEnded`).
            if self.springDrag {
                self.expectActivation(of: pid)
                return
            }
            self.expectedActivationPID = 0
            // Still in front half a second later: the app refused to activate. Undo the handoff state.
            if NSApp.isActive, let p = self.activeProxy, p.pid == pid {
                NSLog("Handoff: \(p.appName) did not activate — rolling back")
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
        if reconcile, let f = p.ax?.frame {
            if let other = desk?.canvas(holding: f), other !== self {
                // Moved to another display while in use: it lives on that display's canvas from now.
                desk?.move(p.windowID, from: self, to: other)
            } else {
                // Wherever the real window is now is where it lives on the canvas (the user may have moved it).
                let before = p.worldRect.origin
                p.reconcile(title: nil, realFrame: f, camera: globalCamera, force: true)
                movedForReal(p, from: before)
            }
        }
        scheduleCapturePass()
    }

    private func returnedToCanvas() {
        NSLog("Sunlight: active (was in \(activeProxy.map { "\($0.appName) — \($0.title)" } ?? "nothing"))")
        let wasIn = activeProxy
        if let id = shadowEasedBack {
            shadowEasedBack = nil
            restoreShadowLooks(of: id, entered: false)
        }
        clearPending()
        passedScroll = nil
        view.endScrollingOn()
        env?.watcher.stopObserving()
        leaveEntered(reconcile: true)
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
        if let travel = pendingPan {
            pendingPan = nil
            view.trackpadPan(by: travel)
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
            NSLog(summary)
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
        NSLog("Launch: \(name) opens on the canvas")
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
                NSLog("Launch: \(l.name) is on the canvas")
            }
            if l.arrived == nil, now >= l.deadline {
                NSLog("Launch: \(l.name) showed no window for the canvas in \(Int(CanvasController.launchWait)) s — no longer held behind it")
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

    // MARK: Takeover — absorbing activations that happened outside the canvas

    func foreignActivation(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPID else { return }   // our own: `returnedToCanvas` handles it
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
        // An app a layout restore opened, activating itself as it launches: its windows belong behind the
        // canvas, and the restore brings the canvas back in front.
        if let restoring, let id = app.bundleIdentifier, restoring.apps.contains(id) { return }
        // A launch being kept on the canvas came to the front again (apps activate themselves as their
        // first window appears): straight back, as for a restore.
        if activeProxy == nil, let launch = launches[pid], Date() < launch.deadline {
            NSLog("Launch: \(launch.name) came to the front as it launched — bringing the canvas back")
            show()
            return
        }
        guard pid != activeProxy?.pid, pid != pendingAbsorbPID else { return }

        let onCanvas = activeProxy == nil   // before `leaveEntered` clears it
        view.cancelAnimation()   // also clears `handingOff`, so a stale handoff can't land later
        closeSwitcher(clearHighlight: true)
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

    /// From the canvas, an app whose focused window the canvas doesn't know is a launch (or a running
    /// app's new window): it stays on the canvas. One it knows is entered where it is. From inside a
    /// window, the new window is entered either way, at 1:1 — that is the current scale there.
    private func absorbForeign(_ app: NSRunningApplication, focused: AXWindow?, onCanvas: Bool) {
        let pid = app.processIdentifier
        if let focused, let id = focused.windowID, let other = desk?.canvas(forWindow: id, frame: focused.frame), other !== self {
            other.absorbForeign(app, focused: focused, onCanvas: onCanvas)
            return
        }
        stepDownForForeignApp()
        // From the canvas, a window taken out of the Dock (its tile clicked, the app's icon) goes back to
        // its place on the canvas, as on any Mac it goes back where it was: the canvas comes straight
        // back, the listing finds the window on screen and puts its proxy back, and the frame scales it
        // in. From inside a window it is entered, as any window brought to the front from there is.
        // The app's focused window may not be readable yet while the Dock is still animating the window
        // out (it is off the screen until then), so a minimized window of the app's counts too.
        if onCanvas, let p = focused?.windowID.flatMap({ away[$0] }) ?? away.values.first(where: { $0.pid == pid && $0.away == .minimized }),
           p.away == .minimized {
            NSLog("Away: \(p.appName) — \(p.title) restored from the Dock; back to its place on the canvas")
            show()
            return
        }
        let known = focused?.windowID.flatMap { proxyReturning($0) }
        if onCanvas, known == nil, focused?.isFullScreen != true, mayHoldBehindCanvas(pid: pid, focused: focused) {
            keepOnCanvas(app)
            return
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
        NSLog("Launch: pid \(pid)'s window \(id) isn't one for the canvas — leaving it in front")
        return false
    }

    /// The app is in front but has nothing we can show yet; absorb it as soon as it opens a window.
    /// Never steal activation back here: the user is meant to end up in that window, and one created
    /// while we're active would land below the canvas (from the canvas, `keepOnCanvas` wants just that).
    private func waitForWindow(of pid: pid_t) {
        if pendingAbsorbPID != pid {
            NSLog("Absorb: pid \(pid) has no window yet, waiting")
            pendingSince = CACurrentMediaTime()
        }
        pendingAbsorbPID = pid
        env?.watcher.observe(pid: pid, window: nil)
        // Accessibility notifications don't flow from an app that is still launching; poll as well.
        if pendingTimer == nil { schedulePendingTick() }
    }

    private var pendingSince: CFTimeInterval = 0

    /// Four times a second at first, once a second after 10 s, and not at all after a minute: by then
    /// the observer has long since registered, and an app with no window isn't about to show one.
    private func schedulePendingTick() {
        let waited = CACurrentMediaTime() - pendingSince
        guard waited < 60 else {
            NSLog("Absorb: pid \(pendingAbsorbPID) showed no window in a minute — no longer waiting")
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

    private func pendingTick() {
        let pid = pendingAbsorbPID
        guard pid != 0 else { clearPending(); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            // The user (or we) moved on; stop waiting for this one.
            clearPending()
            return
        }
        if let ax = AXWindow.focusedWindow(pid: pid) { absorb(window: ax) }
    }

    private func absorb(window ax: AXWindow) {
        guard !ax.isFullScreen, let id = ax.windowID, let real = ax.frame else {
            waitForWindow(of: ax.pid)
            return
        }
        if let other = desk?.canvas(forWindow: id, frame: real), other !== self {
            clearPending()
            other.absorb(window: ax)
            return
        }
        stepDownForForeignApp()
        if let p = proxyReturning(id) {
            adopt(p, ax: ax, real: real)
            return
        }
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
            self.adopt(p, ax: ax, real: real)
        }
    }

    private func adopt(_ p: WindowProxy, ax: AXWindow, real: CGRect) {
        NSLog("Absorb: \(p.appName) — \(p.title) at \(real.integral)")
        clearPending()
        view.bringToFront(p)
        p.ax = ax
        if p.worldRect.size != real.size { p.worldRect.size = real.size }
        // Instant, not animated: the real window already covers its proxy.
        view.set(camera: cameraAligning(p, with: real))
        enter(p, realFrame: real, activateApp: false)
    }

    /// Focus moved to another window of the entered app (⌘`, a click on a sibling, ⌘N): it becomes
    /// the entered window. The camera stays at 1:1, so the proxy just re-anchors under the real window.
    func focusedWindowChanged(pid: pid_t, element: AXUIElement) {
        let ax = AXWindow(element: element, pid: pid)
        if pid == pendingAbsorbPID {
            absorb(window: ax)
            return
        }
        guard pid == activeProxy?.pid, let id = ax.windowID, id != activeProxy?.windowID else { return }
        guard !ax.isFullScreen, let real = ax.frame else { return }
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
        NSLog("Absorb: sibling \(p.appName) — \(p.title) at \(real.integral)")
        p.ax = ax
        let before = p.worldRect.origin
        p.reconcile(title: nil, realFrame: real, camera: globalCamera, force: true)
        movedForReal(p, from: before)
        view.bringToFront(p)
        enter(p, realFrame: real, activateApp: false)
    }

    func windowCreated(pid: pid_t, element: AXUIElement) {
        guard pid == pendingAbsorbPID else { return }
        // Prefer whatever the app focuses; fall back to the window that just appeared.
        absorb(window: AXWindow.focusedWindow(pid: pid) ?? AXWindow(element: element, pid: pid))
    }

    /// The entered window closed. Apps usually focus a sibling first (handled above); if nothing is
    /// focused after a beat, the canvas comes back.
    func enteredWindowDestroyed(pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.activeProxy?.pid == pid, !NSApp.isActive else { return }
            if AXWindow.focusedWindow(pid: pid) == nil {
                NSLog("Entered window closed, nothing else focused — back to the canvas")
                self.showCanvas(fitAll: false)
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
        NSLog("Entered window minimized — into the Dock, its place on the canvas kept")
        returnOnceOffScreen(p, until: CACurrentMediaTime() + CanvasController.genieWait)
    }

    /// The longest the canvas waits for a minimizing entered window to leave the screen before coming
    /// back regardless (the Dock's animation is well under half a second; a slow one, or a window the
    /// window server never reports gone, doesn't strand the user).
    static let genieWait: CFTimeInterval = 1.2

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
                NSLog("Entered app hid or quit — back to the canvas")
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
        NSLog("Key: \(command)")
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
        case .showDesktop: showDesktop()
        }
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
        let windows = deskCanvases.flatMap { $0.view.proxies + $0.view.away }.filter { $0.kind == .window }
            .map { SwitcherCycle.Window(id: $0.windowID, pid: $0.pid, position: CGPoint(x: $0.worldRect.midX, y: $0.worldRect.midY)) }
        let cycle = SwitcherCycle(windows: windows, recent: mru, current: current?.windowID)
        pendingSwitcherMoves = []
        pendingSwitcherCommit = false
        guard !cycle.isEmpty else {
            switcher = nil
            NSLog("Switcher: nothing on the canvas to switch to")
            return
        }
        switcher = cycle
        NSLog("Switcher: from \(current.map { "\($0.appName) — \($0.title)" } ?? "canvas"), \(cycle.apps.count) apps, \(windows.count) windows")
        showSwitcherHUD()
        if current == nil && !reverse {
            applySwitcherSelection()   // from the canvas the first app is the destination already
        } else {
            moveSwitcher(.app(reverse ? -1 : 1))
        }
        // Not `showCanvas`: right after a handoff the app can still read as active while the other
        // app's activation lands, and the early return there would leave the canvas behind.
        if current != nil { show() }
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

    /// A window is entered from another display's canvas.
    private var staysUp: Bool { desk?.canvases.contains { $0 !== self && $0.isEntered } ?? false }

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
        NSLog("Displays: \(p.appName) — \(p.title) to \(target.display.name)")
        // A leased window goes back first: its transform places it in screen points, and a window moved
        // under it would be put back where it was when the lease let go of it.
        if realWindowsPresented { suspendRealWindows(keepingLook: true) }
        let id = p.windowID, pid = p.pid, approx = p.lastRealFrame, known = p.ax
        let point = CanvasController.centred(p.lastRealFrame.size, in: target.display.visible)
        desk?.move(id, from: self, to: target, listing: false)
        AXQueue.interactive.async { [weak self, weak target] in
            let ax = known ?? AXWindow.find(windowID: id, pid: pid, approximateFrame: approx)
            if ax?.setPosition(point) != true { NSLog("Displays: window \(id) didn't move (Accessibility granted?)") }
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
            NSLog("Displays: \(app.localizedName ?? "?")'s window to \(to.name)")
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
        if new.frame != old.frame { NSLog("Displays: \(new.name) is at \(new.frame) (was \(old.frame))") }
        window.setFrame(new.cocoaFrame, display: true)
        backdrop?.setFrame(new.cocoaFrame, display: false)
        view.topInset = new.topInset
        let dx = new.origin.x - old.origin.x, dy = new.origin.y - old.origin.y
        if dx != 0 || dy != 0 {
            for p in Array(proxies.values) + Array(away.values) {
                p.worldRect = p.worldRect.offsetBy(dx: dx, dy: dy)
                p.lastRealFrame = p.lastRealFrame.offsetBy(dx: dx, dy: dy)
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
        NSLog("Displays: \(display.name) is gone; its canvas closes")
        view.cancelAnimation()
        closeSwitcher(clearHighlight: true)
        leaveEntered(reconcile: false)
        paused = true
        dormancyChanged(true)
        shutdown()
        for p in Array(proxies.values) + Array(away.values) { p.stopCapture() }
        backdrop?.orderOut(nil)
        window.orderOut(nil)
    }

    /// Live windows were let go of before the displays changed: the canvas shows pictures meanwhile.
    func suspendForDisplayChange() {
        suspendRealWindows()
        lowerOwnWindows()
    }
}
