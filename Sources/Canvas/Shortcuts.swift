import AppKit
import Carbon.HIToolbox

// MARK: - A key and its modifiers

/// One key press: the physical key, the modifiers held with it, and the character the key types (what a
/// menu's key equivalent shows and matches). Stored with Carbon's modifier bits because that is what
/// `Hotkey` registers, and turned into Cocoa's flags where a menu item needs them.
struct Shortcut: Hashable, Codable, Sendable {
    var keyCode: UInt32
    /// Carbon: `controlKey`, `optionKey`, `shiftKey`, `cmdKey`.
    var modifiers: UInt32
    /// The character the key types without the modifiers that make it a shortcut, for menus.
    var key: String

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A key press as recorded: at least one of ⌃ ⌥ ⌘, so a global shortcut can't swallow ordinary typing.
    init?(event: NSEvent, allowUnmodified: Bool = false) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard allowUnmodified || !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbon(flags), key: key)
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Whether two shortcuts would claim the same key press, whatever character the layout gives it.
    func claimsSameKey(as other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// KeyTap claims these even when a Carbon hotkey is registered. Reject them in the recorder.
    var isReservedByKeyTap: Bool {
        var flags: CGEventFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        var state = KeyTap.State()
        state.entered = true
        state.placesNewWindow = true
        state.switcherOpen = true
        state.showDesktopOnF11 = false
        state.toggleCanvasOnMissionControl = false
        state.howToUseOnDefault = false
        return KeyTap.action(keyCode: Int64(keyCode), flags: flags, state: &state) != .pass
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == UInt32(event.keyCode) && modifiers == Shortcut.carbon(event.modifierFlags)
    }

    /// What Settings and the menus show: ⌃⌥U, ⌃⌥←, ⇧⌘S.
    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    private var keyLabel: String {
        if let named = Shortcut.namedKeys[keyCode] { return named }
        if key == " " { return "Space" }
        if key.count == 1 { return key.uppercased() }
        return key.uppercased()
    }

    /// Keys whose characters are control codes or private-use function keys, which no one wants to read.
    private static let namedKeys: [UInt32: String] = [
        36: "⏎", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 160: "Mission Control",
    ]
}

// MARK: - Commands

