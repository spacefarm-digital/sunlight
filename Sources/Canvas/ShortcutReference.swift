import Foundation

/// What the canvas does with the pointer, trackpad and keys, and Sunlight's own keys: the reference
/// Settings › How to use › Keyboard shows (it was the menu bar icon's Keyboard & Trackpad submenu).
/// On the main actor, like `TileMenu`, whose key summaries it reads.
@MainActor
enum ShortcutReference {
    struct Row: Equatable {
        let title: String
        let keys: String
    }

    /// The canvas, in the order you'd learn it.
    static let canvasRows: [Row] = [
        Row(title: "Zoom", keys: "pinch · ⌥ or ⌘ scroll"),
        Row(title: "Pan", keys: "two-finger scroll · four-finger drag"),
        Row(title: "Move a window", keys: "drag"),
        Row(title: "Flip a window's pole", keys: "P · its ⊕/⊖ button"),
        Row(title: "Enter where it is", keys: "click · pinch in"),
        Row(title: "Centre and enter", keys: "double-click · ⏎"),
        Row(title: "Use a window at 1:1", keys: "click"),
        Row(title: "See everything", keys: "four-finger tap"),
        Row(title: "Canvas ↔ last window", keys: "Mission Control key · four-finger tap"),
        Row(title: "Jump to another window", keys: "hold Mission Control key, point, let go"),
        Row(title: "Switch apps", keys: "⌘Tab · then ⌘← ⌘→"),
        Row(title: "Switch the app's windows", keys: "⌘Tab, then ⌘` · ⌘↑ ⌘↓"),
    ]

    /// Sunlight's own commands, leaving out the experimental ones that are off (`Settings.arranging`,
    /// `Settings.stripModeEnabled`).
    static var commandRows: [Row] {
        commandRows(arranging: Settings.arranging, strip: Settings.stripModeEnabled, tellSunlight: Settings.tellSunlight)
    }

    static func commandRows(arranging: Bool, strip: Bool, tellSunlight: Bool = false) -> [Row] {
        var rows = [
            Row(title: "Save Layout…", keys: "⌘S"),
            Row(title: "Restore a layout", keys: "⌘1 – ⌘9"),
        ]
        if arranging {
            rows += [
                Row(title: "Tidy", keys: TileMenu.tidyKeysSummary),
                Row(title: "Arrange the screen in columns", keys: TileMenu.arrangeKeysSummary),
            ]
        }
        rows.append(Row(title: "Move & Resize a window", keys: TileMenu.tileKeysSummary))
        rows.append(Row(title: "Picture in Picture", keys: "⌃⌥P · right-click"))
        if strip {
            rows.append(Row(title: "Strip mode on or off", keys: "⌃⌥S · then ⌃⌥ arrows step"))
        }
        if tellSunlight {
            rows.append(Row(title: "Tell Sunlight", keys: "⌃⌥Space"))
        }
        rows += [
            Row(title: "Show Desktop", keys: "F11 · four-finger spread"),
            Row(title: "Settings…", keys: "⌘,"),
            Row(title: "How to Use", keys: "⌘?"),
        ]
        return rows
    }
}
