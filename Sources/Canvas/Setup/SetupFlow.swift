import Foundation

/// Which page of Set Up Sunlight shows for a Mac's state, the rail of steps beside it, and the progress
/// the menu bar's rays draw. Pure, so every situation is testable without a Mac: the wizard feeds it
/// `SetupStatus.current()`, what the person has done so far (`Record`, kept by `SetupRecord`) and the
/// facts about the Mac that no step can change (`Mac`).
///
/// Two phases. The preview: Welcome, Accessibility, Screen Recording, the basics (`Tutorial`), then the
/// canvas opens with windows as pictures. Live windows, the real thing: why SIP goes partly off, the background helper, the
/// Recovery restart, a check on the way back, the load, and a tour. The helper comes before the restart
/// on purpose: its one switch in Login Items doesn't need SIP off, and with it on, nothing after the
/// restart asks for a password or a trip to System Settings, so the load runs by itself.
enum SetupFlow {
    enum Page: String, CaseIterable, Sendable {
        case welcome, loginItem, accessibility, screenRecording, basics, preview
        case consent, helper, recovery, welcomeBack, load, tour

        /// The live-windows phase.
        var isLive: Bool {
            switch self {
            case .welcome, .loginItem, .accessibility, .screenRecording, .basics, .preview: return false
            case .consent, .helper, .recovery, .welcomeBack, .load, .tour: return true
            }
        }
    }

    /// What no step can change, read once at launch.
    struct Mac: Equatable, Sendable {
        var appleSilicon: Bool
        /// macOS 15 or later.
        var osSupported: Bool
        /// An administrator account: the SIP step and the helper's approval need one.
        var admin: Bool

        /// Live windows need the arm64e boot argument and the Dock add-on, which is Apple silicon only.
        var liveWindowsSupported: Bool { appleSilicon && osSupported }

        static let supported = Mac(appleSilicon: true, osSupported: true, admin: true)

        static func current() -> Mac {
            Mac(appleSilicon: SetupStatus.isAppleSilicon(), osSupported: SetupStatus.isOSSupported(),
                admin: SetupStatus.isAdministrator())
        }
    }

    /// What the person has done in the wizard that the Mac itself doesn't record.
    struct Record: Equatable, Sendable {
        /// Get Started was pressed: the Welcome page isn't shown again.
        var welcomed = false
        /// Open at login was answered, on its own page after the welcome.
        var loginItemChosen = false
        /// The tutorial was finished or skipped.
        var learnedBasics = false
        /// The SIP consent was given.
        var consented = false
        /// "Skip for now" on Screen Recording: the preview goes on without it.
        var skippedScreenRecording = false
        /// The live-windows phase was started (from the demo mode card, or the preview page).
        var startedLive = false
        /// The page the wizard sent the person away from: a relaunch for Screen Recording, or the
        /// Recovery restart. Routing comes back there first.
        var resume: Page?

        static let fresh = Record()
    }

    // MARK: The page

    static func page(for status: SetupStatus, record: Record, mac: Mac) -> Page {
        // Back from a relaunch or a restart the wizard itself asked for.
        switch record.resume {
        case .screenRecording?:
            if !status.screenRecording { return .screenRecording }
        case .recovery?:
            if !status.sipAllowsLiveWindows || !status.bootArgument { return .welcomeBack }
        default:
            break
        }
        if !record.welcomed { return .welcome }
        if !record.loginItemChosen { return .loginItem }
        if !status.accessibility { return .accessibility }
        if !status.screenRecording && !record.skippedScreenRecording { return .screenRecording }
        // Once, before the canvas first opens; a Mac with live windows on has long found its way around.
        if !record.learnedBasics && !status.liveWindowsLoaded { return .basics }
        if !record.startedLive || !mac.liveWindowsSupported { return .preview }
        if !status.sipAllowsLiveWindows, !record.consented { return .consent }
        // The helper before the restart: a build with no helper at all stops here rather than in Recovery.
        switch status.helper {
        case .daemonNeedsApproval, .daemonNotRegistered, .missing: return .helper
        case .daemonEnabled, .passwordless, .asksForPassword: break
        }
        if !status.sipAllowsLiveWindows { return .recovery }
        if !status.bootArgument { return .welcomeBack }
        if !status.liveWindowsLoaded { return .load }
        return .tour
    }

    /// The step that just got done between two checks, among the ones the wizard sends the person to
    /// System Settings (or an administrator prompt) for, named for the journal: the cue for the wizard
    /// to come back in front by itself, since there's no Dock icon to click back to. Nil otherwise.
    static func stepFinished(from old: SetupStatus, to new: SetupStatus) -> String? {
        if !old.accessibility, new.accessibility { return "Accessibility" }
        if !old.screenRecording, new.screenRecording { return "Screen Recording" }
        if old.helper != .daemonEnabled, new.helper == .daemonEnabled { return "the background helper" }
        if !old.liveWindowsLoaded, new.liveWindowsLoaded { return "loading live windows" }
        return nil
    }

