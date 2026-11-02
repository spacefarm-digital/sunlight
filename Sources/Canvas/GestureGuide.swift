import SwiftUI

/// Settings › How to use › Trackpad: every gesture the canvas answers, shown the way System Settings › Trackpad
/// shows the Mac's. Pick one (or point at it) and a loop acts it out: fingertips on a trackpad beside
/// a miniature canvas doing what the gesture does. A loop is a pure function of time (`frame`), so the
/// views only draw it and the tests can read it.
enum GestureGuide {
    /// The pane's three tabs, as System Settings groups the trackpad's gestures.
    enum Group: String, CaseIterable, Identifiable {
        case pointAndClick, zoomAndPan, more

        var id: Self { self }

        var title: String {
            switch self {
            case .pointAndClick: return "Point & Click"
            case .zoomAndPan: return "Zoom & Pan"
            case .more: return "More Gestures"
            }
        }

        /// The gestures in this tab, with See All shown the way Settings › How to use has it.
        func gestures(seeAll: Settings.SeeAllGesture) -> [Gesture] {
            Gesture.allCases.filter { $0.group == self && $0 != (seeAll == .tap ? .swipeUp : .fourFingerTap) }
        }

        var footer: String? {
            switch self {
            case .pointAndClick: return "At 1:1, clicks go to the window."
            case .zoomAndPan: return "⌥ or ⌘ with a scroll zooms too, for a mouse."
            case .more: return "Sunlight takes four-finger swipes. Five fingers still go to the Mac."
            }
        }
    }

    enum Gesture: String, CaseIterable, Identifiable {
        case click, doubleClick, drag, secondaryClick
        case pinch, pinchIn, scroll
        case fourFingerDrag, fourFingerTap, swipeUp, spread

        var id: Self { self }

        var group: Group {
            switch self {
            case .click, .doubleClick, .drag, .secondaryClick: return .pointAndClick
            case .pinch, .pinchIn, .scroll: return .zoomAndPan
            case .fourFingerDrag, .fourFingerTap, .swipeUp, .spread: return .more
            }
        }

        /// What it does: the row's title.
        var title: String {
            switch self {
            case .click: return "Go into a window"
            case .doubleClick: return "Centre and enter"
            case .drag: return "Move a window"
            case .secondaryClick: return "Secondary click"
            case .pinch: return "Zoom in or out"
            case .pinchIn: return "Enter where it is"
            case .scroll: return "Pan the canvas"
            case .fourFingerDrag: return "Pan from anywhere"
            case .fourFingerTap, .swipeUp: return "See everything"
            case .spread: return "Show Desktop"
            }
        }

        /// What the hand does: the row's second line.
        var how: String {
            switch self {
            case .click: return "Click with one finger"
            case .doubleClick: return "Double-click with one finger"
            case .drag: return "Click and drag with one finger"
            case .secondaryClick: return "Click or tap with two fingers"
            case .pinch: return "Pinch with two fingers"
            case .pinchIn: return "Spread two fingers over a window, all the way"
            case .scroll: return "Slide two fingers"
            case .fourFingerDrag: return "Drag with four fingers"
            case .fourFingerTap: return "Tap with four fingers"
            case .swipeUp: return "Swipe up with four fingers"
            case .spread: return "Spread your thumb and three fingers"
            }
        }

        /// The longer story, under the picture.
        var line: String {
            switch self {
            case .click: return "The window comes to 1:1 where it sits."
            case .doubleClick: return "The window flies to the middle. ⏎ does the same."
            case .drag: return "Edges line up. ⌘-drag to place freely."
            case .secondaryClick: return "Window options, or canvas options."
            case .pinch: return "Zooms around your fingers."
            case .pinchIn: return "Zoom into a window to use it."
            case .scroll: return "Moves the canvas. At 1:1, scrolls the window."
            case .fourFingerDrag: return "Pans from anywhere, even inside a window."
            case .fourFingerTap: return "See every window. Tap again to go back."
            case .swipeUp: return "See every window. Swipe again to go back."
            case .spread: return "Shows the desktop. So does F11."
            }
        }

        var fingers: Int {
            switch self {
            case .click, .doubleClick, .drag: return 1
            case .secondaryClick, .pinch, .pinchIn, .scroll: return 2
            case .fourFingerDrag, .fourFingerTap, .swipeUp, .spread: return 4
            }
        }

