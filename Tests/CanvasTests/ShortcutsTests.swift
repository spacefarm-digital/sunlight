import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Canvas

/// Settings › Shortcuts and › Trackpad: the defaults, the overrides, the conflicts and the old See All
/// choice's migration. Every test starts and ends from the untouched bindings.
@MainActor
final class ShortcutsTests: XCTestCase {
    override nonisolated func setUp() {
        super.setUp()
        // XCTest runs setUp on the main thread; the bindings live on the main actor.
        MainActor.assumeIsolated { Bindings.resetAll() }
    }

    override nonisolated func tearDown() {
        MainActor.assumeIsolated { Bindings.resetAll() }
        super.tearDown()
    }

    private func key(_ code: Int, _ character: String,
                     _ modifiers: UInt32 = UInt32(controlKey | optionKey)) -> Shortcut {
        Shortcut(keyCode: UInt32(code), modifiers: modifiers, key: character)
    }

    func testReservedKeyTapShortcutsAreRejected() {
        XCTAssertTrue(key(kVK_Tab, "\t", UInt32(cmdKey)).isReservedByKeyTap)
        XCTAssertTrue(key(kVK_LeftArrow, "left", UInt32(controlKey)).isReservedByKeyTap)
        XCTAssertFalse(key(kVK_ANSI_U, "u").isReservedByKeyTap)
        XCTAssertFalse(Command.showDesktop.defaultShortcut!.isReservedByKeyTap)
        XCTAssertFalse(Command.toggleCanvas.defaultShortcut!.isReservedByKeyTap)
    }

    // MARK: Defaults

    func testTheDefaultsAreTheKeysSunlightAlwaysHad() {
        XCTAssertEqual(Bindings.shortcut(for: .leftHalf)?.label, "⌃⌥←")
        XCTAssertEqual(Bindings.shortcut(for: .topLeft)?.label, "⌃⌥U")
        XCTAssertEqual(Bindings.shortcut(for: .full)?.label, "⌃⌥⏎")
        XCTAssertEqual(Bindings.shortcut(for: .tidy)?.label, "⌃⌥A")
        XCTAssertEqual(Bindings.shortcut(for: .nextDisplay)?.label, "⌃⌥⇧→")
        XCTAssertEqual(Bindings.shortcut(for: .showDesktop)?.label, "F11")
        XCTAssertNil(Bindings.shortcut(for: .centerTwoThirds))
        XCTAssertNil(Bindings.shortcut(for: .seeAll))
        XCTAssertEqual(Bindings.shortcut(for: .toggleCanvas)?.label, "Mission Control")
        XCTAssertNil(Bindings.shortcut(for: .panCanvas))
        XCTAssertEqual(Bindings.shortcut(for: .enterWindow)?.label, "⏎")
        XCTAssertEqual(Bindings.shortcut(for: .flipPolarity)?.label, "P")
        XCTAssertFalse(Command.globalKeyCommands.contains(.enterWindow))
        XCTAssertFalse(Command.globalKeyCommands.contains(.flipPolarity))
        XCTAssertEqual(Bindings.shortcut(for: .saveLayout)?.label, "⌘S")
        XCTAssertEqual(Bindings.shortcut(for: .restoreLayout9)?.label, "⌘9")
        XCTAssertFalse(Command.globalKeyCommands.contains(.saveLayout))
        XCTAssertEqual(Bindings.conflict(for: key(kVK_ANSI_S, "s", UInt32(cmdKey)), excluding: .tidy), .saveLayout)
    }

    func testTheSummariesReadTheSameAsBeforeUntilAKeyChanges() {
        XCTAssertEqual(TileMenu.tileKeysSummary, "⌃⌥ ← → ↑ ↓ · U I J K · D F G · E T · ⏎ C")
        XCTAssertEqual(TileMenu.arrangeKeysSummary, "⌃⌥ 2 · 3 · 4")
        XCTAssertEqual(TileMenu.tidyKeysSummary, "⌃⌥A")
    }

    // MARK: Changing a key

