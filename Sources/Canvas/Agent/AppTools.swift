import AppKit

/// What Tell Sunlight can do inside apps: read a window's accessibility tree and act on its elements
/// (`AppReader`), never with the pointer or the keyboard. Windows are moved, opened and closed only by
/// the canvas tools.
///
/// Enforced here, whatever the model asks: an element is acted on only from a snapshot Sunlight took of a
/// window on the canvas; apps on `Guardrails.blockedApps` are never worked inside; password fields are
/// never read or typed into; a press on a control that sends, deletes, pays or publishes
/// (`Guardrails.needsConfirmation`) waits for the user's Allow.
@MainActor
final class AppTools {
    let desk: Desk
    /// Asks the user to allow a step, in the bar; true if allowed.
    var confirm: ((String) async -> Bool)?
    /// "Working in Slack", for the bar, as the work moves to a window.
    var onWindow: ((String) -> Void)?
    /// Shows each step on screen (its own pointer, a ripple on a press); nil or off, nothing is drawn.
    var presence: AgentPresence?

    /// The snapshots taken this request: which window each was of, and its elements by ref.
    private struct Snapshot {
        let window: CanvasController.AgentWindow
        var elements: [String: (target: AppReader.Target, handle: AppReader.Handle)]
    }
    private var snapshots: [String: Snapshot] = [:]
    private var lastWindow: CGWindowID?

    init(desk: Desk) {
        self.desk = desk
    }

