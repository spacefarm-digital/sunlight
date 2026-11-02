import SwiftUI

/// The pictures in Settings: a stage at the top of a pane that acts the pane's settings out and
/// changes as they do, and tiles that draw a choice instead of naming it (the ⌘Tab strip's edge, a
/// tiling gap, a window effect). Each loop is a pure function of time and of the settings
/// (`dragFrame`, `effectFrame`), so the views only draw it and the tests can read it, as `GestureGuide`
/// does for the trackpad.
enum SettingsPictures {
    /// The stage is drawn at this size; any other is the same drawing scaled.
    static let stageSize = CGSize(width: 400, height: 250)
    /// A tile's picture.
    static let tileSize = CGSize(width: 92, height: 62)

    static let sun = Color(red: 0.98, green: 0.74, blue: 0.12)
    static let guide = Color(red: 1, green: 0.18, blue: 0.5)
    static let plus = Color(red: 0.88, green: 0.29, blue: 0.24)
    static let minus = Color(red: 0.18, green: 0.44, blue: 0.88)
    static let apps: [Color] = [
        Color(red: 0.35, green: 0.48, blue: 0.85), Color(red: 0.89, green: 0.42, blue: 0.36),
        Color(red: 0.35, green: 0.72, blue: 0.42), Color(red: 0.95, green: 0.69, blue: 0.2), Color(red: 0.61, green: 0.42, blue: 0.84),
    ]

    // MARK: Dragging

    /// Settings › Windows, as the drag loop reads them.
    struct Placing: Equatable {
        var guides = true
        var grid = true
        var step: CGFloat = 40
        var magnetism = false
        var strength: CGFloat = 0.5
        var polarity = false
    }

    /// One moment of the drag: the dragged window `a`, its neighbour `b`, in stage points.
    struct DragFrame: Equatable {
        var a: CGRect
        var b: CGRect
        /// The guide along the neighbour's top edge is showing.
        var guide = false
        /// A firm push's reach, drawn as a line this far right of `a`.
        var reach: CGFloat?
        var pointer: CGPoint?
        var opacity: CGFloat = 1
    }

    static let dragDuration: Double = 4.2
    /// The moment shown still under Reduce Motion: mid-drag, guide caught, push under way.
    static let dragStill: Double = 1.7

    /// The neighbour at rest, and where the dragged window starts.
    static let neighbour = CGRect(x: 206, y: 74, width: 112, height: 78)
    static let dragged = CGRect(x: 44, y: 74, width: 102, height: 78)

    /// The grid's step on the stage: the real one scaled down.
    static func stageStep(_ step: CGFloat) -> CGFloat { max(step * 0.7, 8) }

    /// The drag at `t` seconds in: the window slides right to its neighbour (0.5–2.1 s), is let go
    /// (2.3 s) and settles (to 2.7 s). With guides, its top catches the neighbour's on the way; with a
    /// push, the neighbour moves instead of being covered; with the grid, it snaps on release.
    static func dragFrame(_ s: Placing, at t: Double) -> DragFrame {
        let approach = GestureGuide.ramp(t, 0.5, 2.1)
        let released = t >= 2.3
        let settle = GestureGuide.ramp(t, 2.3, 2.7)
        var a = dragged
        var b = neighbour
        // Touching the neighbour's left edge, a hair over.
        let touching = b.minX - a.width - 1
        a.origin.x += (touching - dragged.minX) * approach
        // Starts a little high; a guide pulls it level, otherwise it stays high.
        let caught = s.guides && approach > 0.3
        a.origin.y = caught ? b.minY : b.minY - 7
        var reach: CGFloat?
        if s.magnetism {
            let firm = s.strength > 0.5
            let gap: CGFloat = firm ? 4 + s.strength * 18 : 0
            let overlap = a.maxX + gap - b.minX
            if overlap > 0 { b.origin.x += overlap }
            if firm, approach > 0.6, !released { reach = a.maxX + gap }
        }
        if released, s.grid {
            let step = stageStep(s.step)
            let target = 12 + ((a.minX - 12) / step).rounded() * step
            a.origin.x += (target - a.minX) * settle
        }
        var f = DragFrame(a: a, b: b)
        f.guide = caught && !released
        f.reach = reach
        f.pointer = t < 2.9 ? CGPoint(x: a.minX + a.width * 0.55, y: a.minY + a.height * 0.45) : nil
        f.opacity = GestureGuide.ramp(t, 0, 0.2) * (1 - GestureGuide.ramp(t, dragDuration - 0.4, dragDuration - 0.15))
        return f
    }