    func testHotkeyIsReleasedWhenOwnerDropsIt() {
        weak var released: Hotkey?
        autoreleasepool {
            let hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey | shiftKey)) {}
            released = hotkey
            withExtendedLifetime(hotkey) { XCTAssertNotNil(released) }
        }
        XCTAssertNil(released)
    }

    func testAKeyCanBeChangedAndCleared() {
        let custom = key(kVK_ANSI_L, "l")
        Bindings.setShortcut(custom, for: .leftHalf)
        XCTAssertEqual(Bindings.shortcut(for: .leftHalf), custom)
        XCTAssertEqual(TileMenu.tileKeysSummary, "⌃⌥L · ⌃⌥→ · ⌃⌥↑ · ⌃⌥↓ · ⌃⌥U · ⌃⌥I · ⌃⌥J · ⌃⌥K · ⌃⌥D · ⌃⌥F · ⌃⌥G · ⌃⌥E · ⌃⌥T · ⌃⌥⏎ · ⌃⌥C")

        // Back to the default: no override is left behind.
        Bindings.setShortcut(key(kVK_LeftArrow, String(Character(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!))),
                             for: .leftHalf)
        XCTAssertEqual(TileMenu.tileKeysSummary, "⌃⌥ ← → ↑ ↓ · U I J K · D F G · E T · ⏎ C")

        // Removed entirely: the menu shows no key and nothing claims it.
        Bindings.setShortcut(nil, for: .tidy)
        XCTAssertNil(Bindings.shortcut(for: .tidy))
        XCTAssertEqual(TileMenu.tidyKeysSummary, "")
    }

    func testAKeyAnotherCommandHoldsIsAConflict() {
        let custom = key(kVK_ANSI_L, "l")
        Bindings.setShortcut(custom, for: .rightHalf)
        XCTAssertEqual(Bindings.conflict(for: custom, excluding: .leftHalf), .rightHalf)
        XCTAssertNil(Bindings.conflict(for: custom, excluding: .rightHalf))
    }

    func testAShortcutNeedsAControlOptionOrCommandKey() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "L", charactersIgnoringModifiers: "L",
                                     isARepeat: false, keyCode: UInt16(kVK_ANSI_L))!
        XCTAssertNil(Shortcut(event: event))
        XCTAssertEqual(Shortcut(event: event, allowUnmodified: true)?.label, "⇧L")
        XCTAssertTrue(Shortcut(event: event, allowUnmodified: true)!.matches(event))
        let withOption = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "l", charactersIgnoringModifiers: "l",
                                          isARepeat: false, keyCode: UInt16(kVK_ANSI_L))!
        XCTAssertEqual(Shortcut(event: withOption)?.label, "⌥L")
    }

    // MARK: Gestures

    func testTheGesturesDefaultToTapSeeAllSpreadDesktopAndDragPan() {
        XCTAssertEqual(Bindings.command(for: .fourFingerTap), .seeAll)
        XCTAssertEqual(Bindings.command(for: .spread), .showDesktop)
        XCTAssertEqual(Bindings.command(for: .fourFingerDrag), .panCanvas)
        XCTAssertNil(Bindings.command(for: .swipeUp))
        XCTAssertNil(Bindings.command(for: .swipeDown))
        XCTAssertNil(Bindings.command(for: .swipeLeft))
        XCTAssertNil(Bindings.command(for: .swipeRight))

        let config = Bindings.trackpadConfig()
        XCTAssertTrue(config.tap)
        XCTAssertTrue(config.spread)
        XCTAssertEqual(config.drag, .pan)
        XCTAssertTrue(config.flicks.isEmpty)
    }

    func testAGestureCanBeGivenACommandAndPutBack() {
        Bindings.setGesture(.tidy, for: .swipeUp)
        XCTAssertEqual(Bindings.command(for: .swipeUp), .tidy)
        XCTAssertEqual(Bindings.gesture(doing: .tidy), .swipeUp)
        XCTAssertEqual(Bindings.trackpadConfig().flicks, [.swipeUp])

        Bindings.setGesture(nil, for: .fourFingerTap)
        XCTAssertNil(Bindings.command(for: .fourFingerTap))
        XCTAssertFalse(Bindings.trackpadConfig().tap)

        Bindings.setGesture(.tidy, for: .fourFingerDrag)
        XCTAssertEqual(Bindings.trackpadConfig().drag, .fire)
        Bindings.setGesture(nil, for: .fourFingerDrag)
        XCTAssertEqual(Bindings.trackpadConfig().drag, .off)

        Bindings.resetGestures()
        XCTAssertEqual(Bindings.command(for: .fourFingerTap), .seeAll)
        XCTAssertNil(Bindings.command(for: .swipeUp))
    }

    // MARK: Migration

    func testTheOldSwipeUpChoiceBecomesTheGestureBindings() {
        UserDefaults.standard.set("swipeUp", forKey: "CanvasSeeAllGesture")
        Bindings.migrateIfNeeded()

        XCTAssertNil(Bindings.command(for: .fourFingerTap))
        XCTAssertEqual(Bindings.command(for: .swipeUp), .seeAll)
        XCTAssertEqual(Settings.seeAllGesture, .swipeUp)
        XCTAssertNil(UserDefaults.standard.string(forKey: "CanvasSeeAllGesture"))
    }
}
