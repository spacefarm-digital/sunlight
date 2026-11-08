import AppKit

/// Keeps the live-window add-on loaded across Dock restarts. The add-on lives inside the Dock's
/// process, so every Dock restart (takeover writing its prefs, `killall Dock`, a crash) unloads it,
/// and only root can put it back: `SunlightLiveWindows load`, the helper in the app bundle, which
/// carries the add-on and its loader (see LiveWindows/).
///
/// The Dock is watched by its process ID. When a new Dock shows up, the controller drops to capture
/// proxies and asks for a reload. The helper's launch daemon (`LiveWindowsService`) runs it as root
/// without any prompt once the user has turned it on in Login Items; asking interactively registers it
/// and opens Login Items for that. Builds without the daemon (ad-hoc signed) use `sudo -n`, which runs
/// the helper without a prompt where sudoers allows that one command; where it doesn't, Sunlight shows
/// the administrator prompt itself (once per Dock), and that prompt also installs the sudoers rule, so
/// later reloads need nothing. Once the add-on answers the capability probe again, live mode resumes.
@MainActor
final class AdditionReloader {
    enum Outcome: Equatable, Sendable {
        case loaded
        /// sudoers doesn't let this user run it without a password: the menu item can still ask for one.
        case needsPassword
        /// The launch daemon is registered but the user hasn't turned it on in Login Items yet.
        case needsApproval
        /// No helper: the app isn't running from a bundle `scripts/package.sh` made.
        case notConfigured
        case failed(String)

        var description: String {
            switch self {
            case .loaded: return "loaded"
            case .needsPassword: return "needs an administrator password (Sunlight › Reload Live Windows…)"
            case .needsApproval: return "needs your OK: turn on Sunlight in System Settings › General › Login Items, under Allow in the Background, then choose Sunlight › Reload Live Windows…"
            case .notConfigured: return "no live-window helper in the app bundle (`make app` builds it in)"
            case .failed(let reason): return "failed: \(reason)"
            }
        }
    }

    nonisolated static let dockBundleID = "com.apple.dock"
    /// How long a new Dock is given to finish starting before the addition is injected into it.
    static let dockSettle: TimeInterval = 1.5
    /// How long a loaded addition gets to start answering before the reload counts as failed.
    nonisolated static let answerTimeout: TimeInterval = 8

    /// A new Dock process is running: whatever was loaded into the old one is gone.
    var onDockRestarted: (() -> Void)?
    /// The Dock kept restarting around loads (`DockCrashGuard`): quiet reloads have just stopped.
    var onPaused: (() -> Void)?
    private var crashGuard = DockCrashGuard()

    /// Where the add-on version the guard stopped quiet reloads for is kept, across launches: a Dock that
    /// crashes on load would otherwise be loaded into again at every launch. A build carrying another
    /// add-on version tries again by itself; Reload Live Windows… or the setup's Load page clears it.
    nonisolated static let pausedKey = "LiveWindowsPausedForAddition"
    nonisolated static var pausedAfterDockCrashes: Bool {
        UserDefaults.standard.string(forKey: pausedKey) == LiveWindowsWire.additionVersion
    }
    private(set) var dockPID: pid_t = AdditionReloader.currentDockPID()
    /// Quiet reloads tried in the Dock with this process ID. Twice per Dock at most (a try can race the
    /// Dock's own startup), so an addition that won't load isn't retried every time something asks.
    private var tried: (pid: pid_t, count: Int) = (0, 0)
    static let quietTriesPerDock = 2
    /// The Dock the administrator prompt was last shown for, so a cancelled prompt doesn't come back
    /// until the next Dock restart (the menu item can still ask).
    private var promptedDock: pid_t = 0
    private(set) var lastOutcome: Outcome?
    private var timer: Timer?

    nonisolated static func currentDockPID() -> pid_t {
        NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first?.processIdentifier ?? 0
    }

