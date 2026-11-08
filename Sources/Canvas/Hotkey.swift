import Carbon.HIToolbox
import Foundation

/// A global hotkey via Carbon's RegisterEventHotKey. Works without Accessibility permission
/// and fires even while another app is frontmost — that's what makes "come back to the canvas" possible.
final class Hotkey {
    private static var registry: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let callback: @MainActor () -> Void
    private var ref: EventHotKeyRef?

    init(keyCode: UInt32, modifiers: UInt32, callback: @escaping @MainActor () -> Void) {
        self.callback = callback
        id = Hotkey.nextID
        Hotkey.nextID += 1
        Hotkey.registry[id] = self
        Hotkey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x4341_4E56) /* 'CANV' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.note("Hotkey: RegisterEventHotKey failed (\(status))") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Hotkey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            if let hotkey = Hotkey.registry[hotKeyID.id] {
                let cb = hotkey.callback
                Task { @MainActor in cb() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