/// Everything a key or a four-finger gesture can do. Tile cases carry their `Tiling.Preset`'s raw value,
/// so the preset and its command are one and the same.
enum Command: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Move & Resize: one window.
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird
    case leftTwoThirds, centerTwoThirds, rightTwoThirds
    case full, center
    // Arrange: the windows of one screen, and everything.
    case arrange2, arrange3, arrange4
    case tidy
    // Displays.
    case nextDisplay, previousDisplay
    // The canvas itself.
    case toggleStrip, pictureInPicture, tellSunlight
    case showDesktop
    case seeAll
    case toggleCanvas
    case panCanvas
    case enterWindow, flipPolarity
    case saveLayout, settings, instructions, quit, closeWindow, undo, redo
    case restoreLayout1, restoreLayout2, restoreLayout3, restoreLayout4, restoreLayout5
    case restoreLayout6, restoreLayout7, restoreLayout8, restoreLayout9

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case moveAndResize, arrange, displays, canvas, menus

        var id: String { rawValue }

        var title: String {
            switch self {
            case .moveAndResize: return "Move & Resize"
            case .arrange: return "Arrange"
            case .displays: return "Displays"
            case .canvas: return "Canvas"
            case .menus: return "Menus"
            }
        }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
             .topLeft, .topRight, .bottomLeft, .bottomRight,
             .leftThird, .centerThird, .rightThird,
             .leftTwoThirds, .centerTwoThirds, .rightTwoThirds,
             .full, .center:
            return .moveAndResize
        case .arrange2, .arrange3, .arrange4, .tidy:
            return .arrange
        case .nextDisplay, .previousDisplay:
            return .displays
        case .toggleStrip, .pictureInPicture, .tellSunlight, .showDesktop, .seeAll, .toggleCanvas, .panCanvas, .enterWindow, .flipPolarity:
            return .canvas
        case .saveLayout, .settings, .instructions, .quit, .closeWindow, .undo, .redo,
             .restoreLayout1, .restoreLayout2, .restoreLayout3, .restoreLayout4, .restoreLayout5,
             .restoreLayout6, .restoreLayout7, .restoreLayout8, .restoreLayout9:
            return .menus
        }
    }

    /// The window slot this command places, if it places one.
    var preset: Tiling.Preset? { Tiling.Preset(rawValue: rawValue) }

    /// The screen arrangement this command makes, if it makes one.
    var arrangement: (columns: Int, rows: Int)? {
        switch self {
        case .arrange2: return (2, 1)
        case .arrange3: return (3, 1)
        case .arrange4: return (4, 1)
        default: return nil
        }
    }

    var title: String {
        if let preset { return preset.title }
        switch self {
        case .arrange2: return "2 Columns"
        case .arrange3: return "3 Columns"
        case .arrange4: return "4 Columns"
        case .tidy: return "Tidy"
        case .nextDisplay: return "Move to Next Display"
        case .previousDisplay: return "Move to Previous Display"
        case .toggleStrip: return "Strip Mode"
        case .pictureInPicture: return "Picture in Picture"
        case .tellSunlight: return "Tell Sunlight"
        case .showDesktop: return "Show Desktop"
        case .seeAll: return "See Everything"
        case .toggleCanvas: return "Canvas ↔ Last Window"
        case .panCanvas: return "Pan the Canvas"
        case .enterWindow: return "Enter Window"
        case .flipPolarity: return "Flip Window Polarity"
        case .saveLayout: return "Save Layout"
        case .settings: return "Settings"
        case .instructions: return "Instructions"
        case .quit: return "Quit Sunlight"
        case .closeWindow: return "Close Window"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .restoreLayout1, .restoreLayout2, .restoreLayout3, .restoreLayout4, .restoreLayout5,
             .restoreLayout6, .restoreLayout7, .restoreLayout8, .restoreLayout9:
            return "Restore Layout \((Self.layoutCommands.firstIndex(of: self) ?? 0) + 1)"
        default: return rawValue
        }
    }

    /// The title in a gesture's menu, grouped so twenty-odd commands stay findable.
    var menuTitle: String { "\(group.title) · \(title)" }

    /// The key a command has before anything is changed.
    var defaultShortcut: Shortcut? {
        let tile = UInt32(controlKey | optionKey)
        let display = UInt32(controlKey | optionKey | shiftKey)
        let command = UInt32(cmdKey)
        func key(_ code: Int, _ character: String, _ modifiers: UInt32) -> Shortcut {
            Shortcut(keyCode: UInt32(code), modifiers: modifiers, key: character)
        }
        func arrow(_ scalar: Int) -> String {
            String(Character(UnicodeScalar(UInt16(scalar))!))
        }
        if let preset {
            switch preset {
            case .leftHalf: return key(kVK_LeftArrow, arrow(NSLeftArrowFunctionKey), tile)
            case .rightHalf: return key(kVK_RightArrow, arrow(NSRightArrowFunctionKey), tile)
            case .topHalf: return key(kVK_UpArrow, arrow(NSUpArrowFunctionKey), tile)
            case .bottomHalf: return key(kVK_DownArrow, arrow(NSDownArrowFunctionKey), tile)
            case .topLeft: return key(kVK_ANSI_U, "u", tile)
            case .topRight: return key(kVK_ANSI_I, "i", tile)
            case .bottomLeft: return key(kVK_ANSI_J, "j", tile)
            case .bottomRight: return key(kVK_ANSI_K, "k", tile)
            case .leftThird: return key(kVK_ANSI_D, "d", tile)
            case .centerThird: return key(kVK_ANSI_F, "f", tile)
            case .rightThird: return key(kVK_ANSI_G, "g", tile)
            case .leftTwoThirds: return key(kVK_ANSI_E, "e", tile)
            // No key by default: the menus have always left it out.
            case .centerTwoThirds: return nil
            case .rightTwoThirds: return key(kVK_ANSI_T, "t", tile)
            case .full: return key(kVK_Return, "\r", tile)
            case .center: return key(kVK_ANSI_C, "c", tile)
            }
        }
        if let i = Self.layoutCommands.firstIndex(of: self) {
            let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            return key(codes[i], String(i + 1), command)
        }
        switch self {
        case .arrange2: return key(kVK_ANSI_2, "2", tile)
        case .arrange3: return key(kVK_ANSI_3, "3", tile)
        case .arrange4: return key(kVK_ANSI_4, "4", tile)
        case .tidy: return key(kVK_ANSI_A, "a", tile)
        case .nextDisplay: return key(kVK_RightArrow, arrow(NSRightArrowFunctionKey), display)
        case .previousDisplay: return key(kVK_LeftArrow, arrow(NSLeftArrowFunctionKey), display)
        case .toggleStrip: return key(kVK_ANSI_S, "s", tile)
        case .pictureInPicture: return key(kVK_ANSI_P, "p", tile)
        case .tellSunlight: return key(kVK_Space, " ", tile)
        // F11 is the Mac's own Show Desktop; while takeover runs, the key tap forwards it here.
        case .showDesktop: return key(kVK_F11, arrow(NSF11FunctionKey), 0)
        case .toggleCanvas: return key(160, arrow(NSF3FunctionKey), 0)
        case .enterWindow: return key(kVK_Return, "\r", 0)
        case .flipPolarity: return key(kVK_ANSI_P, "p", 0)
        case .saveLayout: return key(kVK_ANSI_S, "s", command)
        case .settings: return key(kVK_ANSI_Comma, ",", command)
        case .instructions: return key(kVK_ANSI_Slash, "?", command | UInt32(shiftKey))
        case .quit: return key(kVK_ANSI_Q, "q", command)
        case .closeWindow: return key(kVK_ANSI_W, "w", command)
        case .undo: return key(kVK_ANSI_Z, "z", command)
        case .redo: return key(kVK_ANSI_Z, "Z", command | UInt32(shiftKey))
        case .seeAll, .panCanvas: return nil
        default: return nil
        }
    }

    /// Panning is continuous and cannot be represented by a single key press.
    var keyBindable: Bool { self != .panCanvas }
    /// These act on the window under the pointer and only work while the canvas has focus.
    var isCanvasLocal: Bool { self == .enterWindow || self == .flipPolarity }
    var isMenuShortcut: Bool { group == .menus }

    /// Whether the feature behind a command is on, and whether there is anywhere to move a window to.
    func isAvailable(arranging: Bool, strip: Bool, displays: Bool) -> Bool {
        switch self {
        case .arrange2, .arrange3, .arrange4, .tidy: return arranging
        case .toggleStrip: return strip
        case .nextDisplay, .previousDisplay: return displays
        default: return true
        }
    }

    /// The command that places a window in `preset`.
    static func tile(_ preset: Tiling.Preset) -> Command? { Command(rawValue: preset.rawValue) }

    static var tiles: [Command] { allCases.filter { $0.preset != nil } }
    static var keyBindableCommands: [Command] { allCases.filter(\.keyBindable) }
    static var globalKeyCommands: [Command] { keyBindableCommands.filter { !$0.isCanvasLocal && !$0.isMenuShortcut } }
    static let layoutCommands: [Command] = [.restoreLayout1, .restoreLayout2, .restoreLayout3,
        .restoreLayout4, .restoreLayout5, .restoreLayout6, .restoreLayout7, .restoreLayout8, .restoreLayout9]
}

