import AppKit
import ApplicationServices

enum Permissions {
    /// Prompts for Accessibility (needed to move / raise other apps' windows).
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        Log.note("Accessibility: \(trusted ? "granted" : "not granted yet — enable it in System Settings › Privacy & Security › Accessibility")")
    }

    /// Prompts for Screen Recording (needed by ScreenCaptureKit to stream window contents).
    /// macOS applies a newly granted Screen Recording permission only after the app is relaunched.
    static func requestScreenCapture() {
        if CGPreflightScreenCaptureAccess() {
            Log.note("Screen Recording: granted")
        } else {
            Log.note("Screen Recording: not granted yet — grant it, then relaunch")
            CGRequestScreenCaptureAccess()
        }
    }
}
