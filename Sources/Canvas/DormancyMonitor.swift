import AppKit

/// Whether anything on the screen can be seen at all. The screen locked or asleep, the screen saver
/// up, the Mac going to sleep, or the login session switched to someone else: while any of these
/// holds there is nobody to show frames to, so the canvas stops capturing and polling. The app stays
/// "active" through most of them, which is why `NSApp.isActive` isn't enough to tell.
@MainActor
final class DormancyMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var asleep = false

    private enum Flag: Sendable {
        case screenLocked, screenSaver, screensAsleep, systemAsleep, sessionInactive
    }
    private var flags: Set<Flag> = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        // The lock has no public notification; this pair is what loginwindow posts (not in any header,
        // so each one logs when it fires).
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked", .screenLocked, on: true)
        observe(distributed, "com.apple.screenIsUnlocked", .screenLocked, on: false)
        observe(distributed, "com.apple.screensaver.didstart", .screenSaver, on: true)
        observe(distributed, "com.apple.screensaver.didstop", .screenSaver, on: false)
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue, .screensAsleep, on: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue, .screensAsleep, on: false)
        observe(workspace, NSWorkspace.willSleepNotification.rawValue, .systemAsleep, on: true)
        observe(workspace, NSWorkspace.didWakeNotification.rawValue, .systemAsleep, on: false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue, .sessionInactive, on: true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue, .sessionInactive, on: false)
        // Notifications only tell about changes; an app launched at login, or while the screen is
        // already locked, has to ask. The session dictionary carries the lock state.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            flags.insert(.screenLocked)
            asleep = true
            Log.note("Dormancy: the screen is locked at launch — asleep")
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ flag: Flag, on: Bool) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(flag, on: on, reason: name) }
        }
        tokens.append((center, token))
    }

    private func apply(_ flag: Flag, on: Bool, reason: String) {
        if on { flags.insert(flag) } else { flags.remove(flag) }
        let now = !flags.isEmpty
        Log.note("Dormancy: \(reason) — \(now ? "asleep" : "awake")")
        guard now != asleep else { return }
        asleep = now
        onChange?(now)
    }
}
