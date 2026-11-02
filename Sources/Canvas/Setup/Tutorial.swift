import SwiftUI

/// The basics, as a short tutorial: a handful of moves, one to a step, each acted out by the same loop Settings ›
/// How to use › Trackpad plays (`GestureGuide`): a miniature canvas beside the hand doing it. It
/// asks first whether you use a trackpad or a mouse, and shows the moves for that one: fingertips on a
/// trackpad, or a mouse and the keys. It's a page of Set Up Sunlight (`SetupFlow.Page.basics`), shown
/// once, right after the two permissions and before "You're set"; Settings › How to use ›
/// Basics plays it again.
///
/// A trackpad step names its gesture and takes the hand's words from it (`GestureGuide.Gesture.how`),
/// so when a gesture changes there, the tutorial follows. Where two gestures do the same thing (a click
/// and pinching in, for going into a window), the step plays both side by side with "or" between them.
/// A mouse step plays the same canvas loop with a mouse cue of its own.
enum Tutorial {
    enum Input: String, CaseIterable, Identifiable {
        case trackpad, mouse

        var id: Self { self }

        var title: String {
            switch self {
            case .trackpad: return "Trackpad"
            case .mouse: return "Mouse"
            }
        }

        var steps: [Step] {
            switch self {
            case .trackpad: return Tutorial.trackpad
            case .mouse: return Tutorial.mouse
            }
        }
    }

    struct Step: Equatable {
        /// What the move does: the page's headline.
        var title: String
        /// Why you'd want it, under the headline.
        var line: String
        /// The loop the miniature canvas plays.
        var gesture: GestureGuide.Gesture
        /// With a mouse, what the mouse and keys do; nil on a trackpad, where the gesture's own picture
        /// and words are used.
        var mouse: MouseCue?
        /// The other way to do it, after "or", if there is one.
        var keys: String?
        /// Another gesture that does the same, played beside the first with an "or" between them.
        var also: GestureGuide.Gesture?

        /// What the hand does: the words under the picture.
        var how: String { mouse?.how ?? gesture.how }

        /// The step with See All shown the way Settings › How to use has it (the tap by default).
        func resolved(seeAll: Settings.SeeAllGesture) -> Step {
            var step = self
            if gesture == .fourFingerTap || gesture == .swipeUp {
                step.gesture = seeAll == .tap ? .fourFingerTap : .swipeUp
            }
            return step
        }
    }

    static let trackpad: [Step] = [
        Step(title: "See all your windows.",
             line: "Every window sits on one big canvas. From anywhere, even inside a window, one move brings all of it into view.",
             gesture: .fourFingerTap, keys: "the Mission Control key"),
        Step(title: "Pan around.",
             line: "The canvas goes on in every direction. Slide two fingers over it to move about.",
             gesture: .scroll, keys: "drag the empty canvas"),
        Step(title: "Zoom in and out.",
             line: "From the whole canvas down to a single window, about the spot between your fingers.",
             gesture: .pinch, keys: "⌥ or ⌘ with a scroll"),
        Step(title: "Go into a window.",
             line: "One click and it comes to its real size right where it is, ready to use. Pinching in over it, all the way, does the same.",
             gesture: .click, also: .pinchIn),
        Step(title: "Bring it to the middle.",
             line: "Double-click and the window comes to the middle of the screen at its real size, ready to use.",
             gesture: .doubleClick, keys: "⏎ for the window under the pointer"),
        Step(title: "Arrange them your way.",
             line: "Drag a window anywhere on the canvas. Its edges stick to the neighbours', so things line up.",
             gesture: .drag, keys: "⌃⌥ and an arrow for halves, thirds and more"),
        Step(title: "Pan from anywhere.",
             line: "Drag four fingers in any direction, even inside a window: the canvas comes back and follows them.",
             gesture: .fourFingerDrag),
    ]

