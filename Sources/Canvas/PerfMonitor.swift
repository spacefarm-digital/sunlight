import Darwin
import Foundation
import QuartzCore
import os

/// Frame timing, for tuning: on with `defaults write com.spacefarm.sunlight PerfLog -bool YES` (and off
/// again with NO), restart. Every display-link tick reports how long the frame's work on the main
/// thread took, how many input events it folded in, and whether frames were missed; the live-window
/// driver reports each frame's round trip to the Dock. A summary goes to the log every five seconds,
/// and to a line under the zoom readout, so a pan or a pinch can be read as numbers: ticks per second,
/// p50 / p95 / max of the main-thread work, the Dock round trip, misses, and the app's footprint.
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

    private struct Window {
        var applies: [Double] = []      // ms
        var roundTrips: [Double] = []   // ms
        var coalesced = 0
        var missed = 0
        var ticks = 0
        var since = CACurrentMediaTime()
    }
    private let state = OSAllocatedUnfairLock(initialState: Window())
    @MainActor private var timer: Timer?

    /// One display-link tick: `apply` seconds of work on main, `coalesced` input events folded into
    /// it, `missed` frames since the previous tick.
    nonisolated func tick(apply: CFTimeInterval, coalesced: Int, missed: Int) {
        guard enabled else { return }
        state.withLock { w in
            w.applies.append(apply * 1000)
            w.coalesced += coalesced
            w.missed += missed
            w.ticks += 1
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.armTimer() } }
    }

    /// One live-window frame: from handing it to the socket to the Dock's acknowledgement. Any thread.
    nonisolated func dockRoundTrip(_ seconds: CFTimeInterval) {
        guard enabled else { return }
        state.withLock { $0.roundTrips.append(seconds * 1000) }
    }

    @MainActor private func armTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: PerfMonitor.summaryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.summarise() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @MainActor private func summarise() {
        let now = CACurrentMediaTime()
        let w = state.withLock { (w: inout Window) -> Window in
            let copy = w
            w = Window()
            w.since = now
            return copy
        }
        guard w.ticks > 0 || !w.roundTrips.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        let seconds = max(0.001, now - w.since)
        var parts: [String] = []
        if w.ticks > 0 {
            parts.append(String(format: "%.0f ticks/s", Double(w.ticks) / seconds))
            parts.append("main " + PerfMonitor.describe(w.applies))
            parts.append("\(w.coalesced) events, \(w.missed) missed")
        }
        if !w.roundTrips.isEmpty { parts.append("dock " + PerfMonitor.describe(w.roundTrips) + " ×\(w.roundTrips.count)") }
        parts.append(String(format: "%.0f MB", Double(PerfMonitor.footprint()) / 1_048_576))
        let line = parts.joined(separator: " · ")
        Log.note("Perf: " + line)
        onSummary?(line)
    }

    /// "p50 0.4 / p95 1.2 / max 3.0 ms".
    nonisolated static func describe(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "–" }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
        return String(format: "p50 %.2f / p95 %.2f / max %.2f ms", at(0.5), at(0.95), sorted[sorted.count - 1])
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
