import AppKit

/// An arrangement of the canvas: where every window and widget sits on it, how big each window is, and
/// the camera. Saved by name (Layouts › Save Layout…) or remembered between launches. World coordinates
/// throughout, as on the canvas.
struct Layout: Codable {
    var name: String
    var saved: Date
    /// The camera, as the world point in the middle of the screen and the zoom, so it holds up on a
    /// screen of another size.
    var center: Point
    var zoom: Double
    /// Bottom to top, as they stack.
    var entries: [Entry]
    /// The background, when the layout was saved with "Remember the background"; restoring brings it back.
    var background: BackgroundSpec?
    /// Every display's camera, by display UUID, when there was more than one (`Desk`); `center` and `zoom`
    /// are the main display's.
    var cameras: [String: DisplayCamera]?

    /// One display's camera, as `center` and `zoom` are the main one's.
    struct DisplayCamera: Codable, Equatable {
        var center: Point
        var zoom: Double
    }

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct Rect: Codable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var origin: CGPoint { CGPoint(x: x, y: y) }
        var size: CGSize { CGSize(width: width, height: height) }
        var cgRect: CGRect { CGRect(origin: origin, size: size) }
    }

    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case window, widget }
        var kind: Kind
        var bundleID: String?
        /// The app's name; a widget's own ("Weather").
        var appName: String
        var title: String
        /// The file the window showed (a file URL), so a restore can open it again.
        var document: String?
        /// A widget's Accessibility identifier, `widget-local:<app>:<extension>:<kind>`.
        var widget: String?
        /// The window's ID when it was saved: still the same window while it lives (Canvas relaunched,
        /// the app not).
        var windowID: UInt32
        /// Where it was on the canvas. A widget's is its card.
        var frame: Rect
        /// Its magnetic pole, "plus" or "minus" (`Polarity`); nil for a widget, or from before there were
        /// poles. Kept as a string so a value this build doesn't know can't spoil the whole file.
        var polarity: String?
        /// The group it's bonded into, numbered from 0 within the layout (`Grouping.saved`); nil when free.
        var group: Int?
        /// In Picture in Picture (`PictureInPicture`): its tile's top-left on screen, its scale and, tucked
        /// away, the side; nil when not.
        var pip: Pip?
    }

    /// A tile as saved: view coordinates of the display the layout was saved on; `tucked` is a
    /// `PictureInPicture.Side` raw value, or nil.
    struct Pip: Codable, Equatable {
        var x: Double
        var y: Double
        var scale: Double
        var tucked: Int?
    }

    /// Everything the layout covers on the canvas.
    var bounds: CGRect? {
        guard let first = entries.first else { return nil }
        return entries.dropFirst().reduce(first.frame.cgRect) { $0.union($1.frame.cgRect) }
    }

    /// Same windows in the same places, same camera: nothing worth writing down again.
    func sameArrangement(as other: Layout) -> Bool {
        entries == other.entries && center == other.center && zoom == other.zoom && cameras == other.cameras
    }
}

@MainActor
extension Layout {
    /// The canvas as it is now. `documents` is the file each window shows, by window, looked up through
    /// Accessibility beforehand (off the main thread); only a named layout needs them, to reopen what's gone.
    /// `groups` is the group number of each bonded window (`Grouping.saved`).
    init(name: String, proxies: [WindowProxy], camera: Camera, viewSize: CGSize, documents: [CGWindowID: String] = [:],
         groups: [CGWindowID: Int] = [:]) {
        let c = camera.center(viewSize: viewSize)
        self.init(name: name, saved: Date(), center: Point(x: c.x, y: c.y), zoom: camera.zoom,
                  entries: proxies.map { Entry($0, document: $0.kind == .window ? documents[$0.windowID] : nil, group: groups[$0.windowID]) })
    }

    func camera(viewSize: CGSize) -> Camera {
        Layout.camera(center: center, zoom: zoom, viewSize: viewSize)
    }

    /// The camera of the display with this UUID: its own when it was written down, else the main
    /// display's for the lead canvas (a layout from before there was a camera per display) and none for
    /// another display's.
    func camera(for display: String, lead: Bool, viewSize: CGSize) -> Camera? {
        if let own = cameras?[display] { return Layout.camera(center: own.center, zoom: own.zoom, viewSize: viewSize) }
        return lead ? camera(viewSize: viewSize) : nil
    }

    private static func camera(center: Point, zoom: Double, viewSize: CGSize) -> Camera {
        let zoom = min(CanvasView.maxZoom, max(CanvasView.minZoom, CGFloat(zoom)))
        return Camera(center: CGPoint(x: center.x, y: center.y), zoom: zoom, viewSize: viewSize)
    }

