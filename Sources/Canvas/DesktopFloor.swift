import AppKit
import ApplicationServices
import Carbon.HIToolbox
import QuartzCore

/// Finder's desktop as the floor of the canvas: the files on it, Stacks, tags and the selection, exactly as
/// Finder draws them, under every window and widget, panning and zooming with them. Only the part with
/// files on it is drawn (`contentRect`), wherever the files' position setting puts it (`move(to:)`,
/// see `DesktopPlacement`).
///
/// Finder draws the desktop's icons in one screen-sized window of their own at the desktop-icon level
/// (layer -2147483603 on 27.2) with a clear background: the wallpaper is another window, Window Manager's.
/// The canvas covers it like every other window, so its pictures come from SkyLight's one-shot capture,
/// which works under the canvas (measured on 27.2: about 11 ms at 1x, 35 ms at 2x, transparent around the
/// icons) and leaves no capture pill. ScreenCaptureKit isn't involved: the canvas's listings leave the
/// desktop's windows out. The floor is captured again when something can have changed it: a file added,
/// renamed or removed on the desktop (a file-system watch on ~/Desktop), a selection Sunlight made, the
/// appearance or the Space changing, and the canvas coming back from a window; otherwise only as a
/// safety net every `refreshInterval` while it is in view. The listing of the files (Accessibility, a
/// Finder round trip off the main thread) runs with a file or selection change and the safety net, not
/// with every capture. Takeover leaves Finder's desktop on for it (it used to turn `CreateDesktop` off).
@MainActor
final class DesktopFloor {
    nonisolated static let finderBundleID = "com.apple.finder"
    /// The desktop-icon window level (`kCGDesktopIconWindowLevel`).
    nonisolated static var iconLevel: Int { Int(CGWindowLevelForKey(.desktopIconWindow)) }

    /// Finder's desktop icon window in the window server's listing; `bundleID` is the owner's. A Finder
    /// window at another level, or a small one at this level, isn't it.
    nonisolated static func isDesktop(_ w: WindowInfo, bundleID: String?) -> Bool {
        bundleID == finderBundleID && w.layer == iconLevel && w.bounds.width >= 200 && w.bounds.height >= 200
    }

    /// How stale the picture may get while it's in view, should a change slip past the watch.
    static let refreshInterval: CFTimeInterval = 20
    /// Above this zoom the floor is captured at 2x; below it, it's drawn smaller than the screen, and 1x does.
    static let backingZoom: CGFloat = 0.6
    /// A gap this long between listings means the canvas was away (in a window, or another app in
    /// front) without `noteReturn` being called: longer than the listing's own interval.
    static let awayGap: CFTimeInterval = 4.5