// MARK: - Four-finger gestures

/// The trackpad gestures Sunlight can recognise. The four-finger drag is continuous (a pan by default);
/// the rest are strokes or taps that fire once.
enum TrackpadGesture: String, CaseIterable, Identifiable, Hashable, Sendable {
    case fourFingerTap
    case swipeUp, swipeDown, swipeLeft, swipeRight
    case spread
    case fourFingerDrag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourFingerTap: return "Four-finger tap"
        case .swipeUp: return "Four-finger swipe up"
        case .swipeDown: return "Four-finger swipe down"
        case .swipeLeft: return "Four-finger swipe left"
        case .swipeRight: return "Four-finger swipe right"
        case .spread: return "Thumb and three fingers spread"
        case .fourFingerDrag: return "Four-finger drag"
        }
    }

    var how: String {
        switch self {
        case .fourFingerTap: return "Tap with four fingers"
        case .swipeUp: return "Swipe up with four fingers"
        case .swipeDown: return "Swipe down with four fingers"
        case .swipeLeft: return "Swipe left with four fingers"
        case .swipeRight: return "Swipe right with four fingers"
        case .spread: return "Spread your thumb and three fingers"
        case .fourFingerDrag: return "Drag with four fingers"
        }
    }

    /// What it does before anything is changed.
    @MainActor var defaultCommand: Command? {
        switch self {
        case .fourFingerTap: return .seeAll
        case .spread: return .showDesktop
        case .fourFingerDrag: return .panCanvas
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: return nil
        }
    }

    static var flicks: [TrackpadGesture] { [.swipeUp, .swipeDown, .swipeLeft, .swipeRight] }
    var isFlick: Bool { Self.flicks.contains(self) }

    /// The same gesture as the guide draws, where it draws one.
    var guideGesture: GestureGuide.Gesture? {
        switch self {
        case .fourFingerTap: return .fourFingerTap
        case .swipeUp: return .swipeUp
        case .spread: return .spread
        case .fourFingerDrag: return .fourFingerDrag
        case .swipeDown, .swipeLeft, .swipeRight: return nil
        }
    }
}

