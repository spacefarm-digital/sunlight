import XCTest
@testable import Canvas

final class StageManagerTests: XCTestCase {
    /// A Mac in memory: the switch, and Sunlight's note that it turned it off.
    private final class FakeMac {
        var on: Bool
        var turnedOff = false
        var writes: [Bool] = []
        init(on: Bool) { self.on = on }

        var store: StageManager.Store {
            StageManager.Store(read: { self.on },
                               write: { self.on = $0; self.writes.append($0) },
                               turnedOff: { self.turnedOff },
                               setTurnedOff: { self.turnedOff = $0 })
        }
    }

    func testOnIsTurnedOffAndComesBackOnQuit() {
        let mac = FakeMac(on: true)
        XCTAssertTrue(StageManager.turnOff(mac.store, why: "test"))
        XCTAssertFalse(mac.on)
        XCTAssertTrue(mac.turnedOff)
        XCTAssertTrue(StageManager.restore(mac.store))
        XCTAssertTrue(mac.on)
        XCTAssertFalse(mac.turnedOff)
        XCTAssertEqual(mac.writes, [false, true])
    }

    func testOffIsLeftAloneAndNotTurnedOnLater() {
        let mac = FakeMac(on: false)
        XCTAssertFalse(StageManager.turnOff(mac.store, why: "test"))
        XCTAssertFalse(StageManager.restore(mac.store))
        XCTAssertFalse(mac.on)
        XCTAssertEqual(mac.writes, [])
    }

    /// Every launch turns it off; the note from the first launch stays until a quit gives it back.
    func testASecondTurnOffKeepsTheNote() {
        let mac = FakeMac(on: true)
        StageManager.turnOff(mac.store, why: "setup")
        XCTAssertFalse(StageManager.turnOff(mac.store, why: "launch"))
        XCTAssertTrue(mac.turnedOff)
    }

    /// Turned back on by hand while Sunlight ran: quitting leaves it on and forgets the note.
    func testTurnedBackOnByHandIsLeftOn() {
        let mac = FakeMac(on: true)
        StageManager.turnOff(mac.store, why: "test")
        mac.on = true
        XCTAssertFalse(StageManager.restore(mac.store))
        XCTAssertTrue(mac.on)
        XCTAssertFalse(mac.turnedOff)
        XCTAssertEqual(mac.writes, [false])
    }

    func testDescriptions() {
        XCTAssertEqual(StageManager.describe(on: false, turnedOffBySunlight: false), "off")
        XCTAssertTrue(StageManager.describe(on: true, turnedOffBySunlight: false).hasPrefix("on"))
        XCTAssertTrue(StageManager.describe(on: false, turnedOffBySunlight: true).contains("turned off by Sunlight"))
    }
}
