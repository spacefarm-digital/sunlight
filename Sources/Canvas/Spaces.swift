import AppKit

/// macOS's Spaces, as takeover sees them: one Desktop per display, the canvas's. Other Desktops are folded
/// into it (their windows moved onto the canvas's Desktop, the empty Desktops removed); full-screen apps'
/// Spaces are left as they are.
///
/// Reading goes through SkyLight from Sunlight's own process. Moving another app's window to a Desktop and
/// removing a Desktop don't: with SIP on, the window server only takes them from the Dock (spaces-probe,
/// macOS 27.2), so they go through a `Mover`: the Dock add-on's Desktops op (sunlight-55, `DockSpaces`).
/// With an older add-on in the Dock, folding is a no-op that says so.
enum Spaces {
    struct Space: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A Desktop.
            case user
            /// A full-screen app, or a tiled pair of them.
            case fullScreen
            /// Anything else the window server keeps (the system's own).
            case other
        }

        let id: UInt64
        let kind: Kind

        init(id: UInt64, kind: Kind) {
            self.id = id
            self.kind = kind
        }

        /// `type` in SLSCopyManagedDisplaySpaces: 0 a Desktop, 4 full screen, 2 the system's.
        init(id: UInt64, type: Int) {
            self.init(id: id, kind: type == 0 ? .user : type == 4 ? .fullScreen : .other)
        }
    }

    struct Display: Equatable, Sendable {
        /// The display's UUID, or "Main" when Displays have separate Spaces is off.
        let identifier: String
        let spaces: [Space]
        let current: UInt64

        var desktops: [Space] { spaces.filter { $0.kind == .user } }

        /// The Desktop the canvas is on: the current one, or, inside a full-screen app, the first Desktop.
        var canvasDesktop: UInt64? {
            if let space = spaces.first(where: { $0.id == current }), space.kind == .user { return current }
            return desktops.first?.id
        }
    }

    /// What folding a Mac's Desktops comes to: each window on another Desktop onto its display's canvas
    /// Desktop, then those Desktops removed.
    struct Fold: Equatable, Sendable {
        var moves: [(window: CGWindowID, to: UInt64)] = []
        var removals: [UInt64] = []

        var isEmpty: Bool { moves.isEmpty && removals.isEmpty }

        static func == (a: Fold, b: Fold) -> Bool {
            a.removals == b.removals && a.moves.map(\.window) == b.moves.map(\.window) && a.moves.map(\.to) == b.moves.map(\.to)
        }
    }

    // MARK: Pure

    /// SLSCopyManagedDisplaySpaces' answer, read.
    static func displays(from raw: [[String: Any]]) -> [Display] {
        raw.compactMap { d in
            guard let identifier = d["Display Identifier"] as? String else { return nil }
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s -> Space? in
                guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, type: (s["type"] as? NSNumber)?.intValue ?? -1)
            }
            let current = ((d["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
            return Display(identifier: identifier, spaces: spaces, current: current)
        }
    }

    /// The Desktops beyond one per display.
    static func extraDesktops(_ displays: [Display]) -> Int {
        displays.reduce(0) { $0 + max($1.desktops.count - 1, 0) }
    }

    /// `windows`: each window and the Spaces it is on (SLSCopySpacesForWindows). A window on every Space,
    /// on a full-screen Space, or already on a canvas Desktop stays; one only on other Desktops moves to its
    /// display's canvas Desktop. In the order of `windows`.
    static func fold(_ displays: [Display], windows: [(CGWindowID, [UInt64])]) -> Fold {
        var fold = Fold()
        var canvasFor: [UInt64: UInt64] = [:]
        var canvases = Set<UInt64>()
        for display in displays {
            guard let canvas = display.canvasDesktop else { continue }
            canvases.insert(canvas)
            for desktop in display.desktops where desktop.id != canvas {
                canvasFor[desktop.id] = canvas
                fold.removals.append(desktop.id)
            }
        }
        for (window, spaces) in windows {
            guard !spaces.isEmpty, !spaces.contains(where: canvases.contains) else { continue }
            guard spaces.allSatisfy({ canvasFor[$0] != nil }), let to = canvasFor[spaces[0]] else { continue }
            fold.moves.append((window, to))
        }
        return fold
    }

    // MARK: Reading the Mac

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct SkyLight: @unchecked Sendable {
        let cid: Int32
        let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
        let copySpacesForWindows: CopySpacesForWindows
    }

    private static let skyLight: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cid = dlsym(handle, "SLSMainConnectionID"),
              let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let forWindows = dlsym(handle, "SLSCopySpacesForWindows") else {
            Log.note("Spaces: SkyLight's Space calls aren't available")
            return nil
        }
        return SkyLight(cid: unsafeBitCast(cid, to: MainConnection.self)(),
                        copyManagedDisplaySpaces: unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self),
                        copySpacesForWindows: unsafeBitCast(forWindows, to: CopySpacesForWindows.self))
    }()

    /// Every display's Spaces, now. Empty when SkyLight won't say.
    static func read() -> [Display] {
        guard let sky = skyLight, let raw = sky.copyManagedDisplaySpaces(sky.cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays(from: raw)
    }

    /// The Spaces `window` is on (current, other and hidden ones: mask 0x7).
    static func spaces(of window: CGWindowID) -> [UInt64] {
        guard let sky = skyLight,
              let ids = sky.copySpacesForWindows(sky.cid, 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return ids.map(\.uint64Value)
    }

    /// Whether a display's current Space is a full-screen app's.
    static func inFullScreenSpace(_ displays: [Display] = read()) -> Bool {
        displays.contains { d in d.spaces.first { $0.id == d.current }?.kind == .fullScreen }
    }

    /// Whether `window` is on a full-screen app's Space: in macOS's own full screen, whatever its app says.
    static func isInFullScreenSpace(_ window: CGWindowID, displays: [Display] = read()) -> Bool {
        let fullScreen = Set(displays.flatMap { $0.spaces.filter { $0.kind == .fullScreen }.map(\.id) })
        return !fullScreen.isEmpty && spaces(of: window).contains { fullScreen.contains($0) }
    }

    /// The full-screen apps' Spaces in front, one at most per display.
    static func frontFullScreenSpaces(_ displays: [Display]) -> Set<UInt64> {
        Set(displays.compactMap { d in d.spaces.first { $0.id == d.current && $0.kind == .fullScreen }?.id })
    }

    /// Whether any display has a full-screen app's Space.
    static func hasFullScreenSpaces(_ displays: [Display]) -> Bool {
        displays.contains { $0.spaces.contains { $0.kind == .fullScreen } }
    }

    /// Ordinary windows of other apps, on any Space: what folding moves.
    static func appWindows() -> [(id: CGWindowID, pid: pid_t)] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return (id, pid)
        }
    }

    // MARK: Folding

    /// Moves windows between Desktops and removes Desktops: what only the Dock can do.
    protocol Mover: AnyObject {
        /// Whether moving can happen now (the add-on in the Dock has the op).
        var isAvailable: Bool { get }
        func move(_ windows: [CGWindowID], to desktop: UInt64) -> Bool
        func remove(_ desktop: UInt64) -> Bool
    }

    /// The Dock add-on's (`DockSpaces`); tests put in their own.
    nonisolated(unsafe) static var mover: Mover = DockSpaces()

    /// The apps whose windows a fold just brought over, and until when: macOS brings such an app to the
    /// front as its window arrives, and that isn't the person going to it (`CanvasController.foreignActivation`).
    nonisolated(unsafe) private static var folding: (pids: Set<pid_t>, until: Date) = ([], .distantPast)
    private static let foldingLock = NSLock()
    static let quietAfterFold: TimeInterval = 3

    /// Whether `pid`'s window came over in a fold a moment ago.
    static func justFolded(_ pid: pid_t, now: Date = Date()) -> Bool {
        foldingLock.lock(); defer { foldingLock.unlock() }
        return now < folding.until && folding.pids.contains(pid)
    }

    static func noteFolding(_ pids: Set<pid_t>, now: Date = Date()) {
        foldingLock.lock(); defer { foldingLock.unlock() }
        folding = (pids, now.addingTimeInterval(quietAfterFold))
    }

    enum Outcome: Equatable {
        case nothingToFold
        /// No `mover` (the add-on doesn't have the op yet, or isn't loaded).
        case unavailable
        case folded(moved: Int, removed: Int)
        case failed
    }

    /// Every other Desktop folded into its display's canvas Desktop. Off the main thread is fine.
    @discardableResult
    static func fold() -> Outcome {
        let displays = read()
        let windows = appWindows()
        let plan = fold(displays, windows: windows.map { ($0.id, spaces(of: $0.id)) })
        guard !plan.isEmpty else { return .nothingToFold }
        guard mover.isAvailable else {
            Log.note("Spaces: \(plan.removals.count) other Desktop(s) to fold, but the add-on in the Dock can't move windows between Desktops (sunlight-55 can)")
            return .unavailable
        }
        let moving = Set(plan.moves.map(\.window))
        noteFolding(Set(windows.filter { moving.contains($0.id) }.map(\.pid)))
        var moved = 0
        for (to, group) in Dictionary(grouping: plan.moves, by: \.to) {
            let windows = group.map(\.window)
            if mover.move(windows, to: to) { moved += windows.count }
        }
        var removed = 0
        for desktop in plan.removals where mover.remove(desktop) { removed += 1 }
        Log.note("Spaces: folded \(moved) window(s) and removed \(removed) of \(plan.removals.count) Desktop(s)")
        return moved == plan.moves.count && removed == plan.removals.count ? .folded(moved: moved, removed: removed) : .failed
    }
}

