import XCTest
@testable import Canvas

/// Sunlight's own windows (Sparkle's Software Update, the About panel) land where they can be reached.
final class OwnWindowsTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let side = CGRect(x: 1512, y: 0, width: 1920, height: 1050)

    func testAWindowOnScreenStaysWhereItIs() {
        XCTAssertNil(OwnWindows.placement(for: CGRect(x: 400, y: 300, width: 569, height: 178), screens: [main], pointer: .zero))
    }

    func testAWindowMostlyOnAnotherScreenStays() {
        XCTAssertNil(OwnWindows.placement(for: CGRect(x: 1600, y: 300, width: 569, height: 178), screens: [main, side],
                                          pointer: CGPoint(x: 10, y: 10)))
    }

    func testAWindowOffEveryScreenIsCentredOnThePointersScreen() {
        let far = CGRect(x: -4000, y: 2500, width: 569, height: 178)
        XCTAssertEqual(OwnWindows.placement(for: far, screens: [main, side], pointer: CGPoint(x: 2000, y: 500)),
                       CGRect(x: 2188, y: 436, width: 569, height: 178))
        XCTAssertEqual(OwnWindows.placement(for: far, screens: [main, side], pointer: CGPoint(x: -50, y: -50)),
                       CGRect(x: 472, y: 383, width: 569, height: 178), "the pointer on no screen: the first one")
    }

    func testAWindowHalfOffIsBroughtIn() {
        let half = CGRect(x: 1200, y: 300, width: 600, height: 200)
        XCTAssertNotNil(OwnWindows.placement(for: half, screens: [main], pointer: CGPoint(x: 10, y: 10)))
    }

    func testAWindowBiggerThanTheScreenIsFittedToIt() {
        let big = CGRect(x: -3000, y: 0, width: 3000, height: 2000)
        XCTAssertEqual(OwnWindows.placement(for: big, screens: [main], pointer: .zero), main)
    }
}