    // MARK: Effects

    /// One moment of an effect: the window scaled about its middle (or its top edge), moved down `dy`
    /// stage points, at `opacity`, with a ring `ring` of the way out from its edges.
    struct EffectFrame: Equatable {
        var opacity: CGFloat = 1
        var dy: CGFloat = 0
        var scale = CGSize(width: 1, height: 1)
        var fromTop = false
        var ring: CGFloat?
        /// The window is there at all: None shows it half the loop.
        var shown = true
    }

    static let effectDuration: Double = 3.2
    static let effectStill: Double = 0.5

    /// The styles Automatic cycles through, one per loop, so its tile isn't Sunrise's twin.
    static let automaticCycle: [WindowEffect] = [.sunrise, .unfold, .bloom]

    /// An effect at `t` seconds in: opens over the first 0.9 s, holds, closes from 1.8 s over 0.9 s,
    /// and is gone until the loop comes round. `loop` picks Automatic's style.
    static func effectFrame(_ effect: WindowEffect, at t: Double, loop: Int = 0) -> EffectFrame {
        let u = t.truncatingRemainder(dividingBy: effectDuration)
        let p: Double = u < 0.9 ? u / 0.9 : (u < 1.8 ? 1 : (u < 2.7 ? 1 - (u - 1.8) / 0.9 : 0))
        let style = effect == .automatic ? automaticCycle[((loop % automaticCycle.count) + automaticCycle.count) % automaticCycle.count] : effect
        var f = EffectFrame()
        let e = GestureGuide.ramp(p, 0, 1)
        switch style {
        case .sunrise, .automatic:
            f.opacity = 0.5 + 0.5 * e
            f.dy = 14 * (1 - e)
        case .unfold:
            f.scale = CGSize(width: 1, height: max(0.02, e))
            f.fromTop = true
        case .bloom:
            f.opacity = e
            f.scale = CGSize(width: 0.9 + 0.1 * e, height: 0.9 + 0.1 * e)
            if e > 0, e < 1 { f.ring = e }
        case .dissolve:
            f.opacity = e
        case .none:
            f.shown = p >= 0.5
        }
        return f
    }

    // MARK: Drawing

    /// The screen: its bezel, then the canvas's sky inside it. Returns the screen's rect, with the
    /// context clipped and scaled to it.
    static func screen(in ctx: inout GraphicsContext, drawn: CGSize, base: CGSize = stageSize, bezel: CGFloat = 5) -> CGRect {
        let k = drawn.width / base.width
        ctx.scaleBy(x: k, y: k)
        let size = CGSize(width: base.width, height: drawn.height / k)
        let outer = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: bezel * 1.8, style: .continuous)
        ctx.fill(outer, with: .color(Color(white: 0.11)))
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: bezel, dy: bezel)
        let shape = Path(roundedRect: screen, cornerRadius: bezel, style: .continuous)
        ctx.clip(to: shape)
        sky(shape, in: screen, ctx: &ctx)
        return screen
    }

    /// The canvas's sky, dawn-coloured, as the gesture stage draws it.
    static func sky(_ shape: Path, in r: CGRect, ctx: inout GraphicsContext) {
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.76, blue: 0.93), Color(red: 0.96, green: 0.86, blue: 0.70)]),
                                              startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
    }

    /// A pole's badge at a window's top-right corner.
    static func pole(_ positive: Bool, on r: CGRect, in ctx: inout GraphicsContext) {
        let c = CGPoint(x: r.maxX - 9, y: r.minY + 6.5)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(positive ? plus : minus))
        ctx.draw(Text(positive ? "+" : "−").font(.system(size: 8, weight: .bold)).foregroundStyle(.white), at: c)
    }
}

// MARK: - Stages

