import XCTest
@testable import Canvas

final class SetupDiagnoseTests: XCTestCase {
    private let halfway = SetupStatus(accessibility: true, screenRecording: true, sipAllowsLiveWindows: false,
                                      bootArgument: false, helper: .daemonNotRegistered, liveWindowsLoaded: false)

    private func facts(journal: String = "2026-10-26T12:00:00Z  Page: welcome\n") -> SetupDiagnose.Facts {
        SetupDiagnose.Facts(version: "0.1 (1)", location: "~/Applications/Sunlight.app", system: "macOS 27.2 (Build 27C101)",
                            mac: .supported, status: halfway,
                            renderer: SetupDiagnose.rendererStatus(preferred: "realWindows", wantsLiveWindows: true, available: false,
                                                                   previewMode: true, reload: "no live-window helper in the bundle (make app)"),
                            helper: "Add-on: not installed\nIn the Dock: not answering\n",
                            inputs: SetupDiagnose.Inputs(record: SetupFlow.Record(welcomed: true, loginItemChosen: true, startedLive: true), consentedAt: nil,
                                                         opensAtLaunch: true, previewMode: true, preferredRenderer: "realWindows",
                                                         wantsLiveWindows: true),
                            journal: journal, date: Date(timeIntervalSince1970: 1_777_000_000))
    }

    func testTheReportHasEverySection() {
        let report = SetupDiagnose.report(facts())
        for heading in ["Sunlight diagnose report", "Sunlight 0.1 (1), in ~/Applications/Sunlight.app", "macOS 27.2 (Build 27C101), Apple silicon, an administrator",
                        "== Setup ==", "Setup: 4 steps left, starting with background helper.", "Progress: 2 of 6 steps", "Stage Manager: off",
                        "Wizard: welcomed, open at login chosen, live windows started, opens at launch", "Preview mode: on",
                        "== Renderer ==", "Sunlight live-window protocol v1: unavailable", "Effective renderer: capture",
                        "== Live-windows helper ==", "Add-on: not installed",
                        "== Setup journal (last 80 lines) ==", "Page: welcome"] {
            XCTAssertTrue(report.contains(heading), "missing: \(heading)\n\(report)")
        }
        XCTAssertTrue(report.hasSuffix("\n"))
    }

    func testTheSetupLinesMarkEachStep() {
        let lines = SetupDiagnose.setupLines(halfway)
        XCTAssertEqual(lines.count, 1 + SetupStatus.Step.allCases.count)
        XCTAssertTrue(lines[1].hasPrefix("  ✓ Accessibility"))
        XCTAssertTrue(lines[3].hasPrefix("  ○ Background helper"))
        XCTAssertTrue(lines[4].hasPrefix("  ○ System Integrity Protection"))
        XCTAssertTrue(lines[5].hasPrefix("  · Boot argument"), "waiting on SIP")
    }

    func testTheRendererLinesMatchTheCommandLine() {
        let text = SetupDiagnose.rendererStatus(preferred: "realWindows", wantsLiveWindows: true, available: true, previewMode: false,
                                                reload: "/Applications/Sunlight.app/Contents/Helpers/SunlightLiveWindows load, through the background helper, without a password")
        XCTAssertEqual(text.split(separator: "\n").map(String.init), [
            "Preferred renderer: realWindows",
            "Sunlight live-window protocol v1: available",
            "Effective renderer: realWindows",
            "Preview mode: off",
            "Reload after a Dock restart: /Applications/Sunlight.app/Contents/Helpers/SunlightLiveWindows load, through the background helper, without a password",
        ])
    }

    func testTheHomeFolderIsWrittenAsTilde() {
        XCTAssertEqual(SetupDiagnose.redactingHome("/Users/someone/Applications/Sunlight.app", home: "/Users/someone"), "~/Applications/Sunlight.app")
        XCTAssertEqual(SetupDiagnose.redactingHome("/Applications/Sunlight.app", home: "/Users/someone"), "/Applications/Sunlight.app")
        XCTAssertEqual(SetupDiagnose.redactingHome("/Applications/Sunlight.app", home: ""), "/Applications/Sunlight.app")
    }

    func testTheJournalTailIsBounded() {
        let long = (1...120).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = SetupDiagnose.journalTail(long)
        XCTAssertEqual(tail.split(separator: "\n").count, SetupDiagnose.journalLines)
        XCTAssertTrue(tail.hasPrefix("line 41\n"))
        XCTAssertTrue(tail.hasSuffix("line 120"))
        XCTAssertEqual(SetupDiagnose.journalTail(""), "(empty)")
        XCTAssertTrue(SetupDiagnose.report(facts(journal: "")).hasSuffix("(empty)\n"))
    }

    func testTheWizardSummarySaysWhatWasDone() {
        var inputs = facts().inputs
        inputs.record.skippedScreenRecording = true
        inputs.record.resume = .recovery
        inputs.consentedAt = Date(timeIntervalSince1970: 1_777_000_000)
        inputs.opensAtLaunch = false
        let summary = SetupDiagnose.wizardSummary(inputs)
        XCTAssertTrue(summary.contains("Screen Recording skipped"))
        XCTAssertTrue(summary.contains("SIP consent given "))
        XCTAssertTrue(summary.contains("resuming at recovery"))
        XCTAssertTrue(summary.hasSuffix("doesn't open at launch"))
    }
}

final class DiagnoseDesktopsTests: XCTestCase {
    func testDesktopCount() {
        let one = Spaces.Display(identifier: "A", spaces: [Spaces.Space(id: 1, kind: .user)], current: 1)
        let two = Spaces.Display(identifier: "B", spaces: [Spaces.Space(id: 2, kind: .user), Spaces.Space(id: 3, kind: .user), Spaces.Space(id: 4, kind: .fullScreen)], current: 2)
        XCTAssertEqual(SetupDiagnose.desktopsLine([one]), "1 on 1 display")
        XCTAssertEqual(SetupDiagnose.desktopsLine([one, one]), "1 on each of 2 displays")
        XCTAssertEqual(SetupDiagnose.desktopsLine([one, two]), "3 (1 + 2 on 2 displays), 1 full-screen app Space")
        XCTAssertEqual(SetupDiagnose.desktopsLine([]), "unknown (SkyLight didn't say)")
    }
}
