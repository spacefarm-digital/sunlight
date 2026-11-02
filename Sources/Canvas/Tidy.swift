import CoreGraphics
import Foundation

/// Tidy (Window › Tidy, ⌃⌥A): every window on the canvas laid out on one grid, from the top-left of
/// the screen in view. The third of the three placement scopes: Move & Resize places one window,
/// Arrange the windows of one screen, Tidy everything. World coordinates throughout (top-left origin,
/// points). Pure: items in, rects out; the controller gathers the windows, resizes the real ones and
/// animates.
enum Tidy {
    /// Settings › Experimental › Arranging › Sizes.
    enum Sizing: String, CaseIterable, Sendable {
        /// Nothing is resized: columns as wide as their widest window, rows as tall as their tallest,
        /// each window at the top-left of its cell.
        case keep
        /// Every window to a cell that is a fraction of the screen, the grid continuing onto the
        /// screens below.
        case same

        var title: String {
            switch self {
            case .keep: return "Keep each window's size"
            case .same: return "Make them the same size"
            }
        }
    }

    /// Window › Tidy By: which window comes first.
    enum Order: String, CaseIterable, Sendable {
        /// Rows by where the windows sit now, each row left to right: the canvas you had, straightened.
        case position
        /// The window used last at the top left.
        case recent
        /// An app's windows side by side, apps in the order their first window appears.
        case app

        var title: String {
            switch self {
            case .position: return "Where They Are"
            case .recent: return "Most Recent"
            case .app: return "App"
            }
        }
    }

    /// Settings › Experimental › Arranging › Spacing, in tile gaps: the gap itself, four of them, twelve.
    enum Spacing: String, CaseIterable, Sendable {
        case tight, normal, roomy

        var title: String {
            switch self {
            case .tight: return "Tight"
            case .normal: return "Normal"
            case .roomy: return "Roomy"
            }
        }

        var multiplier: CGFloat {
            switch self {
            case .tight: return 1
            case .normal: return 4
            case .roomy: return 12
            }
        }

        /// In points. Tight is the gap exactly; the other two don't let a gap of none pile the windows up.
        func points(gap: CGFloat) -> CGFloat {
            self == .tight ? gap : multiplier * max(gap, 8)
        }
    }

    /// One thing to place: a window, or a bonded group as a block (`rect` is the group's outline and
    /// `isGroup` keeps it from being resized).
    struct Item: Equatable {
        var rect: CGRect
        /// Place in the recency list, 0 the most recent; nil when never used.
        var recency: Int?
        /// What `Order.app` groups by.
        var app: String
        /// Hidden or minimized: it keeps a cell, after everything visible.
        var away = false
        var isGroup = false
    }

    struct Options: Equatable {
        /// 0 for auto.
        var columns: Int
        var sizing: Sizing
        var order: Order
        /// Between windows and from the grid's edge, in points (`Spacing.points`).
        var spacing: CGFloat
    }

    struct Placement: Equatable {
        /// Each item's new rect, in the items' order: for a window the cell to take (sized, in same-size
        /// mode), for a group where its outline goes.
        var rects: [CGRect]
        /// In same-size mode, the screen each item's cell is in, to record as its tiled area; nil otherwise.
        var screens: [CGRect?]
        /// Around the whole grid, for the camera to frame.
        var bounds: CGRect
    }

    // MARK: Order

    /// The items in the order they fill the grid. Visible ones first, hidden and minimized after, each
    /// part in `order`.
    static func order(_ items: [Item], by order: Order) -> [Int] {
        let visible = items.indices.filter { !items[$0].away }
        let away = items.indices.filter { items[$0].away }
        return sorted(visible, of: items, by: order) + sorted(away, of: items, by: order)
    }

    private static func sorted(_ indices: [Int], of items: [Item], by order: Order) -> [Int] {
        let byPosition = readingOrder(indices, rects: items.map(\.rect))
        switch order {
        case .position:
            return byPosition
        case .recent:
            // Stable on the reading order, so windows never used keep their places among themselves.
            return byPosition.enumerated().sorted {
                let a = items[$0.element].recency ?? Int.max, b = items[$1.element].recency ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        case .app:
            var apps: [String] = []
            for i in byPosition where !apps.contains(items[i].app) { apps.append(items[i].app) }
            return apps.flatMap { app in byPosition.filter { items[$0].app == app } }
        }
    }

    /// Rows by where the rects sit, each row left to right. A rect joins the row above it when its top
    /// is above that row's first (topmost) rect's middle; otherwise it starts the next row. So windows
    /// roughly beside each other read as one row however their tops differ.
    static func readingOrder(_ indices: [Int], rects: [CGRect]) -> [Int] {
        let byTop = indices.sorted { rects[$0].minY != rects[$1].minY ? rects[$0].minY < rects[$1].minY : rects[$0].minX < rects[$1].minX }
        var rows: [[Int]] = []
        var rowMid: CGFloat = 0
        for i in byTop {
            if rows.isEmpty || rects[i].minY >= rowMid {
                rows.append([i])
                rowMid = rects[i].midY
            } else {
                rows[rows.count - 1].append(i)
            }
        }
        return rows.flatMap { row in row.sorted { rects[$0].minX != rects[$1].minX ? rects[$0].minX < rects[$1].minX : rects[$0].minY < rects[$1].minY } }
    }

    // MARK: Columns

    /// Auto is the square root of the count, rounded up; in same-size mode no more than four, so no cell
    /// is smaller than a quarter of the screen.
    static func columns(for count: Int, requested: Int, sizing: Sizing) -> Int {
        if requested > 0 { return requested }
        let auto = Int(Double(max(1, count)).squareRoot().rounded(.up))
        return max(1, sizing == .same ? min(auto, 4) : auto)
    }

    // MARK: Layout

    /// The grid. `screen` is the one in view: the grid starts at its top-left, and in same-size mode its
    /// cells are fractions of it, further screens stacked below it `Tiling.pageGutter` apart.
    static func layout(_ items: [Item], options: Options, screen: CGRect) -> Placement {
        guard !items.isEmpty else { return Placement(rects: [], screens: [], bounds: .null) }
        let order = order(items, by: options.order)
        let columns = columns(for: items.count, requested: options.columns, sizing: options.sizing)
        switch options.sizing {
        case .keep:
            let rects = keepSizes(items, order: order, columns: columns, spacing: options.spacing, origin: screen.origin)
            return Placement(rects: rects, screens: items.map { _ in nil }, bounds: bounds(of: rects, spacing: options.spacing))
        case .same:
            let (rects, screens) = sameSize(items, order: order, columns: columns, screen: screen, spacing: options.spacing)
            return Placement(rects: rects, screens: screens, bounds: bounds(of: rects, spacing: options.spacing))
        }
    }

    private static func bounds(of rects: [CGRect], spacing: CGFloat) -> CGRect {
        guard let first = rects.first else { return .null }
        return rects.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -spacing, dy: -spacing)
    }