/// The Dock add-on's Desktops op (sunlight-55). Whether the Dock's add-on has it is asked again after a
/// while, since the add-on is reloaded under a running Sunlight.
final class DockSpaces: Spaces.Mover, @unchecked Sendable {
    private let lock = NSLock()
    private var checked: (at: Date, has: Bool)?

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        if let checked, Date().timeIntervalSince(checked.at) < 10 { return checked.has }
        let has = LiveWindowsWire.spacesInDock(LiveWindowsConnection.version())
        checked = (Date(), has)
        return has
    }

    func move(_ windows: [CGWindowID], to desktop: UInt64) -> Bool {
        stride(from: 0, to: windows.count, by: LiveWindowsWire.maxWindows).allSatisfy { start in
            let some = Array(windows[start..<min(start + LiveWindowsWire.maxWindows, windows.count)])
            return answer(LiveWindowsWire.moveToDesktop(some, desktop: desktop), "moving \(some.count) window(s) to Desktop \(desktop)")
        }
    }

    func remove(_ desktop: UInt64) -> Bool {
        answer(LiveWindowsWire.removeDesktop(desktop), "removing Desktop \(desktop)")
    }

    private func answer(_ message: Data, _ what: String) -> Bool {
        guard let status = LiveWindowsConnection.answered(message) else {
            Log.note("Spaces: no answer from the Dock \(what)")
            return false
        }
        if status != 0 { Log.note("Spaces: the Dock refused \(what): \(LiveWindowsConnection.reason(for: status))") }
        return status == 0
    }
}

