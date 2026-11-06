import AppKit
import XCTest
@testable import Canvas

@MainActor
final class PanReleaseTests: XCTestCase {
    func testPinchWithoutAutomaticEntryDoesNotSettleIntoAWindow() {
        let defaults = UserDefaults.standard
        let key = "CanvasEnterOnZoom"
        let saved = defaults.object(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(false, forKey: key)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.set(camera: Camera(origin: .zero, zoom: 0.95))
        var entries = 0
        view.onSettle = { entries += 1; return true }
        view.externalPinch(magnification: 0, phase: .began, timestamp: 1, at: CGPoint(x: 500, y: 400))
        view.externalPinch(magnification: 0, phase: .ended, timestamp: 1.1, at: CGPoint(x: 500, y: 400))
        XCTAssertEqual(entries, 0)
        XCTAssertEqual(view.camera.zoom, 0.95, accuracy: 0.001)
    }

    func testDefaultPanDoesNotSnapAtFingerRelease() {
        let defaults = UserDefaults.standard
        let keys = ["SnapOnPanRelease", "autoCenterAfterFourFingerPan"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        var checks = 0
        view.onPanRelease = { _ in checks += 1; return true }
        view.trackpadPan(by: CGVector(dx: 0.1, dy: 0))
        view.trackpadPanEnded()
        XCTAssertEqual(checks, 0)
    }

    func testFourFingerPanChecksForSnapAtReleaseWithDirectionalSnapOff() {
        let defaults = UserDefaults.standard
        let savedSnap = defaults.object(forKey: "SnapOnPanRelease")
        defaults.set(true, forKey: "SnapOnPanRelease")
        defer { if let savedSnap { defaults.set(savedSnap, forKey: "SnapOnPanRelease") } else { defaults.removeObject(forKey: "SnapOnPanRelease") } }
        let saved = defaults.object(forKey: "autoCenterAfterFourFingerPan")
        defer {
            if let saved { defaults.set(saved, forKey: "autoCenterAfterFourFingerPan") }
            else { defaults.removeObject(forKey: "autoCenterAfterFourFingerPan") }
        }
        Settings.autoCenterAfterFourFingerPan = false
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        var checks = 0
        var cameraAtRelease: Camera?
        view.onPanRelease = { _ in
            checks += 1
            cameraAtRelease = view.camera
            return true
        }
        view.trackpadPan(by: CGVector(dx: 0.1, dy: 0))
        XCTAssertEqual(checks, 0)
        view.trackpadPanEnded()
        XCTAssertEqual(checks, 1)
        XCTAssertNotNil(cameraAtRelease)
        XCTAssertNotEqual(cameraAtRelease?.origin.x, 0)
        view.onPanRelease = nil
    }

    func testFourFingerPanUsesDirectionalSnapAtReleaseWhenEnabled() {
        let defaults = UserDefaults.standard
        let savedSnap = defaults.object(forKey: "SnapOnPanRelease")
        defaults.set(true, forKey: "SnapOnPanRelease")
        defer { if let savedSnap { defaults.set(savedSnap, forKey: "SnapOnPanRelease") } else { defaults.removeObject(forKey: "SnapOnPanRelease") } }
        let saved = defaults.object(forKey: "autoCenterAfterFourFingerPan")
        defer {
            if let saved { defaults.set(saved, forKey: "autoCenterAfterFourFingerPan") }
            else { defaults.removeObject(forKey: "autoCenterAfterFourFingerPan") }
        }
        Settings.autoCenterAfterFourFingerPan = true
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        var checks = 0
        view.onFourFingerPanEnd = { _, _ in checks += 1; return true }
        view.trackpadPan(by: CGVector(dx: 0.1, dy: 0))
        XCTAssertEqual(checks, 0)
        view.trackpadPanEnded()
        XCTAssertEqual(checks, 1)
    }

    func testFourFingerPanCanDeclineSnapAtRelease() {
        let defaults = UserDefaults.standard
        let savedSnap = defaults.object(forKey: "SnapOnPanRelease")
        defaults.set(true, forKey: "SnapOnPanRelease")
        defer { if let savedSnap { defaults.set(savedSnap, forKey: "SnapOnPanRelease") } else { defaults.removeObject(forKey: "SnapOnPanRelease") } }
        let saved = defaults.object(forKey: "autoCenterAfterFourFingerPan")
        defer {
            if let saved { defaults.set(saved, forKey: "autoCenterAfterFourFingerPan") }
            else { defaults.removeObject(forKey: "autoCenterAfterFourFingerPan") }
        }
        Settings.autoCenterAfterFourFingerPan = false
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        var releaseChecks = 0
        var stillChecks = 0
        view.onPanRelease = { _ in releaseChecks += 1; return false }
        view.onSettle = { stillChecks += 1; return true }
        view.trackpadPan(by: CGVector(dx: 0.1, dy: 0))
        view.trackpadPanEnded()
        XCTAssertEqual(releaseChecks, 1)
        XCTAssertEqual(stillChecks, 0)
    }

    func testPanThatMissesAtReleaseChecksAgainAfterGlide() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Coasting is disabled by Reduce Motion")
        let defaults = UserDefaults.standard
        let keys = ["SnapOnPanRelease", "autoCenterAfterFourFingerPan", "CanvasPanInertia", "TrackpadCameraSensitivity"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        Settings.snapOnPanRelease = true
        Settings.autoCenterAfterFourFingerPan = false
        Settings.panInertia = true
        Settings.trackpadCameraSensitivity = 1
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows = [WindowSnap.Window(rect: visible, spot: .zero),
                       WindowSnap.Window(rect: visible.offsetBy(dx: 1200, dy: 0), spot: .zero)]
        var targets: [Int?] = []
        view.onPanRelease = { start in
            let hit = WindowSnap.releaseTarget(camera: view.camera, viewSize: visible.size, visible: visible,
                                               windows: windows, strength: .normal, sensitivity: 1, panStart: start)
            targets.append(hit?.index)
            return hit != nil
        }
        view.trackpadPan(by: CGVector(dx: -0.4, dy: 0))
        view.trackpadPanEnded(releaseVelocity: CGVector(dx: -400, dy: 0))
        XCTAssertEqual(targets.count, 1)
        XCTAssertNil(targets[0], "The gap at release should not snap")
        let coast = try XCTUnwrap(view.coast)
        view.set(camera: Camera(origin: CGPoint(x: 1200, y: 0), zoom: 1))
        view.tickInput(at: coast.start + 5)
        view.settleIfStill(at: coast.start + 5)
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(targets.last!, 1, "The window reached by the glide should snap at rest")
    }

    func testPanBufferedWhileReturningToCanvasKeepsGlidingAfterReleaseInGap() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Coasting is disabled by Reduce Motion")
        let defaults = UserDefaults.standard
        let keys = ["autoCenterAfterFourFingerPan", "CanvasPanInertia", "TrackpadCameraSensitivity", "SnapOnPanRelease"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        Settings.autoCenterAfterFourFingerPan = false
        Settings.snapOnPanRelease = true
        Settings.panInertia = true
        Settings.trackpadCameraSensitivity = 1
        var buffered = PendingTrackpadPan(viewWidth: 1000, sensitivity: 1, at: 1)
        buffered.add(CGVector(dx: -0.2, dy: 0), at: 1.05)
        buffered.add(CGVector(dx: -0.2, dy: 0), at: 1.1)
        buffered.end(at: 1.11)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let previous = WindowSnap.Window(rect: visible, spot: .zero)
        view.onPanRelease = { start in
            WindowSnap.target(camera: view.camera, viewSize: visible.size, visible: visible,
                              windows: [previous], sensitivity: 4, requireCenterInside: true,
                              panStart: start) != nil
        }
        view.trackpadPan(by: buffered.travel, preservingVelocity: buffered.velocity)
        view.trackpadPanEnded(releaseVelocity: buffered.releaseVelocity)
        XCTAssertNotNil(view.coast, "A miss at release must keep the buffered gesture's inertia")
        XCTAssertLessThan(view.coast?.velocity.dx ?? 0, -120)
        view.onPanRelease = nil
    }
}