        /// One loop, in seconds.
        var duration: Double {
            switch self {
            case .secondaryClick: return 3.0
            case .drag: return 3.4
            case .click, .doubleClick, .pinch, .pinchIn, .fourFingerTap, .swipeUp, .spread: return 3.6
            case .scroll: return 4.0
            case .fourFingerDrag: return 4.2
            }
        }

        /// The moment shown still under Reduce Motion: fingers down, the gesture plain to see.
        var still: Double {
            switch self {
            case .click: return 1.3
            case .doubleClick: return 1.45
            case .drag: return 1.8
            case .secondaryClick: return 1.2
            case .pinch: return 1.6
            case .pinchIn: return 1.6
            case .scroll: return 1.0
            case .fourFingerDrag: return 1.8
            case .fourFingerTap: return 1.0
            case .swipeUp: return 0.95
            case .spread: return 1.3
            }
        }
    }

    // MARK: The miniature canvas

    /// Where the miniature canvas's camera looks: `center` in the canvas's unit square, `zoom` 1 for the
    /// whole of it on the miniature screen.
    struct Camera: Equatable {
        var center: CGPoint
        var zoom: CGFloat

        static let overview = Camera(center: CGPoint(x: 0.5, y: 0.5), zoom: 1)
        /// In the window the gestures act on: it fills the screen.
        static let entered = Camera(center: CGPoint(x: acted.midX, y: acted.midY), zoom: 1 / acted.width)

        /// Part way to another camera; the zoom moves evenly in log, as a real zoom feels.
        func mix(_ other: Camera, _ p: CGFloat) -> Camera {
            if p <= 0 { return self }
            if p >= 1 { return other }
            return Camera(center: GestureGuide.mix(center, other.center, p), zoom: exp(log(zoom) + (log(other.zoom) - log(zoom)) * p))
        }

