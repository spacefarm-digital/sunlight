import AppKit
import ApplicationServices

/// Asks a running app for a new window by pressing its own menu item through Accessibility, without
/// bringing it forward, as Move & Resize is pressed (`NativeTiling`). Open Here… uses it for an app
/// that already has windows, where a reopen event would only bring one of them back.
enum NewWindowMenu {
    /// What a menu item offers, as far as picking one goes.
    struct Item: Equatable {
        var title: String
        /// AXMenuItemCmdChar, upper-cased; nil without a shortcut.
        var key: String?
        /// ⌘ and no other modifier (AXMenuItemCmdModifiers 0).
        var commandOnly: Bool
        var enabled: Bool
        var hasSubmenu: Bool
    }

    /// The item to press, best first: ⌘N that says it's a window ("New Window", "New Finder Window",
    /// Terminal's "New Window with Profile"), then an item named New Window, then any ⌘N (a new
    /// document, which is a window in most apps). Pure, for tests.
    static func best(_ items: [Item]) -> Int? {
        let usable = items.indices.filter { items[$0].enabled && !items[$0].hasSubmenu }
        let commandN = usable.filter { items[$0].key == "N" && items[$0].commandOnly }
        if let i = commandN.first(where: { items[$0].title.localizedCaseInsensitiveContains("window") }) { return i }
        if let i = usable.first(where: { items[$0].title.caseInsensitiveCompare("New Window") == .orderedSame }) { return i }
        return commandN.first
    }

    /// ⌘N itself, when its item says it makes a window (Finder's New Finder Window, Safari's New Window),
    /// not a new note or message that may not. Some apps' items don't say their modifiers right (Finder's
    /// all read as more than ⌘ on macOS 27): when no N item reads as ⌘ alone, the first N item is taken
    /// to be ⌘N's, as menus list ⌘N before ⇧⌘N, and counts only if it says window. Pure, for tests.
    static func windowCommandN(_ items: [Item]) -> Int? {
        let n = items.indices.filter { items[$0].enabled && !items[$0].hasSubmenu && items[$0].key == "N" }
        let plain = n.filter { items[$0].commandOnly }
        let candidates = plain.isEmpty ? Array(n.prefix(1)) : plain
        return candidates.first { items[$0].title.localizedCaseInsensitiveContains("window") }
    }

    /// Presses the app's new-window item (`pick`, `best` unless asked otherwise). Call off the main thread:
    /// every step is a round trip to the app. False if it has no such item or the press didn't go through.
    static func press(pid: pid_t, pick: ([Item]) -> Int? = NewWindowMenu.best) -> Bool {
        guard let menu = items(pid: pid), let i = pick(menu.items) else { return false }
        Log.note("Open Here: pressing “\(menu.items[i].title)”")
        return AXUIElementPerformAction(menu.elements[i], kAXPressAction as CFString) == .success
    }

    /// Whether the app's ⌘N makes a window (`windowCommandN`). Off the main thread, as `press`.
    static func commandNMakesWindow(pid: pid_t) -> Bool {
        guard let menu = items(pid: pid) else {
            Log.note("New window: pid \(pid)'s menu bar couldn't be read")
            return false
        }
        if let i = windowCommandN(menu.items) { Log.note("New window: pid \(pid)'s ⌘N is “\(menu.items[i].title)”"); return true }
        let n = menu.items.filter { $0.key == "N" }.map { "“\($0.title)” ⌘only \($0.commandOnly) enabled \($0.enabled)" }
        Log.note("New window: pid \(pid): \(menu.items.count) menu items, none a window's ⌘N; N items: \(n)")
        return false
    }

    /// The app's menu items that could open a window, with their elements.
    private static func items(pid: pid_t) -> (elements: [AXUIElement], items: [Item])? {
        let app = AXWindow.application(pid, timeout: 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let bar = ref as! AXUIElement
        var elements: [AXUIElement] = []
        var items: [Item] = []
        func collect(_ menu: AXUIElement, depth: Int) {
            for element in menu.children {
                let title = element.string(kAXTitleAttribute) ?? ""
                let submenu = element.children.first
                elements.append(element)
                items.append(Item(title: title,
                                  key: element.string(kAXMenuItemCmdCharAttribute)?.uppercased(),
                                  // No modifiers attribute is ⌘ alone too (its default).
                                  commandOnly: (element.int(kAXMenuItemCmdModifiersAttribute) ?? 0) == 0,
                                  enabled: element.bool(kAXEnabledAttribute),
                                  hasSubmenu: submenu != nil))
                // Terminal's New Window is a submenu of profiles; ⌘N is the default one inside it.
                if depth == 0, let submenu, title.localizedCaseInsensitiveContains("window") {
                    collect(submenu, depth: 1)
                }
            }
        }
        // The Apple menu first, and nothing there opens a window.
        for barItem in bar.children.dropFirst() {
            for menu in barItem.children { collect(menu, depth: 0) }
        }
        return (elements, items)
    }
}
