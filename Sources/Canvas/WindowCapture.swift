import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// Streams one window's pixels with ScreenCaptureKit, regardless of what's covering it.
/// Frames arrive as IOSurface-backed pixel buffers that Core Animation can display directly — no copies.
///
/// macOS marks a streamed window: a purple capture pill replaces its traffic lights for as long as the
/// stream runs (verified on 27.2 with both window-scoped filter types). The pill is drawn in the window's
/// own title bar, so it's hidden while the window is behind the canvas — which is the only time a proxy
/// streams. A window that is in front of the canvas is refreshed with `OneShotCapture` instead.
///
/// Frames are delivered on one shared queue and parked in a one-slot mailbox for the main thread: a
/// newer frame replaces one still waiting, so a busy main thread catches up with the newest frame
/// rather than working through every one it missed, and holds at most one buffer of the stream's pool.
/// Every way the stream can end — a start that fails, a window that closes, the system stopping it —
/// reports through `onEnd`, so the owner always knows whether it is still streaming. A `stop()` is
/// honoured whenever it comes: a stream stopped before its start has completed is stopped the moment
/// it has, rather than left running with no handle on it.
@MainActor
final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    typealias FrameHandler = @MainActor (CVPixelBuffer) -> Void
    typealias EndHandler = @MainActor (Error?) -> Void

    nonisolated static let framesPerSecond: Int32 = 30

    /// How much of the window to ask for: its output size as a fraction of the window's backing size
    /// (1 at 1:1, less when the proxy is drawn smaller), and a frame rate. See `CanvasController`'s
    /// capture pass for where the numbers come from.
    struct Level: Equatable {
        var factor: CGFloat
        var fps: Int32
    }

    /// What the stream is configured for right now.
    private struct Configured: Equatable {
        var width: Int
        var height: Int
        var fps: Int32
    }

    /// One queue for every stream: a frame only goes into the mailbox, so there's nothing to run in
    /// parallel, and one thread is cheaper than one per window.
    nonisolated private static let sampleQueue = DispatchQueue(label: "canvas.capture", qos: .userInteractive)

    /// The latest frame from the sample queue, waiting for the main thread.
    private struct Mailbox: @unchecked Sendable {
        var buffer: CVPixelBuffer?
    }

    nonisolated private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())
    private let window: SCWindow
    private let scale: CGFloat
    private let onFrame: FrameHandler
    private let onEnd: EndHandler
    private var stream: SCStream?
    private var realSize: CGSize
    private var level: Level
    private var configured = Configured(width: 0, height: 0, fps: 0)
    private var started = false
    /// `stop()` was called. A stream still starting can't be stopped yet (ScreenCaptureKit refuses to
    /// stop a stream that isn't running, and then starts it): the start's completion stops it instead.
    /// Nothing is delivered or reported after this.
    private var stopWanted = false
    private var reconfiguring = false
    private var wantsReconfigure = false

    /// `size` is the real window's size in points: the stream is configured for it, at `level`, from
    /// the first frame.
    init(window: SCWindow, size: CGSize, scale: CGFloat, level: Level,
         onFrame: @escaping FrameHandler, onEnd: @escaping EndHandler) {
        self.window = window
        self.scale = scale
        self.level = level
        self.onFrame = onFrame
        self.onEnd = onEnd
        realSize = size
        super.init()
    }

    /// The output size for a window at a level: its backing size scaled down, never below 2 px.
    static func pixelSize(real: CGSize, scale: CGFloat, factor: CGFloat) -> (width: Int, height: Int) {
        (max(2, Int((real.width * scale * factor).rounded())),
         max(2, Int((real.height * scale * factor).rounded())))
    }

    private var wanted: Configured {
        let px = WindowCapture.pixelSize(real: realSize, scale: scale, factor: level.factor)
        return Configured(width: px.width, height: px.height, fps: level.fps)
    }

    func start() {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        configured = wanted
        let stream = SCStream(filter: filter, configuration: configuration(configured), delegate: self)
        let title = window.title ?? "?"
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: WindowCapture.sampleQueue)
        } catch {
            Log.note("Capture: addStreamOutput failed for \(title): \(error)")
            onEnd(error)
            return
        }
        self.stream = stream
        let id = ObjectIdentifier(stream)
        // Held strongly until the start completes: an owner that has stopped and dropped this object
        // meanwhile still needs it around to stop the stream, which nothing else holds a handle on.
        stream.startCapture { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.isCurrent(id) else { return }
                    if let error {
                        self.stream = nil
                        // Stopped meanwhile: nobody is listening, and the owner may have a newer stream.
                        guard !self.stopWanted else { return }
                        Log.note("Capture: start failed for \(title): \(error)")
                        self.onEnd(error)
                        return
                    }
                    self.started = true
                    // Stopped while it was starting: stop it now that it can be stopped.
                    if self.stopWanted {
                        Log.note("Capture: stopping a stream that was still starting for \(title)")
                        self.stopNow()
                        return
                    }
                    // A size or level asked for while the stream was starting applies now.
                    if self.wantsReconfigure { self.reconfigureIfNeeded() }
                }
            }
        }
    }

    /// Stops the stream. Frames stop being delivered at once; the stream itself stops as soon as it
    /// can be: now if it has started, otherwise when its start completes (see `stopWanted`).
    func stop() {
        stopWanted = true
        mailbox.withLock { $0.buffer = nil }
        if started { stopNow() }
    }

    private func stopNow() {
        guard let stream else { return }
        self.stream = nil
        let title = window.title ?? "?"
        stream.stopCapture { error in
            // A stop that fails leaves the stream running with its pill on the window; say so.
            if let error { Log.note("Capture: stop failed for \(title): \(error)") }
        }
    }

    /// Whether a callback is about the stream we still own, not an earlier one already replaced.
    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        stream.map { ObjectIdentifier($0) == id } ?? false
    }

    /// Call when the real window was resized so the stream's output buffer matches it again.
    /// Until that lands, ScreenCaptureKit scales the content to fit, so a resize shows a brief stretch.
    func set(realSize size: CGSize) {
        guard abs(size.width - realSize.width) > 1 || abs(size.height - realSize.height) > 1 else { return }
        realSize = size
        reconfigureIfNeeded()
    }

    /// Asks for more or less of the window. A change lands after a frame interval or two; frames
    /// already on their way arrive at the old size, which the layer scales like any other.
    func set(level: Level) {
        guard level != self.level else { return }
        self.level = level
        reconfigureIfNeeded()
    }

    /// One reconfiguration at a time, and none before the stream has started: ScreenCaptureKit
    /// takes them in order but a burst of them (a pinch crossing several levels) is wasted work.
    private func reconfigureIfNeeded() {
        let wanted = wanted
        guard wanted != configured else { wantsReconfigure = false; return }
        guard started, !reconfiguring, let stream else { wantsReconfigure = true; return }
        wantsReconfigure = false
        reconfiguring = true
        configured = wanted
        let id = ObjectIdentifier(stream)
        stream.updateConfiguration(configuration(wanted)) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isCurrent(id) else { return }
                    self.reconfiguring = false
                    if let error { Log.note("Capture: updateConfiguration failed: \(error)") }
                    if self.wantsReconfigure { self.reconfigureIfNeeded() }
                }
            }
        }
    }

    private func configuration(_ wanted: Configured) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = wanted.width
        c.height = wanted.height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.scalesToFit = true
        c.queueDepth = 3
        c.minimumFrameInterval = CMTime(value: 1, timescale: wanted.fps)
        c.captureResolution = .best
        c.ignoreShadowsSingleWindow = true  // we draw our own shadow; keeps the texture == the window frame
        c.presenterOverlayPrivacyAlertSetting = .never
        return c
    }

    // MARK: SCStreamOutput (sample queue)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,  // .idle frames carry no new pixels
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Only an empty mailbox needs the main thread woken; a frame already waiting is replaced.
        let frame = Mailbox(buffer: pixelBuffer)
        let wake = mailbox.withLock { box -> Bool in
            let wasEmpty = box.buffer == nil
            box.buffer = frame.buffer
            return wasEmpty
        }
        if wake {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.deliver() }
            }
        }
    }

    private func deliver() {
        let taken = mailbox.withLock { box -> Mailbox in
            defer { box.buffer = nil }
            return box
        }
        // Stopped since the frame was posted: a stale stream frame must not land over a fresher
        // one-shot taken for the window now in front.
        guard let buffer = taken.buffer, !stopWanted, stream != nil else { return }
        onFrame(buffer)
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let id = ObjectIdentifier(stream)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isCurrent(id) else { return }   // an earlier stream of ours, already replaced
                self.stream = nil
                guard !self.stopWanted else { return }   // ours to stop; nobody is listening any more
                Log.note("Capture: stream stopped for \(self.window.title ?? "?"): \(error)")
                self.onEnd(error)
            }
        }
    }
}

