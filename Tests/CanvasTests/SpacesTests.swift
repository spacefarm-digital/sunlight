import XCTest
import CoreGraphics
@testable import Canvas

final class SpacesTests: XCTestCase {
    private func raw(_ displays: [(String, current: UInt64, spaces: [(UInt64, Int)])]) -> [[String: Any]] {
        displays.map { d in
            ["Display Identifier": d.0,
             "Current Space": ["id64": NSNumber(value: d.current), "type": NSNumber(value: 0)],
             "Spaces": d.spaces.map { ["id64": NSNumber(value: $0.0), "type": NSNumber(value: $0.1)] }] as [String: Any]
        }
    }

    func testReadsDesktopsPerDisplay() {
        let displays = Spaces.displays(from: raw([("A", current: 3, spaces: [(1, 0), (3, 0), (9, 4)]), ("B", current: 5, spaces: [(5, 0)])]))
        XCTAssertEqual(displays.map(\.identifier), ["A", "B"])
        XCTAssertEqual(displays[0].desktops.map(\.id), [1, 3])
        XCTAssertEqual(displays[0].spaces.last?.kind, .fullScreen)
        XCTAssertEqual(displays[0].canvasDesktop, 3)
        XCTAssertEqual(Spaces.extraDesktops(displays), 1)
    }

    func testInAFullScreenSpaceTheCanvasIsTheFirstDesktop() {
        let displays = Spaces.displays(from: raw([("A", current: 9, spaces: [(1, 0), (3, 0), (9, 4)])]))
        XCTAssertEqual(displays[0].canvasDesktop, 1)
        XCTAssertTrue(Spaces.inFullScreenSpace(displays))
    }

    func testTheFullScreenSpacesInFrontArePerDisplay() {
        let displays = Spaces.displays(from: raw([("A", current: 9, spaces: [(1, 0), (9, 4)]), ("B", current: 5, spaces: [(5, 0), (12, 4)])]))
        XCTAssertEqual(Spaces.frontFullScreenSpaces(displays), [9])
    }

    func testAFullScreenAppsSpaceIsSeen() {
        let displays = Spaces.displays(from: raw([("A", current: 1, spaces: [(1, 0), (9, 4)])]))
        XCTAssertTrue(Spaces.hasFullScreenSpaces(displays))
        XCTAssertFalse(Spaces.hasFullScreenSpaces(Spaces.displays(from: raw([("A", current: 1, spaces: [(1, 0)])]))))
    }

    func testOneDesktopPerDisplayHasNothingToFold() {
        let displays = Spaces.displays(from: raw([("A", current: 1, spaces: [(1, 0), (9, 4)]), ("B", current: 5, spaces: [(5, 0)])]))
        XCTAssertEqual(Spaces.extraDesktops(displays), 0)
        XCTAssertTrue(Spaces.fold(displays, windows: [(10, [1]), (11, [9]), (12, [5])]).isEmpty)
    }

    func testFoldMovesWindowsOnOtherDesktopsAndRemovesThem() {
        let displays = Spaces.displays(from: raw([("A", current: 1, spaces: [(1, 0), (2, 0), (9, 4)]), ("B", current: 5, spaces: [(5, 0), (6, 0)])]))
        let fold = Spaces.fold(displays, windows: [
            (10, [1]),       // on the canvas already
            (11, [2]),       // another Desktop on A
            (12, [9]),       // a full-screen app: left alone
            (13, [6]),       // another Desktop on B
            (14, [1, 2, 5]), // on every Desktop
            (15, []),        // the window server doesn't say
        ])
        XCTAssertEqual(fold.moves.map(\.window), [11, 13])
        XCTAssertEqual(fold.moves.map(\.to), [1, 5])
        XCTAssertEqual(fold.removals, [2, 6])
    }

    func testAnAppWhoseWindowCameOverIsQuietForAMoment() {
        let now = Date()
        Spaces.noteFolding([42], now: now)
        XCTAssertTrue(Spaces.justFolded(42, now: now.addingTimeInterval(1)))
        XCTAssertFalse(Spaces.justFolded(7, now: now.addingTimeInterval(1)), "another app is the person's")
        XCTAssertFalse(Spaces.justFolded(42, now: now.addingTimeInterval(Spaces.quietAfterFold + 0.1)))
        Spaces.noteFolding([], now: now)
    }

