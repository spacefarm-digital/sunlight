import AppKit

/// Sunlight's own ordinary windows, kept where they can be seen: the canvas is a full-screen window above
/// the normal level (the add-on's `canvasLevel`, or the normal level itself in capture mode, where it is
/// the front window of the app), and Sunlight's windows aren't canvas material, so a normal-level window
/// of Sunlight's sat behind its own canvas, out of sight and out of reach. Sparkle's Software Update
/// window was the one that showed it ("Check for Updates" opened nothing you could see), and the About
/// panel and any window a framework opens for us are the same.
///
/// Each such window, as it first comes on screen, floats above the canvas and is brought onto a screen
/// (centred on the one with the pointer) if most of it is off every screen. After that it follows
/// `Uninstall`'s rule: floating while Sunlight is active, back at the normal level while another app is,
/// so it doesn't stay over that app's windows. The windows that set their own level (Settings floats and
/// hides, the setup wizard, the canvas and its panels) are left alone: only titled, normal-level windows
/// that aren't sheets are taken.
@MainActor
enum OwnWindows {
    /// The windows taken so far, weakly: a closed window drops out by itself.
    private static let taken = NSHashTable<NSWindow>.weakObjects()
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // A window coming on screen changes its occlusion state; one shown with makeKeyAndOrderFront
        // becomes key too. Either is the first sight of it.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow else { return }
                    noticed(window)
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for w in taken.allObjects where w.isVisible && w.level == .normal { w.level = .floating }
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for w in taken.allObjects where w.level == .floating { w.level = .normal }
            }
        })
    }

    private static func noticed(_ window: NSWindow) {
        guard window.isVisible else { return }
        if taken.contains(window) {
            // Seen before: it floats only while Sunlight is active (`start`), so a window shown again
            // from an inactive Sunlight doesn't stay over the app in front.
            if NSApp.isActive, window.level == .normal { window.level = .floating }
            return
        }
        guard takes(window) else { return }
        taken.add(window)
        // Floating even if Sunlight isn't active: a window that just appeared (an update found by the
        // scheduled check) is meant to be seen, and goes back to normal at the next switch away.
        window.level = .floating
        let screens = NSScreen.screens.map(\.visibleFrame)
        let pointer = NSEvent.mouseLocation
        if let frame = placement(for: window.frame, screens: screens, pointer: pointer) {
            window.setFrame(frame, display: true)
        }
        let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
        Log.note("Own window: \(name) lifted above the canvas at (\(Int(window.frame.minX)), \(Int(window.frame.minY)))")
    }

    /// The windows this looks after: titled windows of the normal level that aren't sheets (which ride
    /// with their parent's level) and aren't the canvas or the wizard, which order themselves.
    static func takes(_ window: NSWindow) -> Bool {
        window.level == .normal && window.styleMask.contains(.titled) && window.sheetParent == nil
            && !(window is CanvasWindow) && !(window is SetupWizardWindow)
    }

    /// Where a window should go to be reachable, or nil if it already is: at least most of it on one
    /// screen's visible frame. Otherwise centred on the screen under the pointer (the first screen if the
    /// pointer is on none), and no bigger than that screen. Bottom-left (Cocoa) coordinates throughout.
    nonisolated static func placement(for frame: CGRect, screens: [CGRect], pointer: CGPoint) -> CGRect? {
        guard !screens.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        let area = frame.width * frame.height
        let shown = screens.map { s -> CGFloat in
            let i = s.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }.max() ?? 0
        if shown >= area * 0.6 { return nil }
        let screen = screens.first { $0.contains(pointer) } ?? screens[0]
        let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        return CGRect(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}
