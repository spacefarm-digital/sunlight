import AppKit

/// The canvases, one per display, and what they share: which canvas each window is on, the order windows
/// were used in, ⌘Tab, takeover's keys and activations, and the remembered canvas.
///
/// Every canvas's world is global coordinates (`Display`), so a window's place means the same on each and
/// only its canvas changes when it moves to another display. The canvas on the main display, the lead,
/// keeps what there is one of: the Dock add-on (until an add-on holds a lease per canvas, the other
/// displays show pictures), layouts, the background's settings and setup.
///
/// Commands go to the canvas a window is entered from, else to the one under the pointer.
@MainActor
final class Desk {
    private(set) var canvases: [CanvasController] = []

    /// The canvas on the main display (the one with the menu bar).
    var lead: CanvasController { canvases[0] }

    /// Most recently entered first, across every display.
    var mru: [CGWindowID] = []

    /// Last run's canvas, and the windows of it still to come back: a window goes back where it was
    /// on whichever display's canvas it turns up.
    private(set) var remembered: Layout?
    var unclaimed: [Layout.Entry] = []
    private(set) var rememberedUntil = Date.distantPast

    /// Which display's canvas each window is on, by display UUID. A window is on the canvas of the
    /// display it was first seen on and stays there while the canvas moves it about; it changes canvas
    /// only when it's moved to another display for real (`CanvasController.leaveEntered`).
    private var owner: [CGWindowID: String] = [:]

    init() {
        if Settings.rememberCanvas, let last = LayoutStore.remembered {
            remembered = last
            unclaimed = last.entries
            rememberedUntil = Date().addingTimeInterval(CanvasController.rememberedWindow)
        }
        let displays = Desk.displays
        precondition(!displays.isEmpty, "no display")
        for (i, d) in displays.enumerated() { add(d, lead: i == 0) }
        NSLog("Displays: \(displays.map { "\($0.name) \(Int($0.frame.width))×\(Int($0.frame.height)) at \(Int($0.frame.minX)),\(Int($0.frame.minY))" }.joined(separator: "; "))")

        WindowServerEvents.onWindowCreated = { [weak self] id in self?.canvases.forEach { $0.windowServerCreated(id) } }
        WindowServerEvents.onWindowRemoved = { [weak self] _ in self?.canvases.forEach { $0.windowServerRemoved() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        // Multiple displays turned on or off: canvases come and go as with displays plugged in or out.
        NotificationCenter.default.addObserver(forName: Settings.experimentalFeaturesDidChange,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
        // A click on one display's canvas brings Sunlight forward with only that window: the others come too.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.canvases.count > 1,
                          let key = self.canvases.first(where: { $0.window.isKeyWindow }) else { return }
                    self.bringForward(besides: key)
                }
            }
        }
    }

    /// The displays that get a canvas: every one with Settings › Experimental › Multiple
    /// displays on, else only the main one, whose canvas then shows the others' windows where they are.
    private static var displays: [Display] {
        let all = Display.all
        return Settings.multipleDisplays ? all : Array(all.prefix(1))
    }

    private func add(_ display: Display, lead: Bool) {
        let c = CanvasController(display: display, desk: self, lead: lead)
        c.onSetUp = onSetUp
        c.onHowToUse = onHowToUse
        c.takeover = takeover
        c.permissionsAskedElsewhere = permissionsAskedElsewhere
        c.isSetupShowing = isSetupShowing
        c.background.onCustomise = onCustomiseBackground
        // One background on every display: a change from any canvas's menu reaches them all.
        c.background.onChanged = { [weak self] animated in
            self?.canvases.forEach { $0.view.updateBackground(animated: animated) }
        }
        canvases.append(c)
    }

    // MARK: What the app sets

    var onSetUp: (() -> Void)? { didSet { canvases.forEach { $0.onSetUp = onSetUp } } }
    /// ⌘? anywhere while taken over: Settings › How to use.
    var onHowToUse: (() -> Void)? { didSet { canvases.forEach { $0.onHowToUse = onHowToUse } } }
    /// A display came or went (after `reviewDisplays`).
    var onDisplaysChanged: (() -> Void)?
    /// Customise… on any canvas's background menu.
    var onCustomiseBackground: (() -> Void)? { didSet { canvases.forEach { $0.background.onCustomise = onCustomiseBackground } } }
    var onFirstSync: (() -> Void)? {
        get { lead.onFirstSync }
        set { lead.onFirstSync = newValue }
    }
    weak var takeover: TakeoverMode? { didSet { canvases.forEach { $0.takeover = takeover } } }
    var permissionsAskedElsewhere = false { didSet { canvases.forEach { $0.permissionsAskedElsewhere = permissionsAskedElsewhere } } }
    var isSetupShowing = false { didSet { canvases.forEach { $0.isSetupShowing = isSetupShowing } } }

