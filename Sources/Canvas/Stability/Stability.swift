import AppKit
import Darwin

/// What became of each run of Sunlight, the crash-loop safe mode that follows from it, and the guard
/// that puts the Mac back when a run ends without quitting.
///
/// Each run of the app (not the command-line flags) marks itself the owner in Sunlight's defaults: its
/// process ID, when it started, and whether it has lasted `settleTime`. A quit clears the mark and adds
/// a clean run to `runs`. A run that ends any other way (a crash, a force quit, a kill) is added as an
/// unexpected one, by its guard as it happens or, when nothing saw it (the guard was killed too), by
/// the next launch, which finds the mark of a process that is gone.
///
/// Two unexpected ends in a row, each before the run had settled, start the next launch in safe mode:
/// no takeover and no live windows, the two parts that reach into the rest of the Mac, for that one
/// launch. Without it, a build that crashes at launch would take the Mac over again every time it was
/// opened, and only `--release` in Terminal could free it.
///
/// The guard is a second process of the same binary (`--guard <pid>`), started at launch, which waits
/// for the app to exit. When it exits still marked as the owner, it didn't quit: the guard records that
/// and puts takeover's Dock and Mission Control settings and Stage Manager back at once, as a quit would
/// have, rather than leaving them until the next launch. It needs no installing and nothing as root, and
/// it ends with the app. A newer copy that has taken the mark (one launched over this one) owns the Mac
/// from then on, so the guard leaves it alone.
enum Stability {
    enum Keys {
        static let owner = "stability.owner"
        static let ownerStart = "stability.ownerStart"
        static let ownerSettled = "stability.ownerSettled"
        static let ownerSafeMode = "stability.ownerSafeMode"
        static let runs = "stability.runs"
        static let stalls = "stability.stalls"
    }

    /// A run that has lasted this long has settled: a crash after it isn't a crash at launch.
    nonisolated static let settleTime: TimeInterval = 90
    nonisolated static let keptRuns = 20
    nonisolated static let keptStalls = 20

    struct Run: Codable, Equatable, Sendable {
        var start: Date
        /// When it ended, when that's known: a quit, or the guard watching it go.
        var end: Date?
        var clean: Bool
        var settled: Bool
    }

    struct Stall: Codable, Equatable, Sendable {
        var at: Date
        var ms: Int
        var label: String?
    }

    /// This launch is in safe mode (`launched`).
    @MainActor private(set) static var safeMode = false
    /// When this run started and whether it has settled, kept here too: a copy launched over this one
    /// takes the mark in the defaults, and this one still records its own run when it quits.
    @MainActor private static var started = Date()
    @MainActor private static var settled = false
    /// `launched` ran: this is the app, not a setup preview, so its quit is a run to record.
    @MainActor private static var tracking = false
    @MainActor private static var guardSource: DispatchSourceProcess?

    // MARK: Runs

    nonisolated static func runs(_ defaults: UserDefaults = .standard) -> [Run] {
        decode([Run].self, defaults.data(forKey: Keys.runs)) ?? []
    }

    nonisolated static func stalls(_ defaults: UserDefaults = .standard) -> [Stall] {
        decode([Stall].self, defaults.data(forKey: Keys.stalls)) ?? []
    }

    /// The guard and a launch straight after the crash can both see the same run end: the second record
    /// of it (the same start) only fills in the end, if the first didn't have it.
    nonisolated private static func append(_ run: Run, to defaults: UserDefaults) {
        var all = runs(defaults)
        if let last = all.last, last.start == run.start, !last.clean, !run.clean {
            all[all.count - 1].end = last.end ?? run.end
        } else {
            all.append(run)
        }
        defaults.set(try? JSONEncoder().encode(Array(all.suffix(keptRuns))), forKey: Keys.runs)
    }

    /// For Diagnose, from any process: a running Sunlight that launched in safe mode.
    nonisolated static func ownerInSafeMode(_ defaults: UserDefaults = .standard, isRunning: (pid_t) -> Bool = Stability.isSunlight) -> Bool {
        let owner = pid_t(truncatingIfNeeded: defaults.integer(forKey: Keys.owner))
        return owner != 0 && defaults.bool(forKey: Keys.ownerSafeMode) && isRunning(owner)
    }

