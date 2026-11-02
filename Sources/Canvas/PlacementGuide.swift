import AppKit
import SwiftUI

/// Settings › How to use › Placing (`Manual`): the three placement scopes shown rather than described.
/// Each is a miniature canvas whose windows act the command out on a loop, with the keys beside it and
/// a Try button that runs the real command on the canvas behind the window. Also reached from the ? in
/// Settings › Windows.
enum PlacementGuide {
    enum Scope: CaseIterable, Identifiable {
        case window, screen, everything

        var id: Self { self }

        var eyebrow: String {
            switch self {
            case .window: return "One window"
            case .screen: return "One screen"
            case .everything: return "Everything"
            }
        }

        var title: String {
            switch self {
            case .window: return "Move & Resize"
            case .screen: return "Arrange"
            case .everything: return "Tidy"
            }
        }

        var line: String {
            switch self {
            case .window: return "The window under the pointer takes a half, quarter or third."
            case .screen: return "This screen’s windows share it in columns."
            case .everything: return "Every window on the canvas, on one grid."
            }
        }

        @MainActor var keys: String {
            switch self {
            case .window: return TileMenu.tileKeysSummary
            case .screen: return TileMenu.arrangeKeysSummary
            case .everything: return TileMenu.tidyKeysSummary
            }
        }
    }

    /// The cards shown: Arrange and Tidy only with arranging on (`Settings.arranging`).
    static func scopes(arranging: Bool) -> [Scope] { arranging ? Scope.allCases : [.window] }

    /// What the hand does, under the cards.
    struct HandItem: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let line: String
    }

    static let byHand: [HandItem] = [
        HandItem(id: "drag", symbol: "hand.point.up.left", title: "Drag",
                 line: "Edges line up with the neighbours."),
        HandItem(id: "free", symbol: "command", title: "⌘-drag",
                 line: "Freely, with no guides or grid."),
        HandItem(id: "edge", symbol: "arrow.up.left.and.arrow.down.right", title: "An edge or corner",
                 line: "Resizes the window."),
        HandItem(id: "push", symbol: "arrow.left.and.right", title: "Into a neighbour",
                 line: "It moves aside, if windows push each other."),
    ]

    // MARK: The demos

    /// A miniature canvas: each window's rect before and after the command, in a 222 × 150 box; the
    /// screen's outline, and how far the view pulls back after (Tidy frames the result).
    struct Demo {
        var screen: CGRect
        var before: [CGRect]
        var after: [CGRect]
        /// Which windows the command acts on: drawn in the sun's colour.
        var acted: Set<Int>
        var pullBack: CGFloat = 1
    }

    static let box = CGSize(width: 222, height: 150)

    @MainActor static func demo(for scope: Scope) -> Demo {
        let screen = CGRect(x: 11, y: 11, width: 200, height: 128)
        let gap: CGFloat = 6
        switch scope {
        case .window:
            let others = [CGRect(x: 122, y: 32, width: 62, height: 46), CGRect(x: 140, y: 88, width: 52, height: 40)]
            let hand = CGRect(x: 34, y: 30, width: 72, height: 52)
            let leftHalf = Tiling.rect(Tiling.Preset.leftHalf.unit!, in: screen, gap: gap)
            return Demo(screen: screen, before: [hand] + others, after: [leftHalf] + others, acted: [0])
        case .screen:
            let before = [CGRect(x: 24, y: 26, width: 78, height: 60), CGRect(x: 74, y: 56, width: 88, height: 56),
                          CGRect(x: 136, y: 28, width: 58, height: 70)]
            let after = Tiling.cells(columns: 3, rows: 1).map { Tiling.rect($0, in: screen, gap: gap) }
            return Demo(screen: screen, before: before, after: after, acted: [0, 1, 2])
        case .everything:
            // Zoomed out: the screen is small and the windows are all over the canvas.
            let small = CGRect(x: 30, y: 34, width: 96, height: 62)
            let before = [CGRect(x: 6, y: 8, width: 40, height: 28), CGRect(x: 60, y: 14, width: 34, height: 24),
                          CGRect(x: 118, y: 4, width: 44, height: 30), CGRect(x: 176, y: 20, width: 38, height: 26),
                          CGRect(x: 12, y: 70, width: 36, height: 26), CGRect(x: 86, y: 54, width: 42, height: 30),
                          CGRect(x: 150, y: 76, width: 46, height: 32), CGRect(x: 62, y: 108, width: 40, height: 28)]
            var after: [CGRect] = []
            let cell = CGSize(width: 42, height: 29), spacing: CGFloat = 5
            for i in 0..<8 {
                after.append(CGRect(x: small.minX + spacing + CGFloat(i % 4) * (cell.width + spacing),
                                    y: small.minY + spacing + CGFloat(i / 4) * (cell.height + spacing),
                                    width: cell.width, height: cell.height))
            }
            return Demo(screen: small, before: before, after: after, acted: Set(0..<8), pullBack: 0.86)
        }
    }
}

