import AppKit
import os

/// Drag anywhere to move a window that's being used where it's drawn (`Settings.useScaledWindows`),
/// without taking the drags the app wants.
///
/// While the canvas has stepped aside for a window, its presses go straight to the app, so the canvas
/// never sees them. This session-level tap does (on its own thread, like `KeyTap`). A window that
/// isn't the one in use (`setFocused`) is the canvas's to move: each left press on it is held back
/// until its nature is known.
///
/// * Let go without moving: a click. The press and the release are posted on to the app together,
///   which focuses the window and brings its app forward, as a click does on the Mac; from then on
///   the window is in use and every press is the app's own (text selection, press and hold), until
///   the canvas is back in front. A double-click is the canvas's on any window, in use or not (its
///   first click is what put it in use): the window comes to the middle at 1:1.
/// * Moved past `slop`: the window moves on the canvas, from anywhere. The one exception is a
///   **control that is dragged** (a scroll bar, a slider, a pane divider; the canvas asks the app
///   through Accessibility, `decide`): that drag is the app's. The press is posted on, then everything
///   passes through.
///
/// The window in use is moved by its title strip or with ⌘, which are the canvas's. A pinch over a
/// window not in use zooms the canvas, not the app: its gesture events are taken while the tap
/// watches and handed to the canvas; so does a two-finger scroll there pan it (zoom, with ⌥ or ⌘).
/// With `Settings.scaledHoverScroll` a plain scroll there is the app's instead, as on the Mac. A
/// pinch or a scroll belongs to whoever had it when it began, to its end and through its momentum, as
/// the window server routes it. Over the window in use a pinch and a scroll are the app's, as its
/// presses are; the first event of each is held until the window's real frame is under the pointer
/// (`appGestureBegan`). A right-click over any window, in use or not, is the canvas's too: Sunlight's
/// menu for the window, as a right-click on the canvas gives. Posted events carry
/// `CanvasView.passedOnMark` and pass straight through. The middle button is never touched. Needs
/// Accessibility, which the canvas has for its other taps.
final class PressTap: @unchecked Sendable {
    /// What a press is on: `control` is something the app drags itself (a scroll bar, a slider).
    enum Role: Sendable { case unknown, inert, control }

    /// A gesture event on its way to the main actor.
    struct Gesture: @unchecked Sendable { let event: CGEvent }

    enum Command: Sendable {
        /// A press began at this global point (top-left origin) with these flags: the canvas decides
        /// the spot's role (`decide`) while the tap waits.
        case pressed(at: CGPoint, flags: CGEventFlags)
        /// A double-click: the canvas's, not the app's (the first click was).
        case doubleClick(at: CGPoint)
        /// A click, when clicks are the canvas's (`setClickIsCanvas`): zoom the window in.
        case singleClick(at: CGPoint)
        /// A click posted on to the app: the window is in use from here on.
        case clicked(at: CGPoint)
        case dragBegin(at: CGPoint)
        case dragMove(to: CGPoint, flags: CGEventFlags, timestamp: TimeInterval)
        case dragEnd(at: CGPoint, flags: CGEventFlags, timestamp: TimeInterval)
        /// A pinch over the window, from the window server's gesture stream: the canvas zooms by
        /// `magnification` more.
        case pinch(magnification: CGFloat, phase: NSEvent.Phase, timestamp: TimeInterval, at: CGPoint)
        /// A right-click on the window: Sunlight's menu for it, at this global point (top-left origin).
        case rightClick(at: CGPoint)
        /// A pinch or a scroll is starting over the window in use, for the app, with the pointer at this
        /// global point (top-left origin): the window's real frame goes under the pointer first. The tap
        /// holds the gesture's first event until `done` is signalled (or `anchorWait` passes), so the
        /// app reads the pointer against the moved frame.
        case appGestureBegan(at: CGPoint, done: DispatchSemaphore)
        /// A scroll over a window not in use: the canvas pans.
        case scroll(Gesture)
    }

    /// `NSEvent.EventType.gesture`, which `CGEventType` has no case for: the window server's raw gesture
    /// events, one stream for every kind (its kind in `gestureKindField`), from which AppKit makes each
    /// app's magnify, rotate and swipe events. A session tap sees only these (measured: 4,037 gesture
    /// events in 90 s, none of them a made magnify event), and `NSEvent(cgEvent:)` can't read a made
    /// one anyway, so the pinch is read from the raw fields.
    private static let gestureType: UInt32 = 29
    private static let gestureKindField = CGEventField(rawValue: 110)!
    private static let gestureZoomField = CGEventField(rawValue: 113)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    private static let gestureZoomKind: Int64 = 8

