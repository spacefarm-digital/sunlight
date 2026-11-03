import AppKit

/// The red, yellow and green buttons in a window's top-left corner, as the canvas draws its own over a
/// window: where the window's own sit (`Layout`), and how macOS paints them (`Tone`, `Look`). The
/// green one fills the window's area and, held or hovered, offers the tiling popover (`TilePopover`); the
/// window's magnetic pole (while polarity is on) and a grey menu button sit in the title bar's top-right
/// corner (`WindowProxy.trailingControls`), the menu button last.
enum TrafficLights {
    /// Where a window's buttons are: each one's centre from the window's top-left, in the real window's
    /// points (world units, at 1:1), and their diameter. Close, minimize, zoom, left to right.
    struct Layout: Equatable, Sendable {
        var centres: [CGPoint]
        var diameter: CGFloat

        /// A standard titled window's, for a window Accessibility can't tell us about yet.
        /// Measured on macOS 27: 14 pt circles 23 pt apart, the first centred 16 pt in from the corner (26
        /// in a window with a unified toolbar).
        static let standard = Layout(centres: [CGPoint(x: 16, y: 16), CGPoint(x: 39, y: 16), CGPoint(x: 62, y: 16)],
                                     diameter: 14)

        /// The distance from one centre to the next.
        var pitch: CGFloat {
            centres.count > 1 ? centres[1].x - centres[0].x : diameter + 9
        }

        /// The centre of the `i`th button from the left; past the window's own buttons, carried on at
        /// the same pitch (a window without a green button still gets one).
        func centre(_ i: Int) -> CGPoint {
            if centres.indices.contains(i) { return centres[i] }
            guard let last = centres.last else { return Layout.standard.centre(i) }
            return CGPoint(x: last.x + pitch * CGFloat(i - centres.count + 1), y: last.y)
        }

        /// From the frames Accessibility gives for the window and its buttons (top-left screen points).
        /// The button's frame is a little larger than the circle it draws: the circle is its width less
        /// `framePadding`, centred. Nil without a close button, or with buttons that make no sense: a
        /// sheet, a panel, a window mid-animation.
        static func measured(window: CGRect, close: CGRect?, minimize: CGRect?, zoom: CGRect?) -> Layout? {
            guard let close, close.width > 4, close.height > 4 else { return nil }
            let frames = [close, minimize, zoom].prefix { $0 != nil }.compactMap { $0 }
            let centres = frames.map { CGPoint(x: $0.midX - window.minX, y: $0.midY - window.minY) }
            // Inside the window's top-left corner, in a row, left to right.
            guard centres.allSatisfy({ $0.x > 0 && $0.y > 0 && $0.x < min(240, window.width) && $0.y < min(120, window.height) }),
                  zip(centres, centres.dropFirst()).allSatisfy({ abs($0.y - $1.y) < 1 && $1.x > $0.x })
            else { return nil }
            let diameter = min(close.width, close.height) - framePadding
            return Layout(centres: centres, diameter: min(20, max(8, diameter)))
        }

        /// How much wider an `AXCloseButton`'s frame is than the circle in it: 16 pt around 14 on macOS 27.
        static let framePadding: CGFloat = 2
    }

    /// Which paint a button wears.
    enum Tone: Equatable {
        case close, minimize, zoom
        /// The magnet in the top-right corner: its pole's colour.
        case pole(Polarity)
        /// The menu button, last in the top-right corner: grey, three dots.
        case menu

        var isPole: Bool {
            if case .pole = self { return true }
            return false
        }
    }

    /// One button's paint in one state. macOS 27's buttons aren't flat: a bright rim along the top,
    /// the colour, and a deeper shade toward the bottom edge.
    struct Look: Equatable {
        var highlight: NSColor
        var fill: NSColor
        var edge: NSColor
        var glyph: NSColor
    }