// MARK: - The store

/// The keys and gestures as the person set them, in UserDefaults. Anything unchanged falls back to the
/// command's own default, so a new version's defaults reach people who never touched a row, and a row
/// can be put back by removing its override. Changes post `didChange`: the hotkeys, the menus and the
/// trackpad recognizer follow.
@MainActor
enum Bindings {
    static let didChange = Notification.Name("SunlightBindingsDidChange")

    private static let shortcutsKey = "SunlightShortcutOverrides"
    private static let gesturesKey = "SunlightGestureOverrides"
    private static let migratedKey = "SunlightBindingsMigratedV1"
    private static var defaults: UserDefaults { .standard }

    private struct ShortcutOverride: Codable {
        /// nil: explicitly unbound, which is not the same as "use the default".
        var shortcut: Shortcut?
    }

    private struct GestureOverride: Codable {
        var command: String?
    }

    private static var shortcutCache: [String: ShortcutOverride]?
    private static var gestureCache: [String: GestureOverride]?

    // MARK: Keys

    /// The key a command has now, or nil when it has none.
    static func shortcut(for command: Command) -> Shortcut? {
        if let override = shortcutOverrides()[command.rawValue] { return override.shortcut }
        return command.defaultShortcut
    }

    /// Gives a command a key, or none. The default is stored as no override at all.
    static func setShortcut(_ shortcut: Shortcut?, for command: Command) {
        var overrides = shortcutOverrides()
        if shortcut == command.defaultShortcut {
            overrides[command.rawValue] = nil
        } else {
            overrides[command.rawValue] = ShortcutOverride(shortcut: shortcut)
        }
        shortcutCache = overrides
        save(overrides, key: shortcutsKey)
        post()
    }

    /// The command already holding this key press, if any. Shift alone is part of the comparison too.
    static func conflict(for shortcut: Shortcut, excluding command: Command) -> Command? {
        Command.allCases.first { other in
            other != command && Bindings.shortcut(for: other)?.claimsSameKey(as: shortcut) == true
        }
    }

