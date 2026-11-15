import AppKit
import SwiftUI

extension Notification.Name {
    static let shortcutRecordingChanged = Notification.Name("SunlightShortcutRecordingChanged")
}

/// A shortcut field as System Settings draws one: click it, press the keys, done. Escape leaves the
/// shortcut as it was, Delete removes it, and a key another command already holds is refused with a line
/// saying whose it is. The local monitor is what makes any combination recordable: it sees the key press
/// before the window's menus do, so ⌃⌥U records instead of tiling a window.
struct ShortcutRecorder: View {
    let command: Command
    let shortcut: Shortcut?
    let onSet: (Shortcut?) -> Void

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: toggle) {
                Text(recorder.isRecording ? "Type a shortcut…" : (shortcut?.label ?? "Add"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recorder.isRecording ? Color.accentColor : .primary)
                    .frame(minWidth: 84)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(recorder.isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(recorder.isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                          lineWidth: recorder.isRecording ? 2 : 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shortcut for \(command.title)")
            .accessibilityValue(shortcut?.label ?? "None")
            .help(recorder.isRecording ? "Press the keys, Escape to cancel, Delete to remove" : "Click to change")
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
            return
        }
        error = nil
        recorder.start { event in
            switch event.keyCode {
            case 53:   // Escape
                guard event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty else { break }
                recorder.stop()
                return
            case 51, 117:
                guard event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty else { break }
                // Delete: the command keeps no key, and the menus stop showing one.
                error = nil
                onSet(nil)
                recorder.stop()
                return
            default:
                break
            }
            let isDefaultKey = command.defaultShortcut?.keyCode == UInt32(event.keyCode)
                && command.defaultShortcut?.modifiers == 0
            guard let shortcut = Shortcut(event: event, allowUnmodified: command.isCanvasLocal || isDefaultKey) else {
                error = "Add ⌃, ⌥ or ⌘ to the key."
                NSSound.beep()
                return
            }
            if shortcut.isReservedByKeyTap {
                error = "Reserved by Sunlight or macOS."
                NSSound.beep()
                return
            }
            if let other = Bindings.conflict(for: shortcut, excluding: command) {
                error = "Already \(other.title)'s."
                NSSound.beep()
                return
            }
            error = nil
            onSet(shortcut)
            recorder.stop()
        }
    }
}

/// The monitor behind a recording session. It swallows key presses while it lasts (so menus don't act on
/// them) and lets a click through after ending the session.
@MainActor
private final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var handle: ((NSEvent) -> Void)?

    func start(handle: @escaping (NSEvent) -> Void) {
        guard monitor == nil else { return }
        self.handle = handle
        isRecording = true
        NotificationCenter.default.post(name: .shortcutRecordingChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.stop()
                return event
            }
            self.handle?(event)
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handle = nil
        isRecording = false
        NotificationCenter.default.post(name: .shortcutRecordingChanged, object: false)
    }
}
