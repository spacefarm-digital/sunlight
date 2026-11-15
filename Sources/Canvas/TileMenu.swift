import AppKit
import Carbon.HIToolbox

/// The placement commands and their keys, and the one menu section that lists them. Three scopes in
/// one ⌃⌥ layer: Move & Resize places one window (Rectangle's letters and arrows), Arrange the windows of
/// one screen (digits for columns), Tidy everything (A). The Window menu, a window's right-click menu,
/// the canvas's right-click menu and the menu bar's shortcuts menu are all built from here, in the same
/// order, so the set is the same wherever you look.
@MainActor
enum TileMenu {
    /// One placement command's untouched default key, as the tests and the explainer read them.
    struct PlacementKey {
        let preset: Tiling.Preset
        let keyCode: Int
        /// The same key as a menu key equivalent, so the menus show it.
        let key: String
    }

    static let modifiers: NSEvent.ModifierFlags = [.control, .option]
    static let carbonModifiers = UInt32(controlKey | optionKey)

    /// The key equivalents a menu item shows, from Settings › Shortcuts. A command with no key (or a
    /// rebound one) gets exactly that; nothing here is hard-wired any more.
    static func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.cocoaModifiers ?? []
    }

    private static func arrow(_ code: Int) -> String { String(UnicodeScalar(UInt16(code)).map(Character.init) ?? " ") }

    /// The defaults, for the tests and for anything that needs the untouched set. The menus read
    /// `Bindings`, so a key changed in Settings shows changed everywhere.
    static let shortcuts: [PlacementKey] = Command.tiles.compactMap { command in
        guard let preset = command.preset, let shortcut = command.defaultShortcut else { return nil }
        return PlacementKey(preset: preset, keyCode: Int(shortcut.keyCode), key: shortcut.key)
    }

    /// Arrange: the windows of one screen in columns (⌃⌥ with the digit) or a grid.
    struct Arrangement {
        let columns: Int
        let rows: Int
        let keyCode: Int?
        let key: String

        var title: String { rows == 1 ? "\(columns) Columns" : "\(columns)×\(rows)" }
    }

    static let arrangements: [Arrangement] = [
        Arrangement(columns: 2, rows: 1, keyCode: kVK_ANSI_2, key: "2"),
        Arrangement(columns: 3, rows: 1, keyCode: kVK_ANSI_3, key: "3"),
        Arrangement(columns: 4, rows: 1, keyCode: kVK_ANSI_4, key: "4"),
        Arrangement(columns: 2, rows: 2, keyCode: nil, key: ""),
        Arrangement(columns: 3, rows: 2, keyCode: nil, key: ""),
    ]

    /// Tidy: everything, ⌃⌥A.
    static let tidyKeyCode = kVK_ANSI_A
    static let tidyKey = "a"

    /// A window to the next display (⌃⌥⇧→) or the previous one (⌃⌥⇧←), with more than one display.
    static let displayModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
    static let displayCarbonModifiers = UInt32(controlKey | optionKey | shiftKey)

    /// Strip mode on and off, ⌃⌥S. While it's on, ⌃⌥ ← → ↑ ↓ step along the strip instead of tiling.
    static let stripKeyCode = kVK_ANSI_S
    static let stripKey = "s"
    /// ⌃⌥P: the window into Picture in Picture, or out of it (`PictureInPicture`), from the canvas or from inside it.
    static let pipKeyCode = kVK_ANSI_P
    static let pipKey = "p"

    /// The keys as the explainer and the shortcuts menu show them, as Settings › Shortcuts has them now.
    static var tileKeysSummary: String {
        Bindings.summary(Command.tiles, default: "⌃⌥ ← → ↑ ↓ · U I J K · D F G · E T · ⏎ C")
    }
    static var arrangeKeysSummary: String {
        Bindings.summary([.arrange2, .arrange3, .arrange4], default: "⌃⌥ 2 · 3 · 4")
    }
    static var tidyKeysSummary: String {
        Bindings.summary([.tidy], default: "⌃⌥A")
    }

    private static let sections: [[Tiling.Preset]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.leftThird, .centerThird, .rightThird, .leftTwoThirds, .centerTwoThirds, .rightTwoThirds],
        [.full, .center],
    ]

    /// What the placement items call on their target. Each item's `representedObject`: Tidy By an
    /// `Tidy.Order` raw value, Arrange `[columns, rows]`, Move & Resize whatever `represent` gives.
    struct Actions {
        var tidy: Selector
        var tidyBy: Selector
        var arrange: Selector
        var tile: Selector?
    }

    /// The placement section: Tidy, Tidy By ›, Arrange ›, Move & Resize ›, in scope order, everything to
    /// one window. Without `represent` there's no Move & Resize (the canvas's own menu has no window to move).
    /// Without arranging (`arranging`, else the experimental flag `Settings.arranging`) only Move & Resize.
    static func placementItems(target: AnyObject?, actions: Actions, represent: ((Tiling.Preset) -> Any)? = nil,
                               arranging: Bool? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if arranging ?? Settings.arranging {
            let tidy = NSMenuItem(title: "Tidy", action: actions.tidy, keyEquivalent: "")
            apply(Bindings.shortcut(for: .tidy), to: tidy)
            tidy.target = target
            let tidyBy = NSMenuItem(title: "Tidy By", action: nil, keyEquivalent: "")
            tidyBy.submenu = tidyByMenu(target: target, action: actions.tidyBy)
            let arrange = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
            arrange.submenu = arrangeMenu(target: target, action: actions.arrange)
            items = [tidy, tidyBy, arrange]
        }
        if let represent, let tile = actions.tile {
            let moveAndResize = NSMenuItem(title: "Move & Resize", action: nil, keyEquivalent: "")
            moveAndResize.submenu = build(target: target, action: tile, represent: represent)
            items.append(moveAndResize)
        }
        return items
    }

    /// Every preset in sections, each with its shortcut shown. `represent` gives each item's
    /// `representedObject`.
    static func build(target: AnyObject?, action: Selector, represent: (Tiling.Preset) -> Any) -> NSMenu {
        let menu = NSMenu(title: "Move & Resize")
        for (i, section) in sections.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for preset in section {
                let item = NSMenuItem(title: preset.title, action: action, keyEquivalent: "")
                if let command = Command.tile(preset) { apply(Bindings.shortcut(for: command), to: item) }
                item.target = target
                item.representedObject = represent(preset)
                item.image = picture(of: preset)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// The arrangements, columns first with their digits, then the grids.
    static func arrangeMenu(target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Arrange")
        for (i, a) in arrangements.enumerated() {
            if i > 0, a.rows > 1, arrangements[i - 1].rows == 1 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: a.title, action: action, keyEquivalent: "")
            let command: Command? = switch (a.columns, a.rows) {
            case (2, 1): .arrange2
            case (3, 1): .arrange3
            case (4, 1): .arrange4
            default: nil
            }
            if let command { apply(Bindings.shortcut(for: command), to: item) }
            item.target = target
            item.representedObject = [a.columns, a.rows]
            item.image = picture(Tiling.cells(columns: a.columns, rows: a.rows), litAll: true)
            menu.addItem(item)
        }
        return menu
    }

    /// The orders, the current one checked each time the menu opens (`Settings.tidyOrder`). Choosing one
    /// tidies by it and remembers it.
    static func tidyByMenu(target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Tidy By")
        for order in Tidy.Order.allCases {
            let item = NSMenuItem(title: order.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = order.rawValue
            menu.addItem(item)
        }
        menu.delegate = tidyByChecks
        return menu
    }

    private static let tidyByChecks = TidyByChecks()

    private final class TidyByChecks: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items {
                item.state = (item.representedObject as? String) == Settings.tidyOrder.rawValue ? .on : .off
            }
        }
    }

    // MARK: Pictures

    /// A preset as macOS's Move & Resize menu draws it: a little screen with the slot filled. Centre,
    /// which keeps the window's size, is a smaller window in the middle.
    static func picture(of preset: Tiling.Preset) -> NSImage {
        picture([preset.unit ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)])
    }

    /// A screen outline with each unit cell filled: the first solid and the others faint, or all solid
    /// with `litAll` (an arrangement, where every window is placed alike). A template image, so the
    /// menu tints it, white on the highlighted row.
    static func picture(_ cells: [CGRect], litAll: Bool = false, size: CGSize = CGSize(width: 22, height: 15)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { bounds in
            let screen = bounds.insetBy(dx: 1, dy: 1)
            let frame = NSBezierPath(roundedRect: screen.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = 1
            NSColor.black.setStroke()
            frame.stroke()
            let inner = screen.insetBy(dx: 2, dy: 2)
            for (i, cell) in cells.enumerated() {
                let r = CGRect(x: inner.minX + cell.minX * inner.width, y: inner.minY + cell.minY * inner.height,
                               width: cell.width * inner.width, height: cell.height * inner.height).insetBy(dx: 0.5, dy: 0.5)
                NSColor.black.withAlphaComponent(i == 0 || litAll ? 1 : 0.35).setFill()
                NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Parsing what an item carries

    static func order(of item: NSMenuItem) -> Tidy.Order? {
        (item.representedObject as? String).flatMap(Tidy.Order.init(rawValue:))
    }

    static func arrangement(of item: NSMenuItem) -> (columns: Int, rows: Int)? {
        guard let size = item.representedObject as? [Int], size.count == 2 else { return nil }
        return (size[0], size[1])
    }
}