    var background: BackgroundModel { lead.background }
    /// For sheets and alerts.
    var window: CanvasWindow { lead.window }

    // MARK: Where a command goes

    /// The canvas under the pointer, else the lead.
    var pointed: CanvasController {
        let p = NSEvent.mouseLocation
        return canvases.first { $0.display.cocoaFrame.contains(p) } ?? lead
    }

    /// The canvas a window is entered from, else the pointer's.
    var current: CanvasController { canvases.first(where: \.isEntered) ?? pointed }

    /// Every canvas but `c` in front, under it: Sunlight came forward through one of them.
    func bringForward(besides c: CanvasController) {
        for other in canvases where other !== c && !other.paused { other.window.orderFrontRegardless() }
    }

    // MARK: Which canvas a window is on

    /// The canvas the window is on: the one it's been on, else that of the display holding `frame` (and
    /// from now on that one). Nil only for a window never seen whose frame isn't known.
    func canvas(forWindow id: CGWindowID, frame: @autoclosure () -> CGRect?) -> CanvasController? {
        guard canvases.count > 1 else { return canvases.first }
        if let uuid = owner[id], let c = canvases.first(where: { $0.display.uuid == uuid }) { return c }
        guard let frame = frame(), let c = canvas(holding: frame) else { return nil }
        owner[id] = c.display.uuid
        return c
    }

    /// The canvas of the display a real frame is on.
    func canvas(holding frame: CGRect) -> CanvasController? {
        guard canvases.count > 1 else { return canvases.first }
        return Display.index(for: frame, in: canvases.map(\.display)).map { canvases[$0] }
    }

    /// The window is on another display's canvas than `c`.
    func isElsewhere(_ id: CGWindowID, than c: CanvasController) -> Bool {
        guard let uuid = owner[id] else { return false }
        return uuid != c.display.uuid
    }

    /// The window closed.
    func forget(_ id: CGWindowID) {
        owner[id] = nil
    }

    /// The window was moved to another display for real: it goes to that display's canvas, which lists
    /// it now unless the move is still to be made (`listing` false).
    func move(_ id: CGWindowID, from: CanvasController, to: CanvasController, listing: Bool = true) {
        NSLog("Displays: window \(id) moved from \(from.display.name) to \(to.display.name)")
        owner[id] = to.display.uuid
        from.letGo(of: id)
        if listing { to.scheduleDiff() }
    }

    /// The canvases left to right (then top to bottom), as the displays are arranged.
    var ordered: [CanvasController] {
        canvases.sorted { ($0.display.frame.minX, $0.display.frame.minY) < ($1.display.frame.minX, $1.display.frame.minY) }
    }

    /// The canvas `step` displays along from `c`, round the end.
    func neighbour(of c: CanvasController, step: Int) -> CanvasController? {
        let all = ordered
        guard all.count > 1, let i = all.firstIndex(where: { $0 === c }) else { return nil }
        return all[((i + step) % all.count + all.count) % all.count]
    }

    /// One window entered at a time: `c` entered one, so any other canvas still in one leaves it, and
    /// every other canvas stays up on its display.
    func entered(from c: CanvasController) {
        for other in canvases where other !== c {
            if other.isEntered { other.leaveForAnotherDisplay() }
            other.standUp()
        }
    }

    // MARK: Commands, from the menus, the hotkeys and the gestures

    func show() { current.show() }

    func showCanvas(fitAll: Bool) { current.showCanvas(fitAll: fitAll) }

    /// The Mission Control key: on the canvas, back into the window last entered, on whichever display; in a window, the canvas.
    func toggle() {
        if NSApp.isActive, let id = mru.first(where: { id in canvases.contains { $0.lastEnteredID == id } }),
           let c = canvases.first(where: { $0.lastEnteredID == id }) {
            c.toggle()
            return
        }
        current.toggle()
    }

    /// A four-finger drag stays with the canvas it began on.
    private var panning: CanvasController?

    func trackpadPan(_ phase: TrackpadPan.Phase) {
        switch phase {
        case .began:
            panning = current
            panning?.trackpadPan(phase)
        case .changed:
            (panning ?? current).trackpadPan(phase)
        case .ended:
            (panning ?? current).trackpadPan(phase)
            panning = nil
        case .seeAll:
            // By Settings › How to use, a flick up can end a drag mid-way: that canvas gets it.
            (panning ?? current).trackpadPan(phase)
            panning = nil
        case .spread:
            current.trackpadPan(phase)
        }
    }