    static let actions = ["click", "confirm", "set_value", "type", "clear", "select", "check", "uncheck", "toggle",
                          "expand", "collapse", "scroll_to", "scroll_down", "scroll_up", "focus"]

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]]) -> [String: Any] {
            ["name": name, "description": description, "strict": true,
             "input_schema": ["type": "object", "properties": properties, "required": properties.keys.sorted(),
                              "additionalProperties": false] as [String: Any]]
        }
        let windowID: [String: Any] = ["type": "integer", "description": "A window's id from list_windows."]
        return [
            tool("app_snapshot", "Read a window's controls (its accessibility tree) as JSON: buttons, links, fields, lists and regions like webarea and scrollarea, with headings for orientation. Each has a ref like @s8f3k2p9:e12. It doesn't include body text: to read what a page or document says, app_read a region's ref with property text. After anything changes in the window, snapshot again. For a dense window, pass a region's ref as root_ref to read just that part.",
                 ["window_id": windowID,
                  "root_ref": ["type": "string", "description": "A ref from an earlier snapshot of this window to read only that region, or \"\" for the whole window."]]),
            tool("app_find", "Find elements in a window by role and/or words of their name, label or value. Quicker than a snapshot when you know what you're after. Returns refs.",
                 ["window_id": windowID,
                  "role": ["type": "string", "description": "e.g. button, textfield, checkbox, menuitem, or \"\" for any."],
                  "name": ["type": "string", "description": "Text to match in the element's name, or \"\" for any."]]),
            tool("app_act", "Act on an element by its ref, inside the app, without moving the user's pointer or taking their keyboard. click presses a button, link, tab or row. set_value replaces a field's text; type inserts text at the cursor. confirm is Return in a field: it goes to a URL typed in a browser's address field or runs a search. select picks an option by its text in a popup, menu button, list or tab group. check/uncheck/toggle a checkbox; expand/collapse a disclosure. scroll_to brings an element into view; scroll_down/scroll_up move the scroll area an element is in by a page. Pressing a control that sends, deletes, pays or publishes asks the user first.",
                 ["ref": ["type": "string", "description": "A ref from the latest snapshot or find."],
                  "action": ["type": "string", "enum": actions],
                  "text": ["type": "string", "description": "The text for set_value and type, the option for select; \"\" otherwise."]]),
            tool("app_read", "Read one property of an element: text (all the words a person reads in it, e.g. a whole web page from its webarea ref), value (a field's contents), title (its label) or states (disabled, checked, selected…).",
                 ["ref": ["type": "string"],
                  "property": ["type": "string", "enum": ["text", "value", "title", "states"]]]),
        ]
    }

    func run(_ name: String, _ input: [String: Any]) async -> CanvasTools.Outcome {
        switch name {
        case "app_snapshot":
            return await snapshot(input)
        case "app_find":
            return await find(input)
        case "app_act":
            return await act(input)
        case "app_read":
            return await read(input)
        default:
            return Self.fail("There's no tool called \(name).")
        }
    }

    // MARK: Reading

    private func snapshot(_ input: [String: Any]) async -> CanvasTools.Outcome {
        guard let window = window(input["window_id"]) else { return Self.fail("No window has that id. Call list_windows.") }
        if let refused = refusal(for: window) { return Self.fail(refused) }
        working(in: window)
        presence?.reading(window.id)
        let rootRef = (input["root_ref"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var root: AppReader.Handle?
        if !rootRef.isEmpty {
            guard let snap = known(rootRef), snap.window.id == window.id, let element = snap.elements[rootRef] else {
                return Self.fail(Self.unknownRef(rootRef))
            }
            root = element.handle
        }
        guard let read = await Self.read(window, under: root, maxNodes: 2500) else {
            return Self.fail("\(window.app)'s window isn't answering accessibility right now. It may still be loading; try again, or the app doesn't expose its contents.")
        }
        let id = AppReader.newSnapshotID()
        let (tree, refs) = AppReader.render(read.root, id: id)
        remember(id, window: window, refs: refs, read: read)
        var text = CanvasTools.json(["snapshot_id": id, "tree": tree])
        if read.truncated {
            text += "\nThe window is larger than one read; this is its first part. Pass a region's ref as root_ref to read further into it."
        }
        if text.count > Guardrails.maxSnapshotLength {
            text = String(text.prefix(Guardrails.maxSnapshotLength))
                + "\n… cut here: too large to send whole. Use app_find, or app_snapshot with root_ref set to a region's ref."
        }
        Log.note("Tell Sunlight: read \(read.handles.count) elements of \(window.app), \(refs.count) refs\(read.truncated ? ", cut short" : "")")
        return CanvasTools.Outcome(result: text, isError: false, step: nil)
    }

    private func find(_ input: [String: Any]) async -> CanvasTools.Outcome {
        guard let window = window(input["window_id"]) else { return Self.fail("No window has that id. Call list_windows.") }
        if let refused = refusal(for: window) { return Self.fail(refused) }
        working(in: window)
        presence?.reading(window.id)
        guard let read = await Self.read(window, under: nil, maxNodes: 4000) else {
            return Self.fail("\(window.app)'s window isn't answering accessibility right now. Try again.")
        }
        let id = AppReader.newSnapshotID()
        let (matches, refs) = AppReader.find(read.root, id: id, role: input["role"] as? String ?? "",
                                             name: input["name"] as? String ?? "", limit: 20)
        remember(id, window: window, refs: refs, read: read)
        Log.note("Tell Sunlight: found \(matches.count) in \(read.handles.count) elements of \(window.app)")
        if matches.isEmpty {
            return CanvasTools.Outcome(result: "Nothing matches\(read.truncated ? " in the part of the window read" : ""). Try fewer words, another role, or app_snapshot.", isError: false, step: nil)
        }
        return CanvasTools.Outcome(result: CanvasTools.json(["snapshot_id": id, "matches": matches]), isError: false, step: nil)
    }

    private func read(_ input: [String: Any]) async -> CanvasTools.Outcome {
        let ref = input["ref"] as? String ?? ""
        guard let snap = known(ref), let element = snap.elements[ref] else { return Self.fail(Self.unknownRef(ref)) }
        if let refused = refusal(for: snap.window) { return Self.fail(refused) }
        let property = input["property"] as? String ?? "text"
        if element.target.secure && (property == "text" || property == "value") {
            return Self.fail("That's a password field; Sunlight never reads one.")
        }
        presence?.reading(snap.window.id)
        guard let read = await Self.read(snap.window, under: element.handle, maxNodes: property == "text" ? 6000 : 60, deadline: 6) else {
            return Self.fail("The app didn't answer. Try again.")
        }
        let node = read.root
        switch property {
        case "text":
            let text = AppReader.text(of: node, limit: Guardrails.maxSnapshotLength)
            let note = read.truncated ? "\n… (the region is larger than one read: this is its first part)" : ""
            return CanvasTools.Outcome(result: text.isEmpty ? "(no text)" : text + note, isError: false, step: nil)
        case "value":
            return CanvasTools.Outcome(result: node.value.isEmpty ? "(empty)" : AppReader.clip(node.value, 4000), isError: false, step: nil)
        case "title":
            let name = AppReader.name(of: node)
            return CanvasTools.Outcome(result: name.isEmpty ? "(no title)" : name, isError: false, step: nil)
        default:
            let states = AppReader.states(of: node)
            return CanvasTools.Outcome(result: states.isEmpty ? "enabled" : states.joined(separator: ", "), isError: false, step: nil)
        }
    }

    /// The window's tree (or the part under `root`), read off the main thread.
    private static func read(_ window: CanvasController.AgentWindow, under root: AppReader.Handle?, maxNodes: Int,
                             deadline seconds: TimeInterval = 5) async -> AppReader.Read? {
        let id = window.id, pid = window.pid, rect = window.rect
        return await AppReader.off {
            AppReader.exposeWebContent(pid: pid)
            let start: AXUIElement
            if let root {
                start = root.element
            } else {
                guard let found = AXWindow.find(windowID: id, pid: pid, approximateFrame: rect) else { return nil }
                start = found.element
            }
            return AppReader.read(start, maxNodes: maxNodes, deadline: Date().addingTimeInterval(seconds))
        }
    }

    private func remember(_ id: String, window: CanvasController.AgentWindow, refs: [String: AppReader.Target], read: AppReader.Read) {
        var elements: [String: (target: AppReader.Target, handle: AppReader.Handle)] = [:]
        for (ref, target) in refs where read.handles.indices.contains(target.index) {
            elements[ref] = (target, read.handles[target.index])
        }
        snapshots[id] = Snapshot(window: window, elements: elements)
    }

    // MARK: Acting

    private func act(_ input: [String: Any]) async -> CanvasTools.Outcome {
        let ref = input["ref"] as? String ?? ""
        let action = input["action"] as? String ?? ""
        let text = input["text"] as? String ?? ""
        guard Self.actions.contains(action) else { return Self.fail("Unknown action \(action).") }
        guard let snap = known(ref), let element = snap.elements[ref] else { return Self.fail(Self.unknownRef(ref)) }
        if let refused = refusal(for: snap.window) { return Self.fail(refused) }
        guard desk.canvases.contains(where: { $0.agentHolds(snap.window.id) }) else {
            return Self.fail("That window is gone. Call list_windows.")
        }
        if element.target.secure && ["set_value", "type", "clear"].contains(action) {
            return Self.fail("That's a password field. Sunlight never types passwords; say in your answer that signing in is left to the user.")
        }
        if ["type", "select"].contains(action) && text.isEmpty {
            return Self.fail("That action needs text.")
        }
        let target = element.target
        let label = target.name.isEmpty ? target.role : "“\(Self.short(target.name))”"
        let handle = element.handle
        // The pointer goes to the control first, so a question in the bar points at something on screen.
        // Stopped while it flew (Esc), nothing more happens.
        await point(at: handle, in: snap.window, for: action)
        if Task.isCancelled { return Self.fail("Stopped.") }
        if Guardrails.needsConfirmation(action: action, name: target.name, option: text, role: target.role) {
            let question = action == "select" ? "Choose “\(Self.short(text))” in \(snap.window.app)?"
                : action == "confirm" ? "Press Return in \(label) in \(snap.window.app)?"
                : "\(action.capitalized) \(label) in \(snap.window.app)?"
            presence?.asking()
            let allowed = await confirm?(question) ?? false
            presence?.asked(allowed: allowed)
            guard allowed else {
                return Self.fail("The user didn't allow this step, so it wasn't done. Don't try it another way; say in your answer that it's left for them.")
            }
        }
        working(in: snap.window)
        let outcome = await AppReader.off { AppReader.perform(action, on: handle, text: text) }
        presence?.pressed(outcome.ok ? Self.press(for: action, text: text) : .failed)
        Log.note("Tell Sunlight: \(action) on \(target.role) in \(snap.window.app) → \(outcome.ok ? "ok" : outcome.message)")
        let step: String
        switch action {
        case "set_value", "type": step = "Typed into \(label) in \(snap.window.app)"
        case "select": step = "Chose “\(Self.short(text))” in \(snap.window.app)"
        case "scroll_to", "scroll_down", "scroll_up": step = "Scrolled in \(snap.window.app)"
        case "focus": step = "Focused \(label) in \(snap.window.app)"
        case "confirm": step = "Pressed Return in \(label) in \(snap.window.app)"
        default: step = "\(action.capitalized) \(label) in \(snap.window.app)"
        }
        return CanvasTools.Outcome(result: outcome.message, isError: !outcome.ok, step: outcome.ok ? step : nil)
    }

    // MARK: Showing it

    /// Tell Sunlight's pointer to the element, which it outlines; back once the pointer has landed.
    private func point(at handle: AppReader.Handle, in window: CanvasController.AgentWindow, for action: String) async {
        guard let presence, presence.active else { return }
        let frames = await AppReader.off { AppReader.frames(of: handle) }
        let badge: AgentPresence.Badge = switch action {
        case "set_value", "type", "clear": .typing
        case "scroll_down": .scrollDown
        case "scroll_up": .scrollUp
        default: .none
        }
        await presence.target(window.id, unit: PresenceGeometry.unit(of: frames.element, in: frames.window), badge: badge)
    }

    /// How an action that worked shows once the pointer is on the control.
    static func press(for action: String, text: String) -> AgentPresence.Press {
        switch action {
        case "set_value", "type": .typed(text)
        case "clear": .typed("⌫")
        case "confirm": .returnKey
        case "select": .chose(text)
        case "scroll_down": .scrolled(down: true)
        case "scroll_up": .scrolled(down: false)
        default: .click
        }
    }

    // MARK: Pieces

    private func window(_ value: Any?) -> CanvasController.AgentWindow? {
        guard let id = CanvasTools.windowID(value) else { return nil }
        return desk.canvases.lazy.compactMap { $0.agentWindows.first { $0.id == id } }.first
    }

    /// The snapshot a ref came from, if Sunlight took it.
    private func known(_ ref: String) -> Snapshot? {
        AppReader.snapshotID(ofRef: ref).flatMap { snapshots[$0] }
    }

    private func refusal(for window: CanvasController.AgentWindow) -> String? {
        let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
        guard Guardrails.blockedApps.contains(bundleID) else {
            return window.state == "minimized" || window.state == "hidden"
                ? "\(window.app)'s window is \(window.state). bring_back it first." : nil
        }
        return "Sunlight doesn't work inside \(window.app): settings, passwords and terminals are left to the user. Say so in your answer."
    }

    private func working(in window: CanvasController.AgentWindow) {
        presence?.workingIn(window.id)
        guard lastWindow != window.id else { return }
        lastWindow = window.id
        onWindow?("Working in \(CanvasTools.label(window))")
    }

    private static func unknownRef(_ ref: String) -> String {
        "\(ref.isEmpty ? "No ref" : ref) isn't from a snapshot taken in this request. Call app_snapshot or app_find on the window first."
    }

    private static func short(_ s: String) -> String { s.count > 40 ? String(s.prefix(39)) + "…" : s }

    private static func fail(_ message: String) -> CanvasTools.Outcome {
        CanvasTools.Outcome(result: message, isError: true, step: nil)
    }
}
