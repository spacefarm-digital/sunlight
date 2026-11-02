import AppKit

/// The chrome of a tile in Picture in Picture, as the macOS video PiP draws its: on hover, a dark strip
/// along the tile's top with the home button at its left (leave PiP, the window flies back to its place
/// on the canvas) and the app's icon and title after it; and, tucked away, the tab with a chevron that
/// brings the tile back. A click anywhere else on the tile returns the window to 1:1 where the tile is,
/// with the flight; a drag from anywhere moves the tile; a right-click offers both.
///
/// Each tile has a panel of its own, floating above everything so the chrome shows over the real window
/// however the canvas stands: up, away behind a window in use, or with another app in front. The panel
/// takes the presses on the tile (`ignoresMouseEvents` follows the pointer), but for a band along its
/// edges, which the canvas resizes the tile from, and a tile on its way somewhere, which takes none.
@MainActor
final class PipChrome {
    struct Tile: Equatable {
        let id: CGWindowID
        /// The tile on screen, in the canvas's view coordinates (the display's top-left at zero, y down).
        let rect: CGRect
        let tucked: PictureInPicture.Side?
        let title: String
        let pid: pid_t
        /// On its way somewhere: no chrome until it lands, and no press is the tile's.
        let flying: Bool
    }

    /// The band along the tile's edges the panel leaves to the canvas, for the resize from its edges.
    static let edgeBand: CGFloat = 8

    var onClose: ((CGWindowID) -> Void)?
    var onReturn: ((CGWindowID) -> Void)?
    var onUntuck: ((CGWindowID) -> Void)?
    /// A drag of the tile, in the canvas's view coordinates; `began` answers whether the canvas took it.
    var onDragBegan: ((CGWindowID, CGPoint) -> Bool)?
    var onDragMoved: ((CGPoint, TimeInterval) -> Void)?
    /// The drag's end, with whether ⌘ was held (the tile stays where it's dropped).
    var onDragEnded: ((TimeInterval, Bool) -> Void)?

    private var display: Display
    private var panels: [CGWindowID: PipChromePanel] = [:]
    private var monitors: [Any] = []

    init(display: Display) {
        self.display = display
    }

    func move(to display: Display) {
        self.display = display
    }

    /// The tiles as they stand now: a panel per tile, placed over it; the rest closed.
    func update(_ tiles: [Tile]) {
        for (id, panel) in panels where !tiles.contains(where: { $0.id == id }) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for tile in tiles {
            let panel = panels[tile.id] ?? makePanel(for: tile)
            panels[tile.id] = panel
            panel.tile = tile
            panel.setFrame(cocoaRect(tile.rect), display: false)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        if tiles.isEmpty {
            for m in monitors { NSEvent.removeMonitor(m) }
            monitors = []
        } else if monitors.isEmpty {
            let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] e in
                self?.pointerMoved()
                return e
            }) { monitors.append(m) }
        }
        pointerMoved()
    }

    private func makePanel(for tile: Tile) -> PipChromePanel {
        let panel = PipChromePanel(contentRect: cocoaRect(tile.rect), styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(LiveWindowsWire.pinnedLevel) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        // On the tile's Space only, as the tile itself is for now; full-screen apps are PR B's.
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        let view = PipChromeView(frame: NSRect(origin: .zero, size: tile.rect.size))
        view.onClose = { [weak self] in self?.onClose?(tile.id) }
        view.onReturn = { [weak self] in self?.onReturn?(tile.id) }
        view.onUntuck = { [weak self] in self?.onUntuck?(tile.id) }
        view.onDragBegan = { [weak self] point in self?.onDragBegan?(tile.id, self?.viewPoint(point) ?? point) ?? false }
        view.onDragMoved = { [weak self] point, t in self?.onDragMoved?(self?.viewPoint(point) ?? point, t) }
        view.onDragEnded = { [weak self] t, freely in self?.onDragEnded?(t, freely) }
        panel.contentView = view
        return panel
    }

    /// The pointer moved anywhere: the chrome of the tile under it shows, the others' fade, and the panel
    /// under it takes the presses, but for the edge band (the canvas's) and while the tile is flying.
    private func pointerMoved() {
        let global = NSEvent.mouseLocation   // AppKit, bottom-left
        for panel in panels.values {
            guard let tile = panel.tile, let view = panel.contentView as? PipChromeView else { continue }
            let inside = panel.frame.contains(global)
            let local = view.convert(panel.convertPoint(fromScreen: global), from: nil)
            let over = inside && !tile.flying && view.takesPress(at: local)
            panel.ignoresMouseEvents = !(over || view.isDragging)
            view.setShown(inside && !tile.flying)
        }
    }

    /// A view-coordinate rect of the display as an AppKit screen rect.
    private func cocoaRect(_ r: CGRect) -> NSRect {
        NSRect(x: display.cocoaFrame.minX + r.minX, y: display.cocoaFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// An AppKit screen point in the canvas's view coordinates.
    private func viewPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - display.cocoaFrame.minX, y: display.cocoaFrame.maxY - p.y)
    }
}