    func tile(_ preset: Tiling.Preset) { current.tile(preset) }
    func arrange(columns: Int, rows: Int) { current.arrange(columns: columns, rows: rows) }
    func tidy() { current.tidy() }
    func tidy(by order: Tidy.Order) { current.tidy(by: order) }
    func toggleStripMode() { current.toggleStripMode() }
    func togglePip() { current.togglePipCommand() }
    func toggleMinimap() { current.toggleMinimap() }
    func toggleDesktopFloor() { current.toggleDesktopFloor() }
    func showDesktop() { current.showDesktop() }
    func moveToDisplay(step: Int) { current.moveToDisplay(step: step) }

    // Layouts and the widget gallery are the main display's for now.
    func restoreLayout(named name: String) { lead.restoreLayout(named: name) }
    @discardableResult
    func saveLayout(saved: (() -> Void)? = nil) -> Bool { lead.saveLayout(saved: saved) }
    func addWidgets() { lead.addWidgets() }

    var isMinimapShown: Bool { lead.isMinimapShown }
    var isStripMode: Bool { lead.isStripMode }
    var isDesktopFloorShown: Bool { lead.isDesktopFloorShown }
    var isShowingDesktop: Bool { canvases.contains(where: \.isShowingDesktop) }
    var isAddingWidgets: Bool { canvases.contains(where: \.isAddingWidgets) }
    var isRestoringLayout: Bool { canvases.contains(where: \.isRestoringLayout) }
    var desktopMap: DesktopMapSnapshot { lead.desktopMap }

    // MARK: Rendering

    var renderer: Settings.Renderer { lead.renderer }
    var canReloadLiveWindows: Bool { lead.canReloadLiveWindows }

    /// The lead goes first: whether the others can have live windows depends on its add-on (`leadRendererSettled`).
    func configureRenderer(_ renderer: Settings.Renderer) { lead.configureRenderer(renderer) }

    func reloadAddition(interactive: Bool = false, failure: ((String) -> Void)? = nil) {
        lead.reloadAddition(interactive: interactive, failure: failure)
    }

    /// The lead knows its add-on now: the other canvases follow, live if it holds a lease per canvas.
    func leadRendererSettled() {
        let live = Settings.renderer == .realWindows && lead.renderer == .realWindows
            && lead.additionNumber >= LiveWindowsWire.leasePerCanvas
        for c in canvases.dropFirst() where (c.renderer == .realWindows) != live {
            c.configureRenderer(Settings.renderer)
        }
    }

    func releaseLiveWindowsForDockRestart() { canvases.forEach { $0.releaseLiveWindowsForDockRestart() } }

    // MARK: On, off, quitting

    var paused: Bool { lead.paused }

    func setPaused(_ paused: Bool) {
        // The lead last on the way back: its `show` activates, and the others are up by then.
        for c in canvases.dropFirst() { c.setPaused(paused, showing: false) }
        lead.setPaused(paused)
    }

    func shutdown() { canvases.forEach { $0.shutdown() } }

    /// Writes every display's canvas down for the next launch, as one: the windows of all of them, each
    /// display's camera by its UUID, and last run's windows that haven't come back yet.
    func remember() {
        guard Settings.rememberCanvas, let leadPart = lead.rememberedPart else { return }
        if Date() >= rememberedUntil { unclaimed = [] }
        var proxies = leadPart.proxies
        var groups = leadPart.groups
        var cameras: [String: Layout.DisplayCamera] = [:]
        for c in canvases {
            cameras[c.display.uuid] = Layout.displayCamera(c.view.camera, viewSize: c.view.bounds.size)
            guard c !== lead, let part = c.rememberedPart else { continue }
            // Group numbers count from 0 on every canvas.
            let offset = (groups.values.max() ?? -1) + 1
            proxies += part.proxies
            for (id, g) in part.groups { groups[id] = g + offset }
        }
        var layout = Layout(name: "", proxies: proxies, camera: lead.view.camera, viewSize: lead.view.bounds.size, groups: groups)
        if canvases.count > 1 { layout.cameras = cameras }
        layout.entries = unclaimed + layout.entries
        LayoutStore.remember(layout)
    }

    // MARK: Takeover

