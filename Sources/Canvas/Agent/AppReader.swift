import AppKit
import ApplicationServices

/// Tell Sunlight's hands inside apps: it reads a window's accessibility tree and acts on its elements
/// directly, with the Accessibility permission Sunlight already has for moving windows. Nothing here moves
/// the pointer or sends a key, so it works wherever a window sits on the canvas, zoomed or lifted above the
/// other windows, and a click can never land on the canvas instead of the app.
///
/// Every call is a round trip to the app. Callers run all of it on Tell Sunlight's own AX queue (`AppReader.off`),
/// never the main thread, and reads stop at a node budget and a deadline, so a slow or huge app costs one
/// step, not the canvas.
enum AppReader {
    /// An `AXUIElement` to carry across queues: an immutable token, safe to use from any thread.
    struct Handle: @unchecked Sendable {
        let element: AXUIElement
    }

    /// Runs `work` on the Accessibility queue and hands back its result.
    static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Its own queue: a big read can take seconds, and the canvas's own AX work (`AXQueue.interactive`,
    /// the user's clicks and closes) mustn't wait behind it.
    private static let queue = DispatchQueue(label: "sunlight.tell.ax", qos: .userInitiated)

    // MARK: Reading

    /// One element as read: plain data, so what the tree shows is testable without an app.
    struct Node {
        var role = ""
        var subrole = ""
        var title = ""
        var label = ""
        var value = ""
        var placeholder = ""
        var enabled = true
        var focused = false
        var selected = false
        var expanded: Bool?
        var checked: Bool?
        /// The tooltip: the only words an icon-only button (a paper plane, a bin) may have.
        var help = ""
        /// Has a press action though its role doesn't say so (a clickable group or cell on a web page).
        var pressable = false
        var children: [Node] = []
        /// The element's index in `Read.handles`.
        var index = -1
    }

    struct Read: @unchecked Sendable {
        var root: Node
        var handles: [Handle]
        /// The budget or the deadline ran out before the whole tree was read.
        var truncated: Bool
    }