    /// Sits in the world under the windows (`CanvasView.setFloor`), in world units like a proxy's layer.
    let layer = CALayer()
    /// The part with files on it changed size or place (files added, moved or removed): it's placed again.
    var onContentChanged: (() -> Void)?
    /// Off with Sunlight › Desktop Files: nothing captured, nothing drawn.
    var isEnabled = Settings.showDesktopFloor {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { lastCapture = 0 } else { clear() }
        }
    }
    /// Finder's desktop window, while it's drawing one.
    private(set) var windowID: CGWindowID?
    /// Finder's desktop window on the screen, in screen points: the capture is of all of it.
    private(set) var screenRect: CGRect = .zero
    /// The part of it with files on it (`DesktopPlacement.filesContent`), in screen points: what's
    /// drawn. All of it until the files are listed, and when they can't be.
    private(set) var contentRect: CGRect = .zero
    /// Where that part is drawn in the world (`move(to:)`), at the content's size.
    private(set) var worldRect: CGRect = .zero
    /// The last capture, all of Finder's window; `contentRect` is cut from it.
    private var image: CGImage?
    private var capturing = false
    private var lastCapture: CFTimeInterval = 0
    private var lastBacking = false
    private var lastListing: CFTimeInterval = 0
    /// What the log last said, so a missing desktop or a failing capture is reported once, not every second.
    private enum Reported { case none, found, missing, failing }
    private var reported = Reported.none
    /// The files on the desktop as Accessibility last listed them, refreshed with each capture.
    private(set) var icons: [DesktopIcon] = []
    /// The selected files, as Finder has them: what Sunlight selected, or what was selected on the real
    /// desktop meanwhile (read with each listing).
    private(set) var selection: [DesktopIcon] = []
    /// Bumped by each selection Sunlight makes, so a listing that began before it can't undo it.
    private var selectionGeneration = 0
    /// Files to select once a listing has them (a folder just made).
    private var toSelect: [URL] = []
    /// The group holding them, which takes the selection.
    private var group: AXHandle?
    private var listingIcons = false
    /// ~/Desktop, watched for files coming and going.
    private var watch: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []

    init() {
        startWatching()
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        // Far out, the floor is drawn at a fraction of its size: mipmaps keep the labels from shimmering.
        layer.minificationFilter = .trilinear
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
                         "transform": NSNull()]
    }

    /// The canvas's look at the desktop (the 1 s listing, with the canvas in front). `desktop` is Finder's
    /// desktop window in it, nil when Finder isn't drawing one. `visibleWorld` is what the camera shows;
    /// `zoom` decides the detail.
    /// The canvas is back in front: whatever happened on the desktop meanwhile shows with the next listing.
    func noteReturn() {
        returned = true
    }
    private var returned = false

    func update(desktop: WindowInfo?, visibleWorld: CGRect, zoom: CGFloat) {
        let now = CACurrentMediaTime()
        let wasAway = returned || now - lastListing > DesktopFloor.awayGap
        returned = false
        lastListing = now
        guard isEnabled else { return }
        guard let desktop else {
            if windowID != nil { clear() }
            report(.missing, "Finder isn't drawing the desktop (Desktop › Show Items › On Desktop off, or CreateDesktop false): no floor")
            return
        }
        if desktop.id != windowID || desktop.bounds != screenRect {
            windowID = desktop.id
            screenRect = desktop.bounds
            // Where the screen is at 1:1 the first time, until the controller says otherwise (it does at once).
            setContent(desktop.bounds)
            lastCapture = 0
            report(.found, "Finder's desktop is the floor (window \(desktop.id), \(Int(desktop.bounds.width))×\(Int(desktop.bounds.height)))")
            onContentChanged?()
        }
        guard visibleWorld.intersects(worldRect) else { return }
        let backing = zoom > DesktopFloor.backingZoom
        if wasAway || now - lastCapture >= DesktopFloor.refreshInterval {
            capture(backing: backing, listing: true)
        } else if backing && !lastBacking {
            capture(backing: backing)
        }
    }

    /// Files coming and going on ~/Desktop (the watch), and the appearance and the Space: each one a
    /// fresh picture and listing, a moment later, as `refreshSoon` does for a selection.
    private func startWatching() {
        let fd = open(DesktopFiles.folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watch = source
        } else {
            Log.note("Desktop: can't watch ~/Desktop (\(String(cString: strerror(errno)))); the floor refreshes on its own clock")
        }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main, using: refresh))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: refresh))
    }

    /// The file under a world point on the floor: its picture or its label.
    func icon(atWorld p: CGPoint) -> DesktopIcon? {
        guard contains(p) else { return nil }
        let s = screenPoint(forWorld: p)
        return icons.last { $0.hitRect.contains(s) }
    }

    /// Where a world point on the floor is on Finder's desktop, in screen points.
    func screenPoint(forWorld p: CGPoint) -> CGPoint {
        let k = contentRect.width / max(1, worldRect.width)
        return CGPoint(x: contentRect.minX + (p.x - worldRect.minX) * k, y: contentRect.minY + (p.y - worldRect.minY) * k)
    }

    /// Where a rect on Finder's desktop (a file's picture) is drawn in the world.
    func worldRect(forScreen r: CGRect) -> CGRect {
        let k = worldRect.width / max(1, contentRect.width)
        return CGRect(x: worldRect.minX + (r.minX - contentRect.minX) * k, y: worldRect.minY + (r.minY - contentRect.minY) * k,
                      width: r.width * k, height: r.height * k)
    }

    /// Draws the floor at a new world rect: gliding there over `duration` when it's given, as a dropped
    /// window settles.
    func move(to rect: CGRect, duration: CFTimeInterval? = nil) {
        guard rect != worldRect else { return }
        let from = layer.presentation()?.position ?? layer.position
        worldRect = rect
        place()
        guard let duration, layer.superlayer != nil else { return }
        let glide = CABasicAnimation(keyPath: "position")
        glide.fromValue = NSValue(point: from)
        glide.toValue = NSValue(point: layer.position)
        glide.duration = duration
        glide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(glide, forKey: "glide")
    }

    /// Whether a world point is on the floor.
    func contains(_ p: CGPoint) -> Bool {
        isEnabled && windowID != nil && worldRect.contains(p)
    }

    /// Selects files on the real desktop (none: deselects), as clicks there would; the floor shows it a
    /// moment later.
    func select(_ icons: [DesktopIcon]) {
        selection = icons
        selectionGeneration += 1
        guard let group else { return }
        let elements = icons.map(\.element)
        AXQueue.interactive.async {
            let error = AXUIElementSetAttributeValue(group.element, kAXSelectedChildrenAttribute as CFString, elements as CFArray)
            if error != .success { Log.note("Desktop: couldn't select on Finder's desktop (\(error.rawValue))") }
        }
        refreshSoon()
    }

    /// Selects these files as soon as a listing finds them.
    func select(urls: [URL]) {
        toSelect = urls.map(\.standardizedFileURL)
        refreshSoon()
    }

    /// Something on the desktop just changed (a selection, a rename, a new folder, a file arriving):
    /// capture and list again shortly, a few times, as Finder takes a moment to redraw. Changes that
    /// land within the same moment share one round.
    func refreshSoon() {
        guard isEnabled, windowID != nil, !refreshing else { return }
        refreshing = true
        for (i, delay) in [0.08, 0.5, 1.2].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if i == 2 { self.refreshing = false }
                self.capture(backing: self.lastBacking, listing: true)
            }
        }
    }
    private var refreshing = false

    private func listIcons() {
        guard !listingIcons else { return }
        listingIcons = true
        let generation = selectionGeneration
        AXQueue.background.async {
            let listing = FinderDesktopIcons.list()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.listingIcons = false
                    self.group = listing?.group
                    let icons = listing?.icons ?? []
                    self.icons = icons
                    self.trim(listed: listing != nil)
                    if !self.toSelect.isEmpty {
                        let wanted = icons.filter { $0.url.map { self.toSelect.contains($0.standardizedFileURL) } ?? false }
                        if !wanted.isEmpty {
                            self.toSelect = []
                            self.select(wanted)
                            return
                        }
                    }
                    if generation == self.selectionGeneration {
                        // Finder's word, now that nothing Sunlight did is in flight.
                        let selected = listing?.selected ?? []
                        self.selection = icons.filter { selected.contains($0.key) }
                    } else {
                        // Sunlight's selection, carried over to the fresh elements; files gone drop out.
                        let keys = Set(self.selection.map(\.key))
                        self.selection = icons.filter { keys.contains($0.key) }
                    }
                }
            }
        }
    }

    /// A fresh picture; with `listing`, a fresh list of the files too.
    private func capture(backing: Bool, listing: Bool = false) {
        guard let id = windowID, !capturing else { return }
        if listing { listIcons() }
        capturing = true
        lastCapture = CACurrentMediaTime()
        OneShotCapture.capture(windowID: id, backing: backing) { [weak self] image in
            guard let self else { return }
            self.capturing = false
            guard self.isEnabled, self.windowID == id else { return }
            guard let image else {
                self.report(.failing, "couldn't capture Finder's desktop (Screen Recording granted?)")
                return
            }
            if self.reported == .failing { self.report(.found, "capturing Finder's desktop again") }
            self.lastBacking = backing
            self.image = image
            self.showImage()
        }
    }

    /// The listed files' part of the desktop is what's drawn; all of it when they couldn't be listed
    /// (no Accessibility), so no file goes missing.
    private func trim(listed: Bool) {
        guard windowID != nil else { return }
        let content = listed ? DesktopPlacement.filesContent(hitRects: icons.map(\.hitRect), screen: screenRect) : screenRect
        guard content != contentRect else { return }
        setContent(content)
        showImage()
        onContentChanged?()
    }

    /// A new part of the desktop to draw: the files stay where they were in the world, the floor grows or
    /// shrinks around them, until the controller places it again.
    private func setContent(_ content: CGRect) {
        worldRect = worldRect == .zero || contentRect.isEmpty ? content : worldRect(forScreen: content)
        contentRect = content
        place()
    }

    /// The capture, cut to `contentRect`.
    private func showImage() {
        guard let image, screenRect.width > 0 else { return }
        let scale = CGFloat(image.width) / screenRect.width
        let cut = CGRect(x: (contentRect.minX - screenRect.minX) * scale, y: (contentRect.minY - screenRect.minY) * scale,
                         width: contentRect.width * scale, height: contentRect.height * scale).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = cut == CGRect(x: 0, y: 0, width: image.width, height: image.height) ? image : image.cropping(to: cut)
        CATransaction.commit()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = caRect(worldRect)
        layer.bounds = CGRect(origin: .zero, size: r.size)
        layer.position = r.origin
        CATransaction.commit()
    }

    private func clear() {
        windowID = nil
        image = nil
        screenRect = .zero
        icons = []
        selection = []
        group = nil
        lastCapture = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
    }

    private func report(_ state: Reported, _ message: String) {
        guard reported != state else { return }
        reported = state
        Log.note("Desktop: \(message)")
    }
}

