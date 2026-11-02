import AppKit
import ServiceManagement

/// Takeover mode: the canvas as the session's environment rather than an app you switch to.
///
/// Owns the consent step, the record of what was changed on this Mac, the key tap and the foreground
/// watcher. Everything it changes but the Desktops it merges (`Spaces`) is put back when Canvas quits, and from the command line with
/// `Canvas --release` if the app itself can't launch.
@MainActor
final class TakeoverMode {
    enum Reason {
        /// ⌘Q, Ctrl-C: restore the Mac, but stay opted in (and a login item) for the next launch.
        case userQuit
        /// "Release the Mac…" or `--release`: restore everything and opt out.
        case leaveMode
        /// Logout, restart or shutdown: the Mac's own values go back on disk, with no Dock or Finder restart
        /// (the session is ending), and Sunlight stays opted in and a login item, so the next login takes
        /// over again. Left in place instead, they had nothing to put them back if Sunlight was gone by then
        /// (dragged to the Trash rather than uninstalled).
        case logout
    }

    /// Bump when the consent text changes so it is shown again.
    static let consentVersion = 4

    enum Keys {
        static let enabled = "takeover.enabled"
        static let applied = "takeover.applied"
        static let snapshot = "takeover.snapshot"
        static let declined = "takeover.declinedVersion"
        /// Desktops have been merged on this Mac (Uninstall says they aren't recreated).
        static let merged = "takeover.mergedDesktops"
    }

    let keyTap: KeyTap
    let watcher = ForegroundWatcher()
    let spaces = SpacesWatcher()
    private weak var canvas: Desk?
    private(set) var isRunning = false
    /// Restarting Finder can look like a foreign activation; ignore the window right after a restart.
    private(set) var ignoreActivationsUntil = Date.distantPast

    private let defaults = UserDefaults.standard

    var isEnabled: Bool { defaults.bool(forKey: Keys.enabled) }

    /// `CANVAS_TAKEOVER=light`: the key tap and the watcher only, no consent, no system changes and no
    /// login item. For development, where restarting the Dock and Finder on every run gets old.
    static var isLight: Bool { ProcessInfo.processInfo.environment["CANVAS_TAKEOVER"] == "light" }

    init(canvas: Desk) {
        self.canvas = canvas
        keyTap = KeyTap { [weak canvas] command in canvas?.handle(command) }
        watcher.onForeignActivation = { [weak canvas] app in canvas?.foreignActivation(app) }
        watcher.onAppGone = { [weak canvas] pid in canvas?.appGone(pid: pid) }
        watcher.onFocusedWindowChanged = { [weak canvas] pid, element in canvas?.focusedWindowChanged(pid: pid, element: element) }
        watcher.onWindowCreated = { [weak canvas] pid, element in canvas?.windowCreated(pid: pid, element: element) }
        watcher.onWindowMiniaturized = { [weak canvas] pid, element in canvas?.windowMiniaturized(pid: pid, element: element) }
        watcher.onWindowMoved = { [weak canvas] pid, element in canvas?.windowMoved(pid: pid, element: element) }
        watcher.onEnteredWindowDestroyed = { [weak canvas] pid in canvas?.enteredWindowDestroyed(pid: pid) }
        spaces.onFullScreenChanged = { [keyTap] inFullScreen in keyTap.update(inFullScreenSpace: inFullScreen) }
        spaces.onDesktopsToFold = { [weak self] in self?.desktopsToFold() }
    }

    // MARK: Launch

    /// Apply silently if the user already opted in, or repair what a crashed run left behind. Asking
    /// is separate (`wantsConsent`, `askForConsent`): the app delegate asks once the canvas is up.
    func startup() {
        if TakeoverMode.isLight {
            keyTap.start()
            watcher.start()
            spaces.start()
            isRunning = true
            NSLog("Takeover: light mode — keys and absorb only, nothing changed on the system")
            return
        }
        if isEnabled {
            apply()
            return
        }
        if defaults.bool(forKey: Keys.applied) {
            NSLog("Takeover: found prefs left over from a previous run, restoring")
            TakeoverMode.revertPrefs()
        }
    }

    /// Never opted in, and the current consent text not yet declined.
    var wantsConsent: Bool {
        !TakeoverMode.isLight && !isEnabled && defaults.integer(forKey: Keys.declined) < TakeoverMode.consentVersion
    }

