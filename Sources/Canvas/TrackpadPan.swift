import AppKit
import os

/// Four-finger drag pans the canvas from anywhere: on the canvas, over windows too (where a one-finger
/// drag would move them), and from inside an entered window, which brings the canvas back first. No
/// modifier, no key first, and every direction pans, up included. A four-finger *tap* (four fingers
/// down and up again without moving) shows everything, as Mission Control's swipe does; or, by
/// Settings › How to use, a quick four-finger *flick* up does, Mission Control's own stroke, told from a
/// drag up by its speed as the Mac tells them apart (swiped up slowly, Mission Control follows the
/// fingers instead of opening). Thumb and three fingers spreading apart is Show Desktop, as on the Mac.
///
/// The touches come straight from the trackpad through MultitouchSupport, the private framework Mac
/// gesture tools read (MiddleClick, BetterTouchTool). There's no public route: AppKit only hands touches
/// to a view under the pointer, and the gesture events an event tap sees carry none. It needs no
/// permission.
///
/// The system reads the same four fingers as a Mission Control or Spaces swipe and drives the Dock with
/// Dock-control events. A session event tap (Accessibility, on its own thread like `KeyTap`) drops those
/// while four fingers are down, so the drag pans and does nothing else. That takes the four-finger pinch
/// (Launchpad) with it; five fingers are left alone.
final class TrackpadPan: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case began
        /// Finger travel since the last update, in trackpad widths, y down. The content follows it.
        case changed(CGVector)
        case ended
        /// A four-finger tap, a flick, a spread or a rebound drag: a gesture finished, and Settings ›
        /// Trackpad says what it does. A flick's pan is over with no `ended` to follow.
        case gesture(TrackpadGesture)
    }

    /// What the recognizer should watch for: the gestures Settings › Trackpad has given something to do.
    /// A gesture with nothing bound is left alone, so the Mac or the pan gets it.
    struct GestureConfig: Sendable, Equatable {
        enum Drag: Sendable, Equatable {
            /// Four fingers moving pan the canvas, as they always have.
            case pan
            /// The drag is bound to another command: fire it once, as the fingers start moving.
            case fire
            /// Nothing is bound: a four-finger drag does nothing at all.
            case off
        }

        var freeSteering = false
        var tap = false
        var spread = false
        var flicks: Set<TrackpadGesture> = []
        var drag: Drag = .pan
    }

    /// Centroid travel, in trackpad widths, before four fingers on the trackpad count as a drag. Keeps
    /// a four-finger tap or pinch from moving anything.
    fileprivate static let slop: CGFloat = 0.02
    /// A mostly horizontal or vertical drag initially suppresses accidental sideways drift.
    /// A deliberate turn releases that lock; the same angle also distinguishes straight flicks.
    fileprivate static let axisLock: CGFloat = 22.5 * .pi / 180
    /// A tap's or flick's four fingers land together: the fourth within this long of the first. A
    /// finger that joins a three-finger tap (Look Up) or swipe (back, forward) later never makes one.
    fileprivate static let tapLanding: CFAbsoluteTime = 0.15
    /// Centroid rise, in trackpad widths, that makes an upward drag a flick. About two centimetres on
    /// a built-in trackpad: a short stroke, not a shifting hand.
    fileprivate static let swipeDistance: CGFloat = 0.12
    /// A flick covers `swipeDistance` within this long of the drag beginning. Slower than that, the
    /// fingers are panning, and speeding up later never makes a flick of it.
    fileprivate static let flickWindow: CFAbsoluteTime = 0.35
    /// A tap is over, the first finger lifting, within this long of the first one landing. A hand
    /// that rests on the trackpad longer is resting.
    fileprivate static let tapDuration: CFAbsoluteTime = 0.3
    /// Growth of the fingers' mean distance from their centroid, in trackpad widths, that makes a spread.
    /// About a centimetre on a built-in trackpad: the thumb and the fingers part by twice that. (0.12
    /// before 2026-10-28 asked for a spread wider than a hand makes, so Show Desktop never fired.)
    fileprivate static let spreadDistance: CGFloat = 0.07
    /// Dock-control events are still dropped this long after the fingers lift: the system's swipe ends
    /// a beat later.
    fileprivate static let dockTail: CFAbsoluteTime = 0.3
    /// The CGS event type of Dock control (Mission Control, Spaces and Launchpad gestures). Not in
    /// `CGEventType`.
    private static let dockControl: UInt32 = 30

    /// MultitouchSupport's frame callback is a C function with no context pointer.
    private nonisolated(unsafe) static weak var shared: TrackpadPan?

    private let handler: @MainActor @Sendable (Phase) -> Void
    private let state = OSAllocatedUnfairLock(initialState: TrackpadRecognizer())

    // Main thread.
    private let mt = MultitouchSupport()
    /// Owns the devices; they're released with it.
    private var deviceList: CFArray?
    private var wakeToken: NSObjectProtocol?
    private var settingToken: NSObjectProtocol?

    // Tap thread.
    private var thread: Thread?
    private var port: CFMachPort?

    init(handler: @escaping @MainActor @Sendable (Phase) -> Void) {
        self.handler = handler
    }

    @MainActor func start() {
        guard thread == nil else { return }
        TrackpadPan.shared = self
        // Settings is the main actor's; the recognizer keeps its own copy of the choices it needs.
        followSetting()
        settingToken = NotificationCenter.default.addObserver(
            forName: Bindings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followSetting() }
        }
        startDevices()
        // The trackpad stops reporting across sleep; start over with whatever is attached on wake.
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.restartDevices() }
        }

        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "canvas.trackpadpan"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    @MainActor private func followSetting() {
        let config = Bindings.trackpadConfig()
        state.withLock { $0.config = config }
    }

    /// Sunlight on or off (the menu bar switch). Off, the four fingers are the Mac's own again: the
    /// Dock-control events that make Mission Control's and Spaces' swipes pass. (They were dropped
    /// whenever four fingers were down, on or off, so with Sunlight off a four-finger swipe did nothing
    /// at all: not a pan, and not Mission Control either.)
    @MainActor func setActive(_ active: Bool) {
        state.withLock { $0.active = active }
    }

    // MARK: Touches

    private func startDevices() {
        guard let mt else {
            Log.note("TrackpadPan: MultitouchSupport unavailable, four-finger pan is off")
            return
        }
        guard let list = mt.createList()?.takeRetainedValue() else {
            Log.note("TrackpadPan: no multitouch devices")
            return
        }
        deviceList = list
        var heightPerWidth: [UInt: CGFloat] = [:]
        for device in devices {
            var w: Int32 = 0, h: Int32 = 0
            _ = mt.surfaceSize?(device, &w, &h)
            heightPerWidth[UInt(bitPattern: device)] = w > 0 && h > 0 ? CGFloat(h) / CGFloat(w) : 0.62
            mt.register(device, TrackpadPan.contactFrame)
            _ = mt.start(device, 0)
        }
        state.withLock { [heightPerWidth] in $0.heightPerWidth = heightPerWidth }
        Log.note("TrackpadPan: following \(devices.count) multitouch device(s)")
    }

    private func restartDevices() {
        if let mt {
            for device in devices {
                mt.unregister(device, TrackpadPan.contactFrame)
                _ = mt.stop(device)
            }
        }
        deviceList = nil
        let phases = state.withLock { $0.reset() }
        phases.forEach(send)
        startDevices()
    }

    private var devices: [MultitouchSupport.Device] {
        guard let deviceList else { return [] }
        return (0..<CFArrayGetCount(deviceList)).compactMap { i in
            CFArrayGetValueAtIndex(deviceList, i).map { UnsafeMutableRawPointer(mutating: $0) }
        }
    }

    private static let contactFrame: MultitouchSupport.FrameCallback = { device, contacts, count, _, _ in
        if let device, let pan = TrackpadPan.shared {
            pan.frame(device: device, contacts: contacts, count: Int(count))
        }
        return 0
    }

    /// On MultitouchSupport's thread (one per device).
    private func frame(device: MultitouchSupport.Device, contacts: UnsafeRawPointer?, count: Int) {
        var fingers = Set<Int32>()
        var points: [CGPoint] = []
        if let contacts {
            for i in 0..<count {
                let c = contacts + i * Contact.size
                guard Contact.onSurface.contains(c.load(fromByteOffset: Contact.state, as: Int32.self)) else { continue }
                fingers.insert(c.load(fromByteOffset: Contact.pathIndex, as: Int32.self))
                points.append(CGPoint(x: CGFloat(c.load(fromByteOffset: Contact.x, as: Float.self)),
                                      y: CGFloat(c.load(fromByteOffset: Contact.y, as: Float.self))))
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        let key = UInt(bitPattern: device)
        let phases = state.withLock { [fingers, points] s -> [Phase] in
            // In trackpad widths on both axes, so a diagonal moves diagonally on any trackpad. y is up here.
            let k = s.heightPerWidth[key] ?? 0.62
            let scaled = points.map { CGPoint(x: $0.x, y: $0.y * k) }
            let n = CGFloat(max(scaled.count, 1))
            let centroid = CGPoint(x: scaled.reduce(0) { $0 + $1.x } / n, y: scaled.reduce(0) { $0 + $1.y } / n)
            let spread = scaled.reduce(0) { $0 + hypot($1.x - centroid.x, $1.y - centroid.y) } / n
            return s.update(device: key, fingers: fingers, centroid: centroid, spread: spread, now: now)
        }
        phases.forEach(send)
    }

    private func send(_ phase: Phase) {
        let handler = self.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(phase) }
        }
    }

    // MARK: Tap thread

    private func threadMain() {
        installTap()
        let watchdog = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.current.add(watchdog, forMode: .common)
        CFRunLoopRun()
        watchdog.invalidate()
    }

    private func installTap() {
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: CGEventMask(1) << TrackpadPan.dockControl,
                                           callback: TrackpadPan.callback, userInfo: info) else {
            Log.note("TrackpadPan: tapCreate failed — Accessibility granted? Retrying in 3 s")
            let retry = Timer(timeInterval: 3, repeats: false) { [weak self] _ in self?.installTap() }
            RunLoop.current.add(retry, forMode: .common)
            return
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.note("TrackpadPan: Dock-control tap installed")
    }

    private func checkTap() {
        guard let port else { return }
        if !CFMachPortIsValid(port) {
            Log.note("TrackpadPan: port invalidated, reinstalling")
            self.port = nil
            installTap()
        } else if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<TrackpadPan>.fromOpaque(info).takeUnretainedValue().filter(type: type, event: event)
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == TrackpadPan.dockControl else { return Unmanaged.passUnretained(event) }
        let drop = state.withLock { CFAbsoluteTimeGetCurrent() < $0.dropDockControlUntil }
        return drop ? nil : Unmanaged.passUnretained(event)
    }
}