    /// AXRole … AXChildren, read in one round trip per element.
    private static let attributes = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXPlaceholderValue",
                                     "AXEnabled", "AXFocused", "AXSelected", "AXExpanded", "AXChildren", "AXHelp"]
    /// Roles whose press action is worth one more round trip to ask about.
    private static let maybePressable: Set<String> = ["AXGroup", "AXCell", "AXImage", "AXGenericElement"]

    /// The tree under `root`, depth first, up to `maxNodes` elements or `deadline`.
    static func read(_ root: AXUIElement, maxNodes: Int = 2500, maxDepth: Int = 40, deadline: Date) -> Read {
        var handles: [Handle] = []
        var truncated = false
        let names = attributes as CFArray
        func visit(_ element: AXUIElement, depth: Int) -> Node {
            var node = Node()
            node.index = handles.count
            handles.append(Handle(element: element))
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == attributes.count else { return node }
            func string(_ i: Int) -> String { values[i] as? String ?? "" }
            func flag(_ i: Int) -> Bool? {
                guard CFGetTypeID(values[i]) == CFBooleanGetTypeID() else { return nil }
                return CFBooleanGetValue((values[i] as! CFBoolean))
            }
            node.role = string(0)
            node.subrole = string(1)
            node.title = string(2)
            node.label = string(3)
            if node.subrole != "AXSecureTextField" {
                if let s = values[4] as? String {
                    node.value = s
                } else if CFGetTypeID(values[4]) == CFNumberGetTypeID(), let n = values[4] as? NSNumber {
                    if ["AXCheckBox", "AXRadioButton"].contains(node.role) || node.subrole == "AXSwitch" {
                        node.checked = n.intValue == 1
                    } else {
                        node.value = n.stringValue
                    }
                }
            }
            node.placeholder = string(5)
            node.enabled = flag(6) ?? true
            node.focused = flag(7) ?? false
            node.selected = flag(8) ?? false
            node.expanded = flag(9)
            node.help = string(11)
            if maybePressable.contains(node.role) {
                node.pressable = element.actions.contains("AXPress")
            }
            guard let children = values[10] as? [AXUIElement], !children.isEmpty else { return node }
            guard depth < maxDepth else {
                truncated = true
                return node
            }
            if children.count > 300 { truncated = true }
            for child in children.prefix(300) {
                if handles.count >= maxNodes || Date() > deadline {
                    truncated = true
                    break
                }
                node.children.append(visit(child, depth: depth + 1))
            }
            return node
        }
        let tree = visit(root, depth: 0)
        return Read(root: tree, handles: handles, truncated: truncated)
    }

    /// Chromium and Electron apps build their page's accessibility tree only once asked to; Safari and
    /// native apps always have one. Asked once per app.
    static func exposeWebContent(pid: pid_t) {
        guard asked.insert(pid) else { return }
        let app = AXWindow.application(pid, timeout: 1)
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            Thread.sleep(forTimeInterval: 0.3)  // the tree is built asynchronously
        }
    }

    private final class Asked: @unchecked Sendable {
        private var pids: Set<pid_t> = []
        private let lock = NSLock()
        func insert(_ pid: pid_t) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pids.insert(pid).inserted
        }
    }
    private static let asked = Asked()

    // MARK: What the model sees

    /// What a ref stands for: what the checks read, and where the element is in the read.
    struct Target: Equatable {
        let role: String
        let name: String
        let secure: Bool
        let index: Int
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXMenuButton", "AXLink", "AXMenuItem", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXRow",
        "AXColorWell", "AXDateField", "AXTimeField", "AXStepper", "AXSearchField",
    ]
    /// Containers that get a ref too: to scroll, choose in, or read as text.
    static let regionRoles: Set<String> = [
        "AXWindow", "AXSheet", "AXWebArea", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXTabGroup",
        "AXRadioGroup", "AXBrowser",
    ]
    private static let shortRoles = [
        "AXPopUpButton": "popup", "AXComboBox": "combobox", "AXMenuButton": "menubutton", "AXTextField": "textfield",
        "AXTextArea": "textarea", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXStaticText": "text",
        "AXWebArea": "webarea", "AXScrollArea": "scrollarea", "AXDisclosureTriangle": "disclosure",
        "AXMenuItem": "menuitem", "AXTabGroup": "tabgroup", "AXRadioGroup": "radiogroup",
    ]

    /// "button", "textfield", "searchfield"…: the role as the model reads and asks for it.
    static func role(of node: Node) -> String {
        switch node.subrole {
        case "AXSearchField": return "searchfield"
        case "AXSecureTextField": return "securefield"
        case "AXTabButton": return "tab"
        case "AXSwitch": return "switch"
        default: break
        }
        if let short = shortRoles[node.role] { return short }
        return (node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)) : node.role).lowercased()
    }

    static func isInteractive(_ node: Node) -> Bool {
        interactiveRoles.contains(node.role) || node.subrole == "AXSearchField"
            || (node.pressable && !text(of: node, limit: 80).isEmpty)
    }

    /// What a person would call the element: its title, its label, its text, or what its field asks for.
    static func name(of node: Node) -> String {
        let own = [node.title, node.label, ["AXStaticText", "AXHeading"].contains(node.role) ? node.value : ""]
            .map(clean).first { !$0.isEmpty }
        if let own { return clip(own, 160) }
        // A link or button often carries its words in a text child instead.
        if isInteractive(node) || node.role == "AXHeading", !node.children.isEmpty {
            let inner = text(of: node, limit: 160)
            if !inner.isEmpty { return inner }
        }
        let asked = clean(node.placeholder)
        return clip(asked.isEmpty && isInteractive(node) ? clean(node.help) : asked, 160)
    }

    /// The tree as JSON for the model: interactive elements and regions with refs `@<id>:e<n>`, headings for
    /// orientation, and nothing else (read text with `text(of:)`). Wrappers with one child are skipped.
    static func render(_ root: Node, id: String) -> (tree: [String: Any], refs: [String: Target]) {
        var refs: [String: Target] = [:]
        var count = 0
        func emit(_ node: Node, isRoot: Bool) -> [String: Any]? {
            let interactive = isInteractive(node)
            if !interactive && !isRoot && !regionRoles.contains(node.role) {
                if node.role == "AXHeading" {
                    let heading = name(of: node)
                    return heading.isEmpty ? nil : ["role": "heading", "name": heading]
                }
                let kids = node.children.compactMap { emit($0, isRoot: false) }
                let label = clip(clean(node.title.isEmpty ? node.label : node.title), 160)
                if kids.isEmpty { return nil }
                if kids.count == 1 && label.isEmpty { return kids[0] }
                var out: [String: Any] = ["role": role(of: node), "children": kids]
                if !label.isEmpty { out["name"] = label }
                return out
            }
            count += 1
            let ref = "@\(id):e\(count)"
            let r = role(of: node)
            let n = name(of: node)
            refs[ref] = Target(role: r, name: n, secure: node.subrole == "AXSecureTextField", index: node.index)
            var out: [String: Any] = ["ref": ref, "role": r]
            if !n.isEmpty { out["name"] = n }
            if showsValue(node), !node.value.isEmpty { out["value"] = clip(node.value, 200) }
            let s = states(of: node)
            if !s.isEmpty { out["states"] = s }
            // A control's own parts (a link's text, a button's image) say nothing more.
            if !interactive || node.role == "AXRow" {
                let kids = node.children.compactMap { emit($0, isRoot: false) }
                if !kids.isEmpty { out["children"] = kids }
            }
            return out
        }
        let tree = emit(root, isRoot: true) ?? [:]
        return (tree, refs)
    }

    /// Elements matching a role and words of a name, in reading order, up to `limit`.
    static func find(_ root: Node, id: String, role wanted: String, name query: String,
                     limit: Int) -> (matches: [[String: Any]], refs: [String: Target]) {
        let wantedRole = wanted.lowercased().trimmingCharacters(in: .whitespaces)
        let words = Guardrails.words(query)
        var matches: [[String: Any]] = []
        var refs: [String: Target] = [:]
        func walk(_ node: Node) {
            guard matches.count < limit else { return }
            let r = role(of: node)
            let candidate = isInteractive(node) || regionRoles.contains(node.role)
                || (!wantedRole.isEmpty && (r == wantedRole || node.role.lowercased() == "ax" + wantedRole))
            if candidate {
                let n = name(of: node)
                let roleOK = wantedRole.isEmpty || r == wantedRole || node.role.lowercased() == "ax" + wantedRole
                    || (wantedRole == "textfield" && ["searchfield", "textarea", "combobox"].contains(r))
                let haystack = " " + Guardrails.words(n + " " + node.value + " " + node.placeholder + " " + node.label) + " "
                let nameOK = words.isEmpty || words.split(separator: " ").allSatisfy { haystack.contains(" \($0)") }
                if roleOK && nameOK {
                    let ref = "@\(id):e\(matches.count + 1)"
                    refs[ref] = Target(role: r, name: n, secure: node.subrole == "AXSecureTextField", index: node.index)
                    var out: [String: Any] = ["ref": ref, "role": r]
                    if !n.isEmpty { out["name"] = n }
                    if showsValue(node), !node.value.isEmpty { out["value"] = clip(node.value, 200) }
                    let s = states(of: node)
                    if !s.isEmpty { out["states"] = s }
                    matches.append(out)
                }
            }
            node.children.forEach(walk)
        }
        walk(root)
        return (matches, refs)
    }

    /// The words a person reads in a part of the window, in order, one piece per line.
    static func text(of node: Node, limit: Int) -> String {
        var pieces: [String] = []
        var length = 0
        func walk(_ node: Node) {
            guard length < limit else { return }
            var piece = ""
            switch node.role {
            case "AXStaticText": piece = node.value.isEmpty ? node.title : node.value
            case "AXTextField", "AXTextArea", "AXComboBox": piece = node.subrole == "AXSecureTextField" ? "" : node.value
            case "AXImage": piece = node.children.isEmpty ? node.label : ""
            default: if node.children.isEmpty { piece = node.title.isEmpty ? node.label : node.title }
            }
            let cleaned = clean(piece)
            if !cleaned.isEmpty, pieces.last != cleaned {
                pieces.append(cleaned)
                length += cleaned.count + 1
            }
            node.children.forEach(walk)
        }
        walk(node)
        let joined = pieces.joined(separator: limit <= 200 ? " " : "\n")
        return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
    }

    private static func showsValue(_ node: Node) -> Bool {
        node.subrole != "AXSecureTextField"
            && ["AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXSlider", "AXIncrementor",
                "AXDateField", "AXTimeField", "AXMenuButton"].contains(node.role)
    }

    static func states(of node: Node) -> [String] {
        var s: [String] = []
        if !node.enabled { s.append("disabled") }
        if node.focused { s.append("focused") }
        if node.selected { s.append("selected") }
        if let checked = node.checked { s.append(checked ? "checked" : "unchecked") }
        if let expanded = node.expanded, node.role != "AXWindow" { s.append(expanded ? "expanded" : "collapsed") }
        return s
    }

    /// One line: runs of whitespace one space.
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    /// `@s8f3k2p9:e12` → `s8f3k2p9`. Nil for anything else.
    static func snapshotID(ofRef ref: String) -> String? {
        guard ref.hasPrefix("@"), let colon = ref.firstIndex(of: ":") else { return nil }
        let id = ref[ref.index(after: ref.startIndex)..<colon]
        let element = ref[ref.index(after: colon)...]
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }),
              element.first == "e", element.count > 1, element.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return String(id)
    }

    static func newSnapshotID() -> String {
        String((0..<8).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! })
    }

    // MARK: Acting

    /// What an action did, in a sentence for the model, or why it couldn't.
    struct Outcome: Sendable {
        let ok: Bool
        let message: String
    }

    /// Return pressed in the field: focused, then a key down and up posted to its app's process.
    static func pressReturn(in e: AXUIElement) -> Outcome {
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success, pid > 0 else {
            return Outcome(ok: false, message: "Couldn't reach this field's app. Look for the app's Go, Search or Send button.")
        }
        // The key goes to whatever has focus in the app: only once it's this field, or Return could land
        // in a message box the user wasn't asked about.
        _ = e.axSet("AXFocused", kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, "AXFocused" as CFString, &focused) == .success,
              let isFocused = focused as? Bool, isFocused else {
            return Outcome(ok: false, message: "This field has no Return action and couldn't be focused to press Return in. Look for the app's Go, Search or Send button.")
        }
        let source = CGEventSource(stateID: .privateState)
        let returnKey: CGKeyCode = 0x24
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            return Outcome(ok: false, message: "Couldn't make a Return key. Look for the app's Go, Search or Send button.")
        }
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(pid)
        return Outcome(ok: true, message: "This field has no Return action, so a Return key was sent to the app with the field focused. Check that it took (the page or view should change); if not, use the app's Go, Search or Send button.")
    }

    /// Carries out `action` on the element. Blocking; call it through `off`.
    static func perform(_ action: String, on handle: Handle, text: String) -> Outcome {
        let e = handle.element
        switch action {
        case "click":
            let names = e.actions
            for name in ["AXPress", "AXConfirm", "AXPick", "AXOpen"] where names.contains(name) {
                return result(e.axPerform(name), "Pressed it.")
            }
            if e.axSettable("AXSelected") { return result(e.axSet("AXSelected", kCFBooleanTrue), "Selected it.") }
            if names.contains("AXShowMenu") { return result(e.axPerform("AXShowMenu"), "Opened its menu.") }
            // Web content doesn't always list the press it takes (Safari, while a page is still loading).
            if e.axPerform("AXPress") == .success { return Outcome(ok: true, message: "Pressed it.") }
            return Outcome(ok: false, message: "This element has no press action. Try its button, link or row instead.")
        case "confirm":
            if e.actions.contains("AXConfirm"), e.axPerform("AXConfirm") == .success {
                return Outcome(ok: true, message: "Confirmed it, as Return would.")
            }
            // Fields without a Return action (Chrome's address bar): a Return key sent to the app itself,
            // with the field focused. It goes to the process, not through the screen, so the canvas
            // and the user's pointer don't come into it.
            return pressReturn(in: e)
        case "set_value":
            _ = e.axSet("AXFocused", kCFBooleanTrue)
            let error = e.axSet("AXValue", text as CFString)
            guard error == .success else { return result(error, "") }
            let now = e.string("AXValue") ?? text
            return now == text ? Outcome(ok: true, message: "The field now reads the new text.")
                : Outcome(ok: true, message: "Set it; the field now reads: \(clip(clean(now), 200))")
        case "type":
            _ = e.axSet("AXFocused", kCFBooleanTrue)
            if e.axSettable("AXSelectedText"), e.axSet("AXSelectedText", text as CFString) == .success {
                return Outcome(ok: true, message: "Inserted the text at the cursor.")
            }
            return result(e.axSet("AXValue", ((e.string("AXValue") ?? "") + text) as CFString), "Added the text at the end of the field.")
        case "clear":
            return result(e.axSet("AXValue", "" as CFString), "Cleared it.")
        case "select":
            return select(e, text)
        case "check", "uncheck":
            let want = action == "check"
            if let now = e.axNumber("AXValue"), (now == 1) == want { return Outcome(ok: true, message: "It was already \(action)ed.") }
            return result(e.axPerform("AXPress"), want ? "Checked it." : "Unchecked it.")
        case "toggle":
            return result(e.axPerform("AXPress"), "Toggled it.")
        case "expand", "collapse":
            let flag = action == "expand" ? kCFBooleanTrue! : kCFBooleanFalse!
            for attribute in ["AXExpanded", "AXDisclosing"] where e.axSettable(attribute) {
                return result(e.axSet(attribute, flag), action == "expand" ? "Expanded it." : "Collapsed it.")
            }
            if let triangle = e.children.first(where: { $0.string("AXRole") == "AXDisclosureTriangle" }) {
                return result(triangle.axPerform("AXPress"), "Pressed its disclosure triangle.")
            }
            return result(e.axPerform("AXPress"), "Pressed it.")
        case "scroll_to":
            return result(e.axPerform("AXScrollToVisible"), "Scrolled it into view.")
        case "scroll_down", "scroll_up":
            return scroll(e, down: action == "scroll_down")
        case "focus":
            return result(e.axSet("AXFocused", kCFBooleanTrue), "Focused it.")
        default:
            return Outcome(ok: false, message: "Unknown action \(action).")
        }
    }

    /// The item a select would press needs the user's OK that wasn't asked for (they were asked about
    /// the words the model gave, which matched only part of it): refused, so it's chosen by its full name.
    static func unasked(_ item: String, _ option: String) -> Outcome? {
        guard Guardrails.needsConfirmation(action: "select", name: "", option: item),
              !Guardrails.needsConfirmation(action: "select", name: "", option: option) else { return nil }
        return Outcome(ok: false, message: "The item that matches is “\(clip(clean(item), 80))”, which needs the user's OK. Select it by that full name so they're asked.")
    }

    /// Opens a pop-up or menu button and picks the item, or selects the matching row or tab in a list.
    private static func select(_ e: AXUIElement, _ option: String) -> Outcome {
        let role = e.string("AXRole") ?? ""
        let wanted = Guardrails.words(option)
        func matches(_ s: String) -> Int {  // 2 exact, 1 contains, 0 not
            let w = Guardrails.words(s)
            return w == wanted ? 2 : (!wanted.isEmpty && (" " + w + " ").contains(" " + wanted + " ") ? 1 : 0)
        }
        if role == "AXComboBox", e.axSettable("AXValue"), e.axSet("AXValue", option as CFString) == .success {
            return Outcome(ok: true, message: "Set the box to “\(clip(option, 60))”.")
        }
        if ["AXPopUpButton", "AXMenuButton", "AXComboBox"].contains(role) {
            guard e.axPerform(e.actions.contains("AXPress") ? "AXPress" : "AXShowMenu") == .success else {
                return Outcome(ok: false, message: "The menu didn't open.")
            }
            Thread.sleep(forTimeInterval: 0.3)
            let items = e.children.filter { $0.string("AXRole") == "AXMenu" }.flatMap(\.children)
                .filter { $0.string("AXRole") == "AXMenuItem" }
            let titles = items.map { $0.string("AXTitle") ?? "" }
            if let best = zip(items, titles).map({ ($0, $1, matches($1)) }).filter({ $0.2 > 0 }).max(by: { $0.2 < $1.2 }) {
                if let refused = unasked(best.1, option) {
                    if let menu = e.children.first(where: { $0.string("AXRole") == "AXMenu" }) { _ = menu.axPerform("AXCancel") }
                    return refused
                }
                return result(best.0.axPerform("AXPress"), "Chose it.")
            }
            if let menu = e.children.first(where: { $0.string("AXRole") == "AXMenu" }) { _ = menu.axPerform("AXCancel") }
            return Outcome(ok: false, message: "No item matches. The options are: " + titles.filter { !$0.isEmpty }.prefix(40).joined(separator: ", "))
        }
        // A list, table, outline, tab group or radio group: its rows or buttons, a few levels down.
        var rows: [(AXUIElement, String)] = []
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth < 4, rows.count < 400 else { return }
            for child in element.children {
                let r = child.string("AXRole") ?? ""
                if ["AXRow", "AXRadioButton", "AXMenuItem", "AXButton", "AXCell"].contains(r) {
                    let read = AppReader.read(child, maxNodes: 40, maxDepth: 4, deadline: Date().addingTimeInterval(0.5))
                    rows.append((child, name(of: read.root).isEmpty ? text(of: read.root, limit: 160) : name(of: read.root)))
                } else {
                    collect(child, depth: depth + 1)
                }
            }
        }
        collect(e, depth: 0)
        guard let match = rows.map({ ($0.0, $0.1, matches($0.1)) }).filter({ $0.2 > 0 }).max(by: { $0.2 < $1.2 }) else {
            return Outcome(ok: false, message: "Nothing here matches. Choices: " + rows.map(\.1).filter { !$0.isEmpty }.prefix(40).joined(separator: ", "))
        }
        if let refused = unasked(match.1, option) { return refused }
        let best = match.0
        if best.axSettable("AXSelected") { return result(best.axSet("AXSelected", kCFBooleanTrue), "Selected it.") }
        return result(best.axPerform("AXPress"), "Chose it.")
    }

    /// Moves the scroll area the element is in by about a page.
    private static func scroll(_ e: AXUIElement, down: Bool) -> Outcome {
        var area: AXUIElement? = e
        for _ in 0..<12 where area.map({ $0.string("AXRole") != "AXScrollArea" }) ?? false {
            area = area?.parent
        }
        guard let area, area.string("AXRole") == "AXScrollArea" else {
            return Outcome(ok: false, message: "That isn't inside a scroll area. Pass a scrollarea or webarea ref.")
        }
        let page = down ? "AXScrollDownByPage" : "AXScrollUpByPage"
        if area.actions.contains(page), area.axPerform(page) == .success { return Outcome(ok: true, message: "Scrolled a page.") }
        guard let bar = area.element("AXVerticalScrollBar"), let now = bar.axNumber("AXValue") else {
            return Outcome(ok: false, message: "This area has no vertical scroll bar to move.")
        }
        let step = scrollStep(area: area)
        let next = min(1, max(0, now + (down ? step : -step)))
        guard next != now else { return Outcome(ok: true, message: down ? "It's already at the bottom." : "It's already at the top.") }
        return result(bar.axSet("AXValue", NSNumber(value: next)), "Scrolled; now \(Int((next * 100).rounded()))% of the way down.")
    }

    /// Most of a page, as a fraction of the scrollable range: visible height over content height.
    private static func scrollStep(area: AXUIElement) -> Double {
        guard let visible = area.frame?.height, visible > 0,
              let content = area.children.compactMap(\.frame).map(\.height).max(), content > visible else { return 0.2 }
        return min(1, 0.85 * visible / (content - visible))
    }

    private static func result(_ error: AXError, _ done: String) -> Outcome {
        switch error {
        case .success: return Outcome(ok: true, message: done)
        case .invalidUIElement: return Outcome(ok: false, message: "That element is gone; the window changed. Read it again.")
        case .cannotComplete: return Outcome(ok: false, message: "The app didn't answer in time. It may be busy; try once more.")
        case .actionUnsupported, .attributeUnsupported: return Outcome(ok: false, message: "This element doesn't support that.")
        case .illegalArgument: return Outcome(ok: false, message: "The app refused that value.")
        default: return Outcome(ok: false, message: "The app refused (accessibility error \(error.rawValue)).")
        }
    }
}

private extension AXUIElement {
    func axPerform(_ action: String) -> AXError { AXUIElementPerformAction(self, action as CFString) }

    func axSet(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    func axSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func axNumber(_ attribute: String) -> Double? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == CFNumberGetTypeID() || CFGetTypeID(ref) == CFBooleanGetTypeID() else { return nil }
        return (ref as? NSNumber)?.doubleValue
    }

    func element(_ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }
}