    /// A display's camera as written down.
    static func displayCamera(_ camera: Camera, viewSize: CGSize) -> DisplayCamera {
        let c = camera.center(viewSize: viewSize)
        return DisplayCamera(center: Point(x: c.x, y: c.y), zoom: camera.zoom)
    }

    /// Pairs saved entries with proxies on the canvas, each proxy at most once, surest first: the very same
    /// window (its ID lasts as long as it does), the same widget, the same document, the same title, and
    /// last whatever window of the same app is left, in order. `document` looks up the file a proxy's
    /// window shows; it's only asked about windows of an app that had one.
    static func match(_ entries: [Entry], _ proxies: [WindowProxy],
                      document: (WindowProxy) -> String? = { _ in nil }) -> [(entry: Int, proxy: WindowProxy)] {
        var pairs: [(entry: Int, proxy: WindowProxy)] = []
        var open = Array(entries.indices)
        var free = proxies

        func pass(_ same: (Entry, WindowProxy) -> Bool) {
            open.removeAll { i in
                guard let j = free.firstIndex(where: { same(entries[i], $0) }) else { return false }
                pairs.append((i, free.remove(at: j)))
                return true
            }
        }
        // Every widget is Notification Center's: one only stands in for a widget of the same name.
        func sameApp(_ e: Entry, _ p: WindowProxy) -> Bool {
            e.kind == Entry.Kind(p.kind) && e.bundleID == p.bundleID && (e.kind == .window || e.appName == p.appName)
        }
        pass { e, p in sameApp(e, p) && e.windowID == p.windowID }
        pass { e, p in sameApp(e, p) && e.widget != nil && e.widget == p.widget?.identifier }
        pass { e, p in sameApp(e, p) && e.document != nil && e.document == document(p) }
        pass { e, p in sameApp(e, p) && e.title == p.title }
        pass { e, p in sameApp(e, p) }
        return pairs
    }
}

@MainActor
extension Layout.Entry {
    init(_ p: WindowProxy, document: String?, group: Int? = nil) {
        kind = Kind(p.kind)
        bundleID = p.bundleID
        appName = p.appName
        title = p.title
        self.document = document
        widget = p.widget?.identifier
        windowID = p.windowID
        frame = Layout.Rect(x: p.worldRect.minX, y: p.worldRect.minY, width: p.worldRect.width, height: p.worldRect.height)
        polarity = p.polarity?.rawValue
        self.group = group
        pip = p.pip.map { Layout.Pip(x: $0.origin.x, y: $0.origin.y, scale: $0.scale, tucked: p.pipTucked?.rawValue) }
    }
}

extension Layout.Entry {
    /// The file the window showed, as a URL the app can open.
    var documentURL: URL? { document.flatMap(URL.init(string:)) }
}

extension Layout.Entry.Kind {
    init(_ kind: WindowProxy.Kind) {
        switch kind {
        case .window: self = .window
        case .widget: self = .widget
        }
    }
}

/// Layouts on disk, as JSON in ~/Library/Application Support/Sunlight/: legible, and editable by hand while
/// Sunlight isn't running. Canvas.json is the canvas as it was last seen, Layouts.json the saved layouts in
/// the order they were first saved.
@MainActor
enum LayoutStore {
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sunlight", isDirectory: true)
    private static let rememberedURL = folder.appendingPathComponent("Canvas.json")
    private static let layoutsURL = folder.appendingPathComponent("Layouts.json")
    private static var lastRemembered: Layout?

    static var remembered: Layout? { read(Layout.self, from: rememberedURL) }

    /// Where the app keeps what it writes down.
    static var directory: URL { folder }

    /// Writes the canvas down, unless it's arranged just as it was last time.
    static func remember(_ layout: Layout) {
        if let last = lastRemembered, last.sameArrangement(as: layout) { return }
        if write(layout, to: rememberedURL) { lastRemembered = layout }
    }

    static var layouts: [Layout] { readLayouts().items }

    private static func readLayouts() -> (items: [Layout], intact: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SavedList.read(Layout.self, from: layoutsURL, decoder: decoder)
    }

    /// Saving under a name that's taken replaces that layout, in its place in the order.
    static func save(_ layout: Layout) {
        let read = readLayouts()
        guard read.intact || SavedList.setAside(layoutsURL) != nil else { return }
        var all = read.items
        if let i = all.firstIndex(where: { $0.name == layout.name }) {
            all[i] = layout
        } else {
            all.append(layout)
        }
        write(all, to: layoutsURL)
    }

