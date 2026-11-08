import AppKit

/// Diagnose: one plain-text report about this Mac and this copy of Sunlight, copied to the clipboard and
/// saved beside the setup journal, for pasting into an issue. The Mac's facts, the setup checklist, what
/// `--renderer-status` prints, what the helper says about the add-on, what the person has done in the
/// wizard, and the journal's tail. No window titles, no screenshots, and the home folder is written as ~.
/// `report` is pure; `gather` reads the Mac and takes a moment (launchd, the add-on's socket): off the
/// main thread. `Sunlight --diagnose` prints the same report.
enum SetupDiagnose {
    /// What the main thread knows and the report needs: read there, then handed to `gather`.
    struct Inputs: Sendable {
        var record: SetupFlow.Record
        var consentedAt: Date?
        var opensAtLaunch: Bool
        var previewMode: Bool
        /// `Settings.renderer`, by name.
        var preferredRenderer: String
        var wantsLiveWindows: Bool

        @MainActor static var current: Inputs {
            Inputs(record: SetupRecord.current, consentedAt: SetupRecord.consentedAt,
                   opensAtLaunch: SetupWizardController.showsAtLaunch, previewMode: Settings.previewMode,
                   preferredRenderer: Settings.renderer.rawValue, wantsLiveWindows: Settings.renderer == .realWindows)
        }
    }

    /// Everything the report is made from.
    struct Facts: Sendable {
        var version: String
        /// Where the app is, with the home folder as ~.
        var location: String
        var system: String
        var mac: SetupFlow.Mac
        var status: SetupStatus
        /// `StageManager.describeCurrent()`: Sunlight needs it off.
        var stageManager = "off"
        /// The `--renderer-status` lines about the renderer.
        var renderer: String
        /// What `SunlightLiveWindows status` prints, or why it couldn't be asked.
        var helper: String
        var inputs: Inputs
        var journal: String
        var date: Date
        /// `desktopsLine`: how many Desktops there are, per display.
        var desktops = ""
        /// `stabilityLines`: safe mode, the last runs and stalls, and the newest crash reports.
        var stability: [String] = []
    }

    static let journalLines = 80

    // MARK: The report

