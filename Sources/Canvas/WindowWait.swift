import Foundation

/// The clock on a wait for an app's window (`CanvasController.waitForWindow`): four looks a second at
/// first, one a second after 10 s, none after a minute.
///
/// The clock is the wait's, not the attempt's. A window the app names that can't go on the canvas (an
/// overlay, a panel) ends each attempt and starts the wait again a moment later; with the clock started
/// afresh each time the wait never slowed and never ended (four looks a second for six minutes, in the
/// log). So a wait for the same app taken up again within `gap` of its last look carries on from where
/// it was.
struct WindowWait: Equatable {
    /// How long after its last look a wait for the same app still counts as the same wait.
    static let gap: TimeInterval = 5
    static let quickFor: TimeInterval = 10
    static let giveUpAfter: TimeInterval = 60

    private(set) var pid: pid_t = 0
    private var since: TimeInterval = 0
    private var touched: TimeInterval = 0

    /// A wait for `pid` starts or carries on. True if it is a new one, its clock starting now.
    mutating func begin(pid: pid_t, now: TimeInterval) -> Bool {
        defer { touched = now }
        if self.pid == pid, pid != 0, now - touched < Self.gap { return false }
        self.pid = pid
        since = now
        return true
    }

    /// How long until the next look, or nil once the wait has run its minute.
    mutating func nextLook(now: TimeInterval) -> TimeInterval? {
        touched = now
        let waited = now - since
        guard waited < Self.giveUpAfter else { return nil }
        return waited < Self.quickFor ? 0.25 : 1
    }

    /// The wait is over (the window came, or the user moved on): the next one starts its own clock.
    mutating func end() {
        self = WindowWait()
    }

    /// Over for `pid`, if the clock is still its own.
    mutating func end(for pid: pid_t) {
        if self.pid == pid { end() }
    }
}