/// The frame of every stage: the picture at the pane's width, with a caption under it.
struct SettingsStage<Picture: View>: View {
    let caption: String
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        VStack(spacing: 12) {
            picture()
                .frame(width: SettingsPictures.stageSize.width, height: SettingsPictures.stageSize.height)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                // Two lines always, so the form under it doesn't jump as the caption changes.
                .frame(minHeight: 36, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Canvas: the canvas with what's on it, as the pane has it.
struct CanvasStage: View {
    var minimap: Bool
    var files: Bool
    var strip: Bool
    var edge: SwitcherEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let windows: [CGRect] = [
        CGRect(x: 56, y: 42, width: 106, height: 72), CGRect(x: 182, y: 34, width: 116, height: 76),
        CGRect(x: 96, y: 136, width: 96, height: 62), CGRect(x: 220, y: 128, width: 110, height: 72),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSince(start)
            Canvas { ctx, drawn in
                let screen = SettingsPictures.screen(in: &ctx, drawn: drawn)
                // A slow breath of a pan, so the picture reads as a canvas, not a screenshot.
                let dx = CGFloat(sin(t / 3) * 5)
                for r in Self.windows { MiniCanvasPicture.drawWindow(r.offsetBy(dx: dx, dy: 0), acted: false, in: &ctx) }
                if files {
                    for i in 0..<4 {
                        let y = screen.minY + 34 + CGFloat(i) * 34
                        ctx.fill(Path(roundedRect: CGRect(x: screen.maxX - 48 + dx, y: y, width: 20, height: 17), cornerRadius: 3), with: .color(.white.opacity(0.92)))
                        ctx.fill(Path(roundedRect: CGRect(x: screen.maxX - 53 + dx, y: y + 20, width: 30, height: 3), cornerRadius: 1), with: .color(.white.opacity(0.7)))
                    }
                }
                if minimap {
                    let box = CGRect(x: screen.maxX - 90, y: screen.maxY - 60, width: 80, height: 50)
                    var panel = ctx
                    panel.addFilter(.shadow(color: .black.opacity(0.2), radius: 4, y: 1))
                    panel.fill(Path(roundedRect: box, cornerRadius: 6, style: .continuous), with: .color(.white.opacity(0.78)))
                    for r in Self.windows {
                        let m = CGRect(x: box.minX + 8 + r.minX * 0.16, y: box.minY + 6 + r.minY * 0.16, width: r.width * 0.16, height: r.height * 0.16)
                        ctx.fill(Path(roundedRect: m, cornerRadius: 1), with: .color(Color(white: 0.3).opacity(0.55)))
                    }
                    ctx.stroke(Path(roundedRect: box.insetBy(dx: 4, dy: 3), cornerRadius: 4), with: .color(Color.accentColor.opacity(0.9)), lineWidth: 1.5)
                }
                if strip {
                    let n = SettingsPictures.apps.count
                    let icon: CGFloat = 20, gap: CGFloat = 6, pad: CGFloat = 7
                    let length = CGFloat(n) * icon + CGFloat(n - 1) * gap + pad * 2
                    let thick = icon + pad * 2
                    let vertical = !edge.isRow
                    let bar: CGRect
                    switch edge {
                    case .bottom: bar = CGRect(x: screen.midX - length / 2, y: screen.maxY - thick - 14, width: length, height: thick)
                    case .top: bar = CGRect(x: screen.midX - length / 2, y: screen.minY + 14, width: length, height: thick)
                    case .left: bar = CGRect(x: screen.minX + 14, y: screen.midY - length / 2, width: thick, height: length)
                    case .right: bar = CGRect(x: screen.maxX - thick - 14, y: screen.midY - length / 2, width: thick, height: length)
                    }
                    var panel = ctx
                    panel.addFilter(.shadow(color: .black.opacity(0.22), radius: 6, y: 2))
                    panel.fill(Path(roundedRect: bar, cornerRadius: 9, style: .continuous), with: .color(.white.opacity(0.8)))
                    for (i, colour) in SettingsPictures.apps.enumerated() {
                        let along = pad + CGFloat(i) * (icon + gap)
                        let r = vertical ? CGRect(x: bar.minX + pad, y: bar.minY + along, width: icon, height: icon)
                                         : CGRect(x: bar.minX + along, y: bar.minY + pad, width: icon, height: icon)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 5, style: .continuous), with: .color(colour))
                        if i == 1 { ctx.stroke(Path(roundedRect: r.insetBy(dx: -3, dy: -3), cornerRadius: 7, style: .continuous), with: .color(.black.opacity(0.35)), lineWidth: 1.5) }
                    }
                }
            }
        }
    }
}