    /// macOS's colours, sampled on 27.2 (sRGB): each button's own while its window is key (or the
    /// pointer is on the group), all grey while it isn't; darker while pressed.
    /// The magnet keeps its pole's colours either way: they're the window's state, not a button's.
    static func look(_ tone: Tone, active: Bool, pressed: Bool, dark: Bool) -> Look {
        var look: Look
        if !active, !tone.isPole {
            look = dark
                ? Look(highlight: rgb(0x9A9A9A), fill: rgb(0x4D4D4D), edge: rgb(0x474747), glyph: .clear)
                : Look(highlight: rgb(0xEFEFEF), fill: rgb(0xDCDCDC), edge: rgb(0xC9C9C9), glyph: .clear)
            // The menu button keeps its dots in the background: a bare grey circle says nothing.
            if tone == .menu { look.glyph = dark ? rgb(0xB5B5B5) : rgb(0x7A7A7A) }
        } else {
            switch tone {
            case .close:
                look = Look(highlight: rgb(0xFFA094), fill: rgb(0xE1675B), edge: rgb(0xE05C4E), glyph: rgb(0x5C0E06))
            case .minimize:
                look = Look(highlight: rgb(0xFEDD61), fill: rgb(0xF3C22D), edge: rgb(0xF3BE00), glyph: rgb(0x8A5300))
            case .zoom:
                look = Look(highlight: rgb(0x9BED75), fill: rgb(0x62BD2E), edge: rgb(0x4CB900), glyph: rgb(0x0E5A00))
            case .menu:
                // Grey as well, a shade deeper than the background grey, with dark dots.
                look = dark
                    ? Look(highlight: rgb(0xA8A8A8), fill: rgb(0x7C7C7C), edge: rgb(0x6E6E6E), glyph: rgb(0x1E1E1E))
                    : Look(highlight: rgb(0xD9D9D9), fill: rgb(0xB2B2B2), edge: rgb(0x9C9C9C), glyph: rgb(0x3A3A3A))
            case .pole(let pole):
                let tint = pole.tint
                look = Look(highlight: tint.blended(withFraction: 0.45, of: .white) ?? tint, fill: tint,
                            edge: tint.blended(withFraction: 0.25, of: .black) ?? tint,
                            // The sign sits on the window's title bar between the arms, so it wears the
                            // pole's own colour rather than a darker shade of it.
                            glyph: tint)
            }
        }
        guard pressed else { return look }
        let darker = { (c: NSColor, f: CGFloat) in c.blended(withFraction: f, of: .black) ?? c }
        return Look(highlight: darker(look.highlight, 0.25), fill: darker(look.fill, 0.22),
                    edge: darker(look.edge, 0.22), glyph: darker(look.glyph, 0.35))
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The mark a button shows while the pointer is on the group: macOS's ×, the minimize bar, the zoom
    /// button's two corner triangles (filled as well as stroked: `glyphIsFilled`), and for the magnet,
    /// always, a + or −. Sized for a circle of `diameter` centred in `bounds`; stroked, round-capped.
    static func glyph(_ tone: Tone, in bounds: CGRect) -> CGPath {
        let d = min(bounds.width, bounds.height)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        switch tone {
        case .close:
            let r = d * 0.21
            path.move(to: CGPoint(x: c.x - r, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            path.move(to: CGPoint(x: c.x + r, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
        case .minimize:
            let r = d * 0.30
            path.move(to: CGPoint(x: c.x - r, y: c.y))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y))
        case .zoom:
            // Two right triangles, their square corners at the top left and bottom right, a diagonal
            // gap between them (y-up: the top left is +y).
            let r = d * 0.25, s = r * 0.35
            path.move(to: CGPoint(x: c.x - r, y: c.y + r))
            path.addLine(to: CGPoint(x: c.x + s, y: c.y + r))
            path.addLine(to: CGPoint(x: c.x - r, y: c.y - s))
            path.closeSubpath()
            path.move(to: CGPoint(x: c.x + r, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x - s, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y + s))
            path.closeSubpath()
        case .menu:
            // Three dots across the middle, filled (`glyphIsFilled`).
            let r = d * 0.055, gap = d * 0.24
            for dx in [-gap, 0, gap] {
                path.addEllipse(in: CGRect(x: c.x + dx - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        case .pole(let pole):
            // In the gap between the magnet's arms (`magnet`), above the bend.
            let r = d * 0.13
            let c = CGPoint(x: c.x, y: bounds.minY + d * 0.62)
            path.move(to: CGPoint(x: c.x - r, y: c.y))
            path.addLine(to: CGPoint(x: c.x + r, y: c.y))
            if pole == .plus {
                path.move(to: CGPoint(x: c.x, y: c.y - r))
                path.addLine(to: CGPoint(x: c.x, y: c.y + r))
            }
        }
        return path
    }

    /// The pole's button isn't a circle but a horseshoe magnet standing on its bend, arms up, in
    /// `bounds` (y-up, as Core Animation's): red for ⊕ and blue for ⊖ (`Polarity.tint`), steel tips
    /// (`magnetTips`), the sign between the arms. A little larger than the circles it sits beside,
    /// since a U shows less paint than a disc; `magnetScale` of the diameter, centred on the slot.
    static func magnet(in bounds: CGRect) -> CGPath {
        let m = MagnetShape(bounds)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: m.cx - m.outer, y: m.top))
        path.addLine(to: CGPoint(x: m.cx - m.outer, y: m.bend))
        path.addArc(center: CGPoint(x: m.cx, y: m.bend), radius: m.outer, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        path.addLine(to: CGPoint(x: m.cx + m.outer, y: m.top))
        path.addLine(to: CGPoint(x: m.cx + m.inner, y: m.top))
        path.addLine(to: CGPoint(x: m.cx + m.inner, y: m.bend))
        path.addArc(center: CGPoint(x: m.cx, y: m.bend), radius: m.inner, startAngle: 0, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: m.cx - m.inner, y: m.top))
        path.closeSubpath()
        return path
    }

    /// The bare steel at the end of each arm.
    static func magnetTips(in bounds: CGRect) -> CGPath {
        let m = MagnetShape(bounds)
        let path = CGMutablePath()
        let h = m.size * 0.24
        path.addRect(CGRect(x: m.cx - m.outer, y: m.top - h, width: m.outer - m.inner, height: h))
        path.addRect(CGRect(x: m.cx + m.inner, y: m.top - h, width: m.outer - m.inner, height: h))
        return path
    }

    /// The tips' paint: steel while the buttons wear their colours, the grey's highlight while they
    /// don't; darker while pressed.
    static func magnetTip(active: Bool, pressed: Bool, dark: Bool) -> NSColor {
        let tip = active ? rgb(0xE6E8EB) : (dark ? rgb(0x8A8A8A) : rgb(0xF4F4F4))
        return pressed ? tip.blended(withFraction: 0.25, of: .black) ?? tip : tip
    }

    /// How much larger than a circle's diameter the magnet's box is.
    static let magnetScale: CGFloat = 1.12

    /// A horseshoe's proportions in a square box: arms from just under the top down to the middle,
    /// where they bend round.
    private struct MagnetShape {
        let size, cx, top, bend, outer, inner: CGFloat
        init(_ bounds: CGRect) {
            size = min(bounds.width, bounds.height)
            cx = bounds.midX
            top = bounds.minY + size * 0.98
            bend = bounds.minY + size * 0.50
            outer = size * 0.48
            inner = size * 0.21
        }
    }

    /// Whether the glyph is a shape to fill (the zoom triangles, the menu's dots) rather than lines.
    static func glyphIsFilled(_ tone: Tone) -> Bool { tone == .zoom || tone == .menu }

    /// The glyph's stroke for a circle of `diameter`: a little over a point at 14.
    static func glyphWidth(diameter: CGFloat) -> CGFloat { max(1, diameter * 0.085) }
}
