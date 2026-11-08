import AppKit

/// The card that stands beside System Settings while setup waits on Accessibility or Screen Recording:
/// Sunlight's icon, to drag into the Privacy list when macOS didn't add Sunlight to it by itself (a copy
/// moved after its first launch, a reset list, a prompt dismissed, or macOS 26 not adding new apps at
/// all). Dropping an app on that list adds it once the password or Touch ID prompt is confirmed.
///
/// A hand shows how, on a loop: it picks the icon up off the card and carries a ghost of it into the list
/// (`DragHintWindow`, click-through, over both). The card and the hand follow the System Settings window
/// (looked up by its process, so no Screen Recording is needed for the window's bounds), show only while
/// System Settings is in front, and never take the front or key, so the drag starts from the card without
/// Sunlight coming forward. The wizard hides them once it comes back, or once the switch is on.
@MainActor
final class PermissionDragPanel {
    enum Permission: String {
        case accessibility = "Accessibility"
        case screenRecording = "Screen Recording"
    }

    static let shared = PermissionDragPanel()
    static let settingsBundleID = "com.apple.systempreferences"
    static let size = NSSize(width: 232, height: 244)
    static let gap: CGFloat = 16
    /// After a drop the hand rests this long while the password prompt and the list catch up.
    static let restAfterDrop: TimeInterval = 15

    private var panel: DragPanelWindow?
    private var hint: DragHintWindow?
    private var timer: Timer?
    private var startedAt: Date?
    /// Where System Settings' window was last seen, for telling a drop on it from one elsewhere.
    private var settingsFrame: NSRect?
    private(set) var permission: Permission?

    /// Stands beside System Settings from now on, for the step named.
    func show(for permission: Permission) {
        self.permission = permission
        startedAt = Date()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if hint == nil { hint = DragHintWindow() }
        panel.content.permission = permission
        hint?.resume()
        // Back during hide's fade: a fresh animation to 1 takes over from the one running to 0.
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        follow()
    }

