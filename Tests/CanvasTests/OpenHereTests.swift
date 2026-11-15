import XCTest
@testable import Canvas

final class OpenHereTests: XCTestCase {
    // MARK: The bar's matcher

    func testANamesStartBeatsAWordStartBeatsAnywhereBeatsScatteredLetters() {
        let prefix = AppCatalog.score("saf", in: "safari")
        let word = AppCatalog.score("code", in: "visual studio code")
        let inside = AppCatalog.score("ari", in: "safari")
        let scattered = AppCatalog.score("sfr", in: "safari")
        XCTAssertEqual(prefix, 100)
        XCTAssertEqual(word, 80)
        XCTAssertEqual(inside, 60)
        XCTAssertEqual(scattered, 38)
    }

    func testLettersNotInTheNameDontMatch() {
        XCTAssertNil(AppCatalog.score("xyz", in: "safari"))
        XCTAssertNil(AppCatalog.score("ifas", in: "safari"))   // in the wrong order
    }

    // MARK: Which menu item makes a new window

    private func item(_ title: String, key: String? = nil, commandOnly: Bool = true, enabled: Bool = true,
                      submenu: Bool = false) -> NewWindowMenu.Item {
        NewWindowMenu.Item(title: title, key: key, commandOnly: key != nil && commandOnly, enabled: enabled, hasSubmenu: submenu)
    }

    func testSafarisNewWindowIsPickedOverItsOtherNewItems() {
        let items = [item("New Window", key: "N"), item("New Private Window", key: "N", commandOnly: false),
                     item("New Tab", key: "T")]
        XCTAssertEqual(NewWindowMenu.best(items), 0)
    }

    func testTerminalsDefaultProfileInsideItsNewWindowSubmenu() {
        let items = [item("New Window", submenu: true), item("New Tab", submenu: true),
                     item("New Window with Profile - Basic", key: "N"), item("New Window with Profile - Pro")]
        XCTAssertEqual(NewWindowMenu.best(items), 2)
    }

    func testANewWindowItemWithAnotherShortcutBeatsANewDocument() {
        // Xcode: New Window is ⇧⌘T, ⌘N makes a file.
        let items = [item("New File…", key: "N"), item("New Window", key: "T", commandOnly: false)]
        XCTAssertEqual(NewWindowMenu.best(items), 1)
    }

    func testOtherwiseCommandNMakesANewDocument() {
        let items = [item("New", key: "N"), item("Open…", key: "O")]
        XCTAssertEqual(NewWindowMenu.best(items), 0)
    }

    func testNothingDisabledAndNothingWithoutANewItem() {
        XCTAssertNil(NewWindowMenu.best([item("New Window", key: "N", enabled: false)]))
        XCTAssertNil(NewWindowMenu.best([item("Open…", key: "O"), item("Close", key: "W")]))
    }

    // MARK: Whether ⌘N inside a window is the canvas's

    func testCommandNThatSaysWindowIsTaken() {
        XCTAssertEqual(NewWindowMenu.windowCommandN([item("New Tab", key: "T"), item("New Finder Window", key: "N")]), 1)
        let terminal = [item("New Window", submenu: true), item("New Window with Profile - Basic", key: "N")]
        XCTAssertEqual(NewWindowMenu.windowCommandN(terminal), 1)
    }

    func testCommandNThatMayNotMakeAWindowIsLeftToTheApp() {
        XCTAssertNil(NewWindowMenu.windowCommandN([item("New Note", key: "N")]))
        XCTAssertNil(NewWindowMenu.windowCommandN([item("New File…", key: "N"), item("New Window", key: "T", commandOnly: false)]))
        XCTAssertNil(NewWindowMenu.windowCommandN([item("New Window", key: "N", enabled: false)]))
        // Mail: ⌘N is New Message; ⌥⌘N's New Viewer Window isn't ⌘N's.
        XCTAssertNil(NewWindowMenu.windowCommandN([item("New Message", key: "N"),
                                                   item("New Viewer Window", key: "N", commandOnly: false)]))
    }

    func testWhenNoItemReadsAsCommandAloneTheFirstWindowOneIsTaken() {
        // Finder on macOS 27: every N item reads as having more than ⌘.
        let finder = [item("New Finder Window", key: "N", commandOnly: false),
                      item("New Folder", key: "N", commandOnly: false, enabled: false)]
        XCTAssertEqual(NewWindowMenu.windowCommandN(finder), 0)
    }

    func testWhenNoItemReadsAsCommandAloneAFirstItemThatIsntAWindowsLeavesItToTheApp() {
        // ⌘N makes a document; the window item after it is ⇧⌘N's.
        let editor = [item("New Document", key: "N", commandOnly: false),
                      item("New Private Window", key: "N", commandOnly: false)]
        XCTAssertNil(NewWindowMenu.windowCommandN(editor))
    }

    // MARK: ⌘N, remembered

    func testAnAppsCommandNIsReadOnceAndThenTakenAsRead() {
        var memory = CommandNMemory()
        XCTAssertNil(memory.makes(7))
        XCTAssertTrue(memory.needsReading(7, now: 100))
        XCTAssertNil(memory.note(7, makes: true, settled: true, now: 100))
        XCTAssertEqual(memory.makes(7), true)
        XCTAssertFalse(memory.needsReading(7, now: 100 + CommandNMemory.keepFor - 1))
        XCTAssertTrue(memory.needsReading(7, now: 100 + CommandNMemory.keepFor))
        XCTAssertTrue(memory.needsReading(8, now: 101), "another app is its own question")
        XCTAssertEqual(memory.note(7, makes: false, settled: true, now: 800), true)
        XCTAssertEqual(memory.makes(7), false)
    }

    func testAnAppStillStartingIsAskedAgainSoon() {
        var memory = CommandNMemory()
        memory.note(7, makes: false, settled: false, now: 100)
        XCTAssertFalse(memory.needsReading(7, now: 105))
        XCTAssertTrue(memory.needsReading(7, now: 100 + CommandNMemory.unsettledFor))
    }

    func testAMenuThatCouldNotBeReadKeepsTheLastAnswerAndIsReadAgain() {
        var memory = CommandNMemory()
        memory.note(7, makes: nil, settled: true, now: 100)
        XCTAssertNil(memory.makes(7))
        XCTAssertTrue(memory.needsReading(7, now: 100))
        memory.note(7, makes: true, settled: true, now: 101)
        XCTAssertEqual(memory.note(7, makes: nil, settled: true, now: 110), true)
        XCTAssertEqual(memory.makes(7), true)
        XCTAssertTrue(memory.needsReading(7, now: 110))
    }

    func testCommandNPressedOrTheAppGoneMeansReadingAgain() {
        var memory = CommandNMemory()
        memory.note(7, makes: true, settled: true, now: 100)
        memory.readAgain(7)
        XCTAssertEqual(memory.makes(7), true, "the answer stands until the next read")
        XCTAssertTrue(memory.needsReading(7, now: 101))
        memory.forget(7)
        XCTAssertNil(memory.makes(7))
    }
}
