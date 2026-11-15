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
/// A shorter gap, over `hitch`, is a hitch: too short to read as a freeze, long enough to drop a dozen
/// frames of a flight. It gets a line in the log, named the same way, and nothing else.
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
    /// Work on the main thread this long is a hitch: in the log, not in Diagnose.
    nonisolated static let hitch: TimeInterval = 0.1
    /// A stall still going on this long is logged while it lasts.
    nonisolated static let stuck: TimeInterval = 3
    nonisolated static let checkInterval: TimeInterval = 0.5

    private struct State: Sendable {
        /// When the main run loop last took a step; 0 while it's asleep waiting for events.
        var lastStep: CFTimeInterval = 0
        /// What the main thread is in, when it's in a call that waits on another process.
        var label: String?
        /// The first such call since the last stall that took longer than `threshold`, for the stall it's
        /// part of; with the call it was made from in front, where that is named too (`path`).
        var slowLabel: String?
        /// The same for a call that took longer than `hitch`, for the hitch it's part of.
        var briefLabel: String?
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
            let took = take(activity, at: CACurrentMediaTime())
            // The setting is read only with something to say: this runs at every step of the main run loop.
            guard took != Step(), Watchdog.enabled else { return }
            if let stall = took.stall {
                Log.note("Stall: the main thread was busy for \(stall.ms) ms\(stall.label.map { " (in \($0))" } ?? "")")
                Stability.recordStall(ms: stall.ms, label: stall.label)
            } else if let hitch = took.hitch {
                Log.note("Hitch: the main thread was busy for \(hitch.ms) ms\(hitch.label.map { " (in \($0))" } ?? "")")
            }
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
        let before = shared.state.withLock { s in
            let before = (label: s.label, slow: s.slowLabel, brief: s.briefLabel)
            s.label = label
            return before
        }
        defer {
            let took = CACurrentMediaTime() - started
            shared.state.withLock { s in
                s.label = before.label
                // The first slow call of a step names it. A slow call inside this one has put its name
                // down meanwhile: this one's goes in front of it, so the line says where it was called from.
                if took > threshold, before.slow == nil { s.slowLabel = path(label, over: s.slowLabel) }
                if took > hitch, before.brief == nil { s.briefLabel = path(label, over: s.briefLabel) }
            }
        }
        return try body()
    }

    /// "taking a new window onto the canvas › Accessibility: a window's frame": a call and the slow call
    /// inside it.
    nonisolated static func path(_ outer: String, over inner: String?) -> String {
        inner.map { "\(outer) › \($0)" } ?? outer
    }

    /// What a step of the main run loop makes of the time since the last one: nil, or a stall.
    /// `beforeWaiting`: the loop goes to sleep, and the time until it wakes is no stall.
    struct Stall: Equatable, Sendable {
        var ms: Int
        var label: String?
    }

    nonisolated func step(_ activity: CFRunLoopActivity, at now: CFTimeInterval) -> Stall? {
        take(activity, at: now).stall
    }

    /// What a step found: a stall, a hitch (shorter: over `hitch`, not over `threshold`), or neither.
    struct Step: Equatable, Sendable {
        var stall: Stall?
        var hitch: Stall?
    }

    nonisolated func take(_ activity: CFRunLoopActivity, at now: CFTimeInterval) -> Step {
        state.withLock { s -> Step in
            var found = Step()
            if s.lastStep > 0 {
                let gap = now - s.lastStep
                let ms = Int((gap * 1000).rounded())
                if gap > Watchdog.threshold {
                    // Several calls under the threshold can add up to a stall: the first of them names it then.
                    found.stall = Stall(ms: ms, label: s.slowLabel ?? s.briefLabel)
                } else if gap > Watchdog.hitch {
                    found.hitch = Stall(ms: ms, label: s.briefLabel)
                }
            }
            if found.stall != nil || s.lastStep == 0 { s.slowLabel = nil }
            if found != Step() || s.lastStep == 0 { s.briefLabel = nil }
            s.lastStep = activity == .beforeWaiting ? 0 : now
            s.reportedStuck = false
            return found
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
