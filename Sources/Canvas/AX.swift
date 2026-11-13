import AppKit
import ApplicationServices

/// Maps an AXUIElement to its CGWindowID. Private but SIP-safe and used by every macOS window manager
/// (yabai, Amethyst, AeroSpace, Rectangle). Falls back to frame matching if it ever stops resolving.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The queues Accessibility is talked to on. Every call is a round trip to another process, which
/// may be busy or hung for up to the timeout; none of that belongs on the main thread. Two queues,
/// serial, so a batch of warm-ups stuck on a hung app can't delay the lookup a click is waiting on.
enum AXQueue {
    /// What the user is waiting on: the window under the pointer, a close.
    static let interactive = DispatchQueue(label: "canvas.ax.interactive", qos: .userInitiated)
    /// Warm-ups: widgets' names and cards.
    static let background = DispatchQueue(label: "canvas.ax.background", qos: .utility)
}

/// A thin handle on another app's window through the Accessibility API.
/// All coordinates are Quartz style: top-left origin, points.
/// Sendable: an `AXUIElement` is an immutable token, and the API is safe to call from any thread.
struct AXWindow: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t

    /// The timeout for every element this process talks to that has no timeout of its own. Window
    /// elements never get one — and an element equal to one that has doesn't inherit it — so without
    /// this a hung app holds a frame read for the system's six seconds. Set once, at launch.
    static func installGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// An app element with a short messaging timeout. Apps are often mid-launch or busy when we talk to
    /// them; never let one stall our main thread for the default 6 s.
    static func application(_ pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    static func find(windowID: CGWindowID, pid: pid_t, approximateFrame: CGRect) -> AXWindow? {
        Watchdog.during("Accessibility: finding a window (AXWindow.find)") { findNow(windowID: windowID, pid: pid, approximateFrame: approximateFrame) }
    }

    private static func findNow(windowID: CGWindowID, pid: pid_t, approximateFrame: CGRect) -> AXWindow? {
        let app = application(pid, timeout: 1.0)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        for element in windows {
            let candidate = AXWindow(element: element, pid: pid)
            if candidate.windowID == windowID { return candidate }
        }
        // Fallback: closest frame.
        for element in windows {
            let candidate = AXWindow(element: element, pid: pid)
            if let f = candidate.frame,
               abs(f.minX - approximateFrame.minX) < 2, abs(f.minY - approximateFrame.minY) < 2,
               abs(f.width - approximateFrame.width) < 2, abs(f.height - approximateFrame.height) < 2 {
                return candidate
            }
        }
        return nil
    }

    /// The window the app is focused on, or nil if it has none yet (just launched, or a menu-bar app).
    /// Whether the app names the window among its windows; nil when it doesn't answer (busy, quitting,
    /// or with no Accessibility at all), which is never taken for a no.
    static func names(windowID: CGWindowID, pid: pid_t) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid, timeout: 1.0), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.contains { AXWindow(element: $0, pid: pid).windowID == windowID }
    }

    /// The app's windows by window ID; nil when it doesn't answer.
    static func windowsByID(pid: pid_t) -> [CGWindowID: AXWindow]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid, timeout: 1.0), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var byID: [CGWindowID: AXWindow] = [:]
        for element in windows {
            let w = AXWindow(element: element, pid: pid)
            if let id = w.windowID { byID[id] = w }
        }
        return byID
    }

    /// Whether the app has destroyed this handle's window, as far as Accessibility goes: only an answer
    /// of "invalid element" says so. A slow or silent app, or one that answers anything at all, says no.
    var isDestroyed: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    static func focusedWindow(pid: pid_t) -> AXWindow? {
        Watchdog.during("Accessibility: an app's focused window (AXWindow.focusedWindow)") { focusedWindowNow(pid: pid) }
    }

    private static func focusedWindowNow(pid: pid_t) -> AXWindow? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: value as! AXUIElement, pid: pid)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    var frame: CGRect? { Watchdog.during("Accessibility: a window's frame (AXWindow.frame)") { element.frame } }

    /// Native fullscreen: the window lives on its own Space and refuses to be moved.
    var isFullScreen: Bool { element.bool("AXFullScreen") }

    var isMinimized: Bool { element.bool(kAXMinimizedAttribute) }

    /// The file a document window shows (TextEdit, Preview, Xcode); nil for any other window.
    var document: URL? {
        guard let s = element.string(kAXDocumentAttribute), let url = URL(string: s), url.isFileURL else { return nil }
        return url
    }

    /// Into the Dock, as ⌘M or the yellow button would.
    @discardableResult
    func minimize() -> Bool {
        Watchdog.during("Accessibility: minimize (AXWindow.minimize)") {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        }
    }

    /// Whether the window's green button can be pressed (a window that can't be resized has it greyed).
    var zoomButtonEnabled: Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        return (ref as! AXUIElement).bool(kAXEnabledAttribute)
    }

    /// Out of macOS's own full screen, back onto the Desktop it came from. False if the app refused.
    func exitFullScreen() -> Bool {
        Watchdog.during("Accessibility: leave full screen (AXWindow.exitFullScreen)") {
            AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse) == .success
        }
    }

    @discardableResult
    func unminimize() -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    /// Brings this window to the front *within its app*. Activating the app then makes it frontmost overall.
    func raise() {
        Watchdog.during("Accessibility: raise (AXWindow.raise)") {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Where the window's red, yellow and green buttons are (`TrafficLights.Layout`), from their frames;
    /// nil for a window without them.
    var trafficLights: TrafficLights.Layout? {
        guard let window = frame else { return nil }
        func button(_ attribute: String) -> CGRect? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
                  let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement).frame
        }
        return TrafficLights.Layout.measured(window: window, close: button(kAXCloseButtonAttribute),
                                             minimize: button(kAXMinimizeButtonAttribute),
                                             zoom: button(kAXZoomButtonAttribute))
    }

    /// Presses the window's close button, exactly as a click on the red button would (so an unsaved
    /// document gets its sheet instead of being discarded). False if the window has no close button
    /// (a palette, a sheet) or the app refused.
    @discardableResult
    func close() -> Bool {
        Watchdog.during("Accessibility: close (AXWindow.close)") { closeNow() }
    }

    private func closeNow() -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(ref as! AXUIElement, kAXPressAction as CFString) == .success
    }
}