final class PipChromePanel: NSPanel {
    var tile: PipChrome.Tile? {
        didSet {
            guard let tile, let view = contentView as? PipChromeView else { return }
            view.tile = tile
        }
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the panel draws: the strip, its button and the tab, in a flipped (top-left) view so the
/// geometry is the same as the tile's (`PictureInPicture.Chrome`); and what a press on the tile does.
final class PipChromeView: NSView {
    var onClose: (() -> Void)?
    var onReturn: (() -> Void)?
    var onUntuck: (() -> Void)?
    var onDragBegan: ((NSPoint) -> Bool)?
    var onDragMoved: ((NSPoint, TimeInterval) -> Void)?
    var onDragEnded: ((TimeInterval, Bool) -> Void)?

    var tile: PipChrome.Tile? {
        didSet {
            if tile?.tucked != oldValue?.tucked || tile?.title != oldValue?.title || tile?.pid != oldValue?.pid { needsDisplay = true }
            if tile?.rect.size != oldValue?.rect.size { needsDisplay = true }
        }
    }
    private(set) var isDragging = false
    private var shown = false
    private var pressed: Button?
    private var fadeTimer: Timer?

    private enum Button { case home, tab }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { nil }

    /// The chrome in the view's own (flipped) coordinates: the strip and its button along the top, and
    /// the tab on whichever side of a tucked tile is still on screen.
    private struct Chrome {
        let strip: CGRect
        let home: CGRect
        let tab: CGRect?
    }

    private var chrome: Chrome? {
        guard let tile else { return nil }
        let local = CGRect(origin: .zero, size: tile.rect.size)
        let c = PictureInPicture.Chrome(tile: local, tucked: nil, visible: local)
        var tab: CGRect?
        let w = PictureInPicture.Reference.tabWidth
        switch tile.tucked {
        case .left: tab = CGRect(x: local.maxX - w, y: 0, width: w, height: local.height)
        case .right: tab = CGRect(x: 0, y: 0, width: w, height: local.height)
        case nil: tab = nil
        }
        return Chrome(strip: c.strip, home: c.home, tab: tab)
    }

    /// Whether a press at a point (local, flipped) is the panel's: on the tab of a tucked tile, or anywhere
    /// on a tile but the band along its edges, which the canvas resizes it from.
    func takesPress(at p: NSPoint) -> Bool {
        guard let c = chrome, let tile else { return false }
        if tile.tucked != nil { return c.tab?.contains(p) ?? false }
        return bounds.insetBy(dx: PipChrome.edgeBand, dy: PipChrome.edgeBand).contains(p)
    }

    /// The chrome fading in as the pointer arrives, out a moment after it leaves.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        fadeTimer?.invalidate()
        fadeTimer = nil
        if on {
            fade(to: 1)
        } else {
            fadeTimer = Timer.scheduledTimer(withTimeInterval: PictureInPicture.Reference.chromeLinger, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.fade(to: 0) }
            }
        }
    }