    /// With a mouse there are no four fingers, so the steps are the trackpad's without that one.
    static let mouse: [Step] = [
        Step(title: "See all your windows.",
             line: "Every window sits on one big canvas. From anywhere, even inside a window, one key brings all of it into view.",
             gesture: .fourFingerTap, mouse: MouseCue(how: "Press the Mission Control key", keys: ["F3"], showsMouse: false)),
        Step(title: "Pan around.",
             line: "The canvas goes on in every direction. Scroll to move up and down; hold ⇧ to go sideways.",
             gesture: .scroll, mouse: MouseCue(how: "Scroll, with ⇧ for sideways", keys: ["⇧"], wheel: .pan),
             keys: "drag the empty canvas"),
        Step(title: "Zoom in and out.",
             line: "From the whole canvas down to a single window, about the spot under the pointer.",
             gesture: .pinch, mouse: MouseCue(how: "Hold ⌥ and scroll", keys: ["⌥"], wheel: .zoom),
             keys: "⌘ with a scroll"),
        Step(title: "Go into a window.",
             line: "One click and it comes to its real size right where it is, ready to use.",
             gesture: .click, mouse: MouseCue(how: "Click once")),
        Step(title: "Bring it to the middle.",
             line: "Double-click and the window comes to the middle of the screen at its real size, ready to use.",
             gesture: .doubleClick, mouse: MouseCue(how: "Double-click"), keys: "⏎ for the window under the pointer"),
        Step(title: "Arrange them your way.",
             line: "Drag a window anywhere on the canvas. Its edges stick to the neighbours', so things line up.",
             gesture: .drag, mouse: MouseCue(how: "Drag it"), keys: "⌃⌥ and an arrow for halves, thirds and more"),
    ]

    /// Under the last step: where the rest is.
    static let rest = "The rest is in Settings › How to use, or ⌘?."

    /// The step at `index`, kept in range.
    static func step(_ index: Int, for input: Input) -> Step {
        let steps = input.steps
        return steps[min(max(index, 0), steps.count - 1)]
    }

    static func isLast(_ index: Int, for input: Input) -> Bool { index >= input.steps.count - 1 }
}

/// A mouse step's picture: which keys are held, whether the wheel turns, and whether there's a mouse at
/// all (See All is keys only).
struct MouseCue: Equatable {
    enum Wheel: Equatable { case pan, zoom }

    var how: String
    var keys: [String] = []
    var wheel: Wheel?
    var showsMouse = true
}

// MARK: - The page's picture

/// The tutorial page's middle. Before a choice: Trackpad or Mouse, as two cards. Then the step's loop,
/// large, with the hand's words and the other way under it, and a dot per step.
struct TutorialStage: View {
    var input: Tutorial.Input?
    var index: Int
    var scale: CGFloat
    var onChoose: (Tutorial.Input) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: CGFloat { scale }

    var body: some View {
        Group {
            if let input {
                steps(input)
            } else {
                chooser
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.85), value: index)
        .animation(.easeInOut(duration: 0.25), value: input)
    }