/// Typed attribute reads, shared by the window and widget handles.
extension AXUIElement {
    /// Top-left screen coordinates, points.
    var frame: CGRect? {
        guard let origin: CGPoint = value(kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size: CGSize = value(kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    var children: [AXUIElement] { elements(kAXChildrenAttribute) }

    var parent: AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXParentAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(self, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func string(_ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    func value<T>(_ attribute: String, _ type: AXValueType, _ zero: T) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var result = zero
        let ok = withUnsafeMutablePointer(to: &result) { AXValueGetValue(ref as! AXValue, type, UnsafeMutableRawPointer($0)) }
        return ok ? result : nil
    }

    func bool(_ attribute: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((ref as! CFBoolean))
    }
}

extension AXUIElement {
    /// Whether a press here is on a control the app drags itself: a scroll bar or its thumb, a slider,
    /// a pane divider, a resize handle. A drag anywhere else moves the window on the canvas.
    var isDraggedControl: Bool {
        guard let role = string(kAXRoleAttribute) else { return false }
        let controls: Set<String> = [kAXScrollBarRole, kAXSliderRole, kAXValueIndicatorRole, kAXSplitterRole,
                                     kAXHandleRole, kAXGrowAreaRole, kAXIncrementorRole, kAXColorWellRole]
        if controls.contains(role) { return true }
        // A scroll bar's thumb reports as its own kind of element in some apps; its parent tells.
        return parent?.string(kAXRoleAttribute) == kAXScrollBarRole
    }

    /// The deepest element at a global point (top-left origin), asked of the app.
    static func element(at point: CGPoint, pid: pid_t) -> AXUIElement? {
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &ref) == .success else { return nil }
        return ref
    }
}