    private func fade(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PictureInPicture.Reference.chromeFade
            animator().alphaValue = alpha
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = chrome, let tile else { return }
        let dark = NSColor.black
        if let tab = c.tab, tile.tucked != nil {
            // The tab: a frosted dark pill at the screen's edge, a chevron pointing the way back on.
            let pill = NSBezierPath(roundedRect: tab.insetBy(dx: 0, dy: 8), xRadius: 6, yRadius: 6)
            dark.withAlphaComponent(0.55).setFill()
            pill.fill()
            chevron(in: tab, pointingLeft: tile.tucked == .right)
            return
        }
        // The strip: a gradient from dark at the top edge to clear, as a video's controls sit on, within
        // the tile's rounded corners.
        let radius = PictureInPicture.Reference.cornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
        let gradient = NSGradient(colors: [dark.withAlphaComponent(0.6), dark.withAlphaComponent(0.0)])
        gradient?.draw(in: c.strip, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        homeButton(in: c.home, pressed: pressed == .home)
        // The app's icon and title after the button, when there's room.
        let room = c.strip.maxX - c.home.maxX - 16 - c.home.minX
        if room > 60 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let text = NSAttributedString(string: tile.title, attributes: attrs)
            var size = text.size()
            let iconSize: CGFloat = 16
            let icon = NSRunningApplication(processIdentifier: tile.pid)?.icon
            var x = c.home.maxX + 10
            let midY = c.home.midY
            if let icon {
                icon.draw(in: NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += iconSize + 6
            }
            size.width = min(size.width, c.strip.maxX - c.home.minX - x)
            text.draw(with: NSRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The home button: a frosted circle with the "leave Picture in Picture" symbol (the small pane going
    /// back into the window), or a drawn one where the symbol is missing.
    private func homeButton(in r: NSRect, pressed: Bool) {
        let circle = NSBezierPath(ovalIn: r)
        NSColor.white.withAlphaComponent(pressed ? 0.45 : 0.25).setFill()
        circle.fill()
        let inset = r.width * 0.26
        let box = r.insetBy(dx: inset, dy: inset)
        if let symbol = NSImage(systemSymbolName: "pip.exit", accessibilityDescription: "Leave Picture in Picture")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: box.width * 0.9, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
            let size = symbol.size
            let drawn = NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
            symbol.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        // The fallback: a window frame with a small pane at its bottom-right and an arrow from the pane in.
        let frame = NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.8), xRadius: 1.5, yRadius: 1.5)
        frame.lineWidth = 1.4
        frame.stroke()
        let pane = NSRect(x: box.midX, y: box.midY, width: box.width * 0.5, height: box.height * 0.42)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: pane, xRadius: 1, yRadius: 1).fill()
        path.move(to: NSPoint(x: pane.minX - 1, y: pane.minY - 1)); path.line(to: NSPoint(x: box.minX + box.width * 0.2, y: box.minY + box.height * 0.2))
        path.stroke()
    }

    private func chevron(in r: NSRect, pointingLeft: Bool) {
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let midY = r.midY, w: CGFloat = 5, h: CGFloat = 7
        let x = r.midX + (pointingLeft ? w / 2 : -w / 2)
        path.move(to: NSPoint(x: x, y: midY - h))
        path.line(to: NSPoint(x: x + (pointingLeft ? -w : w), y: midY))
        path.line(to: NSPoint(x: x, y: midY + h))
        NSColor.white.setStroke()
        path.stroke()
    }

    private func hit(_ p: NSPoint) -> Button? {
        guard let c = chrome, let tile else { return nil }
        if tile.tucked != nil { return c.tab?.contains(p) == true ? .tab : nil }
        if c.home.contains(p) { return .home }
        return nil
    }

    /// Where the press began, for the drag; nil once the canvas refused the drag (the canvas away), so
    /// the release is no click either.
    private var dragStart: NSPoint?
    private var dragRefused = false

    override func mouseDown(with event: NSEvent) {
        guard tile?.flying != true else { return }
        let p = convert(event.locationInWindow, from: nil)
        pressed = hit(p)
        needsDisplay = true
        dragRefused = false
        guard pressed == nil, tile?.tucked == nil else { return }
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = dragStart {
            let now = NSEvent.mouseLocation
            if !isDragging {
                guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
                guard onDragBegan?(start) == true else { dragStart = nil; dragRefused = true; return }
                isDragging = true
            }
            onDragMoved?(now, event.timestamp)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; needsDisplay = true; dragStart = nil; dragRefused = false }
        if isDragging {
            isDragging = false
            onDragEnded?(event.timestamp, event.modifierFlags.contains(.command))
            return
        }
        guard tile?.flying != true else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let pressed {
            guard hit(p) == pressed else { return }
            switch pressed {
            case .home: onClose?()
            case .tab: onUntuck?()
            }
            return
        }
        // A click on the tile itself (let go where it was pressed, on a tile that isn't tucked): the window
        // returns to 1:1 where the tile is.
        guard dragStart != nil, !dragRefused, tile?.tucked == nil, bounds.contains(p) else { return }
        onReturn?()
    }

    /// A right-click: the two things the tile does, by name.
    override func rightMouseDown(with event: NSEvent) {
        guard let tile, !tile.flying else { return }
        let menu = NSMenu()
        if tile.tucked == nil {
            menu.addItem(withTitle: "Open Full Size", action: #selector(menuReturn), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Leave Picture in Picture", action: #selector(menuClose), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuReturn() { onReturn?() }
    @objc private func menuClose() { onClose?() }
}