/// The four-finger drag, tap and spread, fed one trackpad frame at a time.
struct TrackpadRecognizer {
    /// Height over width of each device's surface, keyed by device.
    var heightPerWidth: [UInt: CGFloat] = [:]
    /// The device being followed (a Magic Mouse reports through the same framework).
    var device: UInt?
    /// The four contacts being followed.
    var fingers: Set<Int32> = []
    /// Where their centroid was when the fourth one landed; nil once the drag has begun.
    var anchor: CGPoint?
    /// Their mean distance from the centroid when the fourth one landed: a spread grows it.
    var anchorSpread: CGFloat = 0
    /// The centroid at the previous frame while dragging.
    var last: CGPoint?
    /// The initial axis, until the user deliberately steers away from it; nil for free movement.
    var lock: Lock?
    private var crossAxisTravel: CGFloat = 0
    /// Settings › Trackpad: which four-finger gestures have something to do.
    var config = TrackpadPan.GestureConfig()
    /// Settings › How to use: a quick flick up is See All, instead of a tap.
    var swipeUpSeesAll = false
    /// Sunlight is on: the four fingers are the canvas's, and the system's own swipes are held off.
    var active = true
    /// The fingers moved or spread while no drag was under way: not a tap any more.
    var stirred = false
    /// Where the centroid was and when, as the drag began; a flick is measured from there.
    var dragOrigin: CGPoint?
    var dragBegan: CFAbsoluteTime = 0
    /// The touch has fired its one gesture (a spread, a flick or a rebound drag); the rest does nothing.
    var swiped = false
    /// The drag is bound to something other than panning, and fired as the fingers began moving.
    var dragHandled = false
    /// A non-pan drag waits briefly for a configured flick to distinguish the two gestures.
    var pendingDrag = false