/// Settings › Windows: a window dragged beside its neighbour, with the guides, grid and push the pane
/// has on.
struct DragStage: View {
    var placing: SettingsPictures.Placing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let t = reduceMotion ? SettingsPictures.dragStill
                : max(0, context.date.timeIntervalSince(start)).truncatingRemainder(dividingBy: SettingsPictures.dragDuration)
            let f = SettingsPictures.dragFrame(placing, at: t)
            Canvas { ctx, drawn in
                let screen = SettingsPictures.screen(in: &ctx, drawn: drawn)
                if placing.grid {
                    let step = SettingsPictures.stageStep(placing.step)
                    var x = screen.minX + 12
                    while x < screen.maxX {
                        var y = screen.minY + 12
                        while y < screen.maxY {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.black.opacity(0.13)))
                            y += step
                        }
                        x += step
                    }
                }
                ctx.opacity = f.opacity
                MiniCanvasPicture.drawWindow(f.b, acted: false, in: &ctx)
                MiniCanvasPicture.drawWindow(f.a, acted: true, in: &ctx)
                if placing.magnetism, placing.polarity {
                    SettingsPictures.pole(true, on: f.a, in: &ctx)
                    SettingsPictures.pole(false, on: f.b, in: &ctx)
                }
                if f.guide {
                    var line = Path()
                    line.move(to: CGPoint(x: screen.minX + 16, y: f.b.minY))
                    line.addLine(to: CGPoint(x: screen.maxX - 16, y: f.b.minY))
                    ctx.stroke(line, with: .color(SettingsPictures.guide), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                if let reach = f.reach {
                    var line = Path()
                    line.move(to: CGPoint(x: reach, y: f.b.minY - 12))
                    line.addLine(to: CGPoint(x: reach, y: f.b.maxY + 12))
                    ctx.stroke(line, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let p = f.pointer { MiniCanvasPicture.drawPointer(at: p, in: &ctx) }
            }
        }
        .onChange(of: placing) { start = .now }
        .accessibilityLabel("A window dragged beside its neighbour")
    }
}

/// Settings › Motion: a window opening and closing with the chosen effect; as a tile, the same loop
/// small, each effect's loop a little out of step with the next.
struct EffectStage: View {
    var effect: WindowEffect
    /// Drawn as a tile rather than the stage.
    var tile = false
    /// Tiles start their loops staggered, so the row doesn't open and close as one.
    var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? SettingsPictures.effectStill + 0.9 : max(0, context.date.timeIntervalSince(start)) + phase
            let f = SettingsPictures.effectFrame(effect, at: elapsed, loop: Int(elapsed / SettingsPictures.effectDuration))
            Canvas { ctx, drawn in
                let base = tile ? SettingsPictures.tileSize : SettingsPictures.stageSize
                let screen = SettingsPictures.screen(in: &ctx, drawn: drawn, base: base, bezel: tile ? 0 : 5)
                guard f.shown else { return }
                let w = screen.width * 0.46, h = screen.height * 0.5
                let r = CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2 + f.dy * (tile ? 0.35 : 1), width: w, height: h)
                let anchor = CGPoint(x: r.midX, y: f.fromTop ? r.minY : r.midY)
                ctx.translateBy(x: anchor.x, y: anchor.y)
                ctx.scaleBy(x: f.scale.width, y: f.scale.height)
                ctx.translateBy(x: -anchor.x, y: -anchor.y)
                if let ring = f.ring {
                    let grow = ring * (tile ? 8 : 26)
                    var ringed = ctx
                    ringed.opacity = (1 - ring) * 0.7
                    ringed.stroke(Path(roundedRect: r.insetBy(dx: -grow, dy: -grow), cornerRadius: 6 + grow, style: .continuous), with: .color(.white), lineWidth: tile ? 1.5 : 2.5)
                }
                ctx.opacity = f.opacity
                MiniCanvasPicture.drawWindow(r, acted: false, in: &ctx)
            }
        }
        .onChange(of: effect) { start = .now }
        .accessibilityLabel("\(effect.title): a window opening and closing")
    }
}

// MARK: - Tiles

/// A choice drawn, not named: the picture with a ring round it when chosen, its title under it, as
/// System Settings › Appearance offers Light and Dark.
struct PictureTile<Picture: View>: View {
    let title: String
    let selected: Bool
    var width: CGFloat = SettingsPictures.tileSize.width
    let action: () -> Void
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture()
                    .frame(width: width, height: width * SettingsPictures.tileSize.height / SettingsPictures.tileSize.width)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 0.5)
                    }
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of tiles, centred, wrapping if the pane is ever narrower than them.
struct TileRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

/// Two windows on the sky, with the ⌘Tab strip hugging an edge.
struct EdgePicture: View {
    let edge: SwitcherEdge