    func testTheDesktopsOpOnTheWire() {
        let move = LiveWindowsWire.moveToDesktop([7, 9], desktop: 0x0102)
        XCTAssertEqual(Array(move), [19, 0, 0x78, 1, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 2, 7, 0, 0, 0, 9, 0, 0, 0])
        XCTAssertEqual(Array(LiveWindowsWire.removeDesktop(5)), [10, 0, 0x78, 2, 5, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(LiveWindowsWire.spacesInDock(LiveWindowsWire.additionVersion))
        XCTAssertFalse(LiveWindowsWire.spacesInDock("sunlight-54"))
    }
}

final class SpacesKeysTests: XCTestCase {
    private let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126, f: Int64 = 3

    private func act(_ key: Int64, _ flags: CGEventFlags, entered: Bool = false, fullScreen: Bool = false,
                     fullScreenSpaces: Bool = false, character: String? = nil) -> KeyTap.Action {
        var state = KeyTap.State()
        state.entered = entered
        state.inFullScreenSpace = fullScreen
        state.hasFullScreenSpaces = fullScreen || fullScreenSpaces
        return KeyTap.action(keyCode: key, flags: flags, state: &state, character: character)
    }

    func testControlArrowsAreSwallowedOnTheCanvasDesktop() {
        for key in [left, right, up, down] { XCTAssertEqual(act(key, .maskControl), .swallow) }
    }

    func testControlLeftAndRightPassInAFullScreenSpace() {
        XCTAssertEqual(act(left, .maskControl, fullScreen: true), .pass, "the way back to the canvas's Desktop")
        XCTAssertEqual(act(right, .maskControl, fullScreen: true), .pass, "on to the next full-screen app")
        XCTAssertEqual(act(up, .maskControl, fullScreen: true), .swallow)
    }

    func testControlLeftAndRightReachFullScreenAppsFromTheCanvas() {
        XCTAssertEqual(act(right, .maskControl, fullScreenSpaces: true), .pass, "over to a full-screen app's Space")
        XCTAssertEqual(act(left, .maskControl, fullScreenSpaces: true), .pass)
        XCTAssertEqual(act(down, .maskControl, fullScreenSpaces: true), .swallow)
    }


    func testControlCommandFInAWindowIsSunlightsFullScreen() {
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true, character: "\u{06}"), .send(.fillAndEnter))
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true), .send(.fillAndEnter))
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: false), .pass, "on the canvas it's the Mac's")
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true, fullScreen: true), .pass, "a full-screen app leaves its way")
        XCTAssertEqual(act(f, .maskCommand, entered: true, character: "f"), .pass, "⌘F is find")
    }

    // MARK: The green button

    private let window = CGRect(x: 100, y: 200, width: 800, height: 600)
    private var button: KeyTap.GreenButton {
        KeyTap.GreenButton(window: 7, centre: CGPoint(x: 62, y: 16), diameter: 14, windowFrame: window)
    }

    private func press(_ point: CGPoint, _ flags: CGEventFlags = [], entered: Bool = true, fullScreen: Bool = false,
                       front: CGWindowID = 7, state: inout KeyTap.State) -> KeyTap.Action {
        state.entered = entered
        state.inFullScreenSpace = fullScreen
        state.greenButton = button
        let bounds = front == 7 ? window : CGRect(x: 120, y: 205, width: 200, height: 300)
        return KeyTap.press(at: point, flags: flags, state: &state, frontWindow: { _ in (front, bounds) })
    }

    func testAClickOnTheGreenButtonIsSunlightsFullScreen() {
        var state = KeyTap.State()
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), state: &state), .send(.fillAndEnter))
        XCTAssertEqual(KeyTap.releasePress(state: &state), .swallow, "its release is taken too")
        XCTAssertEqual(KeyTap.releasePress(state: &state), .pass)
    }

    func testOtherClicksAreTheApps() {
        var state = KeyTap.State()
        XCTAssertEqual(press(CGPoint(x: 139, y: 216), state: &state), .pass, "the yellow button")
        XCTAssertEqual(press(CGPoint(x: 400, y: 400), state: &state), .pass)
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), .maskAlternate, state: &state), .pass, "⌥-click is the Mac's zoom")
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), entered: false, state: &state), .pass)
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), fullScreen: true, state: &state), .pass, "in full screen it leaves full screen")
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), front: 9, state: &state), .pass, "a menu or panel over the button")
        XCTAssertEqual(KeyTap.releasePress(state: &state), .pass)
    }

    func testAPressForgetsAReleaseThatNeverCame() {
        var state = KeyTap.State()
        XCTAssertEqual(press(CGPoint(x: 162, y: 216), state: &state), .send(.fillAndEnter))
        // The tap was off for the release; the next click is the app's, press and release.
        XCTAssertEqual(press(CGPoint(x: 400, y: 400), state: &state), .pass)
        XCTAssertEqual(KeyTap.releasePress(state: &state), .pass)
    }

    func testOnlyClicksNearWhereTheButtonWasAskTheWindowServer() {
        var state = KeyTap.State()
        state.entered = true
        state.greenButton = button
        XCTAssertTrue(KeyTap.mayBeOnGreenButton(CGPoint(x: 164, y: 218), flags: [], state: state))
        XCTAssertFalse(KeyTap.mayBeOnGreenButton(CGPoint(x: 400, y: 400), flags: [], state: state))
    }
}
