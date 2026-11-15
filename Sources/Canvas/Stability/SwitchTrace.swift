import Foundation
import QuartzCore

/// One switch into a window, timed from the moment it was asked for to the app being in front, as a
/// line in the log:
///
///     Switch: ⌘Tab → Safari — Start Page · canvas 104 · wait 0 · flight 598 · seam 7 · activate 3 · front 28 · total 636 ms
///
/// - canvas: ⌘Tab pressed in a window, until the canvas was the active app.
/// - wait: ⌘ let go, until the flight could start (the canvas still on its way for a quick tap).
/// - flight: the camera's way to the window.
/// - seam: the Dock putting the real window in front where it was drawn.
/// - activate: from there to the app asked to the front.
/// - front: until macOS said the app was in front.
/// - total: from ⌘ let go (or, for a click, the flight's start) to the app in front, which is the
///   wait a person feels.
///
/// The parts a switch didn't have are left out. So a change to any of them can be read off the log
/// before and after, rather than judged by eye.
struct SwitchTrace: Equatable {
    enum Mark: Int, CaseIterable {
        case began, canvas, asked, takeoff, landed, seam, activated, front
    }

    /// "⌘Tab", "click", "entry" (a key, a double-click, a pinch), "tile".
    var how: String
    var to = ""
    var windowID: UInt32 = 0
    var pid: pid_t = 0
    private(set) var times: [Mark: TimeInterval] = [:]

    init(how: String, _ mark: Mark, at now: TimeInterval) {
        self.how = how
        times[mark] = now
    }

    /// The first time each moment is reached is the one that counts.
    mutating func mark(_ mark: Mark, at now: TimeInterval) {
        if times[mark] == nil { times[mark] = now }
    }

    func has(_ mark: Mark) -> Bool { times[mark] != nil }

    func time(_ mark: Mark) -> TimeInterval? { times[mark] }

    /// Milliseconds from one moment to a later one; nil if either wasn't reached or they're out of order.
    func ms(_ from: Mark, _ to: Mark) -> Int? {
        guard let a = times[from], let b = times[to], b >= a else { return nil }
        return Int(((b - a) * 1000).rounded())
    }

    /// The line. `unfinished`: why it never got to the app in front.
    func line(unfinished: String? = nil) -> String {
        var parts: [String] = []
        let segments: [(String, Mark, Mark)] = [
            ("canvas", .began, .canvas), ("wait", .asked, .takeoff), ("flight", .takeoff, .landed),
            ("seam", .landed, .seam), ("activate", .seam, .activated), ("front", .activated, .front),
        ]
        for (name, start, end) in segments {
            if let took = ms(start, end) { parts.append("\(name) \(took)") }
        }
        let first: Mark = has(.asked) ? .asked : .takeoff
        if let last = Mark.allCases.last(where: { has($0) }), let total = ms(first, last) {
            parts.append("total \(total) ms")
        }
        if let unfinished { parts.append(unfinished) }
        return "Switch: \(how) → \(to.isEmpty ? "?" : to) · " + parts.joined(separator: " · ")
    }
}

/// The switch under way, if any: one at a time, on whichever display. The canvas marks the moments as
/// it passes them (`CanvasController.handoff`, `enter`, `foreignActivation`).
@MainActor
enum SwitchLog {
    private(set) static var trace: SwitchTrace?
    /// A ⌘ let go this long ago isn't this flight's: the switch it asked for went another way.
    static let askedFor: TimeInterval = 2

    /// ⌘Tab was pressed.
    static func began(_ how: String, at now: TimeInterval = CACurrentMediaTime()) {
        close("another switch began")
        trace = SwitchTrace(how: how, .began, at: now)
    }

    /// A moment of the switch under way, whichever window it's to.
    static func mark(_ mark: SwitchTrace.Mark, at now: TimeInterval = CACurrentMediaTime()) {
        trace?.mark(mark, at: now)
    }

    /// A moment of the switch into `windowID`; another window's is not this switch's.
    static func mark(_ mark: SwitchTrace.Mark, window windowID: UInt32, at now: TimeInterval = CACurrentMediaTime()) {
        guard trace?.windowID == windowID else { return }
        trace?.mark(mark, at: now)
    }

    /// The flight to a window starts: the ⌘Tab that asked for it carries on, anything else starts here.
    static func takeoff(how: String, to: String, windowID: UInt32, pid: pid_t, at now: TimeInterval = CACurrentMediaTime()) {
        if var t = trace, !t.has(.takeoff), let asked = t.time(.asked), now - asked < askedFor {
            t.to = to
            t.windowID = windowID
            t.pid = pid
            t.mark(.takeoff, at: now)
            trace = t
            return
        }
        close("another switch began")
        var t = SwitchTrace(how: how, .takeoff, at: now)
        t.to = to
        t.windowID = windowID
        t.pid = pid
        trace = t
    }

    /// macOS says `pid` is in front: the switch into its window is done, and gets its line.
    static func front(pid: pid_t, at now: TimeInterval = CACurrentMediaTime()) {
        guard var t = trace, t.pid == pid, t.has(.activated) else { return }
        t.mark(.front, at: now)
        trace = nil
        Log.note(t.line())
    }

    /// The switch into `pid`'s window isn't going to finish: its line as far as it got.
    static func close(pid: pid_t, _ why: String) {
        guard trace?.pid == pid else { return }
        close(why)
    }

    /// The switch under way ends here. One that got as far as flying gets its line, with why.
    static func close(_ why: String) {
        guard let t = trace else { return }
        trace = nil
        if t.has(.takeoff) { Log.note(t.line(unfinished: why)) }
    }
}
