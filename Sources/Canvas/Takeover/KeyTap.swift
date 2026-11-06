import AppKit
import Carbon.HIToolbox
import os

/// A session-level CGEvent tap that claims the app switcher and the Mission Control key while takeover
/// is on. It lives on its own thread so a stalled main thread (AX calls, ScreenCaptureKit) can never
/// get the tap disabled or lag a keystroke; commands are forwarded to the main actor.
///
/// Needs Accessibility (an active session tap is refused without it). Carbon hotkeys can't claim ⌘Tab,
/// which is why this exists alongside `Hotkey`.
final class KeyTap: @unchecked Sendable {
    enum Command: Sendable, Equatable {
        case appSwitchBegin(reverse: Bool)
        case appSwitchStep(reverse: Bool)
        /// ⌘` or ⌘↓ (⇧⌘` or ⌘↑ back) while switching: the highlighted app's next window.
        case appSwitchWindowStep(reverse: Bool)
        case appSwitchCommit
        case appSwitchCancel
        case missionControl
        /// The Mission Control key let go, `held` seconds after it went down (by the events' own times,
        /// so a busy main thread can't make a tap read as a hold): held, it picks the window under the
        /// pointer (`MissionControlHold`).
        case missionControlUp(held: TimeInterval)
        case showDesktop
        /// ⌘N in a window whose app's ⌘N makes a window, when the canvas places new windows itself.
        case newWindow
        /// ⌘? from anywhere: Settings › How to use.
        case howToUse
        /// ⌃⌘F in a window: Sunlight's full screen (filling its area, then entered there), not a Space of its own.
        case fillAndEnter
    }

    struct State: Sendable {
        /// Between `start` and `stop`: the tap acts. Off, every key passes untouched. The tap's thread
        /// and port live on across stops (made once, for the process): stopping used to post the
        /// teardown to the thread's run loop, which a `stop` right after `start` (Sunlight switched off
        /// at login, takeover on) found not up yet and skipped, so the tap went on taking ⌘Tab and the
        /// Mission Control key with Sunlight off; and a stop and a start in quick succession could
        /// invalidate the new thread's port, after which nothing reinstalled it.
        var enabled = false
        var entered = false
        var switcherOpen = false
        /// ⌘N is the canvas's to handle (`Command.newWindow`): the entered app's ⌘N makes a window and
        /// windows push each other.
        var placesNewWindow = false
        /// Whether F11 still means Show Desktop (`Bindings`): rebound, F11 goes back to the Mac.
        var showDesktopOnF11 = true
        var toggleCanvasOnMissionControl = true
        var howToUseOnDefault = true
        var recordingShortcut = false
        /// A full-screen app's Space is in front: ⌃← goes back to the canvas's Desktop, as on the Mac.
        var inFullScreenSpace = false
        /// When the Mission Control key went down (the event's timestamp, ns), until it's let go.
        var missionControlDownAt: UInt64?
        /// Key codes whose keyDown we swallowed; their keyUp is swallowed too so apps never see an orphan.
        var swallowed = Set<Int64>()
    }

    enum Action: Equatable {
        case pass
        case swallow
        case send(Command)
    }

    private static let tab: Int64 = 48
    private static let n: Int64 = 45
    private static let slash: Int64 = 44
    private static let f: Int64 = 3
    /// The key left of 1 (` on US layouts): ⌘` walks an app's windows, as on the Mac.
    private static let grave: Int64 = 50
    private static let escape: Int64 = 53
    private static let f11: Int64 = 103
    private static let leftArrow: Int64 = 123
    private static let rightArrow: Int64 = 124
    private static let downArrow: Int64 = 125
    private static let upArrow: Int64 = 126
    /// The dedicated Mission Control key on Apple keyboards.
    private static let missionControlKey: Int64 = 160

    private let handler: @MainActor @Sendable (Command) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?

    /// The current keyboard layout's key-translation table, for `symbol(of:)`. Read on the main thread
    /// only: Text Input Sources asserts the main queue (macOS 27 traps on any other, and the tap's
    /// thread used to ask it on every ⌘ key), so the tap reads this copy, refreshed as layouts change.
    private let layoutData = OSAllocatedUnfairLock<Data?>(initialState: nil)
    private var layoutObserver: NSObjectProtocol?