        /// A canvas point on the miniature screen, both in unit squares.
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - center.x) * zoom + 0.5, y: (p.y - center.y) * zoom + 0.5)
        }

        func screen(_ r: CGRect) -> CGRect {
            let o = screen(r.origin)
            return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
        }
    }

    /// The window the gestures act on, drawn with a sun-coloured title bar so the eye can follow it. As
    /// wide as it is tall in unit terms, so entered it fills the screen exactly. It starts just under
    /// `others[0]`, so bringing it forward shows.
    static let acted = CGRect(x: 0.12, y: 0.22, width: 0.30, height: 0.30)
    static let others: [CGRect] = [
        CGRect(x: 0.36, y: 0.10, width: 0.30, height: 0.28),
        CGRect(x: 0.56, y: 0.50, width: 0.32, height: 0.32),
        CGRect(x: 0.14, y: 0.62, width: 0.26, height: 0.24),
    ]
    /// Finder's desktop files, on the screen, for Show Desktop.
    static let files: [CGPoint] = [CGPoint(x: 0.88, y: 0.16), CGPoint(x: 0.88, y: 0.38), CGPoint(x: 0.88, y: 0.60)]

    /// One moment of a loop.
    struct Frame: Equatable {
        /// Fingertips on the trackpad, in its unit square, y down. With four, the first is the thumb
        /// for Show Desktop.
        var fingers: [CGPoint] = []
        /// 0 lifted, 1 on the trackpad.
        var touch: CGFloat = 0
        /// Clicked down.
        var pressed = false
        /// A click's ring spreading from the fingertips, 0 to 1.
        var ripple: CGFloat?
        /// The pointer on the miniature screen, in its unit square.
        var pointer: CGPoint?
        var camera = Camera.overview
        /// How far the acted window has been dragged, in canvas units.
        var moved = CGVector.zero
        /// The acted window is in front of the others.
        var raised = false
        /// The secondary click's menu, 0 to 1.
        var menu: CGFloat = 0
        /// The windows moved aside for the desktop, 0 to 1.
        var desktop: CGFloat = 0
        /// The whole picture, faded out and in around a loop that doesn't end where it began.
        var opacity: CGFloat = 1
    }

    /// The pointer's slide to the acted window, and the finger's on the trackpad that moves it.
    static let pointerFrom = CGPoint(x: 0.66, y: 0.80)
    private static let padFrom = CGPoint(x: 0.62, y: 0.66)
    private static let padTo = CGPoint(x: 0.44, y: 0.46)

    /// A gesture's loop at `t` seconds in.
    static func frame(for gesture: Gesture, at t: Double) -> Frame {
        var f = Frame()
        let d = gesture.duration
        let loopFade = ramp(t, 0, 0.2) * (1 - ramp(t, d - 0.4, d - 0.15))
        let target = CGPoint(x: acted.midX, y: acted.midY)
        switch gesture {
        case .click:
            let slide = ramp(t, 0.3, 1.0)
            f.fingers = [mix(padFrom, padTo, slide)]
            f.touch = touch(t, on: 0.25, off: 2.0)
            f.pointer = mix(pointerFrom, target, slide)
            f.pressed = (1.2..<1.35).contains(t)
            f.ripple = ripple(t, at: 1.2)
            f.raised = t >= 1.25
            f.camera = Camera.overview.mix(.entered, ramp(t, 1.45, 2.25))
            f.opacity = loopFade
        case .doubleClick:
            let slide = ramp(t, 0.3, 1.0)
            f.fingers = [mix(padFrom, padTo, slide)]
            f.touch = touch(t, on: 0.25, off: 1.75)
            f.pointer = t < 1.65 ? mix(pointerFrom, target, slide) : nil
            f.pressed = (1.15..<1.27).contains(t) || (1.42..<1.54).contains(t)
            f.ripple = ripple(t, at: 1.42) ?? ripple(t, at: 1.15)
            f.raised = t >= 1.2
            f.camera = Camera.overview.mix(.entered, ramp(t, 1.6, 2.4))
            f.opacity = loopFade
        case .drag:
            let slide = ramp(t, 0.3, 0.9)
            let carry = ramp(t, 1.1, 2.2)
            let travel = CGVector(dx: 0.30, dy: 0.12)
            f.fingers = [CGPoint(x: mix(padFrom, padTo, slide).x + 0.22 * carry, y: mix(padFrom, padTo, slide).y + 0.12 * carry)]
            f.touch = touch(t, on: 0.25, off: 2.6)
            f.moved = CGVector(dx: travel.dx * carry, dy: travel.dy * carry)
            let p = mix(pointerFrom, target, slide)
            f.pointer = CGPoint(x: p.x + f.moved.dx, y: p.y + f.moved.dy)
            f.pressed = (1.0..<2.4).contains(t)
            f.ripple = ripple(t, at: 1.0)
            f.raised = t >= 1.0
            f.opacity = loopFade
        case .secondaryClick:
            f.fingers = [CGPoint(x: 0.45, y: 0.52), CGPoint(x: 0.57, y: 0.49)]
            f.touch = touch(t, on: 0.3, off: 1.4)
            f.pointer = target
            f.pressed = (0.8..<0.95).contains(t)
            f.ripple = ripple(t, at: 0.8)
            f.menu = ramp(t, 0.85, 1.0)
            f.opacity = loopFade
        case .pinch:
            let open = ramp(t, 0.5, 1.5) - ramp(t, 2.0, 3.0)
            f.fingers = pair(around: CGPoint(x: 0.5, y: 0.5), half: 0.07 + 0.13 * open)
            f.touch = touch(t, on: 0.3, off: 3.2)
            f.camera = Camera(center: CGPoint(x: 0.5, y: 0.5), zoom: exp(log(1.9) * open))
        case .pinchIn:
            let open = ramp(t, 0.6, 2.0)
            f.fingers = pair(around: CGPoint(x: 0.5, y: 0.5), half: 0.07 + 0.17 * open)
            f.touch = touch(t, on: 0.4, off: 2.2)
            f.camera = Camera.overview.mix(.entered, ramp(t, 0.7, 2.1))
            f.raised = true
            f.opacity = loopFade
        case .scroll:
            // Two strokes, left then back right: the loop ends where it began.
            let out = ramp(t, 0.4, 1.5), back = ramp(t, 2.2, 3.3)
            let x = t < 1.9 ? 0.66 - 0.30 * out : 0.36 + 0.30 * back
            f.fingers = [CGPoint(x: x - 0.06, y: 0.5), CGPoint(x: x + 0.06, y: 0.48)]
            f.touch = touch(t, on: 0.3, off: 1.7) + touch(t, on: 2.1, off: 3.5)
            f.camera = Camera(center: CGPoint(x: 0.5 + 0.25 * (out - back), y: 0.5), zoom: 1)
        case .fourFingerDrag:
            let out = ramp(t, 0.5, 1.0), pan = ramp(t, 1.1, 2.5)
            // On a slant, down and to the left: any way but straight up pans.
            f.fingers = hand(at: CGPoint(x: 0.62 - 0.24 * pan, y: 0.42 + 0.16 * pan))
            f.touch = touch(t, on: 0.4, off: 2.7)
            var camera = Camera.entered.mix(.overview, out)
            camera.center.x += 0.26 * pan
            camera.center.y -= 0.16 * pan
            f.camera = camera
            f.raised = true
            f.opacity = loopFade
        case .fourFingerTap:
            f.fingers = hand(at: CGPoint(x: 0.5, y: 0.5))
            f.touch = touch(t, on: 0.9, off: 1.1)
            f.camera = Camera.entered.mix(.overview, ramp(t, 1.1, 1.9))
            f.raised = true
            f.opacity = loopFade
        case .swipeUp:
            f.fingers = hand(at: CGPoint(x: 0.5, y: 0.68 - 0.36 * ramp(t, 0.5, 1.05)))
            f.touch = touch(t, on: 0.4, off: 1.15)
            f.camera = Camera.entered.mix(.overview, ramp(t, 0.7, 1.5))
            f.raised = true
            f.opacity = loopFade
        case .spread:
            let thumbAndThree = [CGPoint(x: 0.34, y: 0.76), CGPoint(x: 0.46, y: 0.34), CGPoint(x: 0.58, y: 0.28), CGPoint(x: 0.70, y: 0.34)]
            let c = CGPoint(x: thumbAndThree.map(\.x).reduce(0, +) / 4, y: thumbAndThree.map(\.y).reduce(0, +) / 4)
            let s = 0.5 + 0.5 * ramp(t, 0.6, 1.3)
            f.fingers = thumbAndThree.map { CGPoint(x: c.x + ($0.x - c.x) * s, y: c.y + ($0.y - c.y) * s) }
            f.touch = touch(t, on: 0.4, off: 1.5)
            f.desktop = ramp(t, 0.7, 1.5)
            f.opacity = loopFade
        }
        return f
    }

    /// Where a window is drawn in a frame, in canvas units: dragged if it's the acted one, and moved
    /// out towards the edges for the desktop.
    static func rect(_ r: CGRect, acted isActed: Bool, in f: Frame) -> CGRect {
        var r = r
        if isActed { r = r.offsetBy(dx: f.moved.dx, dy: f.moved.dy) }
        guard f.desktop > 0 else { return r }
        let away = CGVector(dx: r.midX - 0.5, dy: r.midY - 0.5)
        let length = max(hypot(away.dx, away.dy), 0.01)
        return r.offsetBy(dx: away.dx / length * 0.55 * f.desktop, dy: away.dy / length * 0.55 * f.desktop)
    }

    // MARK: Helpers

    /// 0 before `a`, 1 after `b`, eased between.
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let x = min(max((t - a) / (b - a), 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    /// Fingers landing at `on` and lifting at `off`.
    private static func touch(_ t: Double, on: Double, off: Double) -> CGFloat {
        ramp(t, on - 0.12, on) * (1 - ramp(t, off, off + 0.12))
    }

    /// A click's ring, half a second long.
    private static func ripple(_ t: Double, at start: Double) -> CGFloat? {
        (start..<start + 0.5).contains(t) ? CGFloat((t - start) / 0.5) : nil
    }

    /// Two fingertips on a diagonal, `half` from the middle each.
    private static func pair(around c: CGPoint, half: CGFloat) -> [CGPoint] {
        let dx = half * 0.8, dy = half * 0.6
        return [CGPoint(x: c.x - dx, y: c.y + dy), CGPoint(x: c.x + dx, y: c.y - dy)]
    }

    /// Four fingertips side by side in a gentle arc, as a hand rests.
    private static func hand(at c: CGPoint) -> [CGPoint] {
        let offsets: [(CGFloat, CGFloat)] = [(-0.20, 0.06), (-0.07, -0.03), (0.07, -0.04), (0.20, 0.03)]
        return offsets.map { CGPoint(x: c.x + $0.0, y: c.y + $0.1) }
    }
}

// MARK: - Views

/// The miniature canvas and the trackpad, side by side, acting a gesture out on a loop. Under Reduce
/// Motion, one still moment of it. With a `mouse` cue, a mouse (and keys) in place of the trackpad.
struct GestureStage: View {
    let gesture: GestureGuide.Gesture
    /// Larger than Settings' size, drawn sharp: the tutorial in Set Up Sunlight shows it bigger.
    var scale: CGFloat = 1
    /// The tutorial's mouse steps: the same loop on the canvas, done with a mouse.
    var mouse: MouseCue? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = reduceMotion ? gesture.still : max(0, context.date.timeIntervalSince(start)).truncatingRemainder(dividingBy: gesture.duration)
            let frame = GestureGuide.frame(for: gesture, at: t)
            HStack(spacing: 32 * scale) {
                MiniCanvasPicture(frame: frame)
                    .frame(width: MiniCanvasPicture.size.width * scale, height: MiniCanvasPicture.size.height * scale)
                Group {
                    if let mouse {
                        MousePicture(frame: frame, cue: mouse)
                    } else {
                        TrackpadPicture(frame: frame, thumb: gesture == .spread)
                    }
                }
                .frame(width: TrackpadPicture.size.width * scale, height: TrackpadPicture.size.height * scale)
            }
        }
        .onChange(of: gesture) { start = .now }
        .onChange(of: mouse) { start = .now }
        .accessibilityElement()
        .accessibilityLabel("\(mouse?.how ?? gesture.how): \(gesture.title)")
    }
}

