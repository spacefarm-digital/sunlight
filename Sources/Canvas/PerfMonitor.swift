import Darwin
import Foundation
import QuartzCore
import os

/// Frame timing, for tuning: on with `defaults write com.spacefarm.sunlight PerfLog -bool YES` (and off
/// again with NO), restart. Every display-link tick reports how long the frame's work on the main
/// thread took, how many input events it folded in, and whether frames were missed; the live-window
/// driver reports each frame's round trip to the Dock. A summary goes to the log every five seconds,
/// and to a line under the zoom readout, so a pan or a pinch can be read as numbers: frames per second
/// while it moved, p50 / p95 / max of the main-thread work, the Dock round trip, misses, the share of a
/// core the app used, and its footprint.
///
/// At rest too, where the frames say nothing: every ten minutes a line with the share of a core used
/// since the last one and the footprint, and a line whenever the footprint has moved by 50 MB, with
/// the app's windows as they are then (`census`), so a window left drawing off screen or holding
/// memory shows in the log the day it happens.
///
/// Off, every call is one branch; nothing is allocated or timed.
final class PerfMonitor: @unchecked Sendable {
    nonisolated static let shared = PerfMonitor()
    nonisolated static let defaultsKey = "PerfLog"
    nonisolated static let summaryInterval: TimeInterval = 5

    /// Read once at launch: the setting takes a restart.
    nonisolated let enabled = UserDefaults.standard.bool(forKey: PerfMonitor.defaultsKey)

    /// The summary line, on the main thread, every `summaryInterval` while anything was measured.
    @MainActor var onSummary: ((String) -> Void)?
    /// What the app has alive just now (its windows), for the line a jump in memory gets.
    @MainActor var census: (() -> String)?

    /// Frames per second while the canvas moves. Ticks come in runs (a pan, a flight) with nothing
    /// between them; counted over the whole five seconds, a one-second pan at 120 a second read as 24.
    /// Only the time between ticks of one run counts: ticks closer together than `gap`.
    struct Pace: Equatable, Sendable {
        static let gap: TimeInterval = 0.1
        private(set) var ticks = 0
        /// The time between ticks of the same run, and how many such intervals.
        private(set) var moving: TimeInterval = 0
        private(set) var intervals = 0
        private var last: TimeInterval = 0

        mutating func tick(at now: TimeInterval) {
            ticks += 1
            if last > 0, now > last, now - last < Pace.gap {
                moving += now - last
                intervals += 1
            }
            last = now
        }

        /// A new summary's worth: nothing counted, the last tick remembered (a run can span two).
        mutating func startOver() {
            ticks = 0
            moving = 0
            intervals = 0
        }

        var framesPerSecond: Double? { intervals > 0 && moving > 0 ? Double(intervals) / moving : nil }

        /// "118 fps over 2.3 s (271 ticks)"; a lone tick has no rate.
        var summary: String {
            guard let fps = framesPerSecond else { return "\(ticks) tick\(ticks == 1 ? "" : "s")" }
            return String(format: "%.0f fps over %.1f s (%d ticks)", fps, moving, ticks)
        }
    }

    private struct Window {
        var applies: [Double] = []      // ms
        var roundTrips: [Double] = []   // ms
        var fullTrips: [Double] = []    // ms, the full frames among them
        var coalesced = 0
        var missed = 0
        var pace = Pace()
    }
    private let state = OSAllocatedUnfairLock(initialState: Window())
    @MainActor private var timer: Timer?

    /// The app's processor time and the clock, at one moment: two of them give the share of a core used
    /// between.
    struct Usage: Equatable, Sendable {
        var cpu: TimeInterval
        var at: TimeInterval

        static func now() -> Usage { Usage(cpu: PerfMonitor.cpuSeconds(), at: CACurrentMediaTime()) }

        /// Percent of one core used from `earlier` to here; nil over no time at all.
        func share(since earlier: Usage) -> Double? {
            let elapsed = at - earlier.at
            guard elapsed > 0.001 else { return nil }
            return max(0, cpu - earlier.cpu) / elapsed * 100
        }
    }
    /// Where the processor time stood at the last summary (or when the summaries started again).
    @MainActor private var summaryUsage = Usage.now()
    /// And at the last ten-minute line.
    @MainActor private var restUsage = Usage.now()
    @MainActor private var restTimer: Timer?
    @MainActor private var restChecks = 0
    /// The footprint last put in the log by `noteMemory`, in bytes.
    @MainActor private var memoryNoted: UInt64 = 0

    nonisolated static let restCheckInterval: TimeInterval = 60
    /// A line every this many checks: ten minutes.
    nonisolated static let restChecksPerLine = 10
    nonisolated static let memoryStep: UInt64 = 50 * 1_048_576