    /// The window server's gesture phases (not `NSEvent.Phase`'s values).
    private static func phase(ofGesture raw: Int64) -> NSEvent.Phase {
        switch raw {
        case 1: return .began
        case 2: return .changed
        case 4: return .ended
        case 8: return .cancelled
        case 128: return .mayBegin
        default: return []
        }
    }

    static let slop: CGFloat = 3

    private enum Phase {
        case idle
        /// The press, held back until its nature is known.
        case holding(down: CGEvent, start: CGPoint, role: Role, clicks: Int64)
        /// The window is being moved on the canvas: every event until the release is the canvas's.
        case moving
        /// The app's own drag: everything passes until the release.
        case passing
    }

    private struct State {
        var phase = Phase.idle
        var active = false
        /// A single click is the canvas's (it zooms the window in) rather than posted on to the app.
        var clickIsCanvas = false
        /// The window under the pointer is the one in use: its presses are the app's, untouched.
        var focused = false
        /// A plain scroll over any window is the app's, in use or not (`Settings.scaledHoverScroll`).
        var scrollIsApp = false
        /// A right press was taken; its release is swallowed too, so the app never sees an orphan.
        var rightHeld = false
        /// A pinch is under way: its every event is the canvas's until it ends.
        var pinching = false
        /// Scrolls that came in during the pinch (the fingers' drift) and were dropped.
        var scrollsInPinch = 0
        /// A pinch is under way in the window in use, the app's: told once, at its start.
        var appPinching = false
        /// When the pinch under way last had an event (event timestamp, ns): one that hasn't for
        /// `staleGesture` is over, whatever ended it unseen (the tap disabled for a moment, say), so a
        /// missed end can't keep every scroll on the Mac dropped.
        var pinchSeen: UInt64 = 0
        /// Who has the two-finger scroll under way, decided at its start (true: the canvas): the window
        /// server sends a whole scroll, momentum included, to the window it began over, whatever comes
        /// under the pointer as the canvas pans.
        var scrollOwner: Bool?
    }

    /// How long a pinch can go without an event before it counts as over (ns).
    private static let staleGesture: UInt64 = 300_000_000
    /// How long the first event of the app's pinch or scroll waits for its window's real frame to move.
    private static let anchorWait: DispatchTimeInterval = .milliseconds(50)

    private let handler: @MainActor @Sendable (Command) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?

    init(handler: @escaping @MainActor @Sendable (Command) -> Void) {
        self.handler = handler
    }

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "canvas.presstap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        setActive(false)
        guard let runLoop else { return }
        self.runLoop = nil
        thread = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let port { CFMachPortInvalidate(port) }
            self.port = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Watching, while the canvas has stepped aside for a window. Off, every event passes untouched;
    /// a press held at that moment is posted on so its release has something to pair with.
    func setActive(_ on: Bool) {
        let held: CGEvent? = state.withLock { s in
            guard s.active != on else { return nil }
            s.active = on
            if on { return nil }
            s.rightHeld = false
            defer { s.phase = .idle }
            if case .holding(let down, _, _, _) = s.phase { return down }
            return nil
        }
        if let held { PressTap.post(held) }
    }

    /// Whether the window under the pointer is the one in use (clicked into since the canvas was last
    /// in front): its presses pass untouched, and a drag there is the app's.
    func setFocused(_ on: Bool) {
        state.withLock { $0.focused = on }
    }

    /// Whether a plain scroll over a window not in use is the app's (`Settings.scaledHoverScroll`)
    /// rather than panning the canvas.
    func setScrollIsApp(_ on: Bool) {
        state.withLock { $0.scrollIsApp = on }
    }

    /// Whether a single click is the canvas's (`Settings.scaledClickZooms`) or the app's.
    func setClickIsCanvas(_ on: Bool) {
        state.withLock { $0.clickIsCanvas = on }
    }