    static func report(_ facts: Facts) -> String {
        var lines: [String] = []
        lines.append("Sunlight diagnose report")
        lines.append("Made \(stamp(facts.date))")
        lines.append("")
        lines.append("Sunlight \(facts.version), in \(facts.location)")
        lines.append("\(facts.system), \(facts.mac.appleSilicon ? "Apple silicon" : "Intel"), \(facts.mac.admin ? "an administrator" : "a standard user")"
                     + (facts.mac.osSupported ? "" : " (macOS older than Sunlight supports)"))
        lines.append("")
        lines.append("== Setup ==")
        lines.append(contentsOf: setupLines(facts.status))
        let progress = SetupFlow.progress(for: facts.status, mac: facts.mac)
        lines.append("Progress: \(progress.done) of \(progress.total) steps")
        lines.append("Stage Manager: \(facts.stageManager)")
        lines.append("Wizard: " + wizardSummary(facts.inputs))
        lines.append("Preview mode: \(facts.inputs.previewMode ? "on" : "off")")
        if !facts.desktops.isEmpty { lines.append("Desktops: \(facts.desktops)") }
        lines.append("")
        lines.append("== Renderer ==")
        lines.append(facts.renderer)
        lines.append("")
        lines.append("== Live-windows helper ==")
        lines.append(facts.helper.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        if !facts.stability.isEmpty {
            lines.append("== Stability ==")
            lines.append(contentsOf: facts.stability)
            lines.append("")
        }
        lines.append("== Setup journal (last \(journalLines) lines) ==")
        lines.append(journalTail(facts.journal))
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Setup: 3 steps left…" and one line per step, as `--renderer-status` prints them.
    static func setupLines(_ status: SetupStatus) -> [String] {
        var lines = ["Setup: \(status.summary)"]
        for item in status.items {
            let mark = switch item.state { case .done: "✓"; case .todo: "○"; case .waiting: "·" }
            lines.append("  \(mark) \(item.title): \(item.detail)")
        }
        return lines
    }

    static func wizardSummary(_ inputs: Inputs) -> String {
        var parts: [String] = []
        parts.append(inputs.record.welcomed ? "welcomed" : "not welcomed yet")
        if inputs.record.welcomed { parts.append(inputs.record.loginItemChosen ? "open at login chosen" : "open at login not chosen yet") }
        if inputs.record.skippedScreenRecording { parts.append("Screen Recording skipped") }
        parts.append(inputs.record.startedLive ? "live windows started" : "live windows not started")
        if let at = inputs.consentedAt { parts.append("SIP consent given \(stamp(at))") }
        if let resume = inputs.record.resume { parts.append("resuming at \(resume.rawValue)") }
        parts.append(inputs.opensAtLaunch ? "opens at launch" : "doesn't open at launch")
        return parts.joined(separator: ", ")
    }

    /// "1 on each of 2 displays", "3 (2 on one display, 1 on the other), 1 full-screen app": takeover
    /// keeps one Desktop per display, so more says folding hasn't happened.
    static func desktopsLine(_ displays: [Spaces.Display]) -> String {
        guard !displays.isEmpty else { return "unknown (SkyLight didn't say)" }
        let counts = displays.map { $0.desktops.count }
        let total = counts.reduce(0, +)
        var line: String
        if displays.count == 1 {
            line = "\(total) on 1 display"
        } else if Set(counts).count == 1 {
            line = "\(counts[0]) on each of \(displays.count) displays"
        } else {
            line = "\(total) (\(counts.map(String.init).joined(separator: " + ")) on \(displays.count) displays)"
        }
        let fullScreen = displays.reduce(0) { $0 + $1.spaces.filter { $0.kind == .fullScreen }.count }
        if fullScreen > 0 { line += ", \(fullScreen) full-screen app Space\(fullScreen == 1 ? "" : "s")" }
        return line
    }

    static func journalTail(_ journal: String) -> String {
        let lines = journal.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return "(empty)" }
        return lines.suffix(journalLines).joined(separator: "\n")
    }

    /// `path` with the home folder as ~, so a report names no user.
    static func redactingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func stamp(_ date: Date) -> String {
        fixedFormatter("yyyy-MM-dd HH:mm").string(from: date)
    }

    /// A formatter that keeps its pattern: with the Mac set to 12-hour time, a plain DateFormatter
    /// rewrites HH as h a.
    private static func fixedFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    // MARK: Reading the Mac

    /// The renderer lines `--renderer-status` starts with: what's preferred, whether the add-on answers,
    /// what that makes the effective renderer, preview mode, and how reloads run.
    static func rendererStatus(preferred: String, wantsLiveWindows: Bool, available: Bool, previewMode: Bool, reload: String) -> String {
        [
            "Preferred renderer: \(preferred)",
            "Sunlight live-window protocol v1: \(available ? "available" : "unavailable")",
            "Effective renderer: \(wantsLiveWindows && available ? "realWindows" : "capture")",
            "Preview mode: \(previewMode ? "on (windows stream as pictures until live windows first load)" : "off")",
            "Reload after a Dock restart: \(reload)",
        ].joined(separator: "\n")
    }

    /// How a reload after a Dock restart runs on this Mac: a round trip to launchd, off the main thread.
    nonisolated static func reloadDescription() -> String {
        guard let helper = AdditionReloader.helperPath else { return "no live-window helper in the bundle (make app)" }
        let how = switch LiveWindowsService.state {
        case .enabled: "through the background helper, without a password"
        case .needsApproval: "through the background helper, once it's turned on in System Settings › General › Login Items"
        case .notRegistered, .unavailable:
            AdditionReloader.isPasswordless() ? "with sudo, without a password" : "asks for a password once, then not again"
        }
        let paused = AdditionReloader.pausedAfterDockCrashes
            ? "; paused: the Dock kept restarting around loads, so only Reload Live Windows… loads it" : ""
        return "\(redactingHome(helper)) load, \(how)\(paused)"
    }

    /// What the helper says about the add-on: installed, answering, and whether this Mac can load it.
    nonisolated static func helperStatus() -> String {
        guard let helper = AdditionReloader.helperPath else { return "No live-windows helper in this bundle (make app)." }
        let result = AdditionReloader.run(helper, ["status"])
        guard result.status == 0 else { return "SunlightLiveWindows status failed (\(result.status)): \(result.output)" }
        return result.output
    }

    /// The "== Stability ==" section: how the last runs ended, the stalls the watchdog caught, the newest
    /// crash reports of Sunlight and of the Dock, and where the full log is. Reads files: off main.
    nonisolated static func stabilityLines(defaults: UserDefaults = .standard) -> [String] {
        CrashReports.collect()
        var lines = Stability.reportLines(runs: Stability.runs(defaults), stalls: Stability.stalls(defaults),
                                          safeMode: Stability.ownerInSafeMode(defaults),
                                          stamp: stamp)
        let crashes = CrashReports.recent("Sunlight", limit: 5) + CrashReports.recent("Dock", limit: 3)
        lines.append("Crash reports, newest first (\(redactingHome(CrashReports.keptFolder.path))):")
        lines.append(contentsOf: crashes.isEmpty ? ["  (none)"] : CrashReports.reportLines(crashes).map { "  " + $0 })
        lines.append("Log: \(redactingHome(Log.fileURL.path)). It names apps and windows, so it isn't in this report; attach it to an issue only if you're happy to.")
        return lines
    }

    /// Everything, read from the Mac. Takes a moment: off the main thread.
    nonisolated static func gather(_ inputs: Inputs) -> Facts {
        let info = Bundle.main.infoDictionary ?? [:]
        let version: String
        if let short = info["CFBundleShortVersionString"] as? String, let build = info["CFBundleVersion"] as? String {
            version = "\(short) (\(build))"
        } else {
            version = "development build, not in an app bundle"
        }
        let available = LiveWindowsConnection.probe()
        return Facts(version: version,
                     location: redactingHome(Bundle.main.bundleURL.path),
                     system: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""),
                     mac: SetupFlow.Mac.current(),
                     status: SetupStatus.current(),
                     stageManager: StageManager.describeCurrent(),
                     renderer: rendererStatus(preferred: inputs.preferredRenderer, wantsLiveWindows: inputs.wantsLiveWindows,
                                              available: available, previewMode: inputs.previewMode, reload: reloadDescription()),
                     helper: helperStatus(),
                     inputs: inputs, journal: SetupJournal.read(), date: Date(),
                     desktops: desktopsLine(Spaces.read()),
                     stability: stabilityLines())
    }