    var body: some View {
        Canvas { ctx, drawn in
            let screen = SettingsPictures.screen(in: &ctx, drawn: drawn, base: SettingsPictures.tileSize, bezel: 0)
            let shift: CGFloat = edge == .left ? 14 : (edge == .right ? -4 : 0)
            let drop: CGFloat = edge == .top ? 12 : 0
            MiniCanvasPicture.drawWindow(CGRect(x: 12 + shift, y: 10 + drop, width: 30, height: 22), acted: false, in: &ctx)
            MiniCanvasPicture.drawWindow(CGRect(x: 48 + shift, y: 18 + drop, width: 28, height: 20), acted: false, in: &ctx)
            let bar: CGRect
            switch edge {
            case .bottom: bar = CGRect(x: 20, y: screen.maxY - 14, width: 52, height: 11)
            case .top: bar = CGRect(x: 20, y: screen.minY + 4, width: 52, height: 11)
            case .left: bar = CGRect(x: screen.minX + 4, y: 11, width: 11, height: 40)
            case .right: bar = CGRect(x: screen.maxX - 15, y: 11, width: 11, height: 40)
            }
            ctx.fill(Path(roundedRect: bar, cornerRadius: 3, style: .continuous), with: .color(.white.opacity(0.8)))
            for i in 0..<4 {
                let r = edge.isRow ? CGRect(x: bar.minX + 4 + CGFloat(i) * 12, y: bar.minY + 2.5, width: 6, height: 6)
                                   : CGRect(x: bar.minX + 2.5, y: bar.minY + 4 + CGFloat(i) * 9, width: 6, height: 6)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.5), with: .color(SettingsPictures.apps[i]))
            }
        }
    }
}

/// Two tiled halves with the gap between them.
struct GapPicture: View {
    let gap: CGFloat

    var body: some View {
        Canvas { ctx, drawn in
            let k = drawn.width / SettingsPictures.tileSize.width
            ctx.scaleBy(x: k, y: k)
            let size = SettingsPictures.tileSize
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.86)))
            // The gap at a quarter scale, 0 to 6 points on the tile; None touching.
            let g = gap / 4
            let edge: CGFloat = 9
            let half = (size.width - edge * 2 - g) / 2
            for i in 0..<2 {
                let r = CGRect(x: edge + CGFloat(i) * (half + g), y: edge, width: half, height: size.height - edge * 2)
                var shadowed = ctx
                shadowed.addFilter(.shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5))
                shadowed.fill(Path(roundedRect: r, cornerRadius: 3, style: .continuous), with: .color(.white))
            }
        }
    }
}

/// The canvas light, dark, or split down the middle for Match the Mac.
struct AppearancePicture: View {
    let appearance: Settings.Appearance

    var body: some View {
        Canvas { ctx, drawn in
            let k = drawn.width / SettingsPictures.tileSize.width
            ctx.scaleBy(x: k, y: k)
            let size = SettingsPictures.tileSize
            let whole = CGRect(origin: .zero, size: size)
            func side(_ r: CGRect, dark: Bool) {
                var part = ctx
                part.clip(to: Path(r))
                part.fill(Path(whole), with: .linearGradient(Gradient(colors: dark ? [Color(red: 0.1, green: 0.11, blue: 0.17), Color(red: 0.17, green: 0.14, blue: 0.13)]
                                                                                   : [Color(red: 0.62, green: 0.76, blue: 0.93), Color(red: 0.96, green: 0.86, blue: 0.70)]),
                                                            startPoint: CGPoint(x: whole.midX, y: whole.minY), endPoint: CGPoint(x: whole.midX, y: whole.maxY)))
                for w in [CGRect(x: 12, y: 12, width: 32, height: 24), CGRect(x: 48, y: 24, width: 30, height: 22)] {
                    let shape = Path(roundedRect: w, cornerRadius: 3, style: .continuous)
                    part.fill(shape, with: .color(dark ? Color(white: 0.24) : .white))
                    var bar = part
                    bar.clip(to: shape)
                    bar.fill(Path(CGRect(x: w.minX, y: w.minY, width: w.width, height: 4)), with: .color(dark ? Color(white: 0.36) : Color(white: 0.86)))
                }
            }
            switch appearance {
            case .light: side(whole, dark: false)
            case .dark: side(whole, dark: true)
            case .system:
                side(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height), dark: false)
                side(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height), dark: true)
            }
        }
    }
}