/// A little screen showing the canvas: windows, the pointer, a menu, the desktop's files.
struct MiniCanvasPicture: View {
    let frame: GestureGuide.Frame

    private static let sun = Color(red: 0.98, green: 0.74, blue: 0.12)
    /// The size it's drawn at; any other is the same drawing scaled.
    static let size = CGSize(width: 240, height: 150)

    var body: some View {
        Canvas { ctx, drawn in
            let k = drawn.width / Self.size.width
            ctx.scaleBy(x: k, y: k)
            let size = CGSize(width: Self.size.width, height: drawn.height / k)
            let bezel = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 9, style: .continuous)
            ctx.fill(bezel, with: .color(Color(white: 0.11)))
            let screen = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5)
            let screenPath = Path(roundedRect: screen, cornerRadius: 5, style: .continuous)
            ctx.clip(to: screenPath)
            ctx.fill(screenPath, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.76, blue: 0.93), Color(red: 0.96, green: 0.86, blue: 0.70)]),
                                                       startPoint: CGPoint(x: screen.midX, y: screen.minY), endPoint: CGPoint(x: screen.midX, y: screen.maxY)))
            ctx.opacity = frame.opacity

            func place(_ unit: CGRect) -> CGRect {
                CGRect(x: screen.minX + unit.minX * screen.width, y: screen.minY + unit.minY * screen.height,
                       width: unit.width * screen.width, height: unit.height * screen.height)
            }
            func place(_ unit: CGPoint) -> CGPoint {
                CGPoint(x: screen.minX + unit.x * screen.width, y: screen.minY + unit.y * screen.height)
            }

            // Finder's files, under the windows.
            if frame.desktop > 0 {
                var files = ctx
                files.opacity = frame.opacity * frame.desktop
                for spot in GestureGuide.files {
                    let p = place(spot)
                    files.fill(Path(roundedRect: CGRect(x: p.x - 7, y: p.y - 9, width: 14, height: 16), cornerRadius: 2), with: .color(.white.opacity(0.95)))
                    files.fill(Path(CGRect(x: p.x - 9, y: p.y + 10, width: 18, height: 2.5)), with: .color(.white.opacity(0.7)))
                }
            }

            let windows: [(CGRect, Bool)] = frame.raised
                ? GestureGuide.others.map { ($0, false) } + [(GestureGuide.acted, true)]
                : [(GestureGuide.acted, true)] + GestureGuide.others.map { ($0, false) }
            for (unit, isActed) in windows {
                let r = place(frame.camera.screen(GestureGuide.rect(unit, acted: isActed, in: frame)))
                Self.drawWindow(r, acted: isActed, in: &ctx)
            }

            if frame.menu > 0, let pointer = frame.pointer {
                var menu = ctx
                menu.opacity = frame.opacity * frame.menu
                let p = place(pointer)
                let box = CGRect(x: p.x + 3, y: p.y + 3, width: 58, height: 46)
                menu.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, y: 1))
                menu.fill(Path(roundedRect: box, cornerRadius: 5, style: .continuous), with: .color(Color(white: 0.97)))
                for i in 0..<4 {
                    let line = CGRect(x: box.minX + 7, y: box.minY + 8 + CGFloat(i) * 9, width: i == 0 ? 38 : 30 + CGFloat(i % 2) * 10, height: 3)
                    menu.fill(Path(roundedRect: line, cornerRadius: 1.5), with: .color(i == 0 ? Self.sun : Color(white: 0.72)))
                }
            }

            if let pointer = frame.pointer { Self.drawPointer(at: place(pointer), in: &ctx) }
        }
    }

    /// A window: white, a title bar with its three dots, the acted one's bar in the sun's colour. Also
    /// the windows on Settings' stages and tiles (`SettingsPictures`).
    static func drawWindow(_ r: CGRect, acted: Bool, in ctx: inout GraphicsContext) {
        let corner = min(max(r.width * 0.05, 2), 7)
        let shape = Path(roundedRect: r, cornerRadius: corner, style: .continuous)
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.22), radius: 2.5, y: 1))
        shadowed.fill(shape, with: .color(Color(white: 0.985)))
        let bar = min(max(r.height * 0.13, 4), 22)
        var top = ctx
        top.clip(to: shape)
        top.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: bar)), with: .color(acted ? Self.sun : Color(white: 0.88)))
        if bar >= 6 {
            let dot = bar * 0.17
            for (i, colour) in [Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)].enumerated() {
                let c = CGPoint(x: r.minX + bar * 0.5 + CGFloat(i) * dot * 3, y: r.minY + bar / 2)
                let disc = Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
                top.fill(disc, with: .color(colour))
                // The yellow one would vanish on the sun-coloured bar without an edge.
                top.stroke(disc, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
            }
        }
        // A few lines of "content", so a window reads as one at any size.
        let inset = max(r.width * 0.08, 3)
        for i in 0..<3 {
            let y = r.minY + bar + inset + CGFloat(i) * max(r.height * 0.1, 3)
            guard y + 2 < r.maxY - inset else { break }
            let width = (r.width - inset * 2) * (i == 2 ? 0.55 : 0.85)
            top.fill(Path(roundedRect: CGRect(x: r.minX + inset, y: y, width: width, height: max(r.height * 0.035, 1.2)), cornerRadius: 1),
                     with: .color(Color(white: 0.84)))
        }
        ctx.stroke(shape, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
    }

    /// The Mac's arrow, black with a white edge.
    static func drawPointer(at p: CGPoint, in ctx: inout GraphicsContext) {
        var arrow = Path()
        arrow.move(to: CGPoint(x: 0, y: 0))
        arrow.addLine(to: CGPoint(x: 0, y: 13))
        arrow.addLine(to: CGPoint(x: 3.2, y: 10))
        arrow.addLine(to: CGPoint(x: 5.6, y: 14.6))
        arrow.addLine(to: CGPoint(x: 7.6, y: 13.7))
        arrow.addLine(to: CGPoint(x: 5.3, y: 9.2))
        arrow.addLine(to: CGPoint(x: 9.6, y: 9.2))
        arrow.closeSubpath()
        let placed = arrow.applying(CGAffineTransform(translationX: p.x, y: p.y))
        ctx.stroke(placed, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        ctx.fill(placed, with: .color(.black))
    }
}