/// One frame of a window on demand, with no stream behind it. Unlike a stream it leaves no capture pill
/// on the window (also verified on 27.2 at 10 captures/s), so it's how a proxy stays fresh while its real
/// window is in front of the canvas. Served roughly one at a time by the window server; keep the rate low.
///
/// Two paths, chosen by `Settings.captureMethod` and switchable live from the menu:
///   - `.screenCaptureKit`: `SCScreenshotManager` (macOS 26+), ~30 ms a call. The baseline.
///   - `.skyLight`: the private `SLSHWCaptureWindowList` (needs Screen Recording, already granted),
///     ~12 ms a call and no pill either. It falls back to `SCScreenshotManager` whenever its symbol is
///     missing or a call returns nil, so with the private path unavailable the app behaves exactly as
///     before. Each call is timed and a rolling per-method average is logged (see `CaptureMetrics`).
enum OneShotCapture {
    /// True when at least one one-shot path works: `SCScreenshotManager` on macOS 26+, or SkyLight when
    /// its symbol resolves (which can also drive the refresh path on systems before macOS 26).
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return skyLightAvailable
    }

    /// Whether the macOS 26 `SCScreenshotManager` path is usable. Gates its menu choice.
    static var screenCaptureKitAvailable: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// Whether the private SkyLight capture resolved. Sets the default method and gates its menu choice.
    static var skyLightAvailable: Bool { skyLight != nil }

    /// Always calls back on the main actor, with nil when the capture failed or isn't available. `seam`
    /// asks for the handoff seam's full-detail frame: ScreenCaptureKit's native resolution whatever the
    /// method (SkyLight's 2x only where ScreenCaptureKit's one-shot isn't available); a routine tick
    /// takes the chosen method, SkyLight at nominal (1x).
    @MainActor
    static func capture(_ window: SCWindow, seam: Bool = false, completion: @escaping @MainActor (CGImage?) -> Void) {
        // The seam's frame always goes through ScreenCaptureKit where it can. SkyLight's backing (2x)
        // capture came back framed differently from the window (content scaled up and shifted inside the
        // proxy's outline), and the proxy stretches whatever it holds to its outline: the window showed
        // re-laid-out for the few frames between the flight landing and the real window coming forward.
        // ScreenCaptureKit's is the window as it is; ~20 ms more, well inside the flight.
        let skyLightServes = !seam || !screenCaptureKitAvailable
        guard Settings.captureMethod == .skyLight, skyLight != nil, skyLightServes else {
            screenCaptureKitCapture(window, completion: completion)
            return
        }
        let windowID = window.windowID
        // The private call failed (the window just closed, or no Screen Recording): fall back to
        // ScreenCaptureKit so the proxy still refreshes. Kept as a main-isolated closure so the SkyLight
        // queue never captures the non-Sendable `SCWindow` itself.
        let fallback: @MainActor () -> Void = { screenCaptureKitCapture(window, completion: completion) }
        skyLightQueue.async {
            let start = DispatchTime.now()
            let image = skyLightCapture(windowID, seam: seam)
            if image != nil { CaptureMetrics.record(.skyLight, ms: milliseconds(since: start)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let image { completion(image) } else { fallback() }
                }
            }
        }
    }

    /// One frame of a window the canvas has no ScreenCaptureKit handle for: Finder's desktop (see
    /// `DesktopFloor`), which the canvas's listings leave out. SkyLight only, whatever the setting says;
    /// nil when its symbol is missing, without Screen Recording, or when the window is gone. `backing`
    /// asks for 2x detail.
    @MainActor
    static func capture(windowID: CGWindowID, backing: Bool, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard skyLight != nil else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
            return
        }
        skyLightQueue.async {
            let start = DispatchTime.now()
            let image = skyLightCapture(windowID, seam: backing)
            if image != nil { CaptureMetrics.record(.skyLight, ms: milliseconds(since: start)) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(image) } }
        }
    }

    // MARK: ScreenCaptureKit path

    /// Captures at the window's native backing resolution, exactly as the one-shot path always has.
    private static func screenCaptureKitCapture(_ window: SCWindow, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard #available(macOS 26.0, *) else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
            return
        }
        let c = SCScreenshotConfiguration()
        c.showsCursor = false
        c.ignoreShadows = true
        c.includeChildWindows = false   // same as the stream: sheets and popovers aren't in the texture
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let start = DispatchTime.now()
        SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: c) { output, error in
            // A window that just closed fails here; the next sync removes its proxy, so don't log.
            let image = error == nil ? output?.sdrImage : nil
            if image != nil { CaptureMetrics.record(.screenCaptureKit, ms: milliseconds(since: start)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(image) }
            }
        }
    }

    // MARK: SkyLight (private) path

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CaptureWindowList =
        @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?

    private struct SkyLight {
        let mainConnectionID: MainConnectionID
        let captureWindowList: CaptureWindowList
    }

    /// Resolved once: SkyLight is a private framework, so it's opened by path and its two symbols looked
    /// up by name. nil (and so the whole path off) if the framework or either symbol is missing.
    private static let skyLight: SkyLight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cid = dlsym(handle, "CGSMainConnectionID"),
              let capture = dlsym(handle, "SLSHWCaptureWindowList") else { return nil }
        return SkyLight(mainConnectionID: unsafeBitCast(cid, to: MainConnectionID.self),
                        captureWindowList: unsafeBitCast(capture, to: CaptureWindowList.self))
    }()

    /// One queue for every SkyLight call: the window server serializes captures anyway (~100/s across the
    /// whole system), so more threads buy nothing, and it keeps the capture off the main thread.
    nonisolated private static let skyLightQueue =
        DispatchQueue(label: "canvas.oneshot.skylight", qos: .userInteractive)

    /// Captures one window by id. `seam` picks backing (2x) over nominal (1x) detail; the two cost about
    /// the same. Returns nil without Screen Recording, or if the window is gone.
    private static func skyLightCapture(_ windowID: CGWindowID, seam: Bool) -> CGImage? {
        guard let sky = skyLight else { return nil }
        var id = UInt32(windowID)
        let options: UInt32 = seam ? (1 << 8) : (1 << 9)   // 1<<8 = backing/2x, 1<<9 = nominal/1x
        guard let unmanaged = sky.captureWindowList(sky.mainConnectionID(), &id, 1, options) else { return nil }
        let images = unmanaged.takeRetainedValue()   // a retained CFArray holding one CGImage
        guard CFArrayGetCount(images) > 0, let raw = CFArrayGetValueAtIndex(images, 0) else { return nil }
        // The image is owned by the array; takeUnretainedValue brings it under ARC so it outlives it.
        return Unmanaged<CGImage>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}