    enum Lock { case level, plumb }
    /// When the first finger of this touch landed; nil with no finger down.
    var touchBegan: CFAbsoluteTime?
    /// The four fingers landed together (`tapLanding`), so lifting them again soon may be a tap.
    var landedTogether = false
    /// From four fingers landing until the last one lifts: the system's swipe lasts that long, however
    /// many fingers stay down.
    var fourFingerTouch = false
    /// Read by the event tap.
    var dropDockControlUntil: CFAbsoluteTime = 0

    /// `spread` is the fingers' mean distance from `centroid`, in trackpad widths.
    mutating func update(device: UInt, fingers ids: Set<Int32>, centroid: CGPoint, spread: CGFloat = 0,
                         now: CFAbsoluteTime) -> [TrackpadPan.Phase] {
        if let followed = self.device, followed != device { return [] }
        if ids.count == 4 { fourFingerTouch = true } else if ids.isEmpty { fourFingerTouch = false }
        if fourFingerTouch, active { dropDockControlUntil = now + TrackpadPan.dockTail }
        let began = touchBegan ?? now
        if ids.isEmpty { touchBegan = nil } else if touchBegan == nil { touchBegan = now }
        // A finger landed or lifted: whatever was under way is over. Four fingers that landed together,
        // never moved and lift again at once were a tap.
        guard ids.count == 4 else {
            let fireDrag = pendingDrag && config.drag == .fire
            let tap = config.tap && ids.count < 4 && fingers.count == 4 && last == nil && !swiped && !dragHandled
                && !stirred && landedTogether && now - began <= TrackpadPan.tapDuration
            return reset() + (fireDrag ? [.gesture(.fourFingerDrag)] : []) + (tap ? [.gesture(.fourFingerTap)] : [])
        }
        if ids == fingers, swiped || dragHandled { return [] }
        guard ids == fingers, let from = last ?? anchor else {
            let phases = reset()
            self.device = device
            fingers = ids
            anchor = centroid
            anchorSpread = spread
            landedTogether = now - (touchBegan ?? now) <= TrackpadPan.tapLanding
            return phases
        }
        var travel = CGVector(dx: centroid.x - from.x, dy: from.y - centroid.y)
        var phases: [TrackpadPan.Phase] = []
        if last == nil {
            // Before a drag begins, fingers moving apart (or together) more than the hand moves is a
            // spread (or Launchpad's pinch), not a pan.
            let grown = spread - anchorSpread
            if grown >= TrackpadPan.spreadDistance {
                swiped = true
                return config.spread ? [.gesture(.spread)] : []
            }
            if abs(grown) >= TrackpadPan.slop || hypot(travel.dx, travel.dy) >= TrackpadPan.slop { stirred = true }
            // Spreading fingers shift the centroid too (the thumb moves furthest); while the spread keeps
            // up with the shift, the touch is still undecided.
            guard abs(grown) <= hypot(travel.dx, travel.dy) / 2 else { return [] }
            guard hypot(travel.dx, travel.dy) >= TrackpadPan.slop else { return [] }
            anchor = nil
            dragOrigin = from
            dragBegan = now
            let angle = atan2(abs(travel.dy), abs(travel.dx))
            if angle <= TrackpadPan.axisLock {
                lock = .level
            } else if angle >= .pi / 2 - TrackpadPan.axisLock {
                lock = .plumb
            } else {
                lock = nil
            }
            // When flicks are bound, let them resolve before firing a non-pan drag.
            if config.drag != .pan {
                if config.flicks.isEmpty {
                    dragHandled = true
                    return phases + (config.drag == .fire ? [.gesture(.fourFingerDrag)] : [])
                }
                pendingDrag = true
            } else {
                phases.append(.began)
            }
        }
        if let origin = dragOrigin, landedTogether, now - dragBegan <= TrackpadPan.flickWindow,
           let flick = flick(from: origin, to: centroid), config.flicks.contains(flick) {
            // Still early enough to be a flick: the whole travel so far, straight and far enough. The
            // pan it interrupts has moved the canvas a little; the gesture goes on from there.
            swiped = true
            pendingDrag = false
            last = nil   // the pan is over here; lifting the fingers won't `end` it again
            return phases + [.gesture(flick)]
        }
        if pendingDrag {
            if now - dragBegan > TrackpadPan.flickWindow {
                pendingDrag = false
                dragHandled = true
                last = nil
                return config.drag == .fire ? [.gesture(.fourFingerDrag)] : []
            }
            last = centroid
            return []
        }
        // Accumulate intentional cross-axis movement across frames: slow turns must work too.
        switch lock {
        case .level:
            guard config.freeSteering else { travel.dy = 0; break }
            if abs(travel.dy) >= abs(travel.dx) * 0.5 { crossAxisTravel += travel.dy }
            else { crossAxisTravel = 0 }
            if abs(crossAxisTravel) >= 0.015 { lock = nil; travel.dy = crossAxisTravel; crossAxisTravel = 0 }
            else { travel.dy = 0 }
        case .plumb:
            guard config.freeSteering else { travel.dx = 0; break }
            if abs(travel.dx) >= abs(travel.dy) * 0.5 { crossAxisTravel += travel.dx }
            else { crossAxisTravel = 0 }
            if abs(crossAxisTravel) >= 0.015 { lock = nil; travel.dx = crossAxisTravel; crossAxisTravel = 0 }
            else { travel.dx = 0 }
        case nil: break
        }
        phases.append(.changed(travel))
        last = centroid
        return phases
    }