/// The trackpad from above, with fingertips resting, sliding and pressing on it.
struct TrackpadPicture: View {
    let frame: GestureGuide.Frame
    /// The first fingertip is a thumb: a little bigger.
    let thumb: Bool
    @Environment(\.colorScheme) private var scheme
    /// The size it's drawn at; any other is the same drawing scaled.
    static let size = CGSize(width: 186, height: 126)

    var body: some View {
        Canvas { ctx, drawn in
            let k = drawn.width / Self.size.width
            ctx.scaleBy(x: k, y: k)
            let size = CGSize(width: Self.size.width, height: drawn.height / k)
            let pad = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let shape = Path(roundedRect: pad, cornerRadius: 12, style: .continuous)
            let dark = scheme == .dark
            ctx.fill(shape, with: .linearGradient(Gradient(colors: dark ? [Color(white: 0.36), Color(white: 0.27)] : [Color(white: 0.93), Color(white: 0.84)]),
                                                  startPoint: CGPoint(x: pad.midX, y: pad.minY), endPoint: CGPoint(x: pad.midX, y: pad.maxY)))
            ctx.stroke(shape, with: .color(.primary.opacity(dark ? 0.25 : 0.14)), lineWidth: 1)

            ctx.opacity = frame.opacity
            let lift = 1 - frame.touch
            for (i, unit) in frame.fingers.enumerated() {
                let c = CGPoint(x: pad.minX + unit.x * pad.width, y: pad.minY + unit.y * pad.height)
                // Four side by side need a little more room each.
                let base: CGFloat = thumb && i == 0 ? 14.5 : (frame.fingers.count == 4 ? 11 : 12)
                if let ripple = frame.ripple {
                    let r = base + 14 * ripple
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(Color.accentColor.opacity(Double(0.8 * (1 - ripple)))), lineWidth: 1.5)
                }
                // Hovering just above, a fingertip is a touch bigger and fainter; pressed, a touch smaller.
                let r = base * (1 + 0.18 * lift) * (frame.pressed ? 0.9 : 1)
                var tip = ctx
                tip.opacity = frame.opacity * frame.touch
                let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                var shadowed = tip
                shadowed.addFilter(.shadow(color: .black.opacity(0.3), radius: 3 + 4 * lift, y: 1 + 3 * lift))
                shadowed.fill(disc, with: .radialGradient(Gradient(colors: [Color(white: 1), Color(white: 0.86)]),
                                                         center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.3), startRadius: 0, endRadius: r * 1.4))
                if frame.pressed { tip.fill(disc, with: .color(Color.accentColor.opacity(0.35))) }
                tip.stroke(disc, with: .color(.black.opacity(0.2)), lineWidth: 0.75)
            }
        }
    }
}