    /// Whether the load page starts the load the moment it opens, with nothing to click: when the
    /// daemon is on, so loading can't ask for anything. A build without it waits for the button, since
    /// the load the wizard asks for goes through the administrator prompt (even where sudoers would let
    /// a quiet one through), and that prompt shouldn't appear unbidden.
    static func loadsByItself(_ status: SetupStatus) -> Bool {
        status.helper == .daemonEnabled
    }

    /// Whether the wizard opens by itself at launch. Always to finish what it sent the person away
    /// for. In preview mode (live windows have never loaded here), only while the preview isn't ready:
    /// the two permissions, a first Welcome, or the tutorial not yet seen. Past preview mode, as the checkbox says: while a
    /// live-windows step is missing, unless that was turned off. Not for the add-on alone when the canvas
    /// reloads it by itself: quitting puts the Mac's Dock settings back and restarts the Dock, which unloads
    /// it, so it's missing at nearly every launch for a moment (public issue #10).
    static func opensAtLaunch(status: SetupStatus, record: Record, mac: Mac, previewMode: Bool, showsAtLaunch: Bool,
                              quietReloadPaused: Bool = false) -> Bool {
        if record.resume != nil { return true }
        if previewMode {
            return !record.welcomed || !record.loginItemChosen || !status.accessibility || !status.screenRecording && !record.skippedScreenRecording
                || !record.learnedBasics
        }
        if onlyTheAddOnIsMissing(status), reloadsQuietly(status), !quietReloadPaused { return false }
        return showsAtLaunch && !status.isComplete
    }

    /// Every step is done but the add-on answering in the Dock.
    static func onlyTheAddOnIsMissing(_ status: SetupStatus) -> Bool {
        status.missing.map(\.step) == [.liveWindows]
    }

    /// The canvas's own reload (`CanvasController.reloadAddition`) needs nothing from the person.
    static func reloadsQuietly(_ status: SetupStatus) -> Bool {
        status.helper == .daemonEnabled || status.helper == .passwordless
    }

    // MARK: The rail

    struct RailEntry: Equatable, Sendable {
        enum State: Equatable, Sendable { case done, current, todo }
        var title: String
        var pages: [Page]
        var state: State
    }

    /// The rail beside the page: the preview's five steps, then live windows as one folded entry until
    /// that phase is started, and its own steps once it is. A build without the daemon (ad-hoc signed)
    /// has no helper step to show.
    static func rail(for status: SetupStatus, record: Record, mac: Mac, showing page: Page) -> [RailEntry] {
        func entry(_ title: String, _ pages: [Page], done: Bool) -> RailEntry {
            RailEntry(title: title, pages: pages, state: pages.contains(page) ? .current : done ? .done : .todo)
        }
        var rail = [
            entry("Welcome", [.welcome, .loginItem], done: record.welcomed && record.loginItemChosen),
            entry("Accessibility", [.accessibility], done: status.accessibility),
            entry("Screen Recording", [.screenRecording], done: status.screenRecording),
            entry("The basics", [.basics], done: record.learnedBasics || status.liveWindowsLoaded),
            entry("Preview", [.preview], done: page.isLive || status.liveWindowsLoaded),
        ]
        guard mac.liveWindowsSupported else { return rail }
        guard record.startedLive || page.isLive else {
            rail.append(entry("Live windows", [], done: status.isComplete))
            return rail
        }
        rail.append(entry("Why SIP goes partly off", [.consent], done: record.consented || status.sipAllowsLiveWindows))
        switch status.helper {
        case .passwordless, .asksForPassword: break
        case .daemonEnabled, .daemonNeedsApproval, .daemonNotRegistered, .missing:
            rail.append(entry("Background helper", [.helper], done: status.helper == .daemonEnabled))
        }
        rail.append(entry("Recovery restart", [.recovery, .welcomeBack], done: status.sipAllowsLiveWindows && status.bootArgument))
        rail.append(entry("Load live windows", [.load], done: status.liveWindowsLoaded))
        rail.append(entry("Tour", [.tour], done: false))
        return rail
    }

    // MARK: Progress

    /// Steps done out of the steps this Mac has: the two permissions, and on a Mac that can have live
    /// windows, the helper (an ad-hoc build's password path counts as done), SIP, the boot argument and
    /// the load.
    static func progress(for status: SetupStatus, mac: Mac) -> (done: Int, total: Int) {
        var steps = [status.accessibility, status.screenRecording]
        if mac.liveWindowsSupported {
            let helperDone: Bool = switch status.helper {
            case .daemonEnabled, .passwordless, .asksForPassword: true
            case .daemonNeedsApproval, .daemonNotRegistered, .missing: false
            }
            steps += [helperDone, status.sipAllowsLiveWindows, status.bootArgument, status.liveWindowsLoaded]
        }
        return (steps.filter { $0 }.count, steps.count)
    }

    static let rays = 8

    /// How many of the menu bar icon's eight rays are lit, or nil once everything is done and the icon
    /// goes back to normal.
    static func litRays(for status: SetupStatus, mac: Mac) -> Int? {
        let (done, total) = progress(for: status, mac: mac)
        guard done < total else { return nil }
        return Int((Double(done) / Double(total) * Double(rays)).rounded())
    }
}