/// Live windows (the real thing) or screen capture (pictures of them, drawn with a film's scan lines).
struct ModePicture: View {
    let live: Bool

    var body: some View {
        Canvas { ctx, drawn in
            let screen = SettingsPictures.screen(in: &ctx, drawn: drawn, base: SettingsPictures.tileSize, bezel: 0)
            MiniCanvasPicture.drawWindow(CGRect(x: 10, y: 9, width: 34, height: 26), acted: live, in: &ctx)
            MiniCanvasPicture.drawWindow(CGRect(x: 48, y: 19, width: 36, height: 28), acted: false, in: &ctx)
            if !live {
                var y = screen.minY + 1
                while y < screen.maxY {
                    ctx.fill(Path(CGRect(x: screen.minX, y: y, width: screen.width, height: 1)), with: .color(.black.opacity(0.09)))
                    y += 3
                }
                // The capture's frame counter.
                let box = CGRect(x: screen.maxX - 26, y: screen.minY + 4, width: 22, height: 10)
                ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.55)))
                ctx.fill(Path(ellipseIn: CGRect(x: box.minX + 4, y: box.minY + 3, width: 4, height: 4)), with: .color(Color(red: 1, green: 0.25, blue: 0.2)))
                ctx.fill(Path(roundedRect: CGRect(x: box.minX + 11, y: box.minY + 4, width: 7, height: 2), cornerRadius: 1), with: .color(.white.opacity(0.8)))
            }
        }
    }
}

/// Settings › Experimental: a feature's small picture.
struct LabPicture: View {
    enum Kind { case arranging, strip, displays, anyZoom, agent }
    let kind: Kind

    var body: some View {
        Canvas { ctx, drawn in
            let base = CGSize(width: 64, height: 44)
            let k = drawn.width / base.width
            ctx.scaleBy(x: k, y: k)
            let whole = CGRect(origin: .zero, size: base)
            let shape = Path(roundedRect: whole, cornerRadius: 7, style: .continuous)
            switch kind {
            case .arranging:
                SettingsPictures.sky(shape, in: whole, ctx: &ctx)
                for i in 0..<3 { MiniCanvasPicture.drawWindow(CGRect(x: 5 + CGFloat(i) * 19, y: 5, width: 16, height: 34), acted: false, in: &ctx) }
            case .strip:
                SettingsPictures.sky(shape, in: whole, ctx: &ctx)
                ctx.clip(to: shape)
                for i in 0..<4 { MiniCanvasPicture.drawWindow(CGRect(x: -8 + CGFloat(i) * 24, y: 8, width: 20, height: 28), acted: i == 1, in: &ctx) }
            case .displays:
                for i in 0..<2 {
                    let r = CGRect(x: CGFloat(i) * 34, y: 6, width: 30, height: 32)
                    let one = Path(roundedRect: r, cornerRadius: 4, style: .continuous)
                    SettingsPictures.sky(one, in: r, ctx: &ctx)
                    ctx.stroke(one, with: .color(.black.opacity(0.25)), lineWidth: 0.5)
                    MiniCanvasPicture.drawWindow(CGRect(x: r.minX + 6, y: r.minY + 8, width: 18, height: 14), acted: i == 0, in: &ctx)
                }
            case .anyZoom:
                SettingsPictures.sky(shape, in: whole, ctx: &ctx)
                MiniCanvasPicture.drawWindow(CGRect(x: 10, y: 7, width: 44, height: 30), acted: false, in: &ctx)
                MiniCanvasPicture.drawPointer(at: CGPoint(x: 30, y: 19), in: &ctx)
            case .agent:
                SettingsPictures.sky(shape, in: whole, ctx: &ctx)
                MiniCanvasPicture.drawWindow(CGRect(x: 6, y: 5, width: 24, height: 20), acted: true, in: &ctx)
                MiniCanvasPicture.drawWindow(CGRect(x: 34, y: 5, width: 24, height: 20), acted: false, in: &ctx)
                // The request bar along the bottom, with a short line of "text" in it.
                let bar = Path(roundedRect: CGRect(x: 8, y: 30, width: 48, height: 9), cornerRadius: 4.5, style: .continuous)
                ctx.fill(bar, with: .color(.white.opacity(0.9)))
                ctx.stroke(bar, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
                ctx.fill(Path(roundedRect: CGRect(x: 13, y: 33.5, width: 22, height: 2), cornerRadius: 1), with: .color(.black.opacity(0.45)))
            }
        }
        .frame(width: 64, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