    private var chooser: some View {
        HStack(spacing: 24 * s) {
            ForEach(Tutorial.Input.allCases) { input in
                Button { onChoose(input) } label: {
                    VStack(spacing: 16 * s) {
                        Group {
                            switch input {
                            case .trackpad: TrackpadPicture(frame: Self.restingHand, thumb: false)
                            case .mouse: MousePicture(frame: GestureGuide.Frame(), cue: MouseCue(how: ""))
                            }
                        }
                        .frame(width: TrackpadPicture.size.width * s, height: TrackpadPicture.size.height * s)
                        Text(input.title)
                            .font(.system(size: 19 * s, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(ChoiceCardStyle(scale: s))
                .accessibilityLabel(input.title)
            }
        }
        .transition(.opacity)
    }

    /// Two fingertips resting on the trackpad, for its card.
    private static let restingHand: GestureGuide.Frame = {
        var frame = GestureGuide.Frame()
        frame.fingers = [CGPoint(x: 0.44, y: 0.52), CGPoint(x: 0.56, y: 0.49)]
        frame.touch = 1
        return frame
    }()

    private func steps(_ input: Tutorial.Input) -> some View {
        let step = Tutorial.step(index, for: input).resolved(seeAll: Settings.seeAllGesture)
        return VStack(spacing: 18 * s) {
            if let also = step.also {
                // Two ways to the same thing: both loops, smaller, each with its words, "or" between.
                HStack(alignment: .top, spacing: 20 * s) {
                    half(step.gesture, how: step.how)
                    OrPill(scale: s)
                        .padding(.top, 78 * s)
                    half(also, how: also.how)
                }
                .id("\(input)-\(index)")
                .transition(.opacity)
            } else {
                card(GestureStage(gesture: step.gesture, scale: 1.4 * s, mouse: step.mouse))
                    .id("\(input)-\(index)")
                    .transition(.opacity)
            }
            VStack(spacing: 6 * s) {
                if step.also == nil {
                    Text(step.how)
                        .font(.system(size: 17 * s, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                }
                if let keys = step.keys {
                    Text("or  \(keys)")
                        .font(.system(size: 15 * s))
                        .foregroundStyle(.primary.opacity(0.5))
                }
            }
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
            .accessibilityElement(children: .combine)
            HStack(spacing: 8 * s) {
                ForEach(input.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(.primary.opacity(i == index ? 0.85 : 0.22))
                        .frame(width: (i == index ? 16 : 6) * s, height: 6 * s)
                }
            }
            .padding(.top, 4 * s)
            .accessibilityElement()
            .accessibilityLabel("Step \(index + 1) of \(input.steps.count)")
        }
        .transition(.opacity)
    }

    /// A loop in its rounded card.
    private func card(_ stage: GestureStage, compact: Bool = false) -> some View {
        stage
            .padding(.horizontal, (compact ? 22 : 30) * s)
            .padding(.vertical, (compact ? 18 : 24) * s)
            .background(
                RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 22 * s, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
            )
    }

    /// One side of a step with two ways: its loop and, under it, what the hand does.
    private func half(_ gesture: GestureGuide.Gesture, how: String) -> some View {
        VStack(spacing: 14 * s) {
            card(GestureStage(gesture: gesture, scale: s), compact: true)
            Text(how)
                .font(.system(size: 17 * s, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420 * s)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "OR" between two gestures that do the same thing, as the launch email has it: a sun-yellow pill.
private struct OrPill: View {
    var scale: CGFloat

    var body: some View {
        Text("OR")
            .font(.system(size: 14 * scale, weight: .heavy).italic())
            .tracking(1 * scale)
            .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.118))
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 5 * scale)
            .background(Capsule().fill(Color(red: 1, green: 0.79, blue: 0.16)))
            .accessibilityLabel("or")
    }
}

/// A card to pick: lifts a touch under the pointer.
private struct ChoiceCardStyle: ButtonStyle {
    var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 28 * scale)
            .padding(.vertical, 24 * scale)
            .background(
                RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.1 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 22 * scale, style: .continuous)
                        .strokeBorder(.primary.opacity(hovering ? 0.3 : 0.1), lineWidth: 1))
            )
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.98 : hovering ? 1.02 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 22 * scale, style: .continuous))
    }
}

// MARK: - The mouse

/// A mouse from above, in the trackpad picture's place: its left button pressing with the loop's clicks,
/// sliding as the pointer does, the wheel rolling for a scroll, and the keys the step holds beside it.
struct MousePicture: View {
    let frame: GestureGuide.Frame
    let cue: MouseCue
    @Environment(\.colorScheme) private var scheme

    static let size = TrackpadPicture.size