    static func resetShortcuts() {
        shortcutCache = [:]
        defaults.removeObject(forKey: shortcutsKey)
        post()
    }

    /// A group of commands' keys in one line, with `fallback` kept while every one is still the default.
    static func summary(_ commands: [Command], default fallback: String) -> String {
        if commands.allSatisfy({ shortcut(for: $0) == $0.defaultShortcut }) { return fallback }
        return commands.compactMap { shortcut(for: $0)?.label }.joined(separator: " · ")
    }

    // MARK: Gestures

    /// What a four-finger gesture does now, or nil when it does nothing and is left alone.
    static func command(for gesture: TrackpadGesture) -> Command? {
        if let override = gestureOverrides()[gesture.rawValue] {
            return override.command.flatMap(Command.init(rawValue:))
        }
        return gesture.defaultCommand
    }

    static func setGesture(_ command: Command?, for gesture: TrackpadGesture) {
        var overrides = gestureOverrides()
        if command == gesture.defaultCommand {
            overrides[gesture.rawValue] = nil
        } else {
            overrides[gesture.rawValue] = GestureOverride(command: command?.rawValue)
        }
        gestureCache = overrides
        save(overrides, key: gesturesKey)
        post()
    }

    /// The first gesture that does `command`, in the order Settings › Trackpad lists them.
    static func gesture(doing command: Command) -> TrackpadGesture? {
        TrackpadGesture.allCases.first { self.command(for: $0) == command }
    }

    static func resetGestures() {
        gestureCache = [:]
        defaults.removeObject(forKey: gesturesKey)
        post()
    }

    /// The recognizer's copy of the gesture choices, read without touching the main actor from its frames.
    static func trackpadConfig() -> TrackpadPan.GestureConfig {
        var config = TrackpadPan.GestureConfig()
        config.freeSteering = Settings.freePanSteering
        config.tap = command(for: .fourFingerTap) != nil
        config.spread = command(for: .spread) != nil
        config.flicks = Set(TrackpadGesture.flicks.filter { command(for: $0) != nil })
        switch command(for: .fourFingerDrag) {
        case .panCanvas?: config.drag = .pan
        case nil: config.drag = .off
        default: config.drag = .fire
        }
        return config
    }

    // MARK: Migration

    /// Settings › Trackpad used to offer one choice, a tap or a swipe up for See Everything. It becomes
    /// the two gestures' bindings the first time this version runs, and the old key goes.
    static func migrateIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let legacy = defaults.string(forKey: "CanvasSeeAllGesture")
        defaults.removeObject(forKey: "CanvasSeeAllGesture")
        guard legacy == "swipeUp" else { return }
        gestureCache = [TrackpadGesture.fourFingerTap.rawValue: GestureOverride(command: nil),
                       TrackpadGesture.swipeUp.rawValue: GestureOverride(command: Command.seeAll.rawValue)]
        save(gestureCache ?? [:], key: gesturesKey)
        post()
    }

    // MARK: Storage

    private static func shortcutOverrides() -> [String: ShortcutOverride] {
        if let shortcutCache { return shortcutCache }
        let loaded = load([String: ShortcutOverride].self, key: shortcutsKey) ?? [:]
        shortcutCache = loaded
        return loaded
    }

    private static func gestureOverrides() -> [String: GestureOverride] {
        if let gestureCache { return gestureCache }
        let loaded = load([String: GestureOverride].self, key: gesturesKey) ?? [:]
        gestureCache = loaded
        return loaded
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Everything back to its default: the tests use it, and Settings' Restore Defaults.
    static func resetAll() {
        shortcutCache = nil
        gestureCache = nil
        defaults.removeObject(forKey: shortcutsKey)
        defaults.removeObject(forKey: gesturesKey)
        defaults.removeObject(forKey: migratedKey)
        post()
    }
}
