// Shows setup's drag guide on its own, beside System Settings, without Sunlight running or any
// permission changing. Build and run from the repo root:
//   swiftc -O -o /tmp/drag-guide-demo Sources/Canvas/Setup/PermissionDragPanel.swift scripts/drag-guide-demo/main.swift && /tmp/drag-guide-demo
// Optional argument: screen (Screen Recording) instead of Accessibility. Quits after two minutes; ⌃C to stop sooner.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = CommandLine.arguments.dropFirst().contains("screen")
if FileManager.default.fileExists(atPath: "/Applications/Sunlight.app") {
    DraggableAppIcon.bundleURL = URL(fileURLWithPath: "/Applications/Sunlight.app")
}
let anchor = screen ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
MainActor.assumeIsolated {
    PermissionDragPanel.shared.show(for: screen ? .screenRecording : .accessibility)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { exit(0) }
app.run()
