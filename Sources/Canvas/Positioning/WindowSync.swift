import CoreGraphics

/// Who decides where a window is: the canvas, or the person using the window.
///
/// The canvas keeps a map of where every window is (`WindowProxy.worldRect`); macOS keeps its own.
/// They agree by construction while the canvas places windows natively (the seam, kept windows, the
/// app's siblings), and the one way they can come apart is the user moving a window by hand while
/// its app is in front. So a window is the user's from the moment its app comes to the front until
/// the canvas has read it back once; the rest of the time it's the canvas's, and a native frame that
/// differs is something the canvas or macOS did (a menu-bar clamp, a window put back after a
/// restart), not a move to follow.
///
/// This one field replaces the set of apps in front since the last listing (which was per app, so a
/// sheet macOS moved under an app in front read as the user moving it) and the position half of the
/// 1.5 s hold after a resize of ours (a canvas-owned window never takes a position from the listing,
/// so there is nothing to hold).
enum PositionOwner: Equatable {
    /// The canvas placed it, or has read it back since the user last could have moved it. The
    /// listing never moves it on the canvas; it only takes a new size where the canvas has it.
    case canvas
    /// Its app has been in front since the canvas last read it: the user may have moved it. The next
    /// listing (or the return to the canvas) takes the native frame as where it lives.
    case user
}

/// The rules the listing applies to a window it finds, as pure functions: what the window server's
/// frame may change on the canvas. The sequencing (which windows are listed when, proxies made and
/// dropped, what follows a move) stays with the controller; the decision lives here, where a test can
/// reach it.
enum WindowSync {
    /// What a listing does with one window's native frame.
    enum Verdict: Equatable {
        /// Nothing: the frame is the canvas's own output, unchanged, meaningless, or stale.
        case keep
        /// The size, where the canvas has the window (top-left anchored); its place stands. The native
        /// frame is remembered as is, so it stops looking like a move.
        case size
        /// Position and size, as the user left them.
        case move
    }

    /// The word on one window.
    /// - `owner`: whose position it is.
    /// - `isWidget`: a desktop widget's own spot is where it is on the desktop at 1:1, whoever is in front.
    /// - `capturing`: the capture renderer, where the native windows sit behind the canvas. Its listing
    ///   is no more the truth for a canvas-owned window's place than the live one's: the handoff puts
    ///   the real window where the canvas has the proxy through Accessibility, and reads it back the
    ///   same way on the way out, and the window server's frame can differ from the app's own by a
    ///   constant (33 pt under a menu bar, more after a live-windows session); taken as a move through
    ///   the zoomed-out camera, that constant became a jump of the proxy on every trip into the window.
    ///   The size is still taken (the app's own resize).
    /// - `transformed`: live windows are presented, drawn through the canvas's own transforms: the
    ///   window server may report the transformed rectangle, and feeding that back would move the
    ///   proxy by a rounding step every tick.
    /// - `listed` / `last`: the frame as listed now and as last remembered.
    /// - `sizeHeld`: a resize of ours is still settling, and the listing lags the app's answer.
    static func verdict(owner: PositionOwner, isWidget: Bool, capturing: Bool, transformed: Bool,
                        listed: CGRect, last: CGRect, sizeHeld: Bool) -> Verdict {
        guard FrameSnapshot.hasSize(listed) else { return .keep }
        guard !transformed else { return .keep }
        guard !listed.isClose(to: last) else { return .keep }
        guard !sizeHeld else { return .keep }
        if isWidget || owner == .user { return .move }
        return .size
    }
}
