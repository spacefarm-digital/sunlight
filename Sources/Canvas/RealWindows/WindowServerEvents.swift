import Foundation
import CoreGraphics

/// The window server's own word that a window appeared, through SkyLight's connection notifications
/// (private, so opened by path and looked up by name, as `WindowCapture` does).
///
/// The canvas otherwise learns of a new window from the one-second listing, and all that while the
/// window shows as the app made it: full size, on top, wherever the camera is. The notification arrives
/// within milliseconds of the window, so the canvas can list at once and the add-on scale it before
/// it is seen at 1x.
///
/// 1325 is posted as a window is added to a Space, 1326 as it leaves one; the payload is the Space's
/// id (64 bits) then the window's (32), as yabai reads them; on macOS 27.2 both arrive on the main
/// thread, for other processes' windows only (never this app's own menus and panels). A window still
/// ordering in may not be on the listing yet, so `onWindowCreated` is a cue to look, not a promise.
@MainActor
enum WindowServerEvents {
    nonisolated static let windowCreated: UInt32 = 1325
    nonisolated static let windowRemoved: UInt32 = 1326

    /// Called on the main thread with the new window's id, or 0 when the payload wasn't as expected.
    static var onWindowCreated: ((CGWindowID) -> Void)?
    /// Called on the main thread with the id of a window that left the Space (closed, minimized, hidden
    /// or moved), or 0 when the payload wasn't as expected.
    static var onWindowRemoved: ((CGWindowID) -> Void)?

    private typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias Register = @convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32
    private typealias MainConnectionID = @convention(c) () -> Int32

    private static var started = false

    /// Registers once; false when SkyLight or the call isn't there (the listing still finds the window,
    /// a second later).
    @discardableResult
    static func start() -> Bool {
        if started { return true }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cid = dlsym(handle, "SLSMainConnectionID"),
              let register = dlsym(handle, "SLSRegisterConnectionNotifyProc") else {
            Log.note("Window events: SkyLight's notifications aren't available; new windows wait for the listing")
            return false
        }
        let connection = unsafeBitCast(cid, to: MainConnectionID.self)()
        let registerProc = unsafeBitCast(register, to: Register.self)
        let error = registerProc(connection, handler, windowCreated, nil)
        guard error == 0 else {
            Log.note("Window events: registering for new windows failed (\(error))")
            return false
        }
        let removed = registerProc(connection, handler, windowRemoved, nil)
        if removed != 0 { Log.note("Window events: registering for removed windows failed (\(removed)); the listing finds them") }
        started = true
        return true
    }

    private typealias SetLevel = @convention(c) (Int32, CGWindowID, Int32) -> Int32

    /// One of this process's own windows to `level`, as the window server has it (`SLSSetWindowLevel`,
    /// which AppKit's `NSWindow.level` wraps, but without AppKit's record of the level getting in the way:
    /// the add-on changes the canvas's level behind AppKit's back, see `LiveWindowsWire.liftsCanvasInDock`).
    /// Quietly nothing when SkyLight isn't there; false when the call failed.
    @discardableResult
    static func setLevel(of window: CGWindowID, to level: Int32) -> Bool {
        guard window != 0,
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cid = dlsym(handle, "SLSMainConnectionID"),
              let set = dlsym(handle, "SLSSetWindowLevel") else { return false }
        let connection = unsafeBitCast(cid, to: MainConnectionID.self)()
        return unsafeBitCast(set, to: SetLevel.self)(connection, window, level) == 0
    }

    private static let handler: Handler = { type, data, length, _ in
        var id: CGWindowID = 0
        if let data, length >= 12 {
            id = data.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        }
        let deliver: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                if type == WindowServerEvents.windowRemoved { WindowServerEvents.onWindowRemoved?(id) }
                else { WindowServerEvents.onWindowCreated?(id) }
            }
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }
}