    /// Once, at launch, on the main thread: the watch at rest (one wake a minute).
    @MainActor func start() {
        guard enabled, restTimer == nil else { return }
        restUsage = Usage.now()
        // No footprint noted yet: at launch it is a few MB, and the first minute's growth is no jump.
        let t = Timer(timeInterval: PerfMonitor.restCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restCheck() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        restTimer = t
    }

    @MainActor private func restCheck() {
        let footprint = PerfMonitor.footprint()
        noteMemory(footprint)
        restChecks += 1
        guard restChecks >= PerfMonitor.restChecksPerLine else { return }
        restChecks = 0
        let usage = Usage.now()
        defer { restUsage = usage }
        guard let share = usage.share(since: restUsage) else { return }
        Log.note(String(format: "Perf: last %.0f min · cpu %.1f%% · %.0f MB", (usage.at - restUsage.at) / 60, share,
                        Double(footprint) / 1_048_576))
    }

    /// Whether the footprint has moved far enough from the one last noted to say so, and the line.
    nonisolated static func memoryLine(from noted: UInt64, to now: UInt64, census: String?) -> String? {
        guard noted > 0, now > 0 else { return nil }
        let moved = now > noted ? now - noted : noted - now
        guard moved >= memoryStep else { return nil }
        let mb = { (bytes: UInt64) in Int((Double(bytes) / 1_048_576).rounded()) }
        let line = "Memory: \(mb(noted)) → \(mb(now)) MB (\(now > noted ? "+" : "−")\(mb(moved)))"
        return census.map { line + " · " + $0 } ?? line
    }

    @MainActor private func noteMemory(_ footprint: UInt64) {
        guard memoryNoted > 0 else { memoryNoted = footprint; return }
        guard let line = PerfMonitor.memoryLine(from: memoryNoted, to: footprint, census: census?()) else { return }
        memoryNoted = footprint
        Log.note(line)
    }

    /// One display-link tick: `apply` seconds of work on main, `coalesced` input events folded into
    /// it, `missed` frames since the previous tick.
    nonisolated func tick(apply: CFTimeInterval, coalesced: Int, missed: Int) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        state.withLock { w in
            w.applies.append(apply * 1000)
            w.coalesced += coalesced
            w.missed += missed
            w.pace.tick(at: now)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.armTimer() } }
    }

    /// One live-window frame: from handing it to the socket to the Dock's acknowledgement. Any thread.
    /// A frame the Dock acknowledged, and whether it was a full one (level and stacking for every
    /// window, under the update freeze) rather than a partial one (transforms only).
    nonisolated func dockRoundTrip(_ seconds: CFTimeInterval, full: Bool = false) {
        guard enabled else { return }
        state.withLock {
            $0.roundTrips.append(seconds * 1000)
            if full { $0.fullTrips.append(seconds * 1000) }
        }
    }

    @MainActor private func armTimer() {
        guard timer == nil else { return }
        // The summaries start again: the processor time from here, not from before the pause.
        summaryUsage = Usage.now()
        let t = Timer(timeInterval: PerfMonitor.summaryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.summarise() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor private func summarise() {
        let w = state.withLock { (w: inout Window) -> Window in
            let copy = w
            w = Window()
            w.pace = copy.pace
            w.pace.startOver()
            return copy
        }
        guard w.pace.ticks > 0 || !w.roundTrips.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        var parts: [String] = []
        if w.pace.ticks > 0 {
            parts.append(w.pace.summary)
            parts.append("main " + PerfMonitor.describe(w.applies))
            parts.append("\(w.coalesced) events, \(w.missed) missed")
        }
        if !w.roundTrips.isEmpty { parts.append("dock " + PerfMonitor.describe(w.roundTrips) + " ×\(w.roundTrips.count)" + PerfMonitor.describe(full: w.fullTrips)) }
        let usage = Usage.now()
        if let share = usage.share(since: summaryUsage) { parts.append(String(format: "cpu %.0f%%", share)) }
        summaryUsage = usage
        let footprint = PerfMonitor.footprint()
        parts.append(String(format: "%.0f MB", Double(footprint) / 1_048_576))
        let line = parts.joined(separator: " · ")
        Log.note("Perf: " + line)
        onSummary?(line)
        noteMemory(footprint)
    }

    /// ", 3 full max 9.20 ms" after the Dock's frames, when some of them were full ones; nothing when none.
    nonisolated static func describe(full samples: [Double]) -> String {
        guard let slowest = samples.max() else { return "" }
        return ", \(samples.count) full max " + String(format: "%.2f ms", slowest)
    }

    /// "p50 0.4 / p95 1.2 / max 3.0 ms".
    nonisolated static func describe(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "–" }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return String(format: "p50 %.2f / p95 %.2f / max %.2f ms", at(0.5), at(0.95), sorted[sorted.count - 1])
    }

    /// The processor time the app has used since launch, all threads, user and system.
    nonisolated static func cpuSeconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let seconds = { (t: timeval) in TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The app's physical footprint, as Activity Monitor's Memory column has it.
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