    static func delete(name: String) {
        let read = readLayouts()
        guard read.intact || SavedList.setAside(layoutsURL) != nil else { return }
        write(read.items.filter { $0.name != name }, to: layoutsURL)
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            NSLog("Layout: can't read \(url.path) — \(error)")
            return nil
        }
    }

    @discardableResult
    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Layout: can't write \(url.path) — \(error)")
            return false
        }
    }
}

/// The questions saving and restoring ask.
@MainActor
enum LayoutPrompt {
    /// The name to save the canvas under, and whether the background goes with it; nil if cancelled. A
    /// name that's taken asks before replacing.
    static func name(existing: [String]) -> (name: String, withBackground: Bool)? {
        var n = existing.count + 1
        while existing.contains("Layout \(n)") { n += 1 }

        let field = NSTextField(string: "Layout \(n)")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        let background = NSSwitch()
        background.state = Settings.rememberBackgroundInLayouts ? .on : .off
        let accessory = NSStackView(views: [field, NSSwitch.row("Remember the background", background, width: 260)])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Saves where every window and widget is on the canvas, how big each window is, and the view."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // From the menu bar icon, over whatever app is in front: Sunlight has to be active to type the name.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let withBackground = background.state == .on
        Settings.rememberBackgroundInLayouts = withBackground
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard existing.contains(name) else { return (name, withBackground) }
        let replace = NSAlert()
        replace.messageText = "Replace “\(name)”?"
        replace.informativeText = "A layout with that name already exists. Saving replaces it with the canvas as it is now."
        replace.addButton(withTitle: "Replace")
        replace.addButton(withTitle: "Cancel")
        return replace.runModal() == .alertFirstButtonReturn ? (name, withBackground) : nil
    }

    /// What to do with the windows on the canvas that aren't in the layout; nil if cancelled. "Do this
    /// every time" makes the choice the setting, so it isn't asked again.
    static func otherWindows(_ count: Int, layout: String) -> Settings.OtherWindows? {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 window isn’t in “\(layout)”" : "\(count) windows aren’t in “\(layout)”"
        alert.informativeText = "Leave them where they are on the canvas, move them aside to the right of the layout, or close them."
        alert.addButton(withTitle: "Leave Them")
        alert.addButton(withTitle: "Move Aside")
        let close = alert.addButton(withTitle: "Close Them")
        close.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do this every time"

        let choice: Settings.OtherWindows
        switch alert.runModal() {
        case .alertFirstButtonReturn: choice = .leave
        case .alertSecondButtonReturn: choice = .moveAside
        case .alertThirdButtonReturn: choice = .close
        default: return nil
        }
        if alert.suppressionButton?.state == .on { Settings.otherWindows = choice }
        return choice
    }
}

/// A file that is a JSON list of things saved by name (Layouts.json), read one entry at a
/// time: an entry that can't be read (edited by hand, or written by a newer Sunlight) costs only itself,
/// not the list. A list that isn't read whole is never written over as it is: the file is copied aside
/// first, so a save or a delete can't wipe out what couldn't be read.
enum SavedList {
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// The entries that could be read, and whether that's the whole file. No file is an intact, empty list.
    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> (items: [T], intact: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], true) }
        guard let data = try? Data(contentsOf: url) else {
            NSLog("Saved: can't open \(url.path)")
            return ([], false)
        }
        let entries: [Lossy<T>]
        do {
            entries = try decoder.decode([Lossy<T>].self, from: data)
        } catch {
            NSLog("Saved: can't read \(url.path) — \(error)")
            return ([], false)
        }
        let items = entries.compactMap(\.value)
        if items.count < entries.count {
            NSLog("Saved: \(entries.count - items.count) of \(entries.count) entries in \(url.lastPathComponent) can't be read; the rest are used")
        }
        return (items, items.count == entries.count)
    }

    /// A copy of `url` beside it, "Layouts (unreadable 2026-10-28 10.52.07).json", before a write replaces
    /// a file that wasn't read whole. Nil when the copy couldn't be made: then nothing may be written.
    @discardableResult
    static func setAside(_ url: URL, at date: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = url.deletingPathExtension().lastPathComponent
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem) (unreadable \(formatter.string(from: date))).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            NSLog("Saved: kept \(url.lastPathComponent) as \(copy.lastPathComponent) before writing over it")
            return copy
        } catch {
            NSLog("Saved: couldn't keep a copy of \(url.path) (\(error.localizedDescription)); not writing over it")
            return nil
        }
    }
}
