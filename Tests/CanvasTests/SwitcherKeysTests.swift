import XCTest
import CoreGraphics
@testable import Canvas

final class SwitcherKeysTests: XCTestCase {
    private let tab: Int64 = 48, grave: Int64 = 50, left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126

    private func act(_ key: Int64, _ flags: CGEventFlags, open: Bool) -> KeyTap.Action {
        var state = KeyTap.State()
        state.switcherOpen = open
        return KeyTap.action(keyCode: key, flags: flags, state: &state)
    }

    func testCommandTabOpensThenSteps() {
        var state = KeyTap.State()
        XCTAssertEqual(KeyTap.action(keyCode: tab, flags: .maskCommand, state: &state), .send(.appSwitchBegin(reverse: false)))
        XCTAssertTrue(state.switcherOpen)
        XCTAssertEqual(KeyTap.action(keyCode: tab, flags: [.maskCommand, .maskShift], state: &state), .send(.appSwitchStep(reverse: true)))
    }

    func testWindowStepsWhileSwitching() {
        XCTAssertEqual(act(grave, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: false)))
        XCTAssertEqual(act(grave, [.maskCommand, .maskShift], open: true), .send(.appSwitchWindowStep(reverse: true)))
        XCTAssertEqual(act(down, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: false)))
        XCTAssertEqual(act(up, .maskCommand, open: true), .send(.appSwitchWindowStep(reverse: true)))
    }

    func testArrowsAcrossTheStripStepApps() {
        XCTAssertEqual(act(right, .maskCommand, open: true), .send(.appSwitchStep(reverse: false)))
        XCTAssertEqual(act(left, .maskCommand, open: true), .send(.appSwitchStep(reverse: true)))
    }

    func testTheSameKeysPassWhenNotSwitching() {
        XCTAssertEqual(act(grave, .maskCommand, open: false), .pass, "⌘` stays the Mac's own outside the switcher")
        XCTAssertEqual(act(down, .maskCommand, open: false), .pass)
        XCTAssertEqual(act(left, .maskCommand, open: false), .pass)
    }

    func testControlArrowsKeepTheirMeaningWhileSwitching() {
        XCTAssertEqual(act(left, .maskControl, open: true), .swallow)
    }

    func testOnlyTheMissionControlKeySeesAll() {
        let missionControlKey: Int64 = 160
        XCTAssertEqual(act(missionControlKey, [], open: false), .send(.missionControl))
        XCTAssertEqual(act(up, .maskControl, open: false), .swallow, "⌃↑ would open Mission Control: one Desktop, the canvas")
        XCTAssertEqual(act(down, .maskControl, open: false), .swallow, "⌃↓ would open App Exposé")
        XCTAssertEqual(act(grave, .maskAlternate, open: false), .pass, "⌥` is the app's own")
    }

    // MARK: Holding the Mission Control key

    func testHoldingTheMissionControlKeyIsOnePressAndItsReleaseSaysHowLong() {
        let missionControlKey: Int64 = 160
        var state = KeyTap.State()
        XCTAssertEqual(KeyTap.action(keyCode: missionControlKey, flags: [], state: &state, timestamp: 1_000_000_000), .send(.missionControl))
        state.swallowed.insert(missionControlKey)   // as the tap does for anything it doesn't pass
        XCTAssertEqual(KeyTap.action(keyCode: missionControlKey, flags: [], state: &state, autorepeat: true, timestamp: 1_500_000_000),
                       .swallow, "the key repeating while held isn't another toggle")
        XCTAssertEqual(KeyTap.release(keyCode: missionControlKey, state: &state, timestamp: 1_750_000_000),
                       .send(.missionControlUp(held: 0.75)))
        XCTAssertNil(state.missionControlDownAt)
        XCTAssertTrue(state.swallowed.isEmpty)
        XCTAssertEqual(KeyTap.release(keyCode: missionControlKey, state: &state, timestamp: 2_000_000_000), .pass,
                       "a release whose press wasn't ours is the app's")
    }

    func testOtherKeysReleaseAsBefore() {
        var state = KeyTap.State()
        state.swallowed.insert(tab)
        XCTAssertEqual(KeyTap.release(keyCode: tab, state: &state, timestamp: 0), .swallow)
        XCTAssertEqual(KeyTap.release(keyCode: tab, state: &state, timestamp: 0), .pass)
    }

    func testAHoldPicksATapIsTheKeyAsBefore() {
        XCTAssertEqual(MissionControlHold.release(held: 0.1, press: .fromWindow), .stay, "from a window a tap is See All, which stays")
        XCTAssertEqual(MissionControlHold.release(held: 0.1, press: .onCanvas), .toggle, "on the canvas a tap goes back into the last window")
        XCTAssertEqual(MissionControlHold.release(held: 0.6, press: .fromWindow), .pick)
        XCTAssertEqual(MissionControlHold.release(held: 0.6, press: .onCanvas), .pick)
        XCTAssertEqual(MissionControlHold.release(held: MissionControlHold.threshold, press: .onCanvas), .pick)
    }

    // MARK: ⌘N inside a window

    func testCommandNIsTheCanvasesOnlyInsideAWindowThatPlacesNewWindows() {
        let n: Int64 = 45
        var state = KeyTap.State()
        XCTAssertEqual(KeyTap.action(keyCode: n, flags: .maskCommand, state: &state), .pass)
        state.entered = true
        XCTAssertEqual(KeyTap.action(keyCode: n, flags: .maskCommand, state: &state), .pass)
        state.placesNewWindow = true
        XCTAssertEqual(KeyTap.action(keyCode: n, flags: .maskCommand, state: &state), .send(.newWindow))
        XCTAssertEqual(KeyTap.action(keyCode: n, flags: [.maskCommand, .maskShift], state: &state), .pass)
        XCTAssertEqual(KeyTap.action(keyCode: n, flags: [], state: &state), .pass)
    }

    func testCommandNIsTheNWhereverTheLayoutHasIt() {
        var state = KeyTap.State()
        state.entered = true
        state.placesNewWindow = true
        // Dvorak: the key at QWERTY N types b, and N is at QWERTY L (37).
        XCTAssertEqual(KeyTap.action(keyCode: 45, flags: .maskCommand, state: &state, character: "b"), .pass)
        XCTAssertEqual(KeyTap.action(keyCode: 37, flags: .maskCommand, state: &state, character: "n"), .send(.newWindow))
    }

    func testCommandQuestionMarkOpensHowToUseFromAnywhere() {
        var state = KeyTap.State()
        let slash: Int64 = 44
        XCTAssertEqual(KeyTap.action(keyCode: slash, flags: [.maskCommand, .maskShift], state: &state), .send(.howToUse))
        XCTAssertEqual(KeyTap.action(keyCode: 99, flags: .maskCommand, state: &state, character: "?"), .send(.howToUse))
        // Bulgarian Phonetic: ⌘ reads the key as its Latin twin, but without ⌘ it types ?.
        XCTAssertEqual(KeyTap.action(keyCode: 99, flags: [.maskCommand, .maskShift], state: &state, character: "7", symbol: "?"), .send(.howToUse))
        XCTAssertEqual(KeyTap.action(keyCode: slash, flags: .maskCommand, state: &state), .pass, "⌘/ is not ⌘?")
        XCTAssertEqual(KeyTap.action(keyCode: slash, flags: [.maskCommand, .maskShift, .maskAlternate], state: &state), .pass)
        state.entered = true
        XCTAssertEqual(KeyTap.action(keyCode: slash, flags: [.maskCommand, .maskShift], state: &state), .send(.howToUse), "inside a window too")
    }
}