    /// Items in `order` into `columns`, nothing resized: each column as wide as its widest item, each row
    /// as tall as its tallest, `spacing` between them and from `origin`, every item at the top-left of
    /// its cell. Rects come back indexed like `items`.
    static func keepSizes(_ items: [Item], order: [Int], columns: Int, spacing: CGFloat, origin: CGPoint) -> [CGRect] {
        let columns = max(1, columns)
        var widths = [CGFloat](repeating: 0, count: columns)
        var heights = [CGFloat](repeating: 0, count: (order.count + columns - 1) / columns)
        for (slot, i) in order.enumerated() {
            widths[slot % columns] = max(widths[slot % columns], items[i].rect.width)
            heights[slot / columns] = max(heights[slot / columns], items[i].rect.height)
        }
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var x = origin.x + spacing
        for w in widths { xs.append(x); x += w + spacing }
        var y = origin.y + spacing
        for h in heights { ys.append(y); y += h + spacing }
        var rects = items.map(\.rect)
        for (slot, i) in order.enumerated() {
            rects[i].origin = CGPoint(x: xs[slot % columns].rounded(), y: ys[slot / columns].rounded())
        }
        return rects
    }

    /// Items in `order` into equal cells: `columns` across a screen and as many down, each cell keeping
    /// the screen's proportions, the cells spaced as tiled windows are (`Tiling.rect`), the screens
    /// stacked below the one given. A group spans the cells its outline needs, never across two screens,
    /// placed the way CSS grid places a spanning item: the cursor only moves forward, so nothing is
    /// filled in behind an earlier item and the order stays legible.
    static func sameSize(_ items: [Item], order: [Int], columns: Int, screen: CGRect,
                         spacing: CGFloat) -> (rects: [CGRect], screens: [CGRect?]) {
        let columns = max(1, columns), rows = columns
        let cell = Tiling.rect(CGRect(x: 0, y: 0, width: 1 / CGFloat(columns), height: 1 / CGFloat(rows)), in: screen, gap: spacing).size
        var taken = Set<Int>()   // row * columns + column
        var cursor = (row: 0, column: 0)
        var rects = items.map(\.rect)
        var screens: [CGRect?] = items.map { _ in nil }
        for i in order {
            let item = items[i]
            var spanC = 1, spanR = 1
            if item.isGroup {
                spanC = min(columns, max(1, Int(((item.rect.width - cell.width) / (cell.width + spacing)).rounded(.up)) + 1))
                spanR = min(rows, max(1, Int(((item.rect.height - cell.height) / (cell.height + spacing)).rounded(.up)) + 1))
            }
            var row = cursor.row, column = cursor.column
            while true {
                if column + spanC > columns { row += 1; column = 0; continue }
                let fits = (row % rows) + spanR <= rows && (0..<spanR).allSatisfy { r in
                    (0..<spanC).allSatisfy { c in !taken.contains((row + r) * columns + column + c) }
                }
                if fits { break }
                column += 1
            }
            for r in 0..<spanR { for c in 0..<spanC { taken.insert((row + r) * columns + column + c) } }
            cursor = (row, column + spanC)
            let page = row / rows, rowInPage = row % rows
            let area = screen.offsetBy(dx: 0, dy: CGFloat(page) * (screen.height + Tiling.pageGutter))
            let unit = CGRect(x: CGFloat(column) / CGFloat(columns), y: CGFloat(rowInPage) / CGFloat(rows),
                              width: CGFloat(spanC) / CGFloat(columns), height: CGFloat(spanR) / CGFloat(rows))
            let slot = Tiling.rect(unit, in: area, gap: spacing)
            rects[i] = item.isGroup ? CGRect(origin: slot.origin, size: item.rect.size) : slot
            screens[i] = area
        }
        return (rects, screens)
    }
}