/// An Accessibility element handed between queues: the API is safe to call from any thread.
struct AXHandle: @unchecked Sendable {
    let element: AXUIElement
}

/// One file on Finder's desktop, as Accessibility describes it: an AXImage in the desktop's group, with
/// the file's name and URL and the frame of its picture (64 pt on 27.2; the label below isn't in it).
struct DesktopIcon: @unchecked Sendable {
    let element: AXUIElement
    let name: String
    let url: URL?
    /// The picture, in screen coordinates (top-left origin, points).
    let frame: CGRect

    /// Which file it is, across listings (each listing has fresh elements).
    var key: String { url?.standardizedFileURL.path ?? name }

    /// What a click on the desktop hits: the picture, and the label under it, which runs wider.
    var hitRect: CGRect {
        CGRect(x: frame.minX - 20, y: frame.minY - 4, width: frame.width + 40, height: frame.height + 40)
    }
}

/// Finder's desktop through Accessibility: a full-screen AXScrollArea among Finder's windows, holding a
/// group with one AXImage per file (measured on 27.2). Selecting goes through the group's selected
/// children (the icons' own selected flag is read-only); opening goes through NSWorkspace.
enum FinderDesktopIcons {
    /// Blocks on Finder for up to half a second; call it off the main thread. Nil when Finder isn't
    /// running or isn't drawing the desktop, or without Accessibility.
    nonisolated static func list() -> (group: AXHandle, icons: [DesktopIcon], selected: Set<String>)? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: DesktopFloor.finderBundleID).first else {
            return nil
        }
        let app = AXWindow.application(finder.processIdentifier, timeout: 0.5)
        guard let area = app.elements(kAXWindowsAttribute).first(where: { $0.string(kAXRoleAttribute) == kAXScrollAreaRole }) else {
            return nil
        }
        let group = area.children.first { $0.string(kAXRoleAttribute) == kAXGroupRole } ?? area
        let icons = group.children.compactMap { e -> DesktopIcon? in
            guard let frame = e.frame, frame.width > 0, frame.height > 0 else { return nil }
            let url = fileURL(of: e)
            let name = e.string(kAXTitleAttribute) ?? e.string(kAXFilenameAttribute) ?? url?.lastPathComponent ?? ""
            return DesktopIcon(element: e, name: name, url: url, frame: frame)
        }
        let selected = group.elements(kAXSelectedChildrenAttribute)
        let keys = icons.filter { icon in selected.contains { CFEqual($0, icon.element) } }.map(\.key)
        return (AXHandle(element: group), icons, Set(keys))
    }

    nonisolated private static func fileURL(of e: AXUIElement) -> URL? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &ref) == .success else { return nil }
        if let url = ref as? URL { return url }
        if let string = ref as? String { return URL(string: string) }
        return nil
    }
}

