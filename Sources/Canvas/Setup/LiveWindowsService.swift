import AppKit
import ServiceManagement

/// What the app may ask the live-windows daemon for; LiveWindows/helper.m declares the same protocol.
@objc(SunlightLiveWindowsXPC) protocol LiveWindowsXPC {
    func runCommand(_ command: String, reply: @escaping (Int32, String) -> Void)
}

/// The live-windows helper as a launch daemon (Contents/Library/LaunchDaemons), registered with
/// SMAppService. Once the user turns it on in System Settings › General › Login Items, the app reaches
/// root through it without a password and without a sudoers rule. `scripts/package.sh` only puts the
/// daemon's plist in builds signed with a team identity, since launchd won't run an ad-hoc daemon and the
/// daemon checks callers against its own team: ad-hoc builds report `.unavailable` and fall back to
/// `sudo` and the administrator prompt.
///
/// Every call here is a round trip to launchd or the daemon: call them off the main thread.
enum LiveWindowsService {
    enum State: Equatable, Sendable {
        /// No daemon in this build (ad-hoc signed, or running outside a bundle).
        case unavailable
        case notRegistered
        /// Registered; the user still has to turn it on in Login Items.
        case needsApproval
        case enabled
    }

    static let plistName = "com.spacefarm.sunlight.live-windows.plist"
    static let machService = "com.spacefarm.sunlight.live-windows"

    private static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    static func state(of status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    static var state: State {
        guard Bundle.main.bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)").path) else { return .unavailable }
        return state(of: service.status)
    }

    /// Registers the daemon, and opens Login Items when it's waiting for the user's approval there.
    @discardableResult
    static func register() -> State {
        let current = state
        guard current == .notRegistered || current == .needsApproval else { return current }
        do {
            try service.register()
        } catch {
            // Registering an already-registered daemon that awaits approval throws; the status says more.
            Log.note("Live windows: daemon register — \(error.localizedDescription)")
        }
        let after = state
        Log.note("Live windows: daemon \(after)")
        if after == .needsApproval {
            DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
        }
        return after
    }

    static func unregister() {
        guard state == .enabled || state == .needsApproval else { return }
        do { try service.unregister() } catch {
            Log.note("Live windows: daemon unregister failed — \(error.localizedDescription)")
        }
    }

    /// Runs `load` or `bootarg` in the daemon and waits for it; the same status and output as running the
    /// helper with sudo. Status -1 when the daemon couldn't be reached.
    static func run(_ command: String, timeout: TimeInterval = 45) -> (status: Int32, output: String) {
        let connection = NSXPCConnection(machServiceName: machService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LiveWindowsXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.set(-1, "couldn't reach the live-windows daemon: \(error.localizedDescription)")
            done.signal()
        } as? LiveWindowsXPC
        guard let proxy else { return (-1, "the live-windows daemon has no interface") }
        proxy.runCommand(command) { status, output in
            box.set(status, output)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return (-1, "the live-windows daemon didn't answer") }
        return box.value
    }

    /// Runs a helper command as root: through the daemon when it's on, otherwise through the system's
    /// administrator prompt (the helper itself, with `with administrator privileges`).
    static func runPrivileged(_ command: String, prompt: String) -> (status: Int32, output: String) {
        if state == .enabled { return run(command) }
        return runWithAdministratorPrompt(command, prompt: prompt)
    }

    /// Runs a helper command as root through the system's administrator prompt, whatever the daemon's
    /// state: for `unload`, which the daemon doesn't run. The output says "(-128)" when the prompt was
    /// cancelled.
    static func runWithAdministratorPrompt(_ command: String, prompt: String) -> (status: Int32, output: String) {
        guard let helper = AdditionReloader.helperPath else { return (-1, "no live-window helper in the app bundle") }
        let shell = AdditionReloader.shellQuoted(helper) + " " + command
        let script = "do shell script \(AdditionReloader.appleScriptString(shell)) with prompt \(AdditionReloader.appleScriptString(prompt)) with administrator privileges"
        return AdditionReloader.run("/usr/bin/osascript", ["-e", script])
    }

    /// The XPC reply arrives on another queue than the one waiting for it.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: (Int32, String)?
        func set(_ status: Int32, _ output: String) {
            lock.lock(); defer { lock.unlock() }
            if result == nil { result = (status, output) }
        }
        var value: (status: Int32, output: String) {
            lock.lock(); defer { lock.unlock() }
            return result ?? (-1, "no reply")
        }
    }
}
