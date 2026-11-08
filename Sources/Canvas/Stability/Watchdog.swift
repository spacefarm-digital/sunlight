import Foundation
import QuartzCore
import os

/// Notices when the main thread stops answering. An observer on the main run loop notes the time at
/// every step of the loop (timers, sources, the main queue, going to sleep, waking); a gap between two
/// steps longer than `threshold` is one piece of work that held the main thread that long, and is
/// logged and kept with its length. Time asleep, waiting for events, isn't counted. When the work was
/// inside one of the calls known to wait on another process (`during`: a handoff waiting on the Dock,
/// an Accessibility call to a busy app, a socket command), the stall names it. The last stalls are kept
/// across launches (`Stability.recordStall`) for Diagnose.
///
/// A thread of its own looks every half second for a stall still going on, so a hang that never ends
/// (and so is never measured) is in the log too, once, after `stuck`.
///
/// On by default; `defaults write com.spacefarm.sunlight StallWatch -bool NO` turns it off without a
/// restart.
final class Watchdog: @unchecked Sendable {
    nonisolated static let shared = Watchdog()
    nonisolated static let defaultsKey = "StallWatch"
    nonisolated static let threshold: TimeInterval = 0.5
    /// A stall still going on this long is logged while it lasts.
    nonisolated static let stuck: TimeInterval = 3
    nonisolated static let checkInterval: TimeInterval = 0.5

    private struct State: Sendable {
        /// When the main run loop last took a step; 0 while it's asleep waiting for events.
        var lastStep: CFTimeInterval = 0
        /// What the main thread is in, when it's in a call that waits on another process.
        var label: String?
        /// The last such call that took longer than `threshold`, for the stall it's part of.
        var slowLabel: String?
        var reportedStuck = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observer: CFRunLoopObserver?
    private var thread: Thread?

    nonisolated static var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Once, at launch, on the main thread.
    func start() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.allActivities.rawValue, true, 0) { [self] _, activity in
            guard let stall = step(activity, at: CACurrentMediaTime()), Watchdog.enabled else { return }
            Log.note("Stall: the main thread was busy for \(stall.ms) ms\(stall.label.map { " (in \($0))" } ?? "")")
            Stability.recordStall(ms: stall.ms, label: stall.label)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let thread = Thread { [self] in watch() }
        thread.name = "Sunlight watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    /// Runs `body`, noting that the main thread is in `label` while it does, so a stall it causes is
    /// named. Off the main thread it only runs `body`.
    @discardableResult
    nonisolated static func during<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard Thread.isMainThread else { return try body() }
        let started = CACurrentMediaTime()
        let previous = shared.state.withLock { s in
            let previous = s.label
            s.label = label
            return previous
        }
        defer {
            let slow = CACurrentMediaTime() - started > threshold
            shared.state.withLock { s in
                s.label = previous
                if slow, s.slowLabel == nil { s.slowLabel = label }
            }
        }
        return try body()
    }

    /// What a step of the main run loop makes of the time since the last one: nil, or a stall.
    /// `beforeWaiting`: the loop goes to sleep, and the time until it wakes is no stall.
    struct Stall: Equatable, Sendable {
        var ms: Int
        var label: String?
    }

    nonisolated func step(_ activity: CFRunLoopActivity, at now: CFTimeInterval) -> Stall? {
        state.withLock { s -> Stall? in
            var stall: Stall?
            if s.lastStep > 0, now - s.lastStep > Watchdog.threshold {
                stall = Stall(ms: Int(((now - s.lastStep) * 1000).rounded()), label: s.slowLabel)
            }
            if stall != nil || s.lastStep == 0 { s.slowLabel = nil }
            s.lastStep = activity == .beforeWaiting ? 0 : now
            s.reportedStuck = false
            return stall
        }
    }

    /// The watching thread: a stall still going on, logged once while it lasts.
    private nonisolated func watch() {
        while true {
            Thread.sleep(forTimeInterval: Watchdog.checkInterval)
            let now = CACurrentMediaTime()
            let stuck = state.withLock { s -> (ms: Int, label: String?)? in
                guard s.lastStep > 0, !s.reportedStuck, now - s.lastStep > Watchdog.stuck else { return nil }
                s.reportedStuck = true
                return (Int(((now - s.lastStep) * 1000).rounded()), s.label)
            }
            guard let stuck, Watchdog.enabled else { continue }
            Log.note("Stall: the main thread has been busy for \(stuck.ms) ms so far\(stuck.label.map { ", in \($0)" } ?? "")")
        }
    }
}