/// What the desktop's own menus do, done by Sunlight for a file on the floor or the floor itself.
enum DesktopFiles {
    /// ~/Desktop.
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// "untitled folder", or "untitled folder 2", 3… when that's taken, as Finder names a new folder.
    nonisolated static func untitledFolderName(existing: [String]) -> String {
        let base = "untitled folder"
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A name a file can be renamed to: not empty, no slash, not a dot name, and actually different.
    nonisolated static func validRename(_ name: String, from old: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }

    /// The selection after a click on file `key`, by Finder's rules: ⌘ toggles it, ⇧ adds it, a plain
    /// click selects it alone, except on one already selected, which keeps the others until the button
    /// comes up (`released`) without a drag, so the whole selection can be dragged. Nil: no change.
    nonisolated static func click(on key: String, in selection: [String], command: Bool, shift: Bool,
                                  released: Bool) -> [String]? {
        let selected = selection.contains(key)
        if released {
            return !command && !shift && selected && selection.count > 1 ? [key] : nil
        }
        if command { return selected ? selection.filter { $0 != key } : selection + [key] }
        if shift { return selected ? nil : selection + [key] }
        return selected ? nil : [key]
    }

    /// What a key does while the desktop's files have the canvas's attention.
    enum Command: Equatable {
        case open, trash, copy, rename, selectAll, deselect
    }

    /// Finder's desktop keys: ⌘O and ⌘↓ open, ⌘⌫ moves to the Trash, ⌘C copies, ⏎ renames, ⌘A selects
    /// everything, Esc deselects.
    nonisolated static func command(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> Command? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        if mods == .command {
            switch keyCode {
            case kVK_ANSI_O, kVK_DownArrow: return .open
            case kVK_Delete: return .trash
            case kVK_ANSI_C: return .copy
            case kVK_ANSI_A: return .selectAll
            default: return nil
            }
        }
        guard mods.isEmpty else { return nil }
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .rename
        case kVK_Escape: return .deselect
        default: return nil
        }
    }
}

/// Menu items whose actions are closures, for menus built by code that isn't an NSObject. The items hold
/// their target weakly, so whoever builds the menu keeps this alive while it's up.
@MainActor
final class MenuActions: NSObject {
    private var actions: [() -> Void] = []

    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