/// Watches for a Desktop appearing (Mission Control's +, a display's own Desktops coming back) and for
/// the Space changing, while takeover is on. A short while after there are Desktops to fold,
/// `onDesktopsToFold`; `onFullScreenChanged` says whether a full-screen app's Space is in front, and
/// `onFullScreenSpaces` whether there's one at all.
@MainActor
final class SpacesWatcher {
    var onFullScreenChanged: ((Bool) -> Void)?
    var onFullScreenSpaces: ((Bool) -> Void)?
    /// A full-screen app's Space was in front and isn't any more: the person stepped back out of it, or the
    /// app left full screen.
    var onLeftFullScreen: (() -> Void)?
    /// A full-screen app's Space came to the front: a window just went into macOS's own full screen (or
    /// the person went over to one that was).
    var onEnteredFullScreen: (() -> Void)?
    /// The full-screen apps' Spaces in front at the last look, across displays; nil before the first (the
    /// first look sets it quietly: a full-screen app already in front at start isn't one that just went).
    private var frontFullScreen: Set<UInt64>?
    var onDesktopsToFold: (() -> Void)?

    static let foldDelay: TimeInterval = 2
    /// While other Desktops are still there (a fold that couldn't happen: the add-on reloading, a Desktop
    /// refused), how long until it's tried again.
    static let retryInterval: TimeInterval = 30
    private static let pollInterval: TimeInterval = 3

    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var pendingFold: DispatchWorkItem?
    private var lastExtra = 0
    private var retryAt = Date.distantFuture

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Adding a Desktop doesn't change the active Space, so nothing says so: read now and then.
        let timer = Timer(timeInterval: SpacesWatcher.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        pendingFold?.cancel()
        pendingFold = nil
        frontFullScreen = nil
    }

    private func check() {
        let displays = Spaces.read()
        let inFullScreen = Spaces.inFullScreenSpace(displays)
        onFullScreenChanged?(inFullScreen)
        onFullScreenSpaces?(Spaces.hasFullScreenSpaces(displays))
        let front = Spaces.frontFullScreenSpaces(displays)
        if let before = frontFullScreen {
            // Per Space, not per Mac: a window going full screen on one display while another display
            // already shows a full-screen app is still news, and so is going from one to another.
            if !before.subtracting(front).isEmpty { onLeftFullScreen?() }
            if !front.subtracting(before).isEmpty { onEnteredFullScreen?() }
        }
        frontFullScreen = front
        let extra = Spaces.extraDesktops(displays)
        defer { lastExtra = extra }
        // Said once for each count, and again now and then while they stay: not every poll.
        guard extra > 0, pendingFold == nil, extra != lastExtra || Date() >= retryAt else { return }
        retryAt = Date().addingTimeInterval(SpacesWatcher.retryInterval)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingFold = nil
                self?.onDesktopsToFold?()
            }
        }
        pendingFold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SpacesWatcher.foldDelay, execute: work)
    }
}