/// Settings › How to use: the three tabs of gestures, and the picture acting out the one picked or pointed
/// at, as in System Settings › Trackpad.
struct TrackpadPane: View {
    @State private var group: GestureGuide.Group = .pointAndClick
    @State private var gesture: GestureGuide.Gesture = .click
    @State private var seeAll: Settings.SeeAllGesture = Settings.seeAllGesture

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    GestureStage(gesture: gesture)
                    VStack(spacing: 4) {
                        Text(gesture.title).font(.headline)
                        Text(gesture.line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 460)
                    // Two lines always, so the list below doesn't jump as the gesture changes.
                    .frame(minHeight: 56, alignment: .top)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }
            Section {
                ForEach(group.gestures(seeAll: seeAll)) { item in
                    HStack {
                        RowLabel(title: item.title, subtitle: item.how)
                        Spacer()
                        if item == gesture {
                            Image(systemName: "play.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { gesture = item }
                    .onHover { if $0 { gesture = item } }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(item == gesture ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { gesture = item }
                }
            } header: {
                Picker("Gestures", selection: $group) {
                    ForEach(GestureGuide.Group.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
            } footer: {
                if let footer = group.footer {
                    Text(footer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Picker("See everything with", selection: $seeAll) {
                    ForEach(Settings.SeeAllGesture.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                SectionHeader(title: "See everything",
                              detail: "The four-finger gesture that shows every window.")
            } footer: {
                Text("With swipe up, a slow drag up still pans.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onChange(of: group) { gesture = group.gestures(seeAll: seeAll)[0] }
        .onChange(of: seeAll) {
            Settings.seeAllGesture = seeAll
            if gesture == .fourFingerTap || gesture == .swipeUp { gesture = seeAll == .tap ? .fourFingerTap : .swipeUp }
        }
    }
}