    @MainActor
    init(handler: @escaping @MainActor @Sendable (Command) -> Void) {
        self.handler = handler
        refreshLayout()
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLayout() }
        }
    }

    @MainActor
    private func refreshLayout() {
        var data: Data?
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }
        layoutData.withLock { $0 = data }
    }

    func start() {
        state.withLock {
            $0 = State()
            $0.enabled = true
        }
        if let runLoop {
            // The tap is there; have it listen again (the thread re-enables it on its own as well).
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
            }
            CFRunLoopWakeUp(runLoop)
            return
        }
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "canvas.keytap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Off: every key passes, at once, whether or not the tap's thread is up yet. The tap itself is
    /// told to stop listening too, so the keys don't even round-trip through this process meanwhile.
    func stop() {
        state.withLock {
            let desktop = $0.showDesktopOnF11
            let toggle = $0.toggleCanvasOnMissionControl
            let howToUse = $0.howToUseOnDefault
            $0 = State()
            $0.showDesktopOnF11 = desktop
            $0.toggleCanvasOnMissionControl = toggle
            $0.howToUseOnDefault = howToUse
        }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let port { CGEvent.tapEnable(tap: port, enable: false) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private var isEnabled: Bool { state.withLock { $0.enabled } }

    /// Whether a real window is in front (changes what ⌘Tab means).
    func update(entered: Bool) {
        state.withLock {
            $0.entered = entered
            if !entered { $0.placesNewWindow = false }
        }
    }

    /// Whether ⌘N in the entered window is the canvas's (`Command.newWindow`).
    func update(placesNewWindow: Bool) {
        state.withLock { $0.placesNewWindow = placesNewWindow && $0.entered }
    }

    /// Settings › Shortcuts: F11 is Show Desktop until it is rebound, and then it is the Mac's again.
    func update(showDesktopOnF11: Bool) {
        state.withLock { $0.showDesktopOnF11 = showDesktopOnF11 }
    }

    func update(toggleCanvasOnMissionControl: Bool) {
        state.withLock { $0.toggleCanvasOnMissionControl = toggleCanvasOnMissionControl }
    }

    func update(howToUseOnDefault: Bool) {
        state.withLock { $0.howToUseOnDefault = howToUseOnDefault }
    }

    func update(recordingShortcut: Bool) {
        state.withLock { $0.recordingShortcut = recordingShortcut }
    }

    /// Whether a full-screen app's Space is in front (`SpacesWatcher`).
    func update(inFullScreenSpace: Bool) {
        state.withLock { $0.inFullScreenSpace = inFullScreenSpace }
    }

    // MARK: Tap thread

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        installTap()
        // The system disables a tap that stalls; make sure we always come back.
        let watchdog = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.current.add(watchdog, forMode: .common)
        CFRunLoopRun()
        watchdog.invalidate()
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: KeyTap.callback, userInfo: info) else {
            NSLog("KeyTap: tapCreate failed — Accessibility granted? Retrying in 3 s")
            let retry = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.installTap() }
            RunLoop.current.add(retry, forMode: .common)
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: isEnabled)
        NSLog("KeyTap: installed\(isEnabled ? "" : " (stopped)")")
    }

    private func checkTap() {
        guard let port else { return }
        if !CFMachPortIsValid(port) {
            NSLog("KeyTap: port invalidated, reinstalling")
            self.port = nil
            installTap()
        } else if CGEvent.tapIsEnabled(tap: port) != isEnabled {
            CGEvent.tapEnable(tap: port, enable: isEnabled)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<KeyTap>.fromOpaque(info).takeUnretainedValue()
        return tap.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port, isEnabled { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Stopped: nothing is the canvas's (a key that came through before the tap stopped listening).
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])

        let action: Action
        switch type {
        case .keyDown:
            let command = flags.contains(.maskCommand)
            let character = command ? KeyTap.character(of: event) : nil
            let symbol = command ? symbol(of: event) : nil
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let timestamp = event.timestamp
            action = state.withLock { s -> Action in
                let a = KeyTap.action(keyCode: keyCode, flags: flags, state: &s, character: character, symbol: symbol,
                                      autorepeat: autorepeat, timestamp: timestamp)
                if case .pass = a {} else { s.swallowed.insert(keyCode) }
                return a
            }
        case .keyUp:
            let timestamp = event.timestamp
            action = state.withLock { KeyTap.release(keyCode: keyCode, state: &$0, timestamp: timestamp) }
        case .flagsChanged:
            // Letting go of ⌘ while the switcher is open picks the highlighted window.
            let commit = state.withLock { s -> Bool in
                guard s.switcherOpen, !flags.contains(.maskCommand) else { return false }
                s.switcherOpen = false
                return true
            }
            action = commit ? .send(.appSwitchCommit) : .pass
            if case .send(let cmd) = action { send(cmd) }
            return Unmanaged.passUnretained(event)
        default:
            action = .pass
        }

        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .send(let cmd):
            send(cmd)
            return nil
        }
    }

    /// What the key types on the current layout, ⌘ aside: ⌘N is the N wherever the layout has it.
    private static func character(of event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        return length > 0 ? String(utf16CodeUnits: chars, count: length).lowercased() : nil
    }

    /// What the key types with only ⇧ held, ⌘ taken off: on a Cyrillic layout, ⌘ turns a key into its
    /// Latin twin, so ⌘? read with ⌘ is not a ? at all. Translated afresh from the current layout
    /// (`layoutData`, kept by the main thread), since the event's own string was fixed with ⌘ in. For
    /// the keys matched by their symbol (⌘?).
    private func symbol(of event: CGEvent) -> String? {
        guard let layout = layoutData.withLock({ $0 }) else { return nil }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers: UInt32 = event.flags.contains(.maskShift) ? UInt32((shiftKey >> 8) & 0xFF) : 0
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                                  UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                  UInt32(kUCKeyTranslateNoDeadKeysMask), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// `character`: what the key types (`character(of:)`), where known; the N key's code stands in for it.
    /// `symbol`: what it types with ⌘ taken off (`symbol(of:)`), for ⌘? on any layout.
    /// `autorepeat`: the key is held and this is the system repeating it. `timestamp`: the event's, in ns.
    static func action(keyCode: Int64, flags: CGEventFlags, state: inout State, character: String? = nil, symbol: String? = nil,
                       autorepeat: Bool = false, timestamp: UInt64 = 0) -> Action {
        guard !state.recordingShortcut else { return .pass }
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let shift = flags.contains(.maskShift)

        if character.map({ $0 == "n" }) ?? (keyCode == n), state.entered, state.placesNewWindow,
           command, !control, !option, !shift {
            return .send(.newWindow)
        }

        // ⌃⌘F, macOS's full screen, in a window: Sunlight's instead, so the window stays on the canvas.
        // With ⌃ held the key types its control character (⌃F is U+0006 on any layout).
        if character.map({ $0 == "f" || $0 == "\u{06}" }) ?? (keyCode == f), state.entered, !state.inFullScreenSpace,
           command, control, !option, !shift {
            return .send(.fillAndEnter)
        }

        // ⌘? on any layout (the key that types ?, or ⌘⇧/): How to use, from the canvas or inside a window.
        if state.howToUseOnDefault, command, !control, !option, (symbol == "?" || character == "?" || (keyCode == slash && shift)) {
            return .send(.howToUse)
        }

        switch keyCode {
        case tab where command && !control && !option:
            if state.switcherOpen { return .send(.appSwitchStep(reverse: shift)) }
            state.switcherOpen = true
            return .send(.appSwitchBegin(reverse: shift))
        case escape where state.switcherOpen:
            state.switcherOpen = false
            return .send(.appSwitchCancel)
        // While switching, ⌘ is down: the Mac's ⌘-Tab extras. Arrows across the strip step apps,
        // ` and the arrows along an app's windows step its windows.
        case grave where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: shift))
        case downArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: false))
        case upArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchWindowStep(reverse: true))
        case rightArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchStep(reverse: false))
        case leftArrow where state.switcherOpen && command && !control && !option:
            return .send(.appSwitchStep(reverse: true))
        case leftArrow where state.inFullScreenSpace:
            // From a full-screen app's Space, ⌃← is the way back to the canvas's Desktop.
            return .pass
        case leftArrow, rightArrow, upArrow, downArrow:
            // Spaces switching and Mission Control's ⌃↑ ⌃↓: one Desktop per display, the canvas's.
            return (control && !command && !option) ? .swallow : .pass
        case missionControlKey where !command && !control && !option:
            guard state.toggleCanvasOnMissionControl else { return .pass }
            // Held, the key repeats: it's still the one press (held to pick a window), not a toggle each time.
            if autorepeat || state.missionControlDownAt != nil { return .swallow }
            state.missionControlDownAt = timestamp
            return .send(.missionControl)
        case f11 where !command && !control && !option:
            return state.showDesktopOnF11 ? .send(.showDesktop) : .pass
        default:
            return .pass
        }
    }

    /// A key let go: its keyUp is swallowed if its keyDown was. The Mission Control key's says how long it was held.
    static func release(keyCode: Int64, state: inout State, timestamp: UInt64) -> Action {
        let wasSwallowed = state.swallowed.remove(keyCode) != nil
        if keyCode == missionControlKey, let down = state.missionControlDownAt {
            state.missionControlDownAt = nil
            let held = timestamp >= down ? TimeInterval(timestamp - down) / 1_000_000_000 : 0
            return .send(.missionControlUp(held: held))
        }
        return wasSwallowed ? .swallow : .pass
    }

    private func send(_ command: Command) {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(command) }
        }
    }
}