    /// The helper in the app bundle (Contents/Helpers/SunlightLiveWindows, put there by
    /// `scripts/package.sh`), or the one `SUNLIGHT_LIVE_HELPER` names when running outside a bundle.
    nonisolated static var helperPath: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SunlightLiveWindows").path
        let candidates = [ProcessInfo.processInfo.environment["SUNLIGHT_LIVE_HELPER"], bundled]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Watches the Dock while live windows are wanted. A process listing a second is cheap, and the
    /// Dock isn't an app NSWorkspace reliably reports launches and exits for.
    func watch(_ wanted: Bool) {
        guard wanted != (timer != nil) else { return }
        guard wanted else {
            timer?.invalidate()
            timer = nil
            return
        }
        dockPID = AdditionReloader.currentDockPID()
        // The Dock's exit and relaunch are announced; the clock is the fallback, slow.
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == "com.apple.dock" else { return }
                    MainActor.assumeIsolated { self?.checkDock() }
                })
            }
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDock() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private var observers: [NSObjectProtocol] = []

    private func checkDock() {
        let pid = AdditionReloader.currentDockPID()
        guard pid != dockPID else { return }
        let old = dockPID
        dockPID = pid
        // Between the old Dock exiting and launchd starting the new one there's no Dock at all.
        guard pid != 0 else { return }
        Log.note("Rendering: the Dock restarted (\(old) → \(pid))")
        if crashGuard.dockRestarted(at: Date()), !AdditionReloader.pausedAfterDockCrashes {
            UserDefaults.standard.set(LiveWindowsWire.additionVersion, forKey: AdditionReloader.pausedKey)
            Log.note("Rendering: the Dock restarted \(DockCrashGuard.limit) times in a row within \(Int(DockCrashGuard.window)) s of loading the add-on; not loading it by itself again (Reload Live Windows… tries again)")
            onPaused?()
        }
        onDockRestarted?()
    }

    /// Whether a reload without a prompt hasn't been tried in this Dock yet.
    var mayTryQuietly: Bool {
        let pid = AdditionReloader.currentDockPID()
        return pid != 0 && !AdditionReloader.pausedAfterDockCrashes
            && (tried.pid != pid || tried.count < AdditionReloader.quietTriesPerDock)
    }

    /// Whether the administrator prompt hasn't been shown for this Dock yet; marks it shown.
    func claimPrompt() -> Bool {
        let pid = AdditionReloader.currentDockPID()
        guard pid != 0, promptedDock != pid else { return false }
        promptedDock = pid
        return true
    }

    /// Loads the add-on into the running Dock and waits until it answers. Through the daemon when it's on;
    /// otherwise quietly with `sudo -n`, or when `interactive` by registering the daemon (where the build
    /// has one) or with the system's administrator prompt, which also sets up `sudo -n`.
    /// `asked`: the person asked for it (the menu, the setup's Load page), which also lifts a pause the crash
    /// guard put on quiet reloads.
    func reload(interactive: Bool, asked: Bool = false) async -> Outcome {
        let pid = AdditionReloader.currentDockPID()
        if !interactive { tried = (pid, tried.pid == pid ? tried.count + 1 : 1) }
        if asked {
            // The person gets another go, and the guard counts afresh.
            UserDefaults.standard.removeObject(forKey: AdditionReloader.pausedKey)
            crashGuard.reset()
        }
        crashGuard.loadStarted(at: Date())
        let outcome = await Task.detached(priority: .userInitiated) {
            AdditionReloader.load(interactive: interactive)
        }.value
        crashGuard.loadEnded(at: Date())
        lastOutcome = outcome
        return outcome
    }

    // MARK: Off the main thread

    nonisolated private static func load(interactive: Bool) -> Outcome {
        guard let helper = helperPath else { return .notConfigured }
        let result: (status: Int32, output: String)
        var daemon = LiveWindowsService.state
        if interactive, daemon == .notRegistered || daemon == .needsApproval {
            daemon = LiveWindowsService.register()
            if daemon == .needsApproval { return .needsApproval }
        }
        if daemon == .enabled {
            result = LiveWindowsService.run("load")
        } else if daemon == .needsApproval {
            return .needsApproval
        } else if interactive {
            let load = shellQuoted(helper) + " load"
            // The rule goes in first, quietly: if sudoers can't take it, the load still goes ahead.
            let shell = passwordlessRule(for: helper).map { "{ \($0); } >/dev/null 2>&1; " + load } ?? load
            let prompt = "Sunlight wants to load live windows into the Dock, and reload them after Dock restarts without asking again."
            let script = "do shell script \(appleScriptString(shell)) with prompt \(appleScriptString(prompt)) with administrator privileges"
            result = run("/usr/bin/osascript", ["-e", script])
        } else {
            result = run("/usr/bin/sudo", ["-n", helper, "load"])
        }
        guard result.status == 0 else {
            if !interactive, daemon != .enabled, result.output.contains("password") {
                // A build with the daemon asks for the Login Items OK rather than a password.
                return daemon == .notRegistered ? .needsPassword : .needsApproval
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(output.isEmpty ? "exit status \(result.status)" : output)
        }
        // The Dock may still be starting, and the add-on takes a moment to open its socket.
        let deadline = Date().addingTimeInterval(answerTimeout)
        while Date() < deadline {
            if LiveWindowsConnection.probe() { return .loaded }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return .failed("the add-on was loaded, but it doesn't answer the live-window protocol")
    }

    /// The rule letting this user run exactly `<helper> load` as root without a password.
    nonisolated static let sudoersPath = "/private/etc/sudoers.d/sunlight-live-windows"
    /// The rule earlier builds wrote for an external yabai; replaced, not kept.
    nonisolated static let legacySudoersPath = "/private/etc/sudoers.d/canvas-yabai"

    /// Shell, run as root, that installs that rule pinned to the helper's SHA-256 (the add-on and loader
    /// are built into it, so the hash covers everything that runs as root): a rebuilt or swapped helper
    /// no longer matches, and the app asks once more. visudo checks the rule before it's installed. nil
    /// where sudoers couldn't name the path or the user safely; the load still goes ahead without it.
    nonisolated static func passwordlessRule(for helper: String) -> String? {
        let user = NSUserName()
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        guard !user.isEmpty, !user.hasPrefix("-"), helper.hasPrefix("/"),
              helper.unicodeScalars.allSatisfy(safe.contains), user.unicodeScalars.allSatisfy(safe.contains) else { return nil }
        return [
            "t=$(mktemp)",
            "h=$(shasum -a 256 \(helper) | cut -d ' ' -f 1)",
            "echo \"\(user) ALL=(root) NOPASSWD: sha256:$h \(helper) load\" > \"$t\"",
            "visudo -cf \"$t\" && install -m 0440 -o root -g wheel \"$t\" \(sudoersPath) && rm -f \(legacySudoersPath)",
            "rm -f \"$t\"",
        ].joined(separator: "; ")
    }

    nonisolated static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Whether the reload runs without asking: the daemon is on, or `sudo -n` allows it.
    nonisolated static func isPasswordless() -> Bool {
        guard let helper = helperPath else { return false }
        if LiveWindowsService.state == .enabled { return true }
        return run("/usr/bin/sudo", ["-n", "-l", helper, "load"]).status == 0
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, error.localizedDescription) }
        // Read before waiting: a full pipe would otherwise hold the child up forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Notices a Dock that keeps going down around loads of the add-on. Each Dock restart while a load runs,
/// or within `window` of one ending, is a strike; any other restart clears them. At `limit` strikes in a
/// row the add-on is taken to be what brings the Dock down, and `AdditionReloader` stops loading it by
/// itself. A healthy load can cost one strike (the helper restarts the Dock when it installs the add-on)
/// and turning on takeover another, so it takes three.
struct DockCrashGuard {
    static let window: TimeInterval = 60
    static let limit = 3

    private(set) var strikes = 0
    private var loading = false
    private var lastLoad: Date?

    mutating func loadStarted(at date: Date) {
        loading = true
        lastLoad = date
    }

    mutating func loadEnded(at date: Date) {
        loading = false
        lastLoad = date
    }

    /// Counts a Dock restart; true when it makes `limit` strikes in a row.
    mutating func dockRestarted(at date: Date) -> Bool {
        let nearLoad = loading || lastLoad.map { date.timeIntervalSince($0) < DockCrashGuard.window } ?? false
        strikes = nearLoad ? strikes + 1 : 0
        return strikes >= DockCrashGuard.limit
    }

    mutating func reset() {
        strikes = 0
    }
}
