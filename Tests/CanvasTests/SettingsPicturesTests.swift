import XCTest
@testable import Canvas

/// The stages in Settings are pure functions of time and the settings: these read them.
final class SettingsPicturesTests: XCTestCase {
    func testTheDragEndsBesideTheNeighbourAndNeverCoversIt() {
        for magnetism in [false, true] {
            var s = SettingsPictures.Placing()
            s.magnetism = magnetism
            s.strength = 0.9
            s.grid = false
            let f = SettingsPictures.dragFrame(s, at: 2.2)
            XCTAssertLessThanOrEqual(f.a.maxX, f.b.minX + 1.5, "magnetism \(magnetism)")
            XCTAssertGreaterThan(f.a.minX, SettingsPictures.dragged.minX, "it moved")
        }
    }

    func testAFirmPushMovesTheNeighbourAndAGentleOneWaitsToTouch() {
        var firm = SettingsPictures.Placing()
        firm.magnetism = true
        firm.strength = 1
        let pushed = SettingsPictures.dragFrame(firm, at: 2.2)
        XCTAssertGreaterThan(pushed.b.minX, SettingsPictures.neighbour.minX)
        XCTAssertNotNil(pushed.reach)
        var gentle = firm
        gentle.strength = 0.2
        let touched = SettingsPictures.dragFrame(gentle, at: 2.2)
        XCTAssertNil(touched.reach)
        XCTAssertEqual(touched.b.minX, SettingsPictures.neighbour.minX, accuracy: 1.5)
        var off = firm
        off.magnetism = false
        XCTAssertEqual(SettingsPictures.dragFrame(off, at: 2.2).b, SettingsPictures.neighbour)
    }

    func testGuidesLevelTheWindowAndTheGridSnapsItOnRelease() {
        var s = SettingsPictures.Placing()
        s.guides = true
        let caught = SettingsPictures.dragFrame(s, at: 1.7)
        XCTAssertTrue(caught.guide)
        XCTAssertEqual(caught.a.minY, caught.b.minY)
        s.guides = false
        let free = SettingsPictures.dragFrame(s, at: 1.7)
        XCTAssertFalse(free.guide)
        XCTAssertLessThan(free.a.minY, free.b.minY)

        s.grid = true
        s.step = 40
        let settled = SettingsPictures.dragFrame(s, at: 3.0)
        let step = SettingsPictures.stageStep(40)
        let offGrid = (settled.a.minX - 12).truncatingRemainder(dividingBy: step)
        XCTAssertTrue(offGrid < 0.5 || step - offGrid < 0.5, "x \(settled.a.minX) is on the \(step) grid")
        s.grid = false
        let loose = SettingsPictures.dragFrame(s, at: 3.0)
        XCTAssertEqual(loose.a.minX, SettingsPictures.dragFrame(s, at: 2.2).a.minX, accuracy: 0.01)
    }

    func testTheDragLoopFadesAtBothEnds() {
        let s = SettingsPictures.Placing()
        XCTAssertEqual(SettingsPictures.dragFrame(s, at: 0).opacity, 0)
        XCTAssertEqual(SettingsPictures.dragFrame(s, at: SettingsPictures.dragStill).opacity, 1)
        XCTAssertEqual(SettingsPictures.dragFrame(s, at: SettingsPictures.dragDuration - 0.1).opacity, 0)
    }

    func testEveryEffectOpensHoldsAndCloses() {
        for effect in WindowEffect.allCases {
            let opening = SettingsPictures.effectFrame(effect, at: 0.3)
            let open = SettingsPictures.effectFrame(effect, at: 1.2)
            let closed = SettingsPictures.effectFrame(effect, at: 3.0)
            XCTAssertEqual(open.opacity, 1, "\(effect) is fully there while held")
            XCTAssertEqual(open.scale, CGSize(width: 1, height: 1))
            XCTAssertEqual(open.dy, 0)
            XCTAssertNil(open.ring)
            XCTAssertTrue(open.shown)
            switch effect {
            case .none:
                XCTAssertFalse(opening.shown)
                XCTAssertFalse(closed.shown)
            case .unfold:
                XCTAssertLessThan(opening.scale.height, 1)
                XCTAssertTrue(opening.fromTop)
                XCTAssertLessThan(closed.scale.height, 0.1)
            case .bloom:
                XCTAssertNotNil(opening.ring)
                XCTAssertLessThan(opening.scale.width, 1)
                XCTAssertEqual(closed.opacity, 0, accuracy: 0.01)
            case .sunrise, .automatic:
                XCTAssertGreaterThan(opening.dy, 0)
                XCTAssertLessThan(opening.opacity, 1)
            case .dissolve:
                XCTAssertLessThan(opening.opacity, 1)
                XCTAssertEqual(opening.dy, 0)
            }
        }
    }

    func testAutomaticCyclesThroughItsStylesOneLoopEach() {
        let first = SettingsPictures.effectFrame(.automatic, at: 0.3, loop: 0)
        let second = SettingsPictures.effectFrame(.automatic, at: 0.3, loop: 1)
        let third = SettingsPictures.effectFrame(.automatic, at: 0.3, loop: 2)
        XCTAssertEqual(first, SettingsPictures.effectFrame(.sunrise, at: 0.3))
        XCTAssertEqual(second, SettingsPictures.effectFrame(.unfold, at: 0.3))
        XCTAssertEqual(third, SettingsPictures.effectFrame(.bloom, at: 0.3))
        XCTAssertEqual(SettingsPictures.effectFrame(.automatic, at: 0.3, loop: 3), first)
    }

    @MainActor
    func testAnOlderBuildsRememberedPaneStillOpensSomewhereSensible() {
        typealias Tab = SettingsWindowController.Tab
        XCTAssertEqual(Tab(remembered: "arrange"), .experimental)
        XCTAssertEqual(Tab(remembered: "shortcuts"), .howToUse)
        XCTAssertEqual(Tab(remembered: "trackpad"), .howToUse)
        XCTAssertEqual(Tab(remembered: "motion"), .motion)
        XCTAssertNil(Tab(remembered: "rendering"))
        XCTAssertEqual(Tab.allCases.count, 8)
    }
}