    /// The flick a stroke from `origin` to `centroid` makes, if it is quick and straight enough. The
    /// direction is the hand's: up is up the trackpad.
    private func flick(from origin: CGPoint, to centroid: CGPoint) -> TrackpadGesture? {
        let dx = centroid.x - origin.x
        let dy = centroid.y - origin.y
        guard hypot(dx, dy) >= TrackpadPan.swipeDistance else { return nil }
        let angle = atan2(abs(dy), abs(dx))
        if angle <= TrackpadPan.axisLock { return dx >= 0 ? .swipeRight : .swipeLeft }
        if angle >= .pi / 2 - TrackpadPan.axisLock { return dy >= 0 ? .swipeUp : .swipeDown }
        return nil
    }

    mutating func reset() -> [TrackpadPan.Phase] {
        let phases: [TrackpadPan.Phase] = last == nil || pendingDrag ? [] : [.ended]
        device = nil
        fingers = []
        anchor = nil
        last = nil
        lock = nil
        crossAxisTravel = 0
        stirred = false
        dragOrigin = nil
        swiped = false
        dragHandled = false
        pendingDrag = false
        landedTogether = false
        anchorSpread = 0
        return phases
    }
}

/// A contact in a MultitouchSupport frame: its 96-byte `MTTouch`, of which only these fields are read.
private enum Contact {
    static let size = 96
    static let pathIndex = 16    // Int32, stable while the finger stays down
    static let state = 20        // Int32
    static let x = 32            // Float, 0…1 left to right
    static let y = 36            // Float, 0…1 bottom to top
    /// `state` while the finger is on the surface (make-touch, touching). Hovering, lifting and
    /// lingering don't count.
    static let onSurface: ClosedRange<Int32> = 3...4
}

