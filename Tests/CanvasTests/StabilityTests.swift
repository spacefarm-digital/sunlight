import XCTest
@testable import Canvas

final class StabilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    /// Defaults of the test's own, gone afterwards; and the process left out of safe mode for every
    /// other test.
    @MainActor
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "StabilityTests-\(UUID().uuidString)"
        body(UserDefaults(suiteName: name)!)
        UserDefaults.standard.removePersistentDomain(forName: name)
        let clean = UserDefaults(suiteName: name + "-clean")!
        Stability.launched(pid: 1, defaults: clean, isRunning: { _ in false })
        Stability.quitCleanly(pid: 1, defaults: clean)
        UserDefaults.standard.removePersistentDomain(forName: name + "-clean")
    }

    /// A run that ended without quitting before it settled: what a crash at launch leaves. No quit, no
    /// settle: the next launch finds the mark of a process that's gone.
    @MainActor
    private func crashAtLaunch(pid: pid_t, at date: Date, _ defaults: UserDefaults) {
        Stability.launched(pid: pid, now: date, defaults: defaults, isRunning: { _ in false })
    }

    // MARK: Runs and safe mode

    @MainActor
    func testAQuitIsACleanRunAndClearsTheMark() {
        withDefaults { defaults in
            XCTAssertFalse(Stability.launched(pid: 100, now: t0, defaults: defaults, isRunning: { _ in false }))
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 100)
            Stability.quitCleanly(pid: 100, now: t0.addingTimeInterval(200), defaults: defaults)
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 0)
            XCTAssertEqual(Stability.runs(defaults), [Stability.Run(start: t0, end: t0.addingTimeInterval(200), clean: true, settled: true)])
        }
    }

    @MainActor
    func testTheNextLaunchRecordsARunNobodySawEnd() {
        withDefaults { defaults in
            crashAtLaunch(pid: 100, at: t0, defaults)
            XCTAssertFalse(Stability.launched(pid: 101, now: t0.addingTimeInterval(30), defaults: defaults, isRunning: { _ in false }))
            XCTAssertEqual(Stability.runs(defaults), [Stability.Run(start: t0, end: nil, clean: false, settled: false)])
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 101)
        }
    }

    @MainActor
    func testTwoCrashesAtLaunchInARowStartSafeMode() {
        withDefaults { defaults in
            crashAtLaunch(pid: 100, at: t0, defaults)
            crashAtLaunch(pid: 101, at: t0.addingTimeInterval(20), defaults)
            XCTAssertTrue(Stability.launched(pid: 102, now: t0.addingTimeInterval(40), defaults: defaults, isRunning: { _ in false }))
            XCTAssertTrue(Stability.safeMode)
            XCTAssertTrue(defaults.bool(forKey: Stability.Keys.ownerSafeMode))
            // Safe mode is for that one launch: it quits, and the next one is normal.
            Stability.quitCleanly(pid: 102, now: t0.addingTimeInterval(60), defaults: defaults)
            XCTAssertFalse(Stability.launched(pid: 103, now: t0.addingTimeInterval(70), defaults: defaults, isRunning: { _ in false }))
            XCTAssertFalse(Stability.safeMode)
        }
    }

    @MainActor
    func testACrashAfterSettlingDoesntCount() {
        withDefaults { defaults in
            Stability.launched(pid: 100, now: t0, defaults: defaults, isRunning: { _ in false })
            Stability.settle(pid: 100, defaults: defaults)
            crashAtLaunch(pid: 101, at: t0.addingTimeInterval(500), defaults)
            XCTAssertFalse(Stability.launched(pid: 102, now: t0.addingTimeInterval(520), defaults: defaults, isRunning: { _ in false }))
            XCTAssertEqual(Stability.runs(defaults).map(\.settled), [true, false])
        }
    }

    @MainActor
    func testACopyStillRunningIsBeingReplacedNotCrashed() {
        withDefaults { defaults in
            Stability.launched(pid: 100, now: t0, defaults: defaults, isRunning: { _ in false })
            Stability.launched(pid: 101, now: t0.addingTimeInterval(5), defaults: defaults, isRunning: { $0 == 100 })
            XCTAssertTrue(Stability.runs(defaults).isEmpty)
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 101)
        }
    }

    func testSafeModeWantsTwoUnsettledUnexpectedEnds() {
        let crash = Stability.Run(start: t0, end: nil, clean: false, settled: false)
        let quit = Stability.Run(start: t0, end: t0, clean: true, settled: false)
        let late = Stability.Run(start: t0, end: nil, clean: false, settled: true)
        XCTAssertFalse(Stability.wantsSafeMode(after: []))
        XCTAssertFalse(Stability.wantsSafeMode(after: [crash]))
        XCTAssertTrue(Stability.wantsSafeMode(after: [quit, crash, crash]))
        XCTAssertFalse(Stability.wantsSafeMode(after: [crash, quit]))
        XCTAssertFalse(Stability.wantsSafeMode(after: [crash, late]))
    }

    // MARK: The guard

    @MainActor
    func testTheGuardPutsTheMacBackWhenTheAppDidntQuit() {
        withDefaults { defaults in
            Stability.launched(pid: 200, now: t0, defaults: defaults, isRunning: { _ in false })
            var putBack = 0
            Stability.guardSawExit(of: 200, now: t0.addingTimeInterval(10), defaults: defaults, putBack: { putBack += 1; return ["Dock autohide"] })
            XCTAssertEqual(putBack, 1)
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 0)
            XCTAssertEqual(Stability.runs(defaults), [Stability.Run(start: t0, end: t0.addingTimeInterval(10), clean: false, settled: false)])
            // The next launch doesn't count it twice.
            Stability.launched(pid: 201, now: t0.addingTimeInterval(20), defaults: defaults, isRunning: { _ in false })
            XCTAssertEqual(Stability.runs(defaults).count, 1)
        }
    }

    @MainActor
    func testTheGuardLeavesAQuitAlone() {
        withDefaults { defaults in
            Stability.launched(pid: 200, now: t0, defaults: defaults, isRunning: { _ in false })
            Stability.quitCleanly(pid: 200, now: t0.addingTimeInterval(10), defaults: defaults)
            var putBack = 0
            Stability.guardSawExit(of: 200, defaults: defaults, putBack: { putBack += 1; return [] })
            XCTAssertEqual(putBack, 0)
            XCTAssertEqual(Stability.runs(defaults).map(\.clean), [true])
        }
    }

    @MainActor
    func testTheGuardLeavesTheMacToANewerCopy() {
        withDefaults { defaults in
            Stability.launched(pid: 200, now: t0, defaults: defaults, isRunning: { _ in false })
            Stability.launched(pid: 201, now: t0.addingTimeInterval(5), defaults: defaults, isRunning: { $0 == 200 })
            var putBack = 0
            Stability.guardSawExit(of: 200, defaults: defaults, putBack: { putBack += 1; return [] })
            XCTAssertEqual(putBack, 0)
            XCTAssertEqual(defaults.integer(forKey: Stability.Keys.owner), 201)
        }
    }

    // MARK: Stalls and the report

    @MainActor
    func testStallsKeepTheNewest() {
        withDefaults { defaults in
            for i in 0..<(Stability.keptStalls + 5) {
                Stability.recordStall(ms: 600 + i, label: i.isMultiple(of: 2) ? "Accessibility: raise (AXWindow.raise)" : nil, at: t0, defaults: defaults)
            }
            let stalls = Stability.stalls(defaults)
            XCTAssertEqual(stalls.count, Stability.keptStalls)
            XCTAssertEqual(stalls.last?.ms, 600 + Stability.keptStalls + 4)
        }
    }

    func testTheReportListsRunsAndStalls() {
        let runs = [Stability.Run(start: t0, end: t0.addingTimeInterval(100), clean: true, settled: true),
                    Stability.Run(start: t0.addingTimeInterval(200), end: nil, clean: false, settled: false)]
        let stalls = [Stability.Stall(at: t0, ms: 1240, label: "the Dock's answer to a handoff or release (RealWindowDriver.restore)")]
        let lines = Stability.reportLines(runs: runs, stalls: stalls, safeMode: false, stamp: { "T\(Int($0.timeIntervalSince(self.t0)))" })
        XCTAssertEqual(lines.first, "Safe mode: off")
        XCTAssertTrue(lines.contains("  T200, end not seen: ended unexpectedly within 90 s of opening"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("  T0 to T100: quit"))
        XCTAssertTrue(lines.contains("Unexpected ends: 1 of the last 2 runs"))
        XCTAssertTrue(lines.contains("  T0: 1240 ms, in the Dock's answer to a handoff or release (RealWindowDriver.restore)"))
        // Newest first.
        XCTAssertLessThan(lines.firstIndex(of: "  T200, end not seen: ended unexpectedly within 90 s of opening")!, lines.firstIndex(of: "  T0 to T100: quit")!)
    }

    func testDiagnoseCarriesTheStabilitySection() {
        var facts = SetupDiagnose.Facts(version: "0.2 (1)", location: "~/Applications/Sunlight.app", system: "macOS 27.2",
                                        mac: .supported, status: SetupStatus(accessibility: true, screenRecording: true, sipAllowsLiveWindows: true,
                                                                             bootArgument: true, helper: .daemonNotRegistered, liveWindowsLoaded: true),
                                        renderer: "", helper: "", inputs: SetupDiagnose.Inputs(record: SetupFlow.Record(), consentedAt: nil, opensAtLaunch: false,
                                                                                                previewMode: false, preferredRenderer: "realWindows", wantsLiveWindows: true),
                                        journal: "", date: t0)
        XCTAssertFalse(SetupDiagnose.report(facts).contains("== Stability =="))
        facts.stability = ["Safe mode: off"]
        let report = SetupDiagnose.report(facts)
        XCTAssertTrue(report.contains("== Stability ==\nSafe mode: off\n"))
        XCTAssertLessThan(report.range(of: "== Stability ==")!.lowerBound, report.range(of: "== Setup journal")!.lowerBound)
    }

    // MARK: The log

    func testLogLinesAndRotation() {
        let line = Log.line("Rendering: 100% done %s %@", at: t0, pid: 42)
        XCTAssertTrue(line.hasSuffix(" [42] Rendering: 100% done %s %@\n"))
        XCTAssertEqual(line.count, "2026-04-24 03:06:40.000".count + " [42] Rendering: 100% done %s %@\n".count)
        XCTAssertFalse(Log.needsRotation(size: 0, adding: 10, limit: 5), "an empty file takes a long line")
        XCTAssertFalse(Log.needsRotation(size: 10, adding: 10, limit: 20))
        XCTAssertTrue(Log.needsRotation(size: 15, adding: 10, limit: 20))
        XCTAssertFalse(Log.writesFile, "tests never write the real log")
    }

    /// A title with a format in it reaches the log as it is: `NSLog` with it as its format crashed.
    func testAMessageWithAFormatInItIsSafe() {
        Log.note("Close: Safari — 100% sure %s %@ %n")
    }

    // MARK: Crash reports

    private let report = """
    {"app_name":"Sunlight","timestamp":"2026-11-01 17:52:26.00 +0100","app_version":"0.2","build_version":"12","os_version":"macOS 27.2 (27C101)","bug_type":"309","name":"Sunlight"}
    {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"termination":{"indicator":"Trace/BPT trap: 5","namespace":"SIGNAL","code":5},"faultingThread":1,"threads":[{"frames":[{"imageIndex":0,"symbol":"main"}]},{"triggered":true,"frames":[{"imageIndex":1,"symbol":"_dispatch_assert_queue_fail"},{"imageIndex":2,"imageOffset":4660}]}],"usedImages":[{"name":"Sunlight"},{"name":"libdispatch.dylib"},{"path":"/System/Library/Frameworks/Carbon.framework/HIToolbox"}],"asi":{"libsystem_c.dylib":["a secret window title"]}}
    """

    func testReportNames() {
        XCTAssertEqual(CrashReports.app(ofReport: "Sunlight-2026-11-01-175226.ips"), "Sunlight")
        XCTAssertEqual(CrashReports.app(ofReport: "Dock-2026-11-01-175226.ips"), "Dock")
        XCTAssertNil(CrashReports.app(ofReport: "dasd-2026-11-07-091031.ips"))
        XCTAssertNil(CrashReports.app(ofReport: "Sunlight-2026-11-01-175226.diag"))
        XCTAssertNil(CrashReports.app(ofReport: "SunlightHelper-2026-11-01-175226.ips"))
    }

    func testASummaryHasTheCrashedThreadAndNoTitles() throws {
        let summary = try XCTUnwrap(CrashReports.summary(of: report))
        XCTAssertEqual(summary.app, "Sunlight")
        XCTAssertEqual(summary.version, "0.2 (12)")
        XCTAssertEqual(summary.exception, "EXC_BREAKPOINT SIGTRAP")
        XCTAssertEqual(summary.termination, "Trace/BPT trap: 5")
        XCTAssertEqual(summary.frames, ["libdispatch.dylib _dispatch_assert_queue_fail", "HIToolbox +0x1234"])
        let lines = CrashReports.reportLines([summary]).joined(separator: "\n")
        XCTAssertTrue(lines.hasPrefix("Sunlight, 2026-11-01 17:52:26.00 +0100, 0.2 (12): EXC_BREAKPOINT SIGTRAP; Trace/BPT trap: 5"), lines)
        XCTAssertFalse(lines.contains("secret"))
        XCTAssertNil(CrashReports.summary(of: "not a report"))
    }

    func testADockReportSaysWhetherTheAddOnWasLoaded() throws {
        let dock = """
        {"app_name":"Dock","timestamp":"2026-11-02 10:00:00.00 +0100"}
        {"threads":[],"usedImages":[{"path":"/Library/ScriptingAdditions/Sunlight.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload"}]}
        """
        XCTAssertTrue(try XCTUnwrap(CrashReports.summary(of: dock)).addOnLoaded)
        XCTAssertEqual(CrashReports.reportLines([try XCTUnwrap(CrashReports.summary(of: dock))]), ["Dock, 2026-11-02 10:00:00.00 +0100, Sunlight's add-on loaded"])
    }

    func testCollectCopiesOursAndKeepsTheNewest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StabilityTests-\(UUID().uuidString)")
        let reports = root.appendingPathComponent("reports"), kept = root.appendingPathComponent("kept")
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for day in 1...(CrashReports.keptPerApp + 2) {
            try report.write(to: reports.appendingPathComponent(String(format: "Sunlight-2026-10-%02d-120000.ips", day)), atomically: true, encoding: .utf8)
        }
        try "{}".write(to: reports.appendingPathComponent("dasd-2026-11-07-091031.ips"), atomically: true, encoding: .utf8)
        CrashReports.collect(from: [reports, reports.appendingPathComponent("Retired")], into: kept)
        let names = try fm.contentsOfDirectory(atPath: kept.path).sorted()
        XCTAssertEqual(names.count, CrashReports.keptPerApp)
        XCTAssertEqual(names.first, "Sunlight-2026-10-03-120000.ips", "the oldest go")
        XCTAssertFalse(names.contains { $0.hasPrefix("dasd") })
        XCTAssertEqual(CrashReports.recent("Sunlight", limit: 2, in: kept).count, 2)
    }

    // MARK: The watchdog

    func testDuringHandsBackWhatItRan() throws {
        XCTAssertEqual(Watchdog.during("a test") { 7 }, 7)
        XCTAssertThrowsError(try Watchdog.during("a test") { throw CocoaError(.fileNoSuchFile) })
        let off = expectation(description: "off the main thread")
        DispatchQueue.global().async {
            XCTAssertEqual(Watchdog.during("a test") { "ran" }, "ran")
            off.fulfill()
        }
        wait(for: [off], timeout: 2)
    }

    func testAGapBetweenRunLoopStepsIsAStall() {
        let watchdog = Watchdog()
        XCTAssertNil(watchdog.step(.afterWaiting, at: 100))
        XCTAssertNil(watchdog.step(.beforeTimers, at: 100.2))
        XCTAssertEqual(watchdog.step(.beforeSources, at: 100.9), Watchdog.Stall(ms: 700, label: nil))
        // Asleep waiting for events is no stall, however long.
        XCTAssertNil(watchdog.step(.beforeWaiting, at: 101))
        XCTAssertNil(watchdog.step(.afterWaiting, at: 160))
        XCTAssertNil(watchdog.step(.beforeTimers, at: 160.4))
    }

    /// A slow call inside `during` names the stall it's part of, and only that one.
    @MainActor
    func testASlowNamedCallNamesTheStall() {
        let watchdog = Watchdog.shared
        _ = watchdog.step(.beforeWaiting, at: 1)
        XCTAssertNil(watchdog.step(.afterWaiting, at: 1000))
        Watchdog.during("a test call") { Thread.sleep(forTimeInterval: Watchdog.threshold + 0.05) }
        XCTAssertEqual(watchdog.step(.beforeSources, at: 1000.8), Watchdog.Stall(ms: 800, label: "a test call"))
        XCTAssertEqual(watchdog.step(.beforeTimers, at: 1001.6), Watchdog.Stall(ms: 800, label: nil))
        _ = watchdog.step(.beforeWaiting, at: 1002)
    }

    @MainActor
    func testTheGuardAndALaunchStraightAfterRecordOneCrash() {
        withDefaults { defaults in
            Stability.launched(pid: 300, now: t0, defaults: defaults, isRunning: { _ in false })
            // The next launch reads the mark before the guard has cleared it.
            Stability.launched(pid: 301, now: t0.addingTimeInterval(1), defaults: defaults, isRunning: { _ in false })
            defaults.set(300, forKey: Stability.Keys.owner)
            defaults.set(t0, forKey: Stability.Keys.ownerStart)
            Stability.guardSawExit(of: 300, now: t0.addingTimeInterval(0.5), defaults: defaults, putBack: { [] })
            XCTAssertEqual(Stability.runs(defaults), [Stability.Run(start: t0, end: t0.addingTimeInterval(0.5), clean: false, settled: false)])
        }
    }

    @MainActor
    func testDiagnoseSaysSafeModeOnlyWhileThatCopyRuns() {
        withDefaults { defaults in
            defaults.set(400, forKey: Stability.Keys.owner)
            defaults.set(true, forKey: Stability.Keys.ownerSafeMode)
            XCTAssertTrue(Stability.ownerInSafeMode(defaults, isRunning: { $0 == 400 }))
            XCTAssertFalse(Stability.ownerInSafeMode(defaults, isRunning: { _ in false }), "killed with its guard: a stale mark")
        }
    }

    func testCollectDoesntBringBackWhatItPruned() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("StabilityTests-\(UUID().uuidString)")
        let reports = root.appendingPathComponent("reports"), kept = root.appendingPathComponent("kept")
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for day in 1...(CrashReports.keptPerApp + 3) {
            try report.write(to: reports.appendingPathComponent(String(format: "Dock-2026-10-%02d-120000.ips", day)), atomically: true, encoding: .utf8)
        }
        CrashReports.collect(from: [reports], into: kept)
        try fm.removeItem(at: kept.appendingPathComponent("Dock-2026-10-23-120000.ips"))
        CrashReports.collect(from: [reports], into: kept)
        let names = try fm.contentsOfDirectory(atPath: kept.path).sorted()
        XCTAssertEqual(names.count, CrashReports.keptPerApp, "the deleted newest comes back, the pruned old ones don't")
        XCTAssertEqual(names.first, "Dock-2026-10-04-120000.ips")
    }
}
