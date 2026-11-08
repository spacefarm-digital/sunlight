import XCTest
@testable import Canvas

@MainActor
final class PermissionDragPanelTests: XCTestCase {
    private let size = PermissionDragPanel.size
    private let gap = PermissionDragPanel.gap
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)

    func testTheCardStandsToTheRightOfSystemSettingsWhenThereIsRoom() {
        let settings = NSRect(x: 300, y: 200, width: 715, height: 650)
        let frame = PermissionDragPanel.place(size, by: settings, in: screen)
        XCTAssertEqual(frame.minX, settings.maxX + gap, accuracy: 0.5)
        XCTAssertLessThan(frame.maxY, settings.maxY, "level with the list, under the toolbar")
        XCTAssertEqual(frame.size, size)
    }

    func testAWindowAgainstTheRightEdgeGetsTheCardOnItsLeft() {
        let settings = NSRect(x: 780, y: 200, width: 715, height: 650)
        let frame = PermissionDragPanel.place(size, by: settings, in: screen)
        XCTAssertEqual(frame.maxX, settings.minX - gap, accuracy: 0.5)
    }

    func testAWideWindowPutsTheCardUnderItThenInsideIt() {
        let wide = NSRect(x: 100, y: 400, width: 1300, height: 500)
        let under = PermissionDragPanel.place(size, by: wide, in: screen)
        XCTAssertEqual(under.maxY, wide.minY - gap, accuracy: 0.5)
        XCTAssertEqual(under.midX, wide.midX, accuracy: 0.5)

        let inside = PermissionDragPanel.place(size, by: screen, in: screen)
        XCTAssertTrue(screen.contains(inside))
        XCTAssertEqual(inside.minY, gap, accuracy: 0.5)
    }

    func testTheDropPointIsInTheListRightOfTheSidebar() {
        let settings = NSRect(x: 300, y: 200, width: 715, height: 650)
        let point = PermissionDragPanel.dropPoint(in: settings)
        XCTAssertTrue(settings.contains(point))
        XCTAssertGreaterThan(point.x, settings.minX + 215)
        XCTAssertLessThan(point.y, settings.maxY - 100, "below the pane's header")
    }

    func testWindowServerBoundsFlipToAppKitCoordinates() {
        let flipped = PermissionDragPanel.flip(CGRect(x: 100, y: 50, width: 700, height: 500), mainHeight: 982)
        XCTAssertEqual(flipped, NSRect(x: 100, y: 432, width: 700, height: 500))
    }

    func testTheHandGrabsCarriesAndLetsGoOnALoop() {
        let start = DragHintPose.at(0.1)
        XCTAssertEqual(start.progress, 0)
        XCTAssertFalse(start.holding)
        XCTAssertEqual(start.ghostAlpha, 0)

        let carrying = DragHintPose.at(1.3)
        XCTAssertTrue(carrying.holding)
        XCTAssertGreaterThan(carrying.progress, 0)
        XCTAssertLessThan(carrying.progress, 1)
        XCTAssertGreaterThan(carrying.ghostAlpha, 0)

        let dropped = DragHintPose.at(2.9)
        XCTAssertEqual(dropped.progress, 1)
        XCTAssertEqual(dropped.handAlpha, 0)

        XCTAssertEqual(DragHintPose.at(DragHintPose.period), DragHintPose.at(0), "loops")
        XCTAssertLessThan(DragHintPose.at(0.9).progress, DragHintPose.at(1.6).progress, "moves one way")
    }

    func testTheLineNamesTheList() {
        XCTAssertTrue(DragPanelView.detail(for: .screenRecording).contains("Screen Recording list"))
        XCTAssertTrue(DragPanelView.detail(for: .accessibility).contains("Accessibility list"))
    }
}
