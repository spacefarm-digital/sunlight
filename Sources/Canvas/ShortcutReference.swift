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

    /// The canvas, in the order you'd learn it. Gestures and keys are read from `Bindings`, so a
    /// rebound one shows here too.
    static var canvasRows: [Row] {
        let seeAll = gestureLine(for: .seeAll) ?? "—"
        let desktop = [Bindings.shortcut(for: .showDesktop)?.label, gestureLine(for: .showDesktop)]
            .compactMap { $0 }.joined(separator: " · ")
        let zoom = [Settings.canvasPinchEnabled ? "pinch" : nil,
                    Settings.canvasScrollBehavior == .zoom ? "two-finger scroll" : nil,
                    Settings.scrollZoomModifier == .none ? nil : "\(Settings.scrollZoomModifier.title) + scroll"].compactMap { $0 }.joined(separator: " · ")
        let pan = [Settings.canvasScrollBehavior == .pan ? "two-finger scroll" : nil,
                   gestureLine(for: .panCanvas)].compactMap { $0 }.joined(separator: " · ")
        return [
            Row(title: "Zoom", keys: zoom.isEmpty ? "—" : zoom),
            Row(title: "Pan", keys: pan.isEmpty ? "—" : pan),
            Row(title: "Drag a window", keys: Settings.windowDragAction.title),
            Row(title: "Flip a window's pole", keys: (Bindings.shortcut(for: .flipPolarity)?.label ?? "—") + " · its ⊕/⊖ button"),
            Row(title: "Single-click a window", keys: Settings.windowClickAction(double: false).title),
            Row(title: "Double-click a window", keys: Settings.windowClickAction(double: true).title),
            Row(title: "Enter a window", keys: "pinch in · " + (Bindings.shortcut(for: .enterWindow)?.label ?? "—")),
            Row(title: "Use a window at 1:1", keys: "click"),
            Row(title: "See everything", keys: seeAll),
            Row(title: "Canvas ↔ last window", keys: [Bindings.shortcut(for: .toggleCanvas)?.label, gestureLine(for: .toggleCanvas)].compactMap { $0 }.joined(separator: " · ")),
            Row(title: "Show Desktop", keys: desktop.isEmpty ? "—" : desktop),
            Row(title: "Switch apps", keys: "⌘Tab · then ⌘← ⌘→"),
            Row(title: "Switch the app's windows", keys: "⌘Tab, then ⌘` · ⌘↑ ⌘↓"),
        ]
    }

    /// Sunlight's own commands, leaving out the experimental ones that are off (`Settings.arranging`,
    /// `Settings.stripModeEnabled`).
    static var commandRows: [Row] {
        commandRows(arranging: Settings.arranging, strip: Settings.stripModeEnabled, tellSunlight: Settings.tellSunlight)
    }

    static func commandRows(arranging: Bool, strip: Bool, tellSunlight: Bool = false) -> [Row] {
        var rows = [
            Row(title: "Save Layout…", keys: Bindings.shortcut(for: .saveLayout)?.label ?? "—"),
            Row(title: "Restore a layout", keys: Bindings.summary(Command.layoutCommands, default: "⌘1 – ⌘9")),
        ]
        if arranging {
            rows += [
                Row(title: "Tidy", keys: TileMenu.tidyKeysSummary),
                Row(title: "Arrange the screen in columns", keys: TileMenu.arrangeKeysSummary),
            ]
        }
        rows.append(Row(title: "Move & Resize a window", keys: TileMenu.tileKeysSummary))
        rows.append(Row(title: "Picture in Picture", keys: (Bindings.shortcut(for: .pictureInPicture)?.label ?? "—") + " · right-click"))
        if strip {
            let key = Bindings.shortcut(for: .toggleStrip)?.label ?? "—"
            rows.append(Row(title: "Strip mode on or off", keys: key + " · then the arrows step"))
        }
        if tellSunlight { rows.append(Row(title: "Tell Sunlight", keys: Bindings.shortcut(for: .tellSunlight)?.label ?? "—")) }
        let desktop = [Bindings.shortcut(for: .showDesktop)?.label, gestureLine(for: .showDesktop)]
            .compactMap { $0 }.joined(separator: " · ")
        rows += [
            Row(title: "Show Desktop", keys: desktop.isEmpty ? "—" : desktop),
            Row(title: "Settings…", keys: Bindings.shortcut(for: .settings)?.label ?? "—"),
        ]
        return rows
    }

    /// The gesture that does a command now, in the words the Trackpad pane uses.
    private static func gestureLine(for command: Command) -> String? {
        Bindings.gesture(doing: command)?.how.lowercased()
    }
}