/// The few MultitouchSupport calls used here, looked up at runtime (private framework, no headers).
private struct MultitouchSupport {
    typealias Device = UnsafeMutableRawPointer
    /// (device, contacts, contact count, timestamp, frame number).
    typealias FrameCallback = @convention(c) (Device?, UnsafeRawPointer?, Int32, Double, Int32) -> Int32

    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let register: @convention(c) (Device, FrameCallback) -> Void
    let unregister: @convention(c) (Device, FrameCallback) -> Void
    let start: @convention(c) (Device, Int32) -> Int32
    let stop: @convention(c) (Device) -> Int32
    /// In hundredths of a millimetre.
    let surfaceSize: (@convention(c) (Device, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32)?

    init?() {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            return nil
        }
        func fn<T>(_ name: String) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let createList: @convention(c) () -> Unmanaged<CFArray>? = fn("MTDeviceCreateList"),
              let register: @convention(c) (Device, FrameCallback) -> Void = fn("MTRegisterContactFrameCallback"),
              let unregister: @convention(c) (Device, FrameCallback) -> Void = fn("MTUnregisterContactFrameCallback"),
              let start: @convention(c) (Device, Int32) -> Int32 = fn("MTDeviceStart"),
              let stop: @convention(c) (Device) -> Int32 = fn("MTDeviceStop") else {
            return nil
        }
        self.createList = createList
        self.register = register
        self.unregister = unregister
        self.start = start
        self.stop = stop
        surfaceSize = fn("MTDeviceGetSensorSurfaceDimensions")
    }
}
