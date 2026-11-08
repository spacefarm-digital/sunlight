import AppKit
import ApplicationServices

/// What the rest of the system does while the canvas is not in front: app activations and exits from
/// NSWorkspace, plus one Accessibility observer on the entered (or about-to-be-entered) app.
@MainActor
final class ForegroundWatcher {
    var onForeignActivation: ((NSRunningApplication) -> Void)?
    /// Hidden or terminated.
    var onAppGone: ((pid_t) -> Void)?
    var onFocusedWindowChanged: ((pid_t, AXUIElement) -> Void)?
    var onWindowCreated: ((pid_t, AXUIElement) -> Void)?
    var onWindowMiniaturized: ((pid_t, AXUIElement) -> Void)?
    /// A window of the observed app moved or took a new size, as the app says, within a frame or two:
    /// the canvas's map follows while the window is in use rather than on the way back.
    var onWindowMoved: ((pid_t, AXUIElement) -> Void)?
    var onEnteredWindowDestroyed: ((pid_t) -> Void)?
    /// The Dock icon of the app already in front was clicked. macOS reports no activation for it (the
    /// app is active already), so nothing else says the user asked for it: with the canvas up over
    /// the app (one of its windows used where it's drawn), the click went nowhere.
    var onDockClickOnFrontApp: ((NSRunningApplication) -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    /// Activations reported so far: a Dock click that saw one between its press and its answer
    /// brought some app forward, and is that activation's to answer.
    private var activations = 0
    /// A left press on the Dock with another app than Sunlight in front: that app, the activations
    /// counted then, and where and when the press was.
    private var dockPress: (front: pid_t, activations: Int, at: CGPoint, time: CFTimeInterval)?
    /// Longer than this, a press on a Dock icon is a hold (its menu), not a click.
    static let dockClickLimit: CFTimeInterval = 0.6
    private var observer: AXAppObserver?
    private(set) var observedPID: pid_t = 0

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let app = ForegroundWatcher.application
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = app(n) else { return }
            MainActor.assumeIsolated {
                self?.activations += 1
                self?.onForeignActivation?(a)
            }
        })
        // Presses that go to other apps (the Dock among them); the canvas's own aren't seen here.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            let down = e.type == .leftMouseDown
            let point = e.cgEvent?.location ?? CGEvent(source: nil)?.location
            MainActor.assumeIsolated { self?.dockMouse(down: down, at: point) }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let a = app(n) else { return }
                MainActor.assumeIsolated { self?.onAppGone?(a.processIdentifier) }
            })
        }
    }

    nonisolated private static func application(_ n: Notification) -> NSRunningApplication? {
        n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        dockPress = nil
        stopObserving()
    }

    /// A left press and its release, as they went to another app. A click on the Dock, on the icon of
    /// the app that was in front at the press and still is, with no activation since: the Dock is
    /// asked which icon it was (off the main thread), and the click is reported if it was that app's.
    private func dockMouse(down: Bool, at point: CGPoint?) {
        guard let point else { return }
        let now = CACurrentMediaTime()
        if down {
            dockPress = nil
            guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
                  front.activationPolicy == .regular, WindowList.isOverDock(point) else { return }
            dockPress = (front.processIdentifier, activations, point, now)
            return
        }
        guard let press = dockPress else { return }
        dockPress = nil
        // Held (the icon's menu) or dragged (an icon moved along the Dock, or off it): not a click.
        guard now - press.time < ForegroundWatcher.dockClickLimit,
              hypot(point.x - press.at.x, point.y - press.at.y) < 6,
              press.activations == activations,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == press.front,
              let dock = WindowList.dockPID, WindowList.isOverDock(point) else { return }
        let counted = activations, pid = front.processIdentifier
        AXQueue.interactive.async { [weak self] in
            let clicked = DockItem.application(at: point, dockPID: dock)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, counted == self.activations, let clicked,
                          let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid,
                          !front.isTerminated, clicked.stands(for: front) else { return }
                    Log.note("Dock: \(front.localizedName ?? "pid \(front.processIdentifier)")'s icon clicked while it is already in front")
                    self.onDockClickOnFrontApp?(front)
                }
            }
        }
    }

    /// Watches one app's focus and windows; `window` is the entered window, whose destruction we care about.
    func observe(pid: pid_t, window: AXUIElement?) {
        if observedPID != pid || observer == nil {
            observer = AXAppObserver(pid: pid) { [weak self] name, element in
                self?.axEvent(pid: pid, name: name, element: element)
            }
            observedPID = pid
        }
        observer?.watch(window: window)
    }

    func stopObserving() {
        observer = nil
        observedPID = 0
    }

    private func axEvent(pid: pid_t, name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification: onFocusedWindowChanged?(pid, element)
        case kAXWindowCreatedNotification: onWindowCreated?(pid, element)
        case kAXWindowMiniaturizedNotification: onWindowMiniaturized?(pid, element)
        case kAXWindowMovedNotification, kAXWindowResizedNotification: onWindowMoved?(pid, element)
        case kAXUIElementDestroyedNotification: onEnteredWindowDestroyed?(pid)
        default: break
        }
    }
}

