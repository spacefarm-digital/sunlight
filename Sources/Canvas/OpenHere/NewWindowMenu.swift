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

    /// Whether the app's ⌘N makes a window (`windowCommandN`), or nil if its menu bar couldn't be read (an
    /// app still launching, or busy). Off the main thread, as `press`.
    static func commandNMakesWindow(pid: pid_t) -> Bool? {
        guard let menu = items(pid: pid) else {
            Log.note("New window: pid \(pid)'s menu bar couldn't be read")
            return nil
        }
        if let i = windowCommandN(menu.items) { Log.note("New window: pid \(pid)'s ⌘N is “\(menu.items[i].title)”"); return true }
        let n = menu.items.filter { $0.key == "N" }.map { "“\($0.title)” ⌘only \($0.commandOnly) enabled \($0.enabled)" }
        Log.note("New window: pid \(pid): \(menu.items.count) menu items, none a window's ⌘N; N items: \(n)")
        return false
    }

    /// What `items` reads of each menu item, in one round trip to the app (`read`).
    private static let attributes = [kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
                                     kAXEnabledAttribute, kAXChildrenAttribute]

    /// A menu item and its submenu, if it has one. All five attributes in one question to the app where
    /// it answers that way: a menu bar is a few hundred items, and five questions each was most of the
    /// time the scan took. One at a time where it doesn't.
    private static func read(_ element: AXUIElement) -> (item: Item, submenu: AXUIElement?) {
        var raw: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw) == .success,
           let values = raw as? [AnyObject], values.count == attributes.count {
            // A missing attribute comes back as an error value, which is none of the types asked for.
            let modifiers = CFGetTypeID(values[2]) == CFNumberGetTypeID() ? (values[2] as? NSNumber)?.intValue : nil
            let enabled = CFGetTypeID(values[3]) == CFBooleanGetTypeID() && CFBooleanGetValue((values[3] as! CFBoolean))
            let submenu = (values[4] as? [AXUIElement])?.first
            return (Item(title: values[0] as? String ?? "",
                         key: (values[1] as? String)?.uppercased(),
                         // No modifiers attribute is ⌘ alone too (its default).
                         commandOnly: (modifiers ?? 0) == 0,
                         enabled: enabled,
                         hasSubmenu: submenu != nil), submenu)
        }
        let submenu = element.children.first
        return (Item(title: element.string(kAXTitleAttribute) ?? "",
                     key: element.string(kAXMenuItemCmdCharAttribute)?.uppercased(),
                     commandOnly: (element.int(kAXMenuItemCmdModifiersAttribute) ?? 0) == 0,
                     enabled: element.bool(kAXEnabledAttribute),
                     hasSubmenu: submenu != nil), submenu)
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
                let (item, submenu) = read(element)
                elements.append(element)
                items.append(item)
                // Terminal's New Window is a submenu of profiles; ⌘N is the default one inside it.
                if depth == 0, let submenu, item.title.localizedCaseInsensitiveContains("window") {
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

/// What each app's ⌘N does, as its menu bar last said (`NewWindowMenu.commandNMakesWindow`), and for
/// how long that is taken as read. The menu bar used to be read on every entry into a window (1,600
/// times in three days, a few hundred items each); an app's ⌘N doesn't change from one ⌘Tab to the next.
struct CommandNMemory {
    /// How long an answer stands before the menu is read again on the next entry.
    static let keepFor: TimeInterval = 600
    /// An app whose answer may not be its last word (it is still starting up) is asked again this soon.
    static let unsettledFor: TimeInterval = 10

    private struct Answer {
        var makes: Bool
        var until: TimeInterval
    }
    private var answers: [pid_t: Answer] = [:]

    /// The last answer for the app, however old; nil if it was never read.
    func makes(_ pid: pid_t) -> Bool? { answers[pid]?.makes }

    /// Whether the app's menu is due a read.
    func needsReading(_ pid: pid_t, now: TimeInterval) -> Bool {
        guard let answer = answers[pid] else { return true }
        return now >= answer.until
    }

    /// The menu was read. `makes` nil if it couldn't be: the last answer stands, and it is read again
    /// next time. `settled` false for an app that started moments ago, whose menus may not all be there.
    /// Returns the answer before this one.
    @discardableResult
    mutating func note(_ pid: pid_t, makes: Bool?, settled: Bool, now: TimeInterval) -> Bool? {
        let before = answers[pid]?.makes
        guard let makes else {
            answers[pid]?.until = now
            return before
        }
        answers[pid] = Answer(makes: makes, until: now + (settled ? Self.keepFor : Self.unsettledFor))
        return before
    }

    /// ⌘N was pressed, and whatever it did may have changed the menu (a sheet up): read on the next entry.
    mutating func readAgain(_ pid: pid_t) {
        answers[pid]?.until = 0
    }

    /// The app quit: its number may be another app's next.
    mutating func forget(_ pid: pid_t) {
        answers[pid] = nil
    }
}