    /// A sheet on the canvas, not a modal run loop: the canvas keeps syncing and streaming behind it.
    /// The canvas comes to the front first: with no Dock icon Sunlight often isn't the active app when
    /// this is asked (setup has just gone away, or it's launch), and a sheet on a window behind other
    /// apps' goes unseen.
    func askForConsent() {
        guard let canvas else { return }
        let window = canvas.window
        canvas.show()
        let alert = NSAlert()
        alert.messageText = "Take over the Mac?"
        alert.informativeText = """
        Sunlight becomes the environment instead of a window:

        •  The Dock auto-hides system-wide; it slides out at the screen edge.
        •  Desktop widgets are never dimmed, so they show in full colour on the canvas.
        •  Sunlight starts at login.
        •  ⌘Tab, Mission Control and Show Desktop keys go to the canvas. \
        Mission Control gestures and hot corners are off.
        •  Each display keeps one Desktop, the canvas. Other Desktops are merged into it; \
        full-screen apps stay as they are.

        Everything else is restored when Sunlight quits; merged Desktops are not recreated. If Sunlight ever can't launch, \
        run Sunlight.app/Contents/MacOS/Sunlight --release in Terminal to put it all back.
        """
        alert.addButton(withTitle: "Take Over")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    self.defaults.set(true, forKey: Keys.enabled)
                    self.apply()
                } else {
                    self.defaults.set(TakeoverMode.consentVersion, forKey: Keys.declined)
                }
            }
        }
    }

    // MARK: Desktops

    /// There are Desktops to fold (`SpacesWatcher`: at the start, and a couple of seconds after one
    /// appears): merged into the canvas, with nothing asked. The consent says so.
    private func desktopsToFold() {
        guard isRunning, !inputSuspended, !TakeoverMode.isLight else { return }
        DispatchQueue.global(qos: .utility).async {
            if case .folded = Spaces.fold() {
                DispatchQueue.main.async { UserDefaults.standard.set(true, forKey: Keys.merged) }
            }
        }
    }

    // MARK: Apply / revert

    func apply() {
        guard !isRunning else { return }
        // Snapshot before anything is touched. Re-snapshotting a pref later would record our own value,
        // so an existing snapshot only gains the prefs added to takeover since it was taken.
        let applied = defaults.bool(forKey: Keys.applied)
        // A pref takeover no longer manages (Finder's desktop icons) goes back to the user's own value.
        let retired = SystemPrefs.retiredInSnapshot(applied ? defaults.dictionary(forKey: Keys.snapshot) ?? [:] : [:])
        let stored = retired.remaining
        let snapshot = SystemPrefs.snapshot(adding: stored)
        if !applied || snapshot.count != stored.count || !retired.restore.isEmpty {
            defaults.set(snapshot, forKey: Keys.snapshot)
            defaults.set(true, forKey: Keys.applied)
            defaults.synchronize()
        }
        var changed = SystemPrefs.apply()
        if !retired.restore.isEmpty {
            changed.formUnion(SystemPrefs.restore(retired.restore))
            NSLog("Takeover: gave back \(retired.restore.map { "\($0.0.domain) \($0.0.key)" }.joined(separator: ", ")), no longer part of takeover")
        }
        if changed.contains(SystemPrefs.dock) { canvas?.releaseLiveWindowsForDockRestart() }
        let restarted = SystemPrefs.restart(domains: changed)
        if !restarted.isEmpty { ignoreActivationsUntil = Date().addingTimeInterval(2) }
        keyTap.start()
        watcher.start()
        isRunning = true
        spaces.start()
        DispatchQueue.global(qos: .utility).async { LoginItem.register() }   // launchd round trips
        NSLog("Takeover: on\(changed.isEmpty ? "" : " (changed \(changed.sorted().joined(separator: ", ")); restarted \(restarted.isEmpty ? "nothing" : restarted.joined(separator: ", ")))")")
    }

    /// Sunlight switched off in the menu bar: the keys go back to the Mac (⌘Tab is the Mac's switcher
    /// again, Mission Control its own) and other apps' activations go unwatched, while the Dock, the
    /// login item and the rest of takeover stay as they are, so switching back on restarts nothing.
    private(set) var inputSuspended = false

    func suspendInput() {
        guard isRunning, !inputSuspended else { return }
        inputSuspended = true
        keyTap.stop()
        watcher.stop()
        spaces.stop()
        NSLog("Takeover: keys and watching suspended")
    }

    func resumeInput() {
        guard isRunning, inputSuspended else { return }
        inputSuspended = false
        keyTap.start()
        watcher.start()
        spaces.start()
        NSLog("Takeover: keys and watching resumed")
    }

    func revert(reason: Reason) {
        keyTap.stop()
        watcher.stop()
        spaces.stop()
        inputSuspended = false
        isRunning = false
        if TakeoverMode.isLight { return }
        switch reason {
        case .logout:
            TakeoverMode.revertPrefs(restarting: false)
            NSLog("Takeover: logging out; the Mac's own values are back on disk, and the next login takes over again")
        case .userQuit:
            TakeoverMode.revertPrefs()
            NSLog("Takeover: off (still opted in)")
        case .leaveMode:
            TakeoverMode.revertPrefs()
            LoginItem.unregister()
            defaults.set(false, forKey: Keys.enabled)
            NSLog("Takeover: released")
        }
    }

    /// `quit`: the Apple event asking Sunlight to quit, if one did (`NSAppleEventManager.currentAppleEvent`),
    /// which says whether the session is ending. Not `NSWorkspace.willPowerOffNotification`: it stays said
    /// when the logout is cancelled (an app with unsaved work stops it), and every later ⌘Q passed for a
    /// logout, leaving the Mac taken over with Sunlight gone.
    func revertForTermination(quit: NSAppleEventDescriptor?) {
        guard isRunning else { return }
        revert(reason: TakeoverMode.isSessionEnding(quit) ? .logout : .userQuit)
    }

    /// The quit Apple event's reason (`keyAEQuitReason`, 'why?'): log out, restart or shut down, asked
    /// for or confirmed. ⌘Q, the menu and `terminate()` send none.
    nonisolated static func isSessionEnding(_ quit: NSAppleEventDescriptor?) -> Bool {
        guard let quit else { return false }
        let why = fourCharCode("why?")
        guard let reason = quit.attributeDescriptor(forKeyword: why) ?? quit.paramDescriptor(forKeyword: why) else { return false }
        let ending = ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharCode)
        return ending.contains(reason.enumCodeValue) || ending.contains(reason.typeCodeValue)
    }

    nonisolated static func fourCharCode(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Restores the snapshot and clears the flags. Shared with `--release`, so no UI here. `restarting`
    /// false writes the values only, for a session that is ending anyway.
    @discardableResult
    static func revertPrefs(restarting: Bool = true) -> Set<String> {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.applied) else { return [] }
        let snapshot = defaults.dictionary(forKey: Keys.snapshot) ?? [:]
        let changed = SystemPrefs.revert(snapshot: snapshot)
        if restarting { SystemPrefs.restart(domains: changed) }
        defaults.removeObject(forKey: Keys.snapshot)
        defaults.set(false, forKey: Keys.applied)
        defaults.synchronize()
        return changed
    }

    // MARK: Command line

    /// `Canvas --release`: a running Canvas restores the Mac itself as it quits; wait for it, then put
    /// back whatever is left, drop the login item and opt out.
    static func releaseFromCommandLine() -> Int32 {
        let running = otherInstances()
        if !running.isEmpty {
            print("Quitting running Sunlight…")
            running.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, !otherInstances().isEmpty { usleep(100_000) }
            if !otherInstances().isEmpty { print("Sunlight did not quit; restoring anyway.") }
        }
        let changed = revertPrefs()
        let stageManager = StageManager.restore()
        LoginItem.unregister()
        UserDefaults.standard.set(false, forKey: Keys.enabled)
        UserDefaults.standard.synchronize()
        var restored = changed.sorted()
        if stageManager { restored.append("Stage Manager (back on)") }
        print(restored.isEmpty ? "Nothing to restore." : "Restored: \(restored.joined(separator: ", "))")
        print("Login item removed. Takeover mode is off.")
        return 0
    }

    // MARK: One instance

    /// Only one Sunlight at a time. A second instance (a `make run` beside the login item's, or an
    /// earlier run that never quit) would show up on the new canvas as a window of its own (the window
    /// list keeps it off) and stall every Accessibility call made to it. The earlier one is asked to
    /// quit, then made to; `completion` runs once it's gone. Its takeover record lives in the shared
    /// defaults, so whichever instance survives restores the Mac — which is why takeover waits for it.
    static func quitOtherInstances(then completion: @escaping @MainActor () -> Void) {
        let running = otherInstances()
        guard !running.isEmpty else {
            completion()
            return
        }
        NSLog("Startup: quitting \(running.count) other Sunlight instance(s)")
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(2)
        func poll() {
            if otherInstances().isEmpty {
                completion()
            } else if Date() >= deadline {
                let stuck = otherInstances()
                NSLog("Startup: \(stuck.count) did not quit in 2 s — killing")
                stuck.forEach { $0.forceTerminate() }
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
            }
        }
        poll()
    }

    private static func otherInstances() -> [NSRunningApplication] {
        // A Canvas.app from before the rename counts too: it's the same app under its old ID.
        let bundleIDs = [Bundle.main.bundleIdentifier ?? "com.spacefarm.sunlight", LegacyMigration.legacyBundleID]
        let me = ProcessInfo.processInfo.processIdentifier
        return Set(bundleIDs).flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != me }
    }

    static func printStatus() {
        let d = UserDefaults.standard
        print("Takeover mode: \(d.bool(forKey: Keys.enabled) ? "on" : "off")")
        print("Prefs applied: \(d.bool(forKey: Keys.applied))")
        print("Login item: \(LoginItem.describe(LoginItem.status))")
        print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
        print("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
        print("Stage Manager: \(StageManager.describeCurrent())")
        print("Current values:\n\(SystemPrefs.describeCurrent())")
        if let snapshot = d.dictionary(forKey: Keys.snapshot) {
            print("Snapshot to restore:")
            for key in snapshot.keys.sorted() { print("  \(key) = \(snapshot[key] ?? "")") }
        }
    }
}
