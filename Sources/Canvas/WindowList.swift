import AppKit

/// One window as the window server lists it: enough to tell whether it belongs on the canvas and
/// where it is, without asking ScreenCaptureKit, which is needed only to stream it.
struct WindowInfo: Sendable {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    /// Top-left screen coordinates, points: the same space as `SCWindow.frame` and Accessibility.
    let bounds: CGRect
    /// Present with Screen Recording granted (which streaming needs anyway).
    let title: String?
    let alpha: Double
}

/// The window server's own list, through `CGWindowListCopyWindowInfo`: a millisecond or so for a
/// desktop's worth of windows, against the tens of milliseconds and the daemon round trip of
/// `SCShareableContent`. It's what keeps the canvas in agreement with the desktop from second to
/// second; ScreenCaptureKit is asked only when a new window needs a stream.
enum WindowList {
    static let queue = DispatchQueue(label: "canvas.windowlist", qos: .userInitiated)

    /// Every window on screen, front to back, on the current Space. Call it on `queue`.
    nonisolated static func onScreen() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let b = d[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: b as! CFDictionary) else { return nil }
            return WindowInfo(id: id, pid: pid, layer: layer, bounds: bounds,
                              title: d[kCGWindowName as String] as? String,
                              alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }

    /// One window, if it's on screen: for watching for a single window without listing them all.
    nonisolated static func onScreen(_ id: CGWindowID) -> WindowInfo? {
        guard id != 0, let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let d = list.first, (d[kCGWindowIsOnscreen as String] as? Bool) == true,
              let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let b = d[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: b as! CFDictionary) else { return nil }
        return WindowInfo(id: id, pid: pid, layer: layer, bounds: bounds, title: d[kCGWindowName as String] as? String,
                          alpha: (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
    }

    /// Whether a window still exists: on any Space, minimized or not. A fraction of a millisecond,
    /// and no app is asked anything.
    ///
    /// Asked of the window server directly (`SLSGetWindowOwner`, which answers for any window that is
    /// still there, as the add-on relies on): `CGWindowListCopyWindowInfo` with `optionIncludingWindow`
    /// leaves a minimized window out on macOS 27 (measured 2026-10-28: listed until the Dock's
    /// animation ends, then gone while in the Dock), so it took a minimized window for a closed one.
    /// Without SkyLight, the whole list is scanned instead, which does include minimized windows.
    nonisolated static func exists(_ id: CGWindowID) -> Bool {
        guard id != 0 else { return false }
        if let owner = windowOwner {
            var cid: Int32 = 0
            return owner.call(owner.connection, id, &cid) == 0
        }
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    /// Whether a window is on screen on the current Space right now: not closed, minimized, hidden or on
    /// another Space. (The Dock's minimize animation runs with the window still on screen; it leaves the
    /// screen as the animation ends.)
    nonisolated static func isOnScreen(_ id: CGWindowID) -> Bool {
        guard id != 0, let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first else { return false }
        return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// Whether the pointer is on the Dock right now: on a window of the Dock's own at the Dock's level,
    /// as the window server has it. The canvas can't tell by itself, as the Dock sits in front of it.
    static func pointerOverDock() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let pointer = CGEvent(source: nil)?.location else { return false }
        let level = Int(CGWindowLevelForKey(.dockWindow))
        return onScreen().contains { $0.pid == dock && $0.layer == level && $0.alpha > 0 && $0.bounds.contains(pointer) }
    }

    private typealias GetWindowOwner = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias MainConnectionID = @convention(c) () -> Int32

    /// SkyLight's owner lookup and this process's connection, looked up once; nil where SkyLight or the
    /// call isn't there.
    nonisolated private static let windowOwner: (call: GetWindowOwner, connection: Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cid = dlsym(handle, "SLSMainConnectionID"),
              let owner = dlsym(handle, "SLSGetWindowOwner") else { return nil }
        let connection = unsafeBitCast(cid, to: MainConnectionID.self)()
        return (unsafeBitCast(owner, to: GetWindowOwner.self), connection)
    }()
}

/// The Mac's own interface, which draws in windows like any app but isn't one: Notification Center
/// (desktop widgets can sit at the normal-window level, layer 0, alongside app windows on 27.2),
/// Control Center, Spotlight, the Dock, Stage Manager and the rest. None of it belongs on the canvas
/// or in the ⌘Tab switcher. Widgets are taken separately, by `Widgets.isWidget`.
enum SystemUI {
    static let bundleIDs: Set<String> = [
        Widgets.ownerBundleID,               // Notification Center: banners, the panel, widgets
        "com.apple.controlcenter",           // Control Center and the menu bar extras
        "com.apple.Spotlight",
        "com.apple.dock",                    // also Mission Control, Launchpad, the hot corners
        "com.apple.WindowManager",           // Stage Manager, the desktop wallpaper
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.screencaptureui",         // the screenshot toolbar
        "com.apple.OSDUIHelper",             // volume and brightness
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher",
        "com.apple.universalcontrol",
        "com.apple.AirPlayUIAgent",
        "com.apple.wallpaper.agent",
    ]

    static func owns(_ bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }
}