    /// The wizard is back, or the step is done.
    func hide() {
        timer?.invalidate()
        timer = nil
        permission = nil
        startedAt = nil
        hint?.stop()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.permission == nil { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> DragPanelWindow {
        let panel = DragPanelWindow(contentRect: NSRect(origin: .zero, size: Self.size))
        panel.content.onDismiss = { [weak self] in self?.hide() }
        // Only a drop on the System Settings window counts: one on the Dock or a Finder window added nothing.
        panel.content.onDrop = { [weak self] point in
            guard let self, self.settingsFrame?.contains(point) == true else { return }
            self.hint?.rest(for: Self.restAfterDrop)
        }
        return panel
    }

    private func follow() {
        guard let panel, let hint, permission != nil else { return }
        // Ten minutes is long enough for any step; past that the person has gone elsewhere.
        let dragging = panel.content.dragging
        if let startedAt, Date().timeIntervalSince(startedAt) > 600, !dragging { return hide() }
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier == Self.settingsBundleID || dragging,
              let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first,
              let window = Self.frontWindow(of: settings.processIdentifier),
              let screen = Self.screen(containing: window) else {
            if panel.isVisible, !dragging {
                panel.alphaValue = 0
                panel.orderOut(nil)
                hint.stop()
            }
            return
        }
        settingsFrame = window
        let frame = Self.place(Self.size, by: window, in: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
        let from = panel.convertToScreen(panel.content.iconFrame)
        hint.update(from: NSPoint(x: from.midX, y: from.midY), to: Self.dropPoint(in: window),
                    iconSide: from.width, paused: dragging)
    }

    // MARK: Where

    /// The card's level, and the hand's just over it: above any level Sunlight's canvas lifts a window
    /// it's showing to (the entered window sits at 2), under menus and the system's own prompts.
    static let cardLevel = NSWindow.Level.modalPanel
    static let hintLevel = NSWindow.Level(rawValue: NSWindow.Level.modalPanel.rawValue + 1)

    /// The frontmost window of a process, in AppKit's coordinates (origin bottom-left of the main
    /// display). Any layer under the card's, since Sunlight lifts the window it's showing off layer 0.
    /// Bounds come with no Screen Recording; titles wouldn't, and aren't needed.
    static func frontWindow(of pid: pid_t) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < cardLevel.rawValue,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 200, bounds.height > 150 else { continue }
            return flip(bounds)
        }
        return nil
    }

    /// A rect in the window server's top-left coordinates into AppKit's bottom-left ones.
    static func flip(_ rect: CGRect, mainHeight: CGFloat? = nil) -> NSRect {
        let height = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen the window's middle is on; none when it's parked off every screen (Sunlight keeps
    /// windows that aren't in view off to the side), and then the card stays away too.
    private static func screen(containing window: NSRect) -> NSScreen? {
        let center = NSPoint(x: window.midX, y: window.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    /// Beside the window, level with the top of its list: on the right where it fits on the screen,
    /// else on the left, else under it, else just inside its bottom-right corner. On screen either way.
    static func place(_ size: NSSize, by window: NSRect, in visible: NSRect) -> NSRect {
        let top = window.maxY - 90 - size.height
        let right = NSRect(x: window.maxX + gap, y: top, width: size.width, height: size.height)
        let left = NSRect(x: window.minX - gap - size.width, y: top, width: size.width, height: size.height)
        let below = NSRect(x: window.midX - size.width / 2, y: window.minY - gap - size.height,
                           width: size.width, height: size.height)
        let inside = NSRect(x: window.maxX - gap - size.width, y: window.minY + gap, width: size.width, height: size.height)
        let chosen: NSRect
        if right.maxX <= visible.maxX {
            chosen = right
        } else if left.minX >= visible.minX {
            chosen = left
        } else if below.minY >= visible.minY {
            chosen = below
        } else {
            chosen = inside
        }
        return clamp(chosen, to: visible)
    }

    /// Where the hand lets go: the middle of the Privacy list, right of the sidebar and under the
    /// pane's header and description.
    static func dropPoint(in window: NSRect) -> NSPoint {
        let sidebar = min(215, window.width * 0.3)
        return NSPoint(x: window.minX + sidebar + (window.width - sidebar) / 2,
                       y: window.maxY - min(190, window.height * 0.4))
    }

    static func clamp(_ rect: NSRect, to visible: NSRect) -> NSRect {
        var r = rect
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        return r
    }
}

/// Borderless and non-activating: over System Settings (`cardLevel`), never key, never
/// the front app, on every Space.
final class DragPanelWindow: NSPanel {
    let content: DragPanelView

    init(contentRect: NSRect) {
        content = DragPanelView(frame: NSRect(origin: .zero, size: contentRect.size))
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = PermissionDragPanel.cardLevel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        title = "Drag Sunlight"
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card's face: the icon to drag, what to do with it, and a close button.
final class DragPanelView: NSView {
    var onDismiss: (() -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    var permission: PermissionDragPanel.Permission = .accessibility {
        didSet { detail.stringValue = Self.detail(for: permission) }
    }
    var dragging: Bool { icon.dragging }
    var iconFrame: NSRect { icon.frame }

    private let icon = DraggableAppIcon(frame: .zero)
    private let headline = NSTextField(labelWithString: "Drag Sunlight to the list")
    private let detail = NSTextField(labelWithString: "")
    private let close = NSButton()

    static func detail(for permission: PermissionDragPanel.Permission) -> String {
        "Not in the \(permission.rawValue) list? Drop this icon on it, then confirm with your password or Touch ID."
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let effect = NSVisualEffectView(frame: bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        addSubview(effect)

        let side: CGFloat = 84
        icon.frame = NSRect(x: (frame.width - side) / 2, y: frame.height - 26 - side, width: side, height: side)
        icon.onDrop = { [weak self] point in self?.onDrop?(point) }
        effect.addSubview(icon)

        let inset: CGFloat = 18
        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        headline.alignment = .center
        headline.frame = NSRect(x: inset, y: icon.frame.minY - 34, width: frame.width - inset * 2, height: 20)
        effect.addSubview(headline)

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 4
        detail.lineBreakMode = .byWordWrapping
        detail.cell?.wraps = true
        detail.stringValue = Self.detail(for: permission)
        detail.frame = NSRect(x: inset, y: 16, width: frame.width - inset * 2, height: headline.frame.minY - 20)
        effect.addSubview(detail)

        close.bezelStyle = .circular
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        close.contentTintColor = .tertiaryLabelColor
        close.frame = NSRect(x: frame.width - 28, y: frame.height - 28, width: 20, height: 20)
        close.target = self
        close.action = #selector(dismiss)
        effect.addSubview(close)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag Sunlight into the list in System Settings")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func dismiss() { onDismiss?() }
}

/// Sunlight's icon as a file you can pick up: the bundle's URL on the pasteboard, as dragged from
/// Finder, which is what the Privacy lists take.
final class DraggableAppIcon: NSView, NSDraggingSource {
    private(set) var dragging = false
    /// A drop somewhere that took it, at that screen point.
    var onDrop: ((NSPoint) -> Void)?
    private var downAt: NSPoint?
    /// What's dragged: this app's bundle (the demo in scripts/drag-guide-demo points it at an installed Sunlight).
    nonisolated(unsafe) static var bundleURL = Bundle.main.bundleURL
    static let image: NSImage = {
        let image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        image.size = NSSize(width: 128, height: 128)
        return image
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Sunlight")
        toolTip = "Drag into the list in System Settings"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, !dragging else { return }
        let here = convert(event.locationInWindow, from: nil)
        guard hypot(here.x - downAt.x, here.y - downAt.y) > 3 else { return }
        self.downAt = nil
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: Self.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: Self.image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never move: a miss on the Desktop, a Finder window or the Trash would carry the running app
        // out of Applications, the very thing that loses its permissions.
        context == .outsideApplication ? [.copy, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if !operation.isEmpty { onDrop?(screenPoint) }
    }
}

// MARK: The hand

/// One loop of the hand: where it is between the card and the list, whether it's holding the icon,
/// and how visible each is. Pure, so the timing can be checked without a screen.
struct DragHintPose: Equatable {
    var progress: CGFloat   // 0 on the card's icon, 1 at the drop point
    var holding: Bool
    var handAlpha: CGFloat
    var ghostAlpha: CGFloat
    var ghostScale: CGFloat

    static let period: TimeInterval = 3.4

    static func at(_ t: TimeInterval) -> DragHintPose {
        let t = t.truncatingRemainder(dividingBy: period)
        func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        func span(_ a: TimeInterval, _ b: TimeInterval) -> CGFloat { CGFloat(min(max((t - a) / (b - a), 0), 1)) }
        switch t {
        case ..<0.35:   // comes in over the icon
            return DragHintPose(progress: 0, holding: false, handAlpha: span(0, 0.35), ghostAlpha: 0, ghostScale: 1)
        case ..<0.6:    // grabs it
            return DragHintPose(progress: 0, holding: true, handAlpha: 1, ghostAlpha: span(0.35, 0.6) * 0.85,
                                ghostScale: 1 - span(0.35, 0.6) * 0.3)
        case ..<2.0:    // carries it into the list
            return DragHintPose(progress: ease(span(0.6, 2.0)), holding: true, handAlpha: 1, ghostAlpha: 0.85, ghostScale: 0.7)
        case ..<2.5:    // lets go
            let s = span(2.0, 2.5)
            return DragHintPose(progress: 1, holding: false, handAlpha: 1 - s, ghostAlpha: 0.85 * (1 - s), ghostScale: 0.7 - 0.15 * s)
        default:        // a breath before the next
            return DragHintPose(progress: 1, holding: false, handAlpha: 0, ghostAlpha: 0, ghostScale: 1)
        }
    }
}

/// Click-through, over the card and System Settings: draws the hand and the ghost icon it carries.
/// Off while the person drags for real, for a while after a drop, and under Reduce Motion.
@MainActor
final class DragHintWindow: NSPanel {
    private let view = DragHintView(frame: .zero)
    private var timer: Timer?
    private var startedAt = Date()
    private var restUntil: Date?
    private var from = NSPoint.zero
    private var to = NSPoint.zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = PermissionDragPanel.hintLevel
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(from: NSPoint, to: NSPoint, iconSide: CGFloat, paused: Bool) {
        let resting = restUntil.map { Date() < $0 } ?? false
        guard !paused, !resting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if isVisible { orderOut(nil) }
            timer?.invalidate()
            timer = nil
            return
        }
        let pad: CGFloat = iconSide + 40
        let frame = NSRect(x: min(from.x, to.x) - pad, y: min(from.y, to.y) - pad,
                           width: abs(from.x - to.x) + pad * 2, height: abs(from.y - to.y) + pad * 2).integral
        if self.frame != frame { setFrame(frame, display: false) }
        self.from = from
        self.to = to
        view.iconSide = iconSide
        if !isVisible {
            startedAt = Date()
            orderFrontRegardless()
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    /// A real drop: the password prompt and the list take a moment, and the hand would only distract.
    func rest(for seconds: TimeInterval) {
        restUntil = Date().addingTimeInterval(seconds)
        stop()
    }

    /// A new step: a rest from the last one's drop doesn't carry over.
    func resume() {
        restUntil = nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    private func tick() {
        let pose = DragHintPose.at(Date().timeIntervalSince(startedAt))
        let x = from.x + (to.x - from.x) * pose.progress
        let y = from.y + (to.y - from.y) * pose.progress
        view.point = NSPoint(x: x - frame.minX, y: y - frame.minY)
        view.pose = pose
        view.needsDisplay = true
    }
}

final class DragHintView: NSView {
    var point = NSPoint.zero
    var pose = DragHintPose.at(0)
    var iconSide: CGFloat = 84

    private static let openHand = NSCursor.openHand.image
    private static let closedHand = NSCursor.closedHand.image

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if pose.ghostAlpha > 0 {
            let side = iconSide * pose.ghostScale
            let rect = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            DraggableAppIcon.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: pose.ghostAlpha)
        }
        if pose.handAlpha > 0 {
            let hand = pose.holding ? Self.closedHand : Self.openHand
            let side: CGFloat = 34
            // The hand's palm on the icon's middle, a touch down and right, as a real grab sits.
            let rect = NSRect(x: point.x - side / 2 + 6, y: point.y - side / 2 - 6, width: side, height: side)
            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * pose.handAlpha)
            shadow.set()
            hand.draw(in: rect, from: .zero, operation: .sourceOver, fraction: pose.handAlpha)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