    nonisolated static func recordStall(ms: Int, label: String?, at date: Date = Date(), defaults: UserDefaults = .standard) {
        let all = Array((stalls(defaults) + [Stall(at: date, ms: ms, label: label)]).suffix(keptStalls))
        defaults.set(try? JSONEncoder().encode(all), forKey: Keys.stalls)
    }

    /// Two unexpected ends in a row, neither after settling.
    nonisolated static func wantsSafeMode(after runs: [Run]) -> Bool {
        let last = runs.suffix(2)
        return last.count == 2 && last.allSatisfy { !$0.clean && !$0.settled }
    }

    /// The owner's mark, as a run that ended unexpectedly (at `end`, if known).
    nonisolated private static func ownerRun(_ defaults: UserDefaults, end: Date?) -> Run {
        Run(start: defaults.object(forKey: Keys.ownerStart) as? Date ?? end ?? Date(), end: end, clean: false,
            settled: defaults.bool(forKey: Keys.ownerSettled))
    }

    /// At launch, before anything else touches the Mac: records a previous run that ended without
    /// quitting and that nothing saw end, takes the mark, and decides safe mode. Returns it.
    @MainActor @discardableResult
    static func launched(pid: pid_t = getpid(), now: Date = Date(), defaults: UserDefaults = .standard,
                         isRunning: (pid_t) -> Bool = Stability.isSunlight) -> Bool {
        let owner = pid_t(truncatingIfNeeded: defaults.integer(forKey: Keys.owner))
        if owner != 0, owner != pid, !isRunning(owner) {
            append(ownerRun(defaults, end: nil), to: defaults)
            Log.note("Stability: the last run of Sunlight (pid \(owner)) ended without quitting")
        }
        let history = runs(defaults)
        safeMode = wantsSafeMode(after: history)
        started = now
        settled = false
        tracking = true
        defaults.set(Int(pid), forKey: Keys.owner)
        defaults.set(now, forKey: Keys.ownerStart)
        defaults.set(false, forKey: Keys.ownerSettled)
        defaults.set(safeMode, forKey: Keys.ownerSafeMode)
        defaults.synchronize()
        if safeMode {
            Log.note("Stability: Sunlight ended unexpectedly twice soon after opening; this launch is in safe mode (no takeover, no live windows)")
        }
        return safeMode
    }

    /// `settleTime` after launch.
    @MainActor static func settle(pid: pid_t = getpid(), defaults: UserDefaults = .standard) {
        guard tracking else { return }
        settled = true
        if defaults.integer(forKey: Keys.owner) == Int(pid) { defaults.set(true, forKey: Keys.ownerSettled) }
    }

    /// The quit: the last thing `applicationShouldTerminate` does, and an uninstall's before its exit.
    @MainActor static func quitCleanly(pid: pid_t = getpid(), now: Date = Date(), defaults: UserDefaults = .standard) {
        guard tracking else { return }
        tracking = false
        append(Run(start: started, end: now, clean: true, settled: settled || now.timeIntervalSince(started) >= settleTime), to: defaults)
        if defaults.integer(forKey: Keys.owner) == Int(pid) {
            defaults.set(0, forKey: Keys.owner)
            defaults.set(false, forKey: Keys.ownerSafeMode)
        }
        defaults.synchronize()
    }