// MARK: - Views

/// Settings › How to use › Placing: one section per scope, its miniature acting the command out beside
/// what it does, its keys and a Try button, then what the hand does.
struct PlacingChapter: View {
    let onTry: (PlacementGuide.Scope) -> Void
    /// `Settings.arranging`: Arrange and Tidy are shown only with it on.
    let arranging: Bool

    var body: some View {
        Form {
            ForEach(PlacementGuide.scopes(arranging: arranging)) { scope in
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        DemoView(demo: PlacementGuide.demo(for: scope))
                            .frame(width: PlacementGuide.box.width, height: PlacementGuide.box.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scope.line)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(scope.keys)
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button("Try") { onTry(scope) }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionHeader(title: "\(scope.title) · \(scope.eyebrow.lowercased())")
                }
            }
            Section {
                ForEach(PlacementGuide.byHand) { item in
                    Label {
                        RowLabel(title: item.title, subtitle: item.line)
                    } icon: {
                        Image(systemName: item.symbol).foregroundStyle(.secondary)
                    }
                }
            } header: {
                SectionHeader(title: "By hand", detail: "⌘Z undoes any placement.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The miniature canvas. On a loop: the windows as they are, a beat, the command (a spring), a long
/// look at the result, a short fade, and again. With Reduce Motion the result, still.
struct DemoView: View {
    let demo: PlacementGuide.Demo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var placed = false
    @State private var shown = true

    private static let sun = Color(red: 0.98, green: 0.74, blue: 0.12)

    var body: some View {
        let rects = placed ? demo.after : demo.before
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.primary.opacity(scheme == .dark ? 0.06 : 0.04))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: demo.screen.width, height: demo.screen.height)
                .offset(x: demo.screen.minX, y: demo.screen.minY)
            ForEach(rects.indices, id: \.self) { i in
                let acted = demo.acted.contains(i)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(acted ? Self.sun.opacity(placed ? 0.95 : 0.8) : Color.primary.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                    .frame(width: rects[i].width, height: rects[i].height)
                    .offset(x: rects[i].minX, y: rects[i].minY)
            }
        }
        .frame(width: PlacementGuide.box.width, height: PlacementGuide.box.height, alignment: .topLeading)
        .scaleEffect(placed ? demo.pullBack : 1, anchor: .center)
        .opacity(shown ? 1 : 0)
        .task { await run() }
        .accessibilityHidden(true)
    }

    private func run() async {
        if reduceMotion {
            placed = true
            return
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.0))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) { placed = true }
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeInOut(duration: 0.25)) { shown = false }
            try? await Task.sleep(for: .seconds(0.3))
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { placed = false }
            withAnimation(.easeInOut(duration: 0.25)) { shown = true }
            try? await Task.sleep(for: .seconds(0.3))
        }
    }
}