/// A rolling per-method average of one-shot capture latency, logged about every two seconds while
/// refreshes happen. It's the readout for comparing the two capture paths in real use: flip the method
/// from the menu and watch the figures move. Thread-safe — calls arrive from both the SkyLight queue and
/// ScreenCaptureKit's own completion queue.
enum CaptureMetrics {
    private struct Accumulator {
        var total = 0.0
        var count = 0
        mutating func add(_ ms: Double) { total += ms; count += 1 }
        var average: Double { count > 0 ? total / Double(count) : 0 }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var accumulators: [CaptureMethod: Accumulator] = [:]
    nonisolated(unsafe) private static var lastLog = DispatchTime.now()

    static func record(_ method: CaptureMethod, ms: Double) {
        lock.lock()
        accumulators[method, default: Accumulator()].add(ms)
        let now = DispatchTime.now()
        let dueToLog = Double(now.uptimeNanoseconds &- lastLog.uptimeNanoseconds) / 1_000_000_000 >= 2
        let snapshot = dueToLog ? accumulators : [:]
        if dueToLog { lastLog = now }
        lock.unlock()

        guard dueToLog else { return }
        let parts = CaptureMethod.allCases.compactMap { method -> String? in
            guard let acc = snapshot[method], acc.count > 0 else { return nil }
            return String(format: "%@ %.1f ms (n=%d)", method.title, acc.average, acc.count)
        }
        if !parts.isEmpty { Log.note("OneShotCapture latency — " + parts.joined(separator: ", ")) }
    }
}
