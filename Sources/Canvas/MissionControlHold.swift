import Foundation

/// Hold the Mission Control key to pick a window: down, the canvas shows everything (See All); point at
/// a window, the canvas's hover lights it; let go, and you're in it, centred at 1:1. A quick tap is the
/// key as it always was: from a window, See All (and stays there); on the canvas, back into the last
/// window. On the canvas the tap acts on the release, since only then is it known not to be a hold.
enum MissionControlHold {
    /// Held at least this long, the key is a hold: the release picks the window under the pointer. A
    /// tap is well under it (about 0.1 s); long enough that a slow tap isn't taken for a pick.
    static let threshold: TimeInterval = 0.3

    /// Where the press began.
    enum Press: Equatable {
        /// In a window (or any other app): the press brought See All.
        case fromWindow
        /// On the canvas: nothing yet; held, See All comes after `threshold`.
        case onCanvas
    }

    enum Release: Equatable {
        /// A tap on the canvas: back into the last window.
        case toggle
        /// A tap from a window: See All is up, and stays.
        case stay
        /// A hold: into the window under the pointer, if there's one there.
        case pick
    }

    static func release(held: TimeInterval, press: Press) -> Release {
        if held >= threshold { return .pick }
        return press == .onCanvas ? .toggle : .stay
    }
}
