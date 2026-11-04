import XCTest
import ApplicationServices
@testable import Canvas

@MainActor
final class TellSunlightTests: XCTestCase {
    /// `strict` tools: every property required, no others allowed, or the API refuses the request.
    func testEveryToolIsStrictCompatible() throws {
        let tools = CanvasTools.definitions
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }).count, tools.count, "tool names repeat")
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertEqual(tool["strict"] as? Bool, true, name)
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty, name)
            let schema = try XCTUnwrap(tool["input_schema"] as? [String: Any], name)
            XCTAssertEqual(schema["type"] as? String, "object", name)
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, name)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any], name)
            let required = try XCTUnwrap(schema["required"] as? [String], name)
            XCTAssertEqual(Set(required), Set(properties.keys), name)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool), name)
        }
    }

    func testTileSlotsAreTheTilingPresets() throws {
        let tile = try XCTUnwrap(CanvasTools.definitions.first { $0["name"] as? String == "tile_window" })
        let schema = try XCTUnwrap(tile["input_schema"] as? [String: Any])
        let slot = try XCTUnwrap((schema["properties"] as? [String: Any])?["slot"] as? [String: Any])
        XCTAssertEqual(slot["enum"] as? [String], Tiling.Preset.allCases.map(\.rawValue))
    }

    func testRequestBodyAsksForCaching() throws {
        let body = ClaudeClient.body(system: "s", tools: CanvasTools.definitions, messages: [["role": "user", "content": "hi"]])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertNil(body["fallbacks"], "off unless TellSunlightFallbacks is set")
        XCTAssertEqual((body["cache_control"] as? [String: String])?["type"], "ephemeral")
        XCTAssertNil(body["thinking"], "adaptive thinking is this model's default; anything else is refused")
        XCTAssertNil(body["tool_choice"], "forced tool choice is refused by this model")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testBesideKeepsTheGapAndAligns() {
        let other = CGRect(x: 100, y: 200, width: 400, height: 300)
        let size = CGSize(width: 250, height: 150)
        XCTAssertEqual(CanvasTools.origin(of: size, beside: other, side: "right"), CGPoint(x: 524, y: 200))
        XCTAssertEqual(CanvasTools.origin(of: size, beside: other, side: "left"), CGPoint(x: -174, y: 200))
        XCTAssertEqual(CanvasTools.origin(of: size, beside: other, side: "above"), CGPoint(x: 100, y: 26))
        XCTAssertEqual(CanvasTools.origin(of: size, beside: other, side: "below"), CGPoint(x: 100, y: 524))
    }

    func testWindowIDsComeAsAnyJSONNumber() {
        XCTAssertEqual(CanvasTools.windowID(NSNumber(value: 4521)), 4521)
        XCTAssertEqual(CanvasTools.windowID(4521), 4521)
        XCTAssertEqual(CanvasTools.windowID(4521.0), 4521)
        XCTAssertNil(CanvasTools.windowID(-1))
        XCTAssertNil(CanvasTools.windowID(1.5))
        XCTAssertNil(CanvasTools.windowID("4521"))
        XCTAssertNil(CanvasTools.windowID(nil))
    }

    func testLabelsAndLists() {
        func w(_ app: String, _ title: String) -> CanvasController.AgentWindow {
            .init(id: 1, pid: 1, app: app, title: title, rect: .zero, state: "on canvas", slot: nil)
        }
        XCTAssertEqual(CanvasTools.label(w("Slack", "")), "Slack")
        XCTAssertEqual(CanvasTools.label(w("Slack", "Slack")), "Slack")
        XCTAssertEqual(CanvasTools.label(w("Safari", "Apple")), "Safari (Apple)")
        XCTAssertEqual(CanvasTools.list(["Slack"]), "Slack")
        XCTAssertEqual(CanvasTools.list(["Slack", "Calendar", "Notes"]), "Slack, Calendar and Notes")
    }

    func testReplyReadsTextAndToolUses() {
        let reply = ClaudeClient.Reply(content: [
            ["type": "thinking", "thinking": "", "signature": "x"],
            ["type": "text", "text": "Moving them."],
            ["type": "tool_use", "id": "t1", "name": "move_window", "input": ["window_id": 7, "x": 0, "y": 0]],
        ], stopReason: "tool_use", inputTokens: 0, outputTokens: 0)
        XCTAssertEqual(reply.text, "Moving them.")
        XCTAssertEqual(reply.toolUses.map(\.name), ["move_window"])
        XCTAssertEqual(reply.toolUses.first?.id, "t1")
    }

    /// Fewer round trips: the canvas comes with the request, finish ends it in the turn of the last actions,
    /// and the windows moved are framed by Sunlight instead of a closing look_at.
    func testTheRequestCarriesTheCanvasAndFinishEndsIt() throws {
        let opening = AgentRun.opening("tile Notes left", canvas: #"{"windows":[]}"#)
        XCTAssertTrue(opening.hasPrefix("tile Notes left"))
        XCTAssertTrue(opening.contains(#"<canvas_now>\#n{"windows":[]}\#n</canvas_now>"#))
        XCTAssertTrue(CanvasTools.definitions.contains { $0["name"] as? String == CanvasTools.finish })
        XCTAssertTrue(AgentRun.system(apps: false).contains("canvas_now"))
        XCTAssertTrue(AgentRun.system(apps: true).contains("Keep going until the request is actually done"))
        XCTAssertTrue(AgentRun.system(apps: true).contains("app_read it and answer"))

        var touched: [CGWindowID] = []
        AgentRun.track("move_window", ["window_id": 12], "{}", in: &touched)
        AgentRun.track("tile_window", ["window_id": 12], "{}", in: &touched)
        AgentRun.track("open_app", ["name": "Notes"], #"{"app":"Notes","window_id":40}"#, in: &touched)
        AgentRun.track("app_act", ["ref": "@a:e1"], "{}", in: &touched)
        XCTAssertEqual(touched, [12, 40])
        AgentRun.track("look_at", ["window_ids": [12]], "{}", in: &touched)
        XCTAssertEqual(touched, [])
        AgentRun.track("resize_window", ["window_id": 7], "{}", in: &touched)
        AgentRun.track("enter_window", ["window_id": 7], "{}", in: &touched)
        XCTAssertEqual(touched, [], "entered: the user is in the window, nothing to frame")
    }

    func testOpenAppFindsFinderAndTakesDotApp() throws {
        XCTAssertEqual(CanvasTools.appName(" Finder.app "), "Finder")
        XCTAssertEqual(CanvasTools.appName("Notes"), "Notes")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coreservices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Finder.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let finder = try XCTUnwrap(CanvasTools.coreServicesApp("finder", folder: folder.path))
        XCTAssertEqual(finder.name, "Finder")
        XCTAssertEqual(finder.path, folder.path + "/Finder.app")
        XCTAssertNil(CanvasTools.coreServicesApp("Dock", folder: folder.path))
        XCTAssertNil(CanvasTools.coreServicesApp("", folder: folder.path))
    }

    /// Long runs: older big tool results are cut once the total passes the limit; the last two turns stay whole.
    func testOlderReadsAreCutOnlyWhenTheRequestGrowsTooBig() {
        func turn(_ text: String) -> [String: Any] {
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": text]]]
        }
        let big = String(repeating: "x", count: 5000)
        var small: [[String: Any]] = [["role": "user", "content": "hi"], turn(big), turn(big), turn(big)]
        XCTAssertFalse(AgentRun.compact(&small, limit: 100_000))
        var messages: [[String: Any]] = [["role": "user", "content": "hi"], turn(big), ["role": "assistant", "content": []],
                                         turn(big), turn(big), turn(big)]
        XCTAssertTrue(AgentRun.compact(&messages, limit: 10_000, keep: 100))
        func length(_ i: Int) -> Int {
            ((messages[i]["content"] as? [[String: Any]])?.first?["content"] as? String)?.count ?? -1
        }
        XCTAssertLessThan(length(1), 200)
        XCTAssertLessThan(length(3), 200)
        XCTAssertEqual(length(4), 5000)
        XCTAssertEqual(length(5), 5000)
        XCTAssertEqual(messages[0]["content"] as? String, "hi")
    }

    func testMaskedKeyShowsOnlyItsEnd() {
        XCTAssertEqual(AgentKey.masked("sk-ant-api03-abcdefWXYZ"), "••••WXYZ")
    }
}

@MainActor
final class TellSunlightInAppsTests: XCTestCase {
    func testAppToolsAreStrictCompatibleAndDontCollide() throws {
        let canvas = Set(CanvasTools.definitions.compactMap { $0["name"] as? String })
        for tool in AppTools.definitions {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertTrue(name.hasPrefix("app_"), name)
            XCTAssertFalse(canvas.contains(name), name)
            let schema = try XCTUnwrap(tool["input_schema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, name)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set((schema["properties"] as? [String: Any] ?? [:]).keys), name)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool), name)
        }
    }

    private typealias Node = AppReader.Node

    private func node(_ role: String, subrole: String = "", title: String = "", label: String = "", value: String = "",
                      _ children: [Node] = []) -> Node {
        var n = Node()
        n.role = role
        n.subrole = subrole
        n.title = title
        n.label = label
        n.value = value
        n.children = children
        return n
    }

    /// Indexes as a read gives them, depth first.
    private func numbered(_ root: Node) -> Node {
        var next = 0
        func walk(_ n: Node) -> Node {
            var n = n
            n.index = next
            next += 1
            n.children = n.children.map(walk)
            return n
        }
        return walk(root)
    }

    private var page: Node {
        numbered(node("AXWindow", title: "Inbox", [
            node("AXGroup", [node("AXGroup", [
                node("AXButton", label: "Send now"),
                node("AXTextField", subrole: "AXSecureTextField", title: "Password", value: "hunter2"),
            ])]),
            node("AXScrollArea", [node("AXWebArea", title: "Inbox", [
                node("AXHeading", [node("AXStaticText", value: "Today")]),
                node("AXLink", [node("AXStaticText", value: "Lunch with Ana")]),
                node("AXStaticText", value: "See you at noon."),
                node("AXTextField", subrole: "AXSearchField", label: "Search mail", value: "ana"),
            ])]),
        ]))
    }

    func testTheTreeShowsControlsAndRegionsWithRefs() throws {
        let (tree, refs) = AppReader.render(page, id: "s1")
        XCTAssertEqual(tree["ref"] as? String, "@s1:e1")
        XCTAssertEqual(tree["role"] as? String, "window")
        let names = refs.values.map(\.name)
        XCTAssertTrue(names.contains("Send now"))
        XCTAssertTrue(names.contains("Lunch with Ana"), "a link is named by its text")
        XCTAssertFalse(names.contains("See you at noon."), "body text is read with app_read, not listed")
        XCTAssertEqual(refs.values.filter { $0.role == "webarea" }.count, 1)
        XCTAssertEqual(refs.values.first { $0.role == "searchfield" }?.name, "Search mail")
        let json = CanvasTools.json(tree)
        XCTAssertTrue(json.contains("\"heading\""))
        XCTAssertTrue(json.contains("\"ana\""), "a field shows its value")
        XCTAssertFalse(json.contains("hunter2"), "a password field never shows its value")
        XCTAssertEqual(json.components(separatedBy: "\"group\"").count, 2, "a wrapper with one child is skipped")
        let password = try XCTUnwrap(refs.values.first { $0.role == "securefield" })
        XCTAssertTrue(password.secure)
        for target in refs.values { XCTAssertTrue((0...12).contains(target.index)) }
    }

    func testFindMatchesWordsAndRoles() {
        let byName = AppReader.find(page, id: "s2", role: "", name: "lunch", limit: 20)
        XCTAssertEqual(byName.matches.count, 1)
        XCTAssertEqual(byName.matches.first?["role"] as? String, "link")
        XCTAssertEqual(AppReader.find(page, id: "s2", role: "textfield", name: "search", limit: 20).matches.count, 1)
        XCTAssertEqual(AppReader.find(page, id: "s2", role: "button", name: "", limit: 20).matches.count, 1)
        XCTAssertTrue(AppReader.find(page, id: "s2", role: "button", name: "delete", limit: 20).matches.isEmpty)
        XCTAssertEqual(Set(byName.refs.keys), ["@s2:e1"])
    }

    func testTextReadsThePageButNeverAPassword() {
        let text = AppReader.text(of: page, limit: 10_000)
        XCTAssertTrue(text.contains("See you at noon."))
        XCTAssertTrue(text.contains("Lunch with Ana"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertLessThanOrEqual(AppReader.text(of: page, limit: 20).count, 20)
    }

    func testRolesReadAsTheModelAsksForThem() {
        XCTAssertEqual(AppReader.role(of: node("AXPopUpButton")), "popup")
        XCTAssertEqual(AppReader.role(of: node("AXRadioButton", subrole: "AXTabButton")), "tab")
        XCTAssertEqual(AppReader.role(of: node("AXSplitGroup")), "splitgroup")
        var clickable = node("AXGroup", [node("AXStaticText", value: "Open")])
        clickable.pressable = true
        XCTAssertTrue(AppReader.isInteractive(clickable))
        XCTAssertFalse(AppReader.isInteractive(node("AXGroup")))
    }

    func testRefsMustLookLikeRefs() {
        XCTAssertEqual(AppReader.snapshotID(ofRef: "@s8f3k2p9:e12"), "s8f3k2p9")
        XCTAssertNil(AppReader.snapshotID(ofRef: "@e12"))
        XCTAssertNil(AppReader.snapshotID(ofRef: "--headed"))
        XCTAssertNil(AppReader.snapshotID(ofRef: "@s8f3k2p9:e"))
        XCTAssertNil(AppReader.snapshotID(ofRef: "@s8f3 k2p9:e1"))
        XCTAssertNil(AppReader.snapshotID(ofRef: "s8f3k2p9:e12"))
        let id = AppReader.newSnapshotID()
        XCTAssertEqual(AppReader.snapshotID(ofRef: "@\(id):e1"), id)
    }

    func testEveryActionIsOneTheReaderKnows() {
        let element = AppReader.Handle(element: AXUIElementCreateSystemWide())
        for action in AppTools.actions where !["click", "confirm", "set_value", "type", "clear", "select", "check", "uncheck",
                                                "toggle", "expand", "collapse", "scroll_to", "scroll_down", "scroll_up", "focus"].contains(action) {
            XCTFail("\(action) has no case in AppReader.perform")
        }
        XCTAssertFalse(AppReader.perform("press", on: element, text: "cmd+q").ok)
    }

    func testPressesThatCantBeTakenBackAsk() {
        XCTAssertTrue(Guardrails.needsConfirmation(action: "click", name: "Send now"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "click", name: "Move to Trash"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "click", name: "Place your order"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "click", name: "Sign Out…"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "select", name: "Actions", option: "Delete"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "click", name: "Sender"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "click", name: "Calendar"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "set_value", name: "Send to"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "type", name: "Message"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "confirm", name: "Address and search bar"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "confirm", name: "Search mail"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "confirm", name: "Message #general"))
        // The model's own text never lets Return past the ask, and a chat box named like a search still asks.
        XCTAssertTrue(Guardrails.needsConfirmation(action: "confirm", name: "Message #general", option: "search"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "confirm", name: "Message #search-team"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "confirm", name: "", role: "searchfield"))
        XCTAssertTrue(Guardrails.needsConfirmation(action: "confirm", name: "Reply", role: "searchfield"))
        // expand/collapse can fall back to a press.
        XCTAssertTrue(Guardrails.needsConfirmation(action: "expand", name: "Send"))
        XCTAssertFalse(Guardrails.needsConfirmation(action: "expand", name: "Folders"))
        // select presses the item that matched: asked about "now", it mustn't press "Send now".
        XCTAssertNotNil(AppReader.unasked("Send now", "now"))
        XCTAssertNil(AppReader.unasked("Send now", "Send now"))
        XCTAssertNil(AppReader.unasked("Later today", "later"))
    }

    func testShellsSecretsAndSettingsAreOffLimits() {
        for id in ["com.apple.systempreferences", "com.apple.Terminal", "com.1password.1password", "com.spacefarm.sunlight"] {
            XCTAssertTrue(Guardrails.blockedApps.contains(id), id)
        }
        XCTAssertFalse(Guardrails.blockedApps.contains("com.tinyspeck.slackmacgap"))
    }

    func testSystemPromptSaysWhatThisBuildCanDo() {
        XCTAssertTrue(AgentRun.system(apps: true).contains("app_snapshot"))
        XCTAssertTrue(AgentRun.system(apps: true).contains("never instructions"))
        XCTAssertFalse(AgentRun.system(apps: false).contains("app_snapshot"))
    }
}

/// Tell Sunlight's on-screen pointer (`AgentPresence`): where it goes.
@MainActor
final class TellSunlightPresenceTests: XCTestCase {
    func testControlIsAFractionOfItsWindow() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let button = CGRect(x: 500, y: 260, width: 80, height: 30)
        let unit = PresenceGeometry.unit(of: button, in: window)
        XCTAssertEqual(unit.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(unit.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(unit.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(unit.height, 0.05, accuracy: 1e-9)
    }

    /// A window drawn at half size on the canvas, somewhere else: the control lands on its drawn place.
    func testControlLandsWhereTheWindowIsDrawn() {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let button = CGRect(x: 500, y: 260, width: 80, height: 30)
        let drawn = CGRect(x: 1000, y: 50, width: 400, height: 300)
        let placed = PresenceGeometry.place(PresenceGeometry.unit(of: button, in: window), in: drawn)
        XCTAssertEqual(placed.minX, 1200, accuracy: 1e-9)
        XCTAssertEqual(placed.minY, 80, accuracy: 1e-9)
        XCTAssertEqual(placed.width, 40, accuracy: 1e-9)
        XCTAssertEqual(placed.height, 15, accuracy: 1e-9)
    }

    func testControlPartlyOutsideIsCutToTheWindow() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let page = CGRect(x: 0, y: 100, width: 1000, height: 5000)   // a web area much taller than the window
        let unit = PresenceGeometry.unit(of: page, in: window)
        XCTAssertEqual(unit.minY, 0.1, accuracy: 1e-9)
        XCTAssertEqual(unit.maxY, 1, accuracy: 1e-9)
    }

    func testControlScrolledAwayGoesToTheEdgeWithNoOutline() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let below = CGRect(x: 400, y: 3000, width: 100, height: 20)
        let unit = PresenceGeometry.unit(of: below, in: window)
        XCTAssertEqual(unit.size, .zero)
        XCTAssertEqual(unit.minX, 0.45, accuracy: 1e-9)
        XCTAssertEqual(unit.minY, 1, accuracy: 1e-9)
    }

    func testNoFramesGiveTheMiddle() {
        XCTAssertEqual(PresenceGeometry.unit(of: nil, in: CGRect(x: 0, y: 0, width: 10, height: 10)),
                       CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
        XCTAssertEqual(PresenceGeometry.unit(of: CGRect(x: 1, y: 1, width: 1, height: 1), in: nil),
                       CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    }

    /// The title bar spot scales with the zoom the window is drawn at.
    func testOffsetScalesWithZoom() {
        let p = PresenceGeometry.point(unit: CGPoint(x: 0.5, y: 0), offset: CGPoint(x: 0, y: 15),
                                       in: CGRect(x: 0, y: 0, width: 400, height: 300), zoom: 0.5)
        XCTAssertEqual(p, CGPoint(x: 200, y: 7.5))
    }

    func testOffScreenSpotWaitsAtTheEdge() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let inside = PresenceGeometry.clamp(CGPoint(x: 700, y: 400), into: display, inset: 36)
        XCTAssertFalse(inside.outside)
        XCTAssertEqual(inside.point, CGPoint(x: 700, y: 400))
        let right = PresenceGeometry.clamp(CGPoint(x: 4000, y: 400), into: display, inset: 36)
        XCTAssertTrue(right.outside)
        XCTAssertEqual(right.point, CGPoint(x: 1476, y: 400))
    }

    func testArcStartsAndEndsOnItsPoints() {
        let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 900, y: 500)
        XCTAssertEqual(PresenceGeometry.arc(from: a, to: b, t: 0), a)
        let end = PresenceGeometry.arc(from: a, to: b, t: 1)
        XCTAssertEqual(end.x, b.x, accuracy: 1e-6)
        XCTAssertEqual(end.y, b.y, accuracy: 1e-6)
        // Bowed: the middle is off the straight line.
        let mid = PresenceGeometry.arc(from: a, to: b, t: 0.5)
        XCTAssertGreaterThan(hypot(mid.x - (a.x + b.x) / 2, mid.y - (a.y + b.y) / 2), 10)
    }

    func testFlightsAreQuick() {
        XCTAssertEqual(PresenceGeometry.flightDuration(from: .zero, to: CGPoint(x: 1, y: 1)), 0)
        XCTAssertEqual(PresenceGeometry.flightDuration(from: .zero, to: CGPoint(x: 40, y: 0)), 0.18, accuracy: 1e-9)
        XCTAssertEqual(PresenceGeometry.flightDuration(from: .zero, to: CGPoint(x: 5000, y: 0)), 0.45, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(PresenceGeometry.typingDuration(500), 0.9)
    }

    /// The overlay's layers are y-up, from the display's bottom-left; global points are y-down.
    func testLocalCoordinatesFlip() {
        let display = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(PresenceGeometry.local(CGPoint(x: 1512, y: -200), display: display), CGPoint(x: 0, y: 1080))
        XCTAssertEqual(PresenceGeometry.local(CGRect(x: 1612, y: -100, width: 50, height: 20), display: display),
                       CGRect(x: 100, y: 960, width: 50, height: 20))
    }

    func testPressesForActions() {
        XCTAssertEqual(AppTools.press(for: "set_value", text: "hi"), .typed("hi"))
        XCTAssertEqual(AppTools.press(for: "confirm", text: ""), .returnKey)
        XCTAssertEqual(AppTools.press(for: "select", text: "Economy"), .chose("Economy"))
        XCTAssertEqual(AppTools.press(for: "scroll_up", text: ""), .scrolled(down: false))
        XCTAssertEqual(AppTools.press(for: "click", text: ""), .click)
    }
}
