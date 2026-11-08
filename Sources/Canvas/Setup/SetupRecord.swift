import Foundation

/// What the person has done in Set Up Sunlight that the Mac itself doesn't record, in UserDefaults: see
/// `SetupFlow.Record`. The resume page carries the wizard across the relaunch Screen Recording needs
/// and the restart Recovery needs; it's read once at launch and expires after a day, so a setup
/// abandoned in Recovery doesn't bounce the wizard to "Welcome back" a week later.
@MainActor
enum SetupRecord {
    private static let welcomedKey = "SetupWelcomed"
    private static let loginItemChosenKey = "SetupLoginItemChosen"
    private static let learnedBasicsKey = "SetupLearnedBasics"
    private static let consentedKey = "SetupConsentedAt"
    private static let skippedScreenRecordingKey = "SetupSkippedScreenRecording"
    private static let startedLiveKey = "SetupStartedLive"
    private static let resumePageKey = "SetupResumePage"
    private static let resumeAtKey = "SetupResumeAt"
    static let resumeLifetime: TimeInterval = 24 * 60 * 60

    private static var defaults: UserDefaults { .standard }

    static var welcomed: Bool {
        get { defaults.bool(forKey: welcomedKey) }
        set { defaults.set(newValue, forKey: welcomedKey) }
    }

    /// Open at login answered. A Mac welcomed before it had a page of its own answered it on the
    /// welcome, so with nothing stored it follows `welcomed`; Get Started stores false.
    static var loginItemChosen: Bool {
        get { loginItemChosen(stored: defaults.object(forKey: loginItemChosenKey) as? Bool, welcomed: welcomed) }
        set { defaults.set(newValue, forKey: loginItemChosenKey) }
    }

    nonisolated static func loginItemChosen(stored: Bool?, welcomed: Bool) -> Bool { stored ?? welcomed }

    /// The tutorial finished or skipped.
    static var learnedBasics: Bool {
        get { defaults.bool(forKey: learnedBasicsKey) }
        set { defaults.set(newValue, forKey: learnedBasicsKey) }
    }

    static var consentedAt: Date? {
        get { defaults.object(forKey: consentedKey) as? Date }
        set { defaults.set(newValue, forKey: consentedKey) }
    }

    static var skippedScreenRecording: Bool {
        get { defaults.bool(forKey: skippedScreenRecordingKey) }
        set { defaults.set(newValue, forKey: skippedScreenRecordingKey) }
    }

    static var startedLive: Bool {
        get { defaults.bool(forKey: startedLiveKey) }
        set { defaults.set(newValue, forKey: startedLiveKey) }
    }

    /// Where to come back to after the relaunch or restart about to happen.
    static func setResume(_ page: SetupFlow.Page) {
        defaults.set(page.rawValue, forKey: resumePageKey)
        defaults.set(Date(), forKey: resumeAtKey)
        SetupJournal.note("Leaving for \(page.rawValue); the wizard resumes there")
    }

    /// The stored resume page, cleared on reading, and only if it's less than a day old.
    static func takeResume() -> SetupFlow.Page? {
        defer {
            defaults.removeObject(forKey: resumePageKey)
            defaults.removeObject(forKey: resumeAtKey)
        }
        guard let raw = defaults.string(forKey: resumePageKey), let page = SetupFlow.Page(rawValue: raw),
              let at = defaults.object(forKey: resumeAtKey) as? Date, Date().timeIntervalSince(at) < resumeLifetime else { return nil }
        return page
    }

    /// The record as stored, without a resume page: the wizard adds the one it took at launch.
    static var current: SetupFlow.Record {
        SetupFlow.Record(welcomed: welcomed, loginItemChosen: loginItemChosen, learnedBasics: learnedBasics, consented: consentedAt != nil, skippedScreenRecording: skippedScreenRecording,
                         startedLive: startedLive, resume: nil)
    }
}

/// A plain-text log of what setup did and when: consent, each step, the helper's answers. Read by the
/// Diagnose report. ~/Library/Application Support/Sunlight/setup.log, one line per entry.
enum SetupJournal {
    nonisolated static var url: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Sunlight", isDirectory: true).appendingPathComponent("setup.log")
    }

    nonisolated static func note(_ line: String) {
        Log.note("Setup: \(line)")
        guard let url else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(line)\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            Log.note("Setup: couldn't write the journal — \(error.localizedDescription)")
        }
    }

    nonisolated static func read() -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
