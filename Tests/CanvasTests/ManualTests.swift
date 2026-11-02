import AppKit
import XCTest
@testable import Canvas

final class ManualTests: XCTestCase {
    func testEveryChapterHasATitleAndASymbol() {
        for chapter in Manual.Chapter.allCases {
            XCTAssertFalse(chapter.title.isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: chapter.symbol, accessibilityDescription: nil), chapter.symbol)
        }
    }

    func testTheBasicsTeachTheGesturesAsTheyAreNow() {
        let rows = Manual.gettingAround
        XCTAssertEqual(rows.first?.title, "See everything")
        XCTAssertEqual(rows.first?.how, "four-finger tap (or swipe up: Settings › How to use)")
        XCTAssertFalse(rows.contains { $0.how.contains("esc") }, "esc does nothing on the canvas")
        XCTAssertEqual(Set(rows.map(\.title)).count, rows.count)
        XCTAssertTrue(rows.suffix(2).contains { $0.how.contains("four-finger drag") }, "four-finger pan near the end")
        XCTAssertTrue(rows.contains { $0.title == "Go into a window" && $0.how.contains("pinch in") })
        XCTAssertEqual(Set(Manual.whereThingsAre.map(\.title)).count, Manual.whereThingsAre.count)
    }
}