    /// A process with this ID is running and is a Sunlight.
    nonisolated static func isSunlight(_ pid: pid_t) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        let process = String(cString: name)
        return process == "Sunlight" || process == "Canvas"
    }

    // MARK: The guard

    /// Starts `Sunlight --guard <this pid>` in a session of its own, so a Terminal's Ctrl-C or a closed
    /// Terminal window doesn't take it down with the app.
    nonisolated static func startGuard() {
        guard let executable = Bundle.main.executablePath else { return }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x0400))   // POSIX_SPAWN_SETSID
        let arguments = [executable, "--guard", String(getpid())]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, nil, &attributes, argv, envp)
        if status == 0 {
            Log.note("Stability: guard started (pid \(child))")
        } else {
            Log.note("Stability: couldn't start the guard (\(String(cString: strerror(status)))); a crash would leave takeover's settings until the next launch")
        }
    }

    /// `Sunlight --guard <pid>`: waits for that process to exit, then does `guardSawExit`. Never returns.
    @MainActor static func guardMain(parent: pid_t) -> Never {
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let status = guardSawExit(of: parent)
                exit(status)
            }
        }
        source.resume()
        guardSource = source
        // Gone before the source was watching: it never fires.
        if kill(parent, 0) != 0, errno == ESRCH { exit(guardSawExit(of: parent)) }
        dispatchMain()
    }

    /// The app has exited. Still the owner: it didn't quit, so the run is recorded and the Mac put back.
    /// Returns the exit status for the guard.
    @MainActor @discardableResult
    static func guardSawExit(of parent: pid_t, now: Date = Date(), defaults: UserDefaults = .standard,
                             putBack: @MainActor () -> [String] = Stability.putMacBack) -> Int32 {
        defaults.synchronize()
        guard defaults.integer(forKey: Keys.owner) == Int(parent) else { return 0 }
        append(ownerRun(defaults, end: now), to: defaults)
        defaults.set(0, forKey: Keys.owner)
        defaults.set(false, forKey: Keys.ownerSafeMode)
        defaults.synchronize()
        Log.note("Guard: Sunlight (pid \(parent)) ended without quitting; putting the Mac back")
        let restored = putBack()
        Log.note("Guard: \(restored.isEmpty ? "nothing to put back" : "put back \(restored.joined(separator: ", "))")")
        return 0
    }

    /// What a quit would have put back: takeover's settings (the Dock restarts if they changed) and
    /// Stage Manager. The login item and the opt-in stay, so the next launch takes over again.
    @MainActor static func putMacBack() -> [String] {
        var restored = TakeoverMode.revertPrefs().sorted()
        if StageManager.restore() { restored.append("Stage Manager") }
        return restored
    }

    // MARK: Safe mode

    /// Says so once the canvas is up, with Diagnose a click away.
    @MainActor static func announceSafeMode() {
        guard safeMode else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Sunlight opened in safe mode"
        alert.informativeText = """
        It quit unexpectedly twice soon after opening, so this time it hasn't taken over the Mac, and windows \
        show as pictures rather than live. Quit Sunlight and open it again to go back to normal.

        A Diagnose report lists what happened, for an issue on GitHub.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Diagnose…")
        if alert.runModal() == .alertSecondButtonReturn { SetupDiagnose.run(from: nil) }
    }

    // MARK: For Diagnose

    /// The "== Stability ==" lines: this copy's mode, the last runs and stalls. No window titles.
    nonisolated static func reportLines(runs: [Run], stalls: [Stall], safeMode: Bool, stamp: (Date) -> String) -> [String] {
        var lines = ["Safe mode: \(safeMode ? "on for this launch (two unexpected ends in a row soon after opening)" : "off")"]
        lines.append("Runs, newest first:")
        if runs.isEmpty { lines.append("  (none recorded yet)") }
        for run in runs.reversed().prefix(10) {
            let ending: String
            if run.clean {
                ending = "quit"
            } else {
                ending = "ended unexpectedly\(run.settled ? "" : " within \(Int(settleTime)) s of opening")"
            }
            let span = run.end.map { "\(stamp(run.start)) to \(stamp($0))" } ?? "\(stamp(run.start)), end not seen"
            lines.append("  \(span): \(ending)")
        }
        let unexpected = runs.filter { !$0.clean }.count
        lines.append("Unexpected ends: \(unexpected) of the last \(runs.count) runs")
        lines.append("Stalls (main thread over \(Int(Watchdog.threshold * 1000)) ms), newest first:")
        if stalls.isEmpty { lines.append("  (none)") }
        for stall in stalls.reversed().prefix(10) {
            lines.append("  \(stamp(stall.at)): \(stall.ms) ms\(stall.label.map { ", in \($0)" } ?? "")")
        }
        return lines
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
