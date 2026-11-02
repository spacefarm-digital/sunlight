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

    private func act(_ key: Int64, _ flags: CGEventFlags, entered: Bool = false, fullScreen: Bool = false, character: String? = nil) -> KeyTap.Action {
        var state = KeyTap.State()
        state.entered = entered
        state.inFullScreenSpace = fullScreen
        return KeyTap.action(keyCode: key, flags: flags, state: &state, character: character)
    }

    func testControlArrowsAreSwallowedOnTheCanvasDesktop() {
        for key in [left, right, up, down] { XCTAssertEqual(act(key, .maskControl), .swallow) }
    }

    func testControlLeftPassesInAFullScreenSpace() {
        XCTAssertEqual(act(left, .maskControl, fullScreen: true), .pass, "the way back to the canvas's Desktop")
        XCTAssertEqual(act(right, .maskControl, fullScreen: true), .swallow)
        XCTAssertEqual(act(up, .maskControl, fullScreen: true), .swallow)
    }

    func testControlCommandFInAWindowIsSunlightsFullScreen() {
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true, character: "\u{06}"), .send(.fillAndEnter))
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true), .send(.fillAndEnter))
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: false), .pass, "on the canvas it's the Mac's")
        XCTAssertEqual(act(f, [.maskControl, .maskCommand], entered: true, fullScreen: true), .pass, "a full-screen app leaves its way")
        XCTAssertEqual(act(f, .maskCommand, entered: true, character: "f"), .pass, "⌘F is find")
    }
}
