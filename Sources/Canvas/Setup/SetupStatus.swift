import AppKit
import ApplicationServices

/// What a Mac still needs before Sunlight works as intended. Two permissions, Accessibility and Screen
/// Recording, make a usable preview (windows as pictures; see `Settings.previewMode`). Live windows, the
/// real thing, take the helper's OK, System Integrity Protection partly off, a boot argument and the
/// add-on in the Dock. The setup window walks through it, Settings › Live Windows draws it, and
/// `--renderer-status` prints it.
struct SetupStatus: Equatable, Sendable {
    enum Helper: Equatable, Sendable {
        /// The launch daemon is on: reloads need nothing.
        case daemonEnabled
        /// Registered, waiting for the switch in Login Items.
        case daemonNeedsApproval
        /// This build has the daemon; it hasn't been registered yet.
        case daemonNotRegistered
        /// No daemon (ad-hoc build): sudoers lets the reload run without a password.
        case passwordless
        /// No daemon: the first reload asks for an administrator password, then sets up `sudo -n`.
        case asksForPassword
        /// No helper in the bundle at all.
        case missing
    }

    var accessibility: Bool
    var screenRecording: Bool
    /// Filesystem Protections and Debugging Restrictions off.
    var sipAllowsLiveWindows: Bool
    /// `-arm64e_preview_abi` in this boot's arguments.
    var bootArgument: Bool
    var helper: Helper
    /// The add-on in the Dock answers the live-window protocol.
    var liveWindowsLoaded: Bool

    /// In the order they're done: the preview's two permissions first, then live windows' steps, with
    /// the helper before the Recovery restart so nothing after it asks for anything.
    enum Step: String, CaseIterable, Sendable {
        case accessibility, screenRecording, helper, systemIntegrity, bootArgument, liveWindows
    }

    enum State: Equatable, Sendable {
        case done
        case todo
        /// Waiting on an earlier step.
        case waiting
    }

    /// One fix per step, which the setup window offers as its button.
    enum Fix: Equatable, Sendable {
        case allowAccessibility
        case showRecoverySteps
        case setBootArgument
        case approveHelper
        case loadLiveWindows
        case allowScreenRecording
    }

    struct Item: Equatable, Sendable {
        var step: Step
        var title: String
        var detail: String
        var state: State
        var fix: Fix?
        /// Live windows don't wait on it: Screen Recording covers the preview, widgets and the stills.
        var required: Bool
    }

    var items: [Item] {
        let sipNeeded = !sipAllowsLiveWindows
        let liveReady = sipAllowsLiveWindows && bootArgument
        return [
            Item(step: .accessibility, title: "Accessibility",
                 detail: accessibility
                    ? "Sunlight can move, raise and focus other apps' windows."
                    : "Lets Sunlight move, raise and focus other apps' windows. Turn Sunlight on in the list that opens.",
                 state: accessibility ? .done : .todo, fix: accessibility ? nil : .allowAccessibility, required: true),
            Item(step: .screenRecording, title: "Screen Recording",
                 detail: screenRecording
                    ? "Sunlight can show windows as pictures, and desktop widgets."
                    : "Shows your windows as pictures on the canvas until live windows are set up, and desktop widgets after. Turn Sunlight on in the list that opens, then open Sunlight again.",
                 state: screenRecording ? .done : .todo, fix: screenRecording ? nil : .allowScreenRecording, required: false),
            helperItem(liveReady: liveReady),
            Item(step: .systemIntegrity, title: "System Integrity Protection, partly off",
                 detail: sipNeeded
                    ? "Live windows run inside the Dock, which macOS only allows with two protections off. It takes a restart into Recovery and two lines in Terminal there."
                    : "Filesystem Protections and Debugging Restrictions are off, as live windows need.",
                 state: sipNeeded ? .todo : .done, fix: sipNeeded ? .showRecoverySteps : nil, required: true),
            Item(step: .bootArgument, title: "Boot argument",
                 detail: bootArgument
                    ? "The Mac started with -arm64e_preview_abi, so the add-on can load."
                    : sipNeeded
                        ? "Set in Recovery with the same steps, or here afterwards."
                        : "Lets the add-on load into the Dock. Sunlight sets it for you; it applies after a restart.",
                 state: bootArgument ? .done : sipNeeded ? .waiting : .todo,
                 fix: bootArgument || sipNeeded ? nil : .setBootArgument, required: true),
            Item(step: .liveWindows, title: "Live windows",
                 detail: liveWindowsLoaded
                    ? "The add-on is loaded in the Dock and answering."
                    : liveReady ? "Loads Sunlight's add-on into the Dock and switches the canvas to live windows."
                                : "Ready once the steps above are done.",
                 state: liveWindowsLoaded ? .done : liveReady && helperReady ? .todo : .waiting,
                 fix: !liveWindowsLoaded && liveReady && helperReady ? .loadLiveWindows : nil, required: true),
        ]
    }