    /// Where a report goes: beside the setup journal, named by the minute.
    nonisolated static func reportURL(for date: Date = Date()) -> URL? {
        guard let folder = SetupJournal.url?.deletingLastPathComponent() else { return nil }
        return folder.appendingPathComponent("Diagnose \(fixedFormatter("yyyy-MM-dd HH.mm").string(from: date)).txt")
    }

    nonisolated static func save(_ report: String) -> URL? {
        guard let url = reportURL() else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.note("Diagnose: couldn't save the report — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: From a button

    /// Gathers the report off the main thread, copies it to the clipboard, saves it, and says so in a
    /// sheet on `window` (an alert of its own without one).
    @MainActor
    static func run(from window: NSWindow?) {
        let inputs = Inputs.current
        SetupJournal.note("Diagnose report requested")
        DispatchQueue.global(qos: .userInitiated).async {
            let text = report(gather(inputs))
            let url = save(text)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { present(text, savedAt: url, in: window) }
            }
        }
    }

    @MainActor
    private static func present(_ text: String, savedAt url: URL?, in window: NSWindow?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let alert = NSAlert()
        alert.messageText = "The diagnose report is on the clipboard"
        var detail = "Paste it into an issue or a message. It lists this Mac's setup, the renderer, what the helper says, recent crashes and stalls, and the setup log: no window titles, no pictures."
        if let url { detail += "\n\nSaved as \(url.lastPathComponent) in Sunlight's Application Support folder." }
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if url != nil { alert.addButton(withTitle: "Show in Finder") }
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn, let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } else if alert.runModal() == .alertSecondButtonReturn, let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
