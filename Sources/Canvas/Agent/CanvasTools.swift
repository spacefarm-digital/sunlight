import AppKit

/// What Tell Sunlight can do on the canvas: each tool is a command a hand on the canvas could give, run
/// through the canvas's own methods (`CanvasController`'s Tell Sunlight section), so the model can do
/// nothing the user couldn't. Every result is JSON text the model reads back.
@MainActor
struct CanvasTools {
    let desk: Desk
    /// A layout was saved: the menus list it.
    var onLayoutsChanged: (() -> Void)?
    /// Shows each command on screen: the pointer takes the window by its title bar and rides along.
    var presence: AgentPresence?

    struct Outcome {
        /// What goes back to the model.
        let result: String
        let isError: Bool
        /// One line for the bar ("Moved Slack"), nil for a look that changed nothing.
        let step: String?
    }

    // MARK: Definitions

    /// The tool definitions sent with every request. `strict`: the arguments always match the schema,
    /// so every property is required and none other is allowed.
    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:]) -> [String: Any] {
            [
                "name": name,
                "description": description,
                "strict": true,
                "input_schema": [
                    "type": "object",
                    "properties": properties,
                    "required": properties.keys.sorted(),
                    "additionalProperties": false,
                ] as [String: Any],
            ]
        }
        let windowID: [String: Any] = ["type": "integer", "description": "A window's id from list_windows."]
        return [
            tool("list_windows", "Every app window on the canvas: id, app, title, its rect on the canvas, its state (on canvas, entered, minimized, hidden) and tiling slot. Also the part of the canvas in view and the size of one screen. The request already comes with this list, and every window tool returns the window's new rect, so call it only when something else may have changed the canvas (a restored layout, a window that didn't arrive)."),
            tool("move_window", "Move a window so its top-left corner lands at (x, y) on the canvas. Its size stays.",
                 ["window_id": windowID,
                  "x": ["type": "number", "description": "Canvas x of the top-left corner, points."],
                  "y": ["type": "number", "description": "Canvas y of the top-left corner, points (y grows downwards)."]]),
            tool("resize_window", "Resize a window, keeping its top-left corner. Some apps hold a minimum or fixed size.",
                 ["window_id": windowID,
                  "width": ["type": "number", "description": "Points."],
                  "height": ["type": "number", "description": "Points."]]),
            tool("place_beside", "Move a window next to another one, with a small gap, aligned to its top (left, right) or left edge (above, below).",
                 ["window_id": windowID,
                  "next_to": ["type": "integer", "description": "The id of the window to place it beside."],
                  "side": ["type": "string", "enum": ["left", "right", "above", "below"]]]),
            tool("tile_window", "Fit a window to a slot of the screen-sized area it's in, like the ⌃⌥ tiling keys: halves, quarters, thirds, two-thirds, full, or centre.",
                 ["window_id": windowID,
                  "slot": ["type": "string", "enum": Tiling.Preset.allCases.map(\.rawValue)]]),
            tool("enter_window", "Go into a window at full size so the user can use it. This leaves the canvas, so do it last, and only when the user asked to end up in that window or it's clearly the point of the request.",
                 ["window_id": windowID]),
            tool("look_at", "Move the camera to frame these windows, or every window when the list is empty. Use it to show the user the result.",
                 ["window_ids": ["type": "array", "items": ["type": "integer"], "description": "Window ids; empty for everything."]]),
            tool("open_app", "Open an app by name (fuzzy matched against installed apps) and wait for a window of it to land on the canvas. Returns that window's id.",
                 ["name": ["type": "string", "description": "The app's name, e.g. \"Calendar\"."]]),
            tool("minimize_window", "Minimize a window to the Dock. Its place on the canvas is kept.", ["window_id": windowID]),
            tool("bring_back", "Bring back a minimized or hidden window to its place on the canvas.", ["window_id": windowID]),
            tool("close_window", "Close a window, as its red button does; the app may ask to save. Only when the user asked for it.", ["window_id": windowID]),
            tool("list_layouts", "The saved layouts' names. A layout is a saved arrangement of windows."),
            tool("restore_layout", "Restore a saved layout: its windows go back where it had them, missing apps and documents are reopened.",
                 ["name": ["type": "string", "description": "Exactly as list_layouts gives it."]]),
            tool("save_layout", "Save the canvas as it is now as a layout under a name. Only when the user asked for it.",
                 ["name": ["type": "string"]]),
            tool(finish, "End the request with what you'll tell the user, once the request is really done. You may call it in the same turn as your last actions when their results don't need checking (moving or tiling windows): if they all succeed the request ends there and Sunlight frames the windows you moved; if one fails you get the results back and carry on. When the request needs something to have happened inside an app (a page loaded, a search run, a message filled in), check that first and finish in a later turn.",
                 ["summary": ["type": "string", "description": "One or two short sentences saying what you did."]]),
        ]
    }

    /// Handled by `AgentRun`, not run here: the request ends.
    static let finish = "finish"

    /// The canvas as list_windows gives it: sent with the request, so the first turn needn't ask.
    func canvasNow() -> String { listWindows().result }

    // MARK: Running a call

    func run(_ name: String, _ input: [String: Any]) async -> Outcome {
        switch name {
        case "list_windows": return listWindows()
        case "list_layouts":
            return ok(["layouts": LayoutStore.layouts.map(\.name)], step: nil)
        case "look_at":
            let ids = (input["window_ids"] as? [Any] ?? []).compactMap(CanvasTools.windowID)
            // The canvas the windows are on, which with several displays may not be the current one.
            let canvas = ids.compactMap { id in desk.canvases.first { $0.agentHolds(id) } }.first ?? desk.current
            await bringCanvasForward(canvas)
            canvas.agentLook(at: ids)
            return ok(["done": true], step: ids.isEmpty ? "Showed every window" : "Showed \(names(ids))")
        case "open_app":
            return await openApp(input["name"] as? String ?? "")
        case "restore_layout":
            let name = input["name"] as? String ?? ""
            guard LayoutStore.layouts.contains(where: { $0.name == name }) else {
                return fail("No layout is named “\(name)”. Saved: \(LayoutStore.layouts.map(\.name).joined(separator: ", ")).")
            }
            desk.restoreLayout(named: name)
            return ok(["done": true, "note": "Windows are moving into place and missing apps are opening; give it a few seconds before listing windows."],
                      step: "Restored “\(name)”")
        case "save_layout":
            let name = (input["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return fail("The layout needs a name.") }
            guard desk.lead.agentSaveLayout(named: name, saved: onLayoutsChanged) else { return fail(desk.lead.agentBusy ?? "The canvas is busy.") }
            return ok(["done": true], step: "Saved the layout “\(name)”")
        default:
            break
        }

        // The rest act on one window.
        guard let id = CanvasTools.windowID(input["window_id"]) else { return fail("window_id is missing.") }
        guard let canvas = desk.canvases.first(where: { $0.agentHolds(id) }),
              let window = canvas.agentWindows.first(where: { $0.id == id }) else {
            return fail("No window has id \(id). Call list_windows for the current ids.")
        }
        if let busy = canvas.agentBusy { return fail("The canvas can't do that now: \(busy).") }
        let label = CanvasTools.label(window)
        await bringCanvasForward(canvas)
        defer { presence?.release() }

        switch name {
        case "move_window":
            guard let x = CanvasTools.number(input["x"]), let y = CanvasTools.number(input["y"]) else { return fail("x and y are needed.") }
            guard await show(.titleBar, on: id) else { return stopped }
            return await done(canvas.agentMove(id, to: CGPoint(x: x, y: y)), "Moved \(label)", id: id, on: canvas)
        case "resize_window":
            guard let w = CanvasTools.number(input["width"]), let h = CanvasTools.number(input["height"]), w >= 80, h >= 60 else {
                return fail("width and height are needed, at least 80 × 60.")
            }
            guard await show(.corner, on: id) else { return stopped }
            return await done(canvas.agentResize(id, to: CGSize(width: w, height: h)), "Resized \(label)", id: id, on: canvas)
        case "place_beside":
            guard let otherID = CanvasTools.windowID(input["next_to"]),
                  let other = canvas.agentWindows.first(where: { $0.id == otherID }) else {
                return fail("next_to must be the id of another window on the same canvas.")
            }
            guard otherID != id else { return fail("A window can't be placed beside itself.") }
            let side = input["side"] as? String ?? "right"
            let origin = CanvasTools.origin(of: window.rect.size, beside: other.rect, side: side)
            guard await show(.titleBar, on: id) else { return stopped }
            return await done(canvas.agentMove(id, to: origin), "Put \(label) \(side == "left" || side == "right" ? "to the \(side) of" : side) \(CanvasTools.label(other))", id: id, on: canvas)
        case "tile_window":
            guard let preset = (input["slot"] as? String).flatMap(Tiling.Preset.init(rawValue:)) else { return fail("Unknown slot.") }
            guard await show(.titleBar, on: id) else { return stopped }
            return await done(canvas.agentTile(id, preset), "Tiled \(label) to \(preset.title.lowercased())", id: id, on: canvas)
        case "enter_window":
            guard await show(.center, on: id) else { return stopped }
            return await done(pressed(canvas.agentEnter(id)), "Went into \(label)", id: id, on: canvas)
        case "minimize_window":
            guard await show(.minimize, on: id) else { return stopped }
            return await done(pressed(canvas.agentMinimize(id)), "Minimized \(label)", id: id, on: canvas)
        case "bring_back":
            // The pointer has nothing to take hold of until the window is back on the canvas.
            return await done(canvas.agentBringBack(id), "Brought back \(label)", id: id, on: canvas)
        case "close_window":
            guard await show(.close, on: id) else { return stopped }
            return await done(pressed(canvas.agentClose(id)), "Closed \(label)", id: id, on: canvas)
        default:
            return fail("There's no tool called \(name).")
        }
    }

    // MARK: Tools with more to them

    private func listWindows() -> Outcome {
        let c = desk.current
        let windows = desk.canvases.flatMap(\.agentWindows).map { w -> [String: Any] in
            var d: [String: Any] = ["id": Int(w.id), "app": w.app, "title": w.title, "state": w.state,
                                    "x": Int(w.rect.minX), "y": Int(w.rect.minY),
                                    "width": Int(w.rect.width), "height": Int(w.rect.height)]
            if let slot = w.slot { d["slot"] = slot }
            return d
        }
        let view = c.agentView
        return ok(["windows": windows,
                   "in_view": CanvasTools.rect(view.visible),
                   "screen": ["width": Int(view.screen.width), "height": Int(view.screen.height)]], step: nil)
    }

    private func openApp(_ query: String) async -> Outcome {
        let catalog = AppCatalog.shared
        catalog.refresh()
        // The first walk of the app folders, if it hasn't landed yet.
        for _ in 0..<30 where catalog.apps.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
        let name = CanvasTools.appName(query)
        guard let app = catalog.search(name, limit: 1).first ?? CanvasTools.coreServicesApp(name) else {
            return fail("No installed app matches “\(query)”.")
        }
        let canvas = desk.current
        if let busy = canvas.agentBusy { return fail("The canvas can't do that now: \(busy).") }
        await bringCanvasForward(canvas)
        guard let id = await canvas.agentOpen(app) else {
            return fail("\(app.name) opened but no window of it reached the canvas within a few seconds. It may need a moment, or have opened no window; call list_windows to check.")
        }
        await presence?.grab(id, .titleBar)
        presence?.release()
        var result: [String: Any] = ["window_id": Int(id), "app": app.name]
        if let w = canvas.agentWindows.first(where: { $0.id == id }) {
            result["title"] = w.title
            result["rect"] = CanvasTools.rect(w.rect)
        }
        return ok(result, step: "Opened \(app.name)")
    }

    // MARK: Pieces

    /// Before a window command, the pointer goes where a hand would: the title bar to move or tile, the
    /// corner to resize, the traffic lights to close or minimize, the middle to go in. False if the
    /// request was stopped (Esc) while it flew: the command isn't given.
    private func show(_ grip: AgentPresence.Grip, on id: CGWindowID) async -> Bool {
        await presence?.grab(id, grip)
        return !Task.isCancelled
    }

    /// A button-like command (close, minimize, go in) shows its press once it's been given.
    private func pressed(_ succeeded: Bool) -> Bool {
        presence?.pressed(succeeded ? .click : .failed)
        return succeeded
    }

    private var stopped: Outcome { fail("Stopped.") }

    /// The canvas's commands are given on the canvas: from inside a window, or with another app in front,
    /// it comes forward first, as the menu bar's commands do.
    private func bringCanvasForward(_ canvas: CanvasController) async {
        guard canvas.isEntered || !NSApp.isActive else { return }
        canvas.show()
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    private func done(_ succeeded: Bool, _ step: String, id: CGWindowID, on canvas: CanvasController) async -> Outcome {
        guard succeeded else { return fail("The canvas couldn't do that to window \(id) now. It may be minimized, hidden or entered; call list_windows.") }
        // Where it ended up, so the next step needs no listing: the glide (0.16 s) lands first, and an app
        // holding its own size has had its say.
        for _ in 0..<12 where !canvas.agentSettled { try? await Task.sleep(nanoseconds: 50_000_000) }
        var result: [String: Any] = ["done": true]
        if let w = canvas.agentWindows.first(where: { $0.id == id }) {
            result["state"] = w.state
            result["rect"] = CanvasTools.rect(w.rect)
            if let slot = w.slot { result["slot"] = slot }
        }
        return ok(result, step: step)
    }

    private func names(_ ids: [CGWindowID]) -> String {
        let all = desk.canvases.flatMap(\.agentWindows)
        let apps = ids.compactMap { id in all.first { $0.id == id }?.app }
        return apps.isEmpty ? "the windows" : CanvasTools.list(apps)
    }

    private func ok(_ value: [String: Any], step: String?) -> Outcome {
        Outcome(result: CanvasTools.json(value), isError: false, step: step)
    }

    private func fail(_ message: String) -> Outcome {
        Outcome(result: message, isError: true, step: nil)
    }

    // MARK: Pure helpers (tested)

    /// "Finder.app" or " finder " as the app's name.
    static func appName(_ query: String) -> String {
        var name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name
    }

    /// Finder and the other apps in CoreServices, which the app folders Open Here… walks leave out.
    static func coreServicesApp(_ name: String, folder: String = "/System/Library/CoreServices") -> AppEntry? {
        guard !name.isEmpty, let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        guard let match = items.first(where: { $0.lowercased() == name.lowercased() + ".app" }) else { return nil }
        return AppEntry(name: String(match.dropLast(4)), path: folder + "/" + match)
    }

    static let gap: CGFloat = 24

    /// Where a window of `size` goes beside `other`: left or right aligned to its top, above or below
    /// aligned to its left edge, `gap` apart.
    static func origin(of size: CGSize, beside other: CGRect, side: String) -> CGPoint {
        switch side {
        case "left": return CGPoint(x: other.minX - gap - size.width, y: other.minY)
        case "above": return CGPoint(x: other.minX, y: other.minY - gap - size.height)
        case "below": return CGPoint(x: other.minX, y: other.maxY + gap)
        default: return CGPoint(x: other.maxX + gap, y: other.minY)
        }
    }

    /// JSON numbers arrive as NSNumber, Int or Double.
    static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let n as NSNumber: return CGFloat(truncating: n)
        case let d as Double: return CGFloat(d)
        case let i as Int: return CGFloat(i)
        default: return nil
        }
    }

    static func windowID(_ value: Any?) -> CGWindowID? {
        guard let n = number(value), n >= 0, n <= CGFloat(UInt32.max), n == n.rounded() else { return nil }
        return CGWindowID(n)
    }

    /// "Slack" or "Safari: Apple" for the bar's steps.
    static func label(_ w: CanvasController.AgentWindow) -> String {
        let title = w.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != w.app else { return w.app }
        let short = title.count > 32 ? String(title.prefix(31)) + "…" : title
        return "\(w.app) (\(short))"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func rect(_ r: CGRect) -> [String: Int] {
        ["x": Int(r.minX), "y": Int(r.minY), "width": Int(r.width), "height": Int(r.height)]
    }

    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