    func handle(_ command: KeyTap.Command) {
        let switching = canvases.first(where: \.isSwitching)
        switch command {
        case .missionControl where switching == nil:
            NSLog("Key: \(command)")
            missionControlHold?.cancel()
            if NSApp.isActive {
                // Pressed again on the canvas, a tap goes back into the last window, on whichever display; it
                // waits for the release to know it's a tap. Held, the canvas fits everything to pick from.
                let hold = DispatchWorkItem { [weak self] in
                    guard let self, case .onCanvas = self.missionControlPress else { return }
                    self.pointed.seeAllHeld()
                }
                missionControlPress = .onCanvas
                missionControlHold = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + MissionControlHold.threshold, execute: hold)
            } else {
                missionControlPress = .fromWindow
                current.handle(command)
            }
            return
        case .missionControlUp(let held):
            missionControlHold?.cancel()
            missionControlHold = nil
            guard let press = missionControlPress else { return }
            missionControlPress = nil
            NSLog("Key: Mission Control key let go after \(String(format: "%.2f", held)) s")
            guard switching == nil else { return }
            switch MissionControlHold.release(held: held, press: press) {
            case .toggle: toggle()
            case .stay: break
            case .pick: pointed.enterUnderPointer()
            }
            return
        case .missionControlUp:
            return
        default:
            (switching ?? current).handle(command)
        }
    }

    /// The Mission Control key, between going down and being let go (`MissionControlHold`).
    private var missionControlPress: MissionControlHold.Press?
    /// Pressed on the canvas: fits everything once the key has been held a moment.
    private var missionControlHold: DispatchWorkItem?

    /// An app came forward by itself: to the canvas waiting on it, or in one of its windows, else the
    /// current one; that canvas hands it to the one its window is on (`absorbForeign`).
    func foreignActivation(_ app: NSRunningApplication) {
        (canvases.first { $0.isExpecting(app) } ?? current).foreignActivation(app)
    }

    func appGone(pid: pid_t) { canvases.forEach { $0.appGone(pid: pid) } }

    private func following(_ pid: pid_t) -> CanvasController { canvases.first { $0.isFollowing(pid) } ?? lead }

    func focusedWindowChanged(pid: pid_t, element: AXUIElement) { following(pid).focusedWindowChanged(pid: pid, element: element) }
    func windowCreated(pid: pid_t, element: AXUIElement) { following(pid).windowCreated(pid: pid, element: element) }
    func windowMiniaturized(pid: pid_t, element: AXUIElement) { following(pid).windowMiniaturized(pid: pid, element: element) }
    func windowMoved(pid: pid_t, element: AXUIElement) { following(pid).windowMoved(pid: pid, element: element) }
    func enteredWindowDestroyed(pid: pid_t) { following(pid).enteredWindowDestroyed(pid: pid) }

    // MARK: Displays coming and going

    private var displayReview: DispatchWorkItem?

    /// The system says the displays changed. The menu bar or the Dock changing a display's visible part
    /// is taken at once; a display added, removed or moved waits a second for the system to settle
    /// (a display waking from sleep comes and goes several times).
    private func displaysChanged() {
        let now = Desk.displays
        guard !now.isEmpty else { return }
        let same = now.count == canvases.count && zip(now, canvases).allSatisfy { d, c in
            d.uuid == c.display.uuid && d.frame == c.display.frame && d.scale == c.display.scale
        }
        if same {
            for (d, c) in zip(now, canvases) { c.adopt(d) }
            return
        }
        displayReview?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reviewDisplays() }
        }
        displayReview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func reviewDisplays() {
        let now = Desk.displays
        guard let primary = now.first else { return }
        let before = canvases.count
        defer { if canvases.count != before { onDisplaysChanged?() } }
        let primaryChanged = primary.uuid != lead.display.uuid
        // Gone, or now the main display, which is the lead's.
        for c in canvases.dropFirst() where c.display.uuid == primary.uuid || !now.contains(where: { $0.uuid == c.display.uuid }) {
            c.retire()
            owner = owner.filter { $0.value != c.display.uuid }
            canvases.removeAll { $0 === c }
        }
        lead.adopt(primary)
        if primaryChanged {
            // Another display is the main one now (the lid closed on an external display, say): global
            // coordinates moved under every window, so each is listed afresh where it is.
            NSLog("Displays: \(primary.name) is the main display now; every canvas starts over")
            owner.removeAll()
            for c in canvases {
                c.suspendForDisplayChange()
                c.startOver()
            }
        }
        for d in now.dropFirst() {
            if let c = canvases.first(where: { $0 !== lead && $0.display.uuid == d.uuid }) {
                c.adopt(d)
            } else {
                NSLog("Displays: \(d.name) connected; a canvas for it")
                add(d, lead: false)
                guard let c = canvases.last else { continue }
                if lead.paused { c.setPaused(true) } else { c.window.orderFrontRegardless() }
            }
        }
    }
}