/// An app's icon on the Dock, as the Dock tells Accessibility.
struct DockItem: Sendable {
    let url: URL?
    let title: String?

    /// The app icon at a global point (top-left origin); nil over anything else on the Dock (a folder,
    /// a minimized window, the Trash, a gap) or when the Dock doesn't answer.
    static func application(at point: CGPoint, dockPID: pid_t) -> DockItem? {
        guard var e = AXUIElement.element(at: point, pid: dockPID) else { return nil }
        // The item itself, or something inside it (its badge, its label): up to the item.
        for _ in 0..<3 {
            if e.string(kAXRoleAttribute) == "AXDockItem" {
                guard e.string(kAXSubroleAttribute) == "AXApplicationDockItem" else { return nil }
                return DockItem(url: url(of: e), title: e.string(kAXTitleAttribute))
            }
            guard let up = e.parent else { return nil }
            e = up
        }
        return nil
    }

    /// Whether the icon is this app's: the same bundle, or (with no bundle given) the same name.
    func stands(for app: NSRunningApplication) -> Bool {
        if let url, let bundle = app.bundleURL {
            return DockItem.samePath(url, bundle)
        }
        guard let title, let name = app.localizedName else { return false }
        return title == name
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func url(of e: AXUIElement) -> URL? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &ref) == .success else { return nil }
        if let url = ref as? URL { return url }
        if let string = ref as? String { return URL(string: string) }
        return nil
    }
}

/// One AXObserver on one app. Its run-loop source sits on the main run loop, so callbacks arrive on
/// the main thread.
final class AXAppObserver {
    typealias Handler = @MainActor (String, AXUIElement) -> Void

    let pid: pid_t
    private let observer: AXObserver
    private let app: AXUIElement
    private var window: AXUIElement?
    private let handler: Handler

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
    ]

    init?(pid: pid_t, handler: @escaping Handler) {
        var created: AXObserver?
        guard AXObserverCreate(pid, AXAppObserver.callback, &created) == .success, let created else {
            Log.note("AXObserver: create failed for pid \(pid)")
            return nil
        }
        self.pid = pid
        self.observer = created
        self.app = AXWindow.application(pid)
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for name in AXAppObserver.appNotifications { add(name, to: app) }
    }

    func watch(window element: AXUIElement?) {
        if let old = window, old != element {
            let observer = observer
            AXAppObserver.teardown.async { [weak self] in
                AXObserverRemoveNotification(observer, old, kAXUIElementDestroyedNotification as CFString)
                DispatchQueue.main.async {
                    // Watched again meanwhile (into one window, another, and back): the removal just
                    // undid its registration, so it's made again.
                    guard let self, self.window == old else { return }
                    self.add(kAXUIElementDestroyedNotification, to: old)
                }
            }
        }
        window = element
        if let element { add(kAXUIElementDestroyedNotification, to: element) }
    }

    /// Where registrations are taken back. Each removal is a round trip to the app, which is usually
    /// busy just then (it has been sent behind the canvas and is redrawing for See All) and answers
    /// only at the messaging timeout: on the main thread that was up to a second at every return to
    /// the canvas, more with more windows on show. Nothing waits for the answer.
    private static let teardown = DispatchQueue(label: "canvas.ax.teardown", qos: .utility)

    deinit {
        // The run-loop source goes first, here: no callback can arrive after this, so the unretained
        // refcon never outlives the observer. The registrations go on the teardown queue, which keeps
        // the observer and the elements alive until it's done.
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let observer = observer, app = app, window = window
        AXAppObserver.teardown.async {
            for name in AXAppObserver.appNotifications {
                AXObserverRemoveNotification(observer, app, name as CFString)
            }
            if let window {
                AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
            }
        }
    }

    /// A launching app, or an Electron/Chromium app enabling accessibility lazily, answers
    /// `cannotComplete` for a while; keep trying for a few seconds.
    private func add(_ name: String, to element: AXUIElement, attempt: Int = 0) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, element, name as CFString, refcon)
        switch err {
        case .success, .notificationAlreadyRegistered:
            if attempt > 0 { Log.note("AXObserver: \(name) for pid \(pid) registered after \(attempt) retries") }
        case .cannotComplete where attempt < 20:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.add(name, to: element, attempt: attempt + 1)
            }
        case .invalidUIElement where name == kAXUIElementDestroyedNotification:
            // The window being entered is already gone as far as its app is concerned (Music's closed
            // window, which the window server still listed and ⌘Tab still went to): told as its
            // destruction, a moment from now, so the canvas asks the app and comes back.
            Log.note("AXObserver: the window entered in pid \(pid) is already gone for its app")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window == element else { return }
                MainActor.assumeIsolated { self.handler(name, element) }
            }
        default:
            Log.note("AXObserver: \(name) for pid \(pid) failed (\(err.rawValue))")
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated { me.handler(name, element) }
    }
}