    private var helperReady: Bool {
        switch helper {
        case .daemonEnabled, .passwordless, .asksForPassword: return true
        case .daemonNeedsApproval, .daemonNotRegistered, .missing: return false
        }
    }

    private func helperItem(liveReady: Bool) -> Item {
        let title = "Background helper"
        switch helper {
        case .daemonEnabled:
            return Item(step: .helper, title: title, detail: "Turned on, so live windows reload by themselves after the Dock restarts.",
                        state: .done, fix: nil, required: true)
        case .daemonNeedsApproval:
            return Item(step: .helper, title: title,
                        detail: "Turn on Sunlight in System Settings › General › Login Items, under Allow in the Background.",
                        state: .todo, fix: .approveHelper, required: true)
        case .daemonNotRegistered:
            return Item(step: .helper, title: title,
                        detail: "Loads live windows into the Dock after the restart, and reloads them whenever the Dock restarts, without asking for your password.",
                        state: .todo, fix: .approveHelper, required: true)
        case .passwordless:
            return Item(step: .helper, title: title, detail: "Reloads run without a password.", state: .done, fix: nil, required: true)
        case .asksForPassword:
            return Item(step: .helper, title: title,
                        detail: "This build asks for your administrator password the first time live windows load, then not again.",
                        state: .done, fix: nil, required: true)
        case .missing:
            return Item(step: .helper, title: title, detail: "This copy of Sunlight has no live-windows helper; build it with `make app`.",
                        state: .todo, fix: nil, required: true)
        }
    }

    /// The steps live windows still need, in order.
    var missing: [Item] { items.filter { $0.required && $0.state != .done } }

    /// Live windows are set up.
    var isComplete: Bool { missing.isEmpty }

    /// The preview works: both permissions granted. Live windows' steps don't count against it.
    var previewReady: Bool { accessibility && screenRecording }

    /// One line for Settings.
    var summary: String {
        guard let first = missing.first else {
            return screenRecording ? "Everything's set up." : "Live windows are set up. Screen Recording would add desktop widgets."
        }
        let count = missing.count
        return "\(count) step\(count == 1 ? "" : "s") left, starting with \(first.title.lowercased())."
    }

    // MARK: Reading the Mac

    /// The Mac as it is now. Several checks are round trips (launchd, the add-on's socket): off the main thread.
    static func current() -> SetupStatus {
        SetupStatus(accessibility: AXIsProcessTrusted(),
                    screenRecording: CGPreflightScreenCaptureAccess(),
                    sipAllowsLiveWindows: sipAllowsLiveWindows(),
                    bootArgument: bootArgumentActive(),
                    helper: currentHelper(),
                    liveWindowsLoaded: LiveWindowsConnection.probe())
    }

    static func currentHelper() -> Helper {
        guard AdditionReloader.helperPath != nil else { return .missing }
        switch LiveWindowsService.state {
        case .enabled: return .daemonEnabled
        case .needsApproval: return .daemonNeedsApproval
        case .notRegistered: return .daemonNotRegistered
        case .unavailable: return AdditionReloader.isPasswordless() ? .passwordless : .asksForPassword
        }
    }

    /// CSR_ALLOW_UNRESTRICTED_FS and CSR_ALLOW_TASK_FOR_PID, as the helper checks them.
    static func sipAllowsLiveWindows() -> Bool {
        typealias GetConfig = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_get_active_config") else { return false }
        var config: UInt32 = 0
        _ = unsafeBitCast(symbol, to: GetConfig.self)(&config)
        return config & 0x02 != 0 && config & 0x04 != 0
    }

    // MARK: The Mac

    /// The Dock add-on is arm64e, so live windows are Apple silicon only; the app is built for it alone.
    static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// macOS 15 or later, as the app's minimum says.
    static func isOSSupported() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    /// Whether the user is in the admin group: the SIP step and the helper's Login Items switch need one.
    static func isAdministrator() -> Bool {
        guard let group = getgrnam("admin") else { return false }
        if getgid() == group.pointee.gr_gid { return true }
        let user = NSUserName()
        var member = group.pointee.gr_mem
        while let name = member?.pointee {
            if String(cString: name) == user { return true }
            member = member?.successor()
        }
        return false
    }

    /// Whether the add-on could load into the Dock at all: SIP partly off and the boot argument active.
    /// Without both, a load attempt fails and only leaves an administrator prompt behind.
    static func liveWindowsPossible() -> Bool { sipAllowsLiveWindows() && bootArgumentActive() }

    static func bootArgumentActive() -> Bool {
        var size = 0
        guard sysctlbyname("kern.bootargs", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("kern.bootargs", &buffer, &size, nil, 0) == 0 else { return false }
        return String(cString: buffer).split(separator: " ").contains("-arm64e_preview_abi")
    }

    /// What to type in Recovery's Terminal: both protections and NVRAM's off, and the boot argument set,
    /// so one restart covers both. `nvram` here replaces any boot arguments already set.
    static let recoveryCommands = """
        csrutil enable --without fs --without debug --without nvram
        nvram boot-args=-arm64e_preview_abi
        """
}