    /// The canvas's answer for the press under way: on an inert spot a drag moves the window.
    func decide(_ role: Role) {
        state.withLock { s in
            if case .holding(let down, let start, _, let clicks) = s.phase { s.phase = .holding(down: down, start: start, role: role, clicks: clicks) }
        }
    }

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        installTap()
        let watchdog = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.current.add(watchdog, forMode: .common)
        CFRunLoopRun()
        watchdog.invalidate()
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << PressTap.gestureType)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: PressTap.callback, userInfo: info) else {
            Log.note("PressTap: tapCreate failed — Accessibility granted? Retrying in 3 s")
            let retry = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.installTap() }
            RunLoop.current.add(retry, forMode: .common)
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.note("PressTap: installed")
    }

    private func checkTap() {
        guard let port else { return }
        if !CFMachPortIsValid(port) {
            Log.note("PressTap: port invalidated, reinstalling")
            self.port = nil
            installTap()
        } else if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<PressTap>.fromOpaque(info).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            // Whatever ended while the tap was off went unseen: no gesture is held over it.
            state.withLock { s in
                s.pinching = false; s.appPinching = false; s.scrollsInPinch = 0; s.scrollOwner = nil
            }
            return Unmanaged.passUnretained(event)
        }
        // The canvas's own posted events (held presses, 1:1 presses) go on untouched.
        if event.getIntegerValueField(.eventSourceUserData) == CanvasView.passedOnMark { return Unmanaged.passUnretained(event) }
        if type.rawValue == PressTap.gestureType {
            guard event.getIntegerValueField(PressTap.gestureKindField) == PressTap.gestureZoomKind else { return Unmanaged.passUnretained(event) }
            let rawPhase = event.getIntegerValueField(PressTap.gesturePhaseField)
            var phase = PressTap.phase(ofGesture: rawPhase)
            let magnification = CGFloat(event.getDoubleValueField(PressTap.gestureZoomField))
            let now = event.timestamp
            let (taken, appBegins): (Bool, Bool) = state.withLock { s in
                if s.pinching || s.appPinching, now > s.pinchSeen, now - s.pinchSeen > PressTap.staleGesture {
                    s.pinching = false; s.appPinching = false; s.scrollsInPinch = 0
                }
                s.pinchSeen = now
                // A pinch starts with its first event over a window not in use, whatever phase it
                // claims; over the window in use it's the app's, as its scrolls are.
                if !s.pinching, s.active, !s.focused, phase != .ended, phase != .cancelled {
                    s.pinching = true
                    if phase == [] { phase = .began }
                }
                let taken = s.pinching
                var appBegins = false
                if !taken, !s.appPinching, s.active, s.focused, phase != .ended, phase != .cancelled {
                    s.appPinching = true
                    appBegins = true
                }
                if phase == .ended || phase == .cancelled { s.pinching = false; s.appPinching = false }
                return (taken, appBegins)
            }
            if phase != .changed {
                let dropped = state.withLock { s -> Int in defer { if !s.pinching { s.scrollsInPinch = 0 } }; return s.scrollsInPinch }
                Log.note("PressTap: gesture pinch phase \(rawPhase) by \(magnification) — \(taken ? "the canvas's" : "passed")\(dropped > 0 ? ", \(dropped) scrolls dropped" : "")")
            }
            guard taken else {
                if appBegins { anchorFirst(event) }
                return Unmanaged.passUnretained(event)
            }
            // The canvas reads the pointer itself (`CanvasView.externalPinch`); the event's own point is
            // the fallback.
            send(.pinch(magnification: magnification, phase: phase, timestamp: TimeInterval(event.timestamp) / 1_000_000_000, at: event.location))
            return nil
        }
        if type == .scrollWheel {
            let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            let now = event.timestamp
            let zooms = !event.flags.intersection([.maskAlternate, .maskCommand]).isEmpty
            let (taken, inPinch, appBegins) = state.withLock { s -> (Bool, Bool, Bool) in
                if s.pinching {
                    if now > s.pinchSeen, now - s.pinchSeen > PressTap.staleGesture {
                        s.pinching = false; s.appPinching = false; s.scrollsInPinch = 0
                    } else {
                        s.scrollsInPinch += 1
                        return (false, true, false)
                    }
                }
                // A window not in use: the canvas pans, unless scrolling is the app's there too (then
                // only a ⌥- or ⌘-scroll, which zooms the canvas, is the canvas's).
                let canvas = s.active && !s.focused && (!s.scrollIsApp || zooms)
                var taken = canvas
                var appBegins = false
                switch (scrollPhase, momentum) {
                case (1, _):
                    // A two-finger scroll begins: whoever has it now has it to its end.
                    s.scrollOwner = canvas
                    appBegins = !canvas && s.active && s.focused
                case (0, 0), (128, _):
                    // A mouse wheel's click, or fingers resting: decided where the pointer is.
                    break
                default:
                    // The rest of a scroll, and its momentum: still whoever had it at its start.
                    if let owner = s.scrollOwner { taken = owner }
                    if momentum == 3 { s.scrollOwner = nil }
                }
                return (taken, false, appBegins)
            }
            // The fingers drift a little while they pinch, which comes through as scrolls as well: a pinch
            // taken by the canvas keeps its anchor, so those are dropped rather than panning it away.
            if inPinch { return nil }
            guard taken, let copy = event.copy() else {
                // The app's scroll (⌘- or ⌥-scroll zooms in many apps, around the pointer): the window's
                // real frame goes under the pointer at its start, as for the app's pinch.
                if appBegins { anchorFirst(event) }
                return Unmanaged.passUnretained(event)
            }
            send(.scroll(Gesture(event: copy)))
            return nil
        }
        if type == .rightMouseDown || type == .rightMouseUp {
            // A right-click is the canvas's whatever the window's state, as long as no left press is under way.
            let taken: Bool = state.withLock { s in
                guard s.active else { return false }
                if type == .rightMouseDown {
                    guard case .idle = s.phase else { return false }
                    s.rightHeld = true
                    return true
                }
                defer { s.rightHeld = false }
                return s.rightHeld
            }
            guard taken else { return Unmanaged.passUnretained(event) }
            if type == .rightMouseDown { send(.rightClick(at: event.location)) }
            return nil
        }

        let point = event.location
        let flags = event.flags
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        enum Outcome { case pass, swallow, click(CGEvent, CGEvent), appDrag(CGEvent, CGEvent), send(Command) }
        var outcomes: [Outcome] = []
        state.withLock { s in
            guard s.active else { outcomes = [.pass]; return }
            switch (s.phase, type) {
            case (.idle, .leftMouseDown):
                let clicks = event.getIntegerValueField(.mouseEventClickState)
                // The window in use gets its presses untouched, but a double-click is the canvas's even
                // there (the first click is what put the window in use): it centres the window at 1:1.
                if s.focused, clicks < 2 {
                    s.phase = .passing
                    outcomes = [.pass]
                    return
                }
                let modified = !flags.intersection([.maskCommand, .maskAlternate]).isEmpty
                guard let down = event.copy() else { outcomes = [.pass]; return }
                s.phase = .holding(down: down, start: point, role: modified ? .inert : .unknown, clicks: clicks)
                outcomes = [.swallow, .send(.pressed(at: point, flags: flags))]
            case (.idle, _):
                outcomes = [.pass]
            case (.holding(let down, let start, let role, let clicks), .leftMouseUp):
                s.phase = .idle
                if clicks >= 2 { outcomes = [.swallow, .send(.doubleClick(at: start))] }
                else if s.clickIsCanvas { outcomes = [.swallow, .send(.singleClick(at: start))] }
                else { outcomes = [.click(down, event), .send(.clicked(at: start))] }
            case (.holding(let down, let start, let role, _), .leftMouseDragged):
                guard hypot(point.x - start.x, point.y - start.y) >= PressTap.slop else { outcomes = [.swallow]; return }
                // A dragged control's drag is the app's; so is any drag in the window in use (a double
                // press that moves: selecting by words).
                if role == .control || s.focused {
                    s.phase = .passing
                    outcomes = [.appDrag(down, event)]
                } else {
                    s.phase = .moving
                    outcomes = [.swallow, .send(.dragBegin(at: start)), .send(.dragMove(to: point, flags: flags, timestamp: timestamp))]
                }
            case (.moving, .leftMouseDragged):
                outcomes = [.swallow, .send(.dragMove(to: point, flags: flags, timestamp: timestamp))]
            case (.moving, .leftMouseUp):
                s.phase = .idle
                outcomes = [.swallow, .send(.dragEnd(at: point, flags: flags, timestamp: timestamp))]
            case (.passing, .leftMouseUp):
                s.phase = .idle
                outcomes = [.pass]
            case (.passing, _), (.holding, _), (.moving, _):
                outcomes = [.pass]
            }
        }
        var result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
        for outcome in outcomes {
            switch outcome {
            case .pass: break
            case .swallow: result = nil
            case .click(let down, let up):
                PressTap.post(down)
                if let copy = up.copy() { PressTap.post(copy) }
                result = nil
            case .appDrag(let down, let drag):
                PressTap.post(down)
                if let copy = drag.copy() { PressTap.post(copy) }
                result = nil
            case .send(let command):
                send(command)
            }
        }
        return result
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: CanvasView.passedOnMark)
        event.post(tap: .cghidEventTap)
    }

    /// The app's pinch or scroll is starting in the window in use: its real frame goes under the pointer
    /// before this, the gesture's first event, reaches the app, which reads the pointer against that
    /// frame. The tap's thread waits for the canvas to say it's done, `anchorWait` at most.
    private func anchorFirst(_ event: CGEvent) {
        let done = DispatchSemaphore(value: 0)
        send(.appGestureBegan(at: CGEvent(source: nil)?.location ?? event.location, done: done))
        _ = done.wait(timeout: .now() + PressTap.anchorWait)
    }

    private func send(_ command: Command) {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(command) }
        }
    }
}