    var body: some View {
        Canvas { ctx, drawn in
            let k = drawn.width / Self.size.width
            ctx.scaleBy(x: k, y: k)
            let size = Self.size
            let dark = scheme == .dark
            // Keys are held while the loop's fingers would be down.
            let held = frame.touch > 0.5

            let capSide: CGFloat = 34, capGap: CGFloat = 8
            let capsWidth = CGFloat(cue.keys.count) * capSide + CGFloat(max(cue.keys.count - 1, 0)) * capGap
            let mouseWidth: CGFloat = 58, mouseHeight: CGFloat = 92
            let gap: CGFloat = cue.showsMouse && !cue.keys.isEmpty ? 22 : 0
            let total = (cue.showsMouse ? mouseWidth : 0) + gap + capsWidth
            var x = (size.width - total) / 2

            if cue.showsMouse {
                // It slides with the pointer, a little.
                var shift = CGVector.zero
                if let pointer = frame.pointer {
                    shift = CGVector(dx: (pointer.x - GestureGuide.pointerFrom.x) * 34, dy: (pointer.y - GestureGuide.pointerFrom.y) * 22)
                }
                let body = CGRect(x: x + shift.dx, y: (size.height - mouseHeight) / 2 + shift.dy, width: mouseWidth, height: mouseHeight)
                // Faded out and in around the loop with the canvas, so its slide back doesn't jump.
                var faded = ctx
                faded.opacity = 0.3 + 0.7 * frame.opacity
                drawMouse(body, dark: dark, held: held, in: &faded)
                x += mouseWidth + gap
            }

            for key in cue.keys {
                let cap = CGRect(x: x, y: (size.height - capSide) / 2 + (held ? 1.5 : 0), width: capSide, height: capSide)
                let shape = Path(roundedRect: cap, cornerRadius: 7, style: .continuous)
                var shadowed = ctx
                if !held { shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 1.5, y: 1.5)) }
                shadowed.fill(shape, with: .color(dark ? Color(white: 0.32) : Color(white: 0.97)))
                if held { ctx.fill(shape, with: .color(Color.accentColor.opacity(0.35))) }
                ctx.stroke(shape, with: .color(.black.opacity(0.18)), lineWidth: 0.75)
                ctx.draw(Text(key).font(.system(size: 16, weight: .medium)).foregroundStyle(dark ? Color.white : Color.black.opacity(0.8)),
                         at: CGPoint(x: cap.midX, y: cap.midY))
                x += capSide + capGap
            }
        }
    }

    private func drawMouse(_ r: CGRect, dark: Bool, held: Bool, in ctx: inout GraphicsContext) {
        let shape = Path(roundedRect: r, cornerRadius: r.width / 2, style: .continuous)
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.3), radius: 4, y: 2))
        shadowed.fill(shape, with: .linearGradient(Gradient(colors: dark ? [Color(white: 0.42), Color(white: 0.3)] : [Color(white: 0.99), Color(white: 0.86)]),
                                                   startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        ctx.stroke(shape, with: .color(.black.opacity(0.2)), lineWidth: 0.75)

        // The two buttons, split down the middle of the top part; the left one pressing with the clicks.
        let split = r.minY + r.height * 0.42
        var inside = ctx
        inside.clip(to: shape)
        let left = CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: split - r.minY)
        if frame.pressed { inside.fill(Path(left), with: .color(Color.accentColor.opacity(0.4))) }
        if let ripple = frame.ripple {
            inside.fill(Path(left), with: .color(Color.accentColor.opacity(Double(0.3 * (1 - ripple)))))
        }
        var lines = Path()
        lines.move(to: CGPoint(x: r.midX, y: r.minY))
        lines.addLine(to: CGPoint(x: r.midX, y: split))
        lines.move(to: CGPoint(x: r.minX, y: split))
        lines.addLine(to: CGPoint(x: r.maxX, y: split))
        inside.stroke(lines, with: .color(.black.opacity(0.18)), lineWidth: 0.75)

        // The wheel, its ridges rolling while the loop scrolls or zooms.
        let wheel = CGRect(x: r.midX - 4.5, y: r.minY + 13, width: 9, height: 20)
        let wheelShape = Path(roundedRect: wheel, cornerRadius: 4.5, style: .continuous)
        let rolling = cue.wheel != nil && held
        ctx.fill(wheelShape, with: .color(rolling ? Color.accentColor.opacity(0.85) : Color(white: dark ? 0.2 : 0.62)))
        var ridges = ctx
        ridges.clip(to: wheelShape)
        let phase: CGFloat
        switch cue.wheel {
        case .pan?: phase = frame.camera.center.x * 60
        case .zoom?: phase = log(frame.camera.zoom) * 30
        case nil: phase = 0
        }
        let step: CGFloat = 4
        let offset = phase.truncatingRemainder(dividingBy: step)
        for i in -1...6 {
            let y = wheel.minY + CGFloat(i) * step + (offset < 0 ? offset + step : offset)
            ridges.fill(Path(CGRect(x: wheel.minX, y: y, width: wheel.width, height: 1)), with: .color(.black.opacity(0.25)))
        }
    }
}
