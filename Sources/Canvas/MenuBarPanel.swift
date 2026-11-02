import AppKit
import SwiftUI

/// What the menu bar panel shows and does, apart from the window it sits in (`MenuBarItem`). The
/// state is pulled from the app each time the panel opens (`refresh`, the way a menu's items are
/// validated as it opens) and pushed in between for what changes on its own: the layouts list, setup
/// progress, an update that arrived. Every button is a closure in `actions`, so the panel knows nothing
/// of the canvas; what is enabled when is decided here, where it can be tested.
@MainActor
final class MenuBarPanelModel: ObservableObject {
    enum Screen: Equatable { case main, more }

    struct Layout: Identifiable, Equatable {
        let name: String
        /// ⌘1–⌘9 for the first nine.
        let key: String?
        var id: String { name }
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    /// How windows reach the canvas, for the line under the name.
    enum Rendering: Equatable { case live, pictures, preview }

    /// The line under "Sunlight", and the one thing it may ask for.
    struct Caption: Equatable {
        enum Prompt: Equatable { case continueSetup, reload, install }
        var text: String
        var prompt: String?
        var action: Prompt?
    }

    /// Everything the panel can do. Each is set by the app delegate; unset ones do nothing.
    struct Actions {
        var setOn: (Bool) -> Void = { _ in }
        var tidy: () -> Void = {}
        var toggleMinimap: () -> Void = {}
        var toggleSwitcher: () -> Void = {}
        var restoreLayout: (String) -> Void = { _ in }
        var saveLayout: () -> Void = {}
        var deleteLayout: (String) -> Void = { _ in }
        var toggleStrip: () -> Void = {}
        var showDesktop: () -> Void = {}
        var arrange: (Int, Int) -> Void = { _, _ in }
        var showSettings: () -> Void = {}
        var showInstructions: () -> Void = {}
        var setUp: () -> Void = {}
        var checkForUpdates: () -> Void = {}
        var reloadLiveWindows: () -> Void = {}
        var takeOver: () -> Void = {}
        var release: () -> Void = {}
        var quit: () -> Void = {}
    }

    @Published var screen: Screen = .main
    @Published var isOn = true
    @Published var minimap = true
    /// The ⌘Tab strip shown (`Settings.switcherOn`); off, ⌘Tab still switches without it.
    @Published var switcher = true
    @Published var stripMode = false
    /// The experimental flags (`Settings.arranging`, `Settings.stripModeEnabled`): off, the Tidy tile,
    /// the Arrange row and the Strip Mode switch aren't there.
    @Published var arranging = false
    @Published var stripModeEnabled = false
    @Published var showingDesktop = false
    @Published var layouts: [Layout] = []
    /// A layout restoring or widgets being added: layouts and placement wait.
    @Published var busy = false
    /// The setup window is up: nothing that would put another window in front of it.
    @Published var setupShowing = false
    @Published var setupProgress: Progress?
    @Published var rendering: Rendering = .live
    /// Live windows wanted but not answering (the Dock restarted, say): Reload has something to do.
    @Published var liveWindowsUnloaded = false
    /// An update Sparkle found, by version, until it's installed.
    @Published var updateVersion: String?
    @Published var takeoverRunning = false
    @Published var canCheckForUpdates = false
    var actions = Actions()

    // MARK: What is enabled when

    var caption: Caption {
        Self.caption(on: isOn, setup: setupProgress, liveWindowsUnloaded: liveWindowsUnloaded,
                     update: updateVersion, rendering: rendering)
    }

    /// Off first, then whatever needs doing, in the order it would be done: finish setup, bring live
    /// windows back, install the update. Nothing to do: how windows are reaching the canvas.
    static func caption(on: Bool, setup: Progress?, liveWindowsUnloaded: Bool, update: String?, rendering: Rendering) -> Caption {
        guard on else { return Caption(text: "Off · windows left as they are") }
        if let setup, setup.done < setup.total {
            return Caption(text: "Setting up · \(setup.done) of \(setup.total) steps", prompt: "Continue", action: .continueSetup)
        }
        if liveWindowsUnloaded {
            return Caption(text: "Live windows aren't loaded", prompt: "Reload", action: .reload)
        }
        if let update {
            return Caption(text: "Sunlight \(update) is ready", prompt: "Install", action: .install)
        }
        switch rendering {
        case .live: return Caption(text: "On · live windows")
        case .pictures: return Caption(text: "On · screen capture")
        case .preview: return Caption(text: "On · preview")
        }
    }

    /// Off: nothing on the canvas can be acted on. The switch and More stay live.
    var canvasAvailable: Bool { isOn && !setupShowing }
    /// Strip mode lays the windows out itself: Tidy and Arrange have nothing to do.
    var canTidy: Bool { canvasAvailable && !busy && !stripMode }
    var canArrange: Bool { canTidy }
    var canUseLayouts: Bool { canvasAvailable && !busy }
    var canToggleStrip: Bool { canvasAvailable && !busy }
    var canShowDesktop: Bool { canvasAvailable && !busy }
    var canToggleMinimap: Bool { isOn }
    /// ⌘Tab is only claimed while takeover's key tap runs.
    var canToggleSwitcher: Bool { isOn && takeoverRunning }
    var canReload: Bool { isOn && liveWindowsUnloaded && !setupShowing }
    var canTakeOver: Bool { isOn && !takeoverRunning && !setupShowing }

    /// Under Layouts when it's folded: the count, or what to do.
    var layoutsSummary: String {
        switch layouts.count {
        case 0: return "none saved"
        case 1: return "1 saved"
        default: return "\(layouts.count) saved"
        }
    }

    static func layoutRows(_ names: [String]) -> [Layout] {
        names.enumerated().map { i, name in Layout(name: name, key: i < 9 ? "⌘\(i + 1)" : nil) }
    }

    func caption(action prompt: Caption.Prompt) {
        switch prompt {
        case .continueSetup: actions.setUp()
        case .reload: actions.reloadLiveWindows()
        case .install: actions.checkForUpdates()
        }
    }
}

// MARK: - The views

/// The panel, Control Center's way: the Sunlight switch, Minimap, ⌘Tab and Desktop as round controls in a row, Layouts,
/// and More for everything else, which opens in place with a back row.
struct MenuBarPanelView: View {
    @ObservedObject var model: MenuBarPanelModel
    /// Closes the panel: rows that open a window do it before they open it.
    var dismiss: () -> Void = {}

    /// The content; the panel adds its 12 pt margins.
    static let width: CGFloat = 276
    static let tileRadius: CGFloat = 18
    /// The round controls and the saved layouts: three to a row, the same circle in each.
    static let roundColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
    static let roundSize: CGFloat = 38

    var body: some View {
        Group {
            switch model.screen {
            case .main: MainScreen(model: model, dismiss: dismiss)
            case .more: MoreScreen(model: model, dismiss: dismiss)
            }
        }
        .frame(width: Self.width)
        .padding(12)
        .font(.system(size: 13))
        .focusEffectDisabled()   // no focus ring round the first tile as the panel opens and takes key
    }
}

private struct MainScreen: View {
    @ObservedObject var model: MenuBarPanelModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            masterTile
            Tile {
                // Control Center's round controls: three to a row in one tile; Tidy, with Arranging on,
                // wraps below.
                LazyVGrid(columns: MenuBarPanelView.roundColumns, spacing: 8) {
                    SmallTile(title: "Minimap", symbol: "map", on: model.minimap, enabled: model.canToggleMinimap, help: "Minimap") {
                        model.minimap.toggle()
                        model.actions.toggleMinimap()
                    }
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityValue(model.minimap ? "On" : "Off")
                    SmallTile(title: "⌘Tab", symbol: "command", on: model.switcher, enabled: model.canToggleSwitcher,
                              help: "⌘Tab strip; off, ⌘Tab still switches without it") {
                        model.switcher.toggle()
                        model.actions.toggleSwitcher()
                    }
                    .accessibilityLabel("Command Tab strip")
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityValue(model.switcher ? "On" : "Off")
                    SmallTile(title: "Desktop", symbol: "menubar.dock.rectangle", on: model.showingDesktop,
                              enabled: model.canShowDesktop, help: "Show Desktop F11") {
                        model.showingDesktop.toggle()
                        model.actions.showDesktop()
                    }
                    .accessibilityLabel("Show Desktop")
                    .accessibilityAddTraits(.isToggle)
                    .accessibilityValue(model.showingDesktop ? "On" : "Off")
                    if model.arranging {
                        SmallTile(title: "Tidy", symbol: "sparkles", on: false, enabled: model.canTidy, help: "Tidy ⌃⌥A") {
                            model.actions.tidy()
                            dismiss()
                        }
                    }
                }
            }
            layoutsTile
            Tile {
                VStack(spacing: 2) {
                    Row(title: "How to Use…", detail: "⌘?", enabled: !model.setupShowing, bold: true) {
                        dismiss(); model.actions.showInstructions()
                    }
                    HeaderRow(title: "More", detail: nil, open: nil, enabled: true) {
                        withAnimation(.easeOut(duration: 0.15)) { model.screen = .more }
                    }
                }
            }
        }
    }

    /// Layouts, always open: Save Layout at the top right, and every saved layout as a round button
    /// with its name under it, three to a row like the controls above.
    private var layoutsTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Layouts").fontWeight(.semibold)
                    Text(model.layoutsSummary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button {
                        model.actions.saveLayout()
                        dismiss()
                    } label: {
                        Label("Save", systemImage: "plus")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(!model.canUseLayouts)
                    .help("Save Layout… ⌘S")
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                if !model.layouts.isEmpty {
                    LazyVGrid(columns: MenuBarPanelView.roundColumns, spacing: 8) {
                        ForEach(model.layouts) { layout in
                            LayoutButton(layout: layout, enabled: model.canUseLayouts) {
                                model.actions.restoreLayout(layout.name)
                                dismiss()
                            }
                            .contextMenu {
                                Button("Delete “\(layout.name)”") { model.actions.deleteLayout(layout.name) }
                            }
                        }
                    }
                }
            }
        }
    }

    private var masterTile: some View {
        Tile {
            HStack(spacing: 10) {
                CircleGlyph(symbol: "sun.max.fill", on: model.isOn, tint: .yellow, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sunlight").fontWeight(.semibold)
                    captionView
                }
                Spacer(minLength: 8)
                Toggle("Sunlight on", isOn: Binding(get: { model.isOn }, set: { on in
                    model.isOn = on
                    model.actions.setOn(on)
                }))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var captionView: some View {
        let caption = model.caption
        return HStack(spacing: 5) {
            Text(caption.text)
            if let prompt = caption.prompt, let action = caption.action {
                Button(prompt) {
                    model.caption(action: action)
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.semibold)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

}

private struct MoreScreen: View {
    @ObservedObject var model: MenuBarPanelModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            BackRow(title: "More") {
                withAnimation(.easeOut(duration: 0.15)) { model.screen = .main }
            }
            Tile {
                VStack(spacing: 2) {
                    if model.stripModeEnabled || model.arranging {
                        SectionLabel("Canvas")
                    }
                    if model.stripModeEnabled {
                        SwitchRow(title: "Strip Mode", keys: "⌃⌥S", on: model.stripMode, enabled: model.canToggleStrip) {
                            model.stripMode.toggle()
                            model.actions.toggleStrip()
                        }
                    }
                    if model.arranging {
                        arrangeRow
                    }
                    SectionLabel("Sunlight")
                    Row(title: "Settings…", detail: "⌘,", enabled: true) { dismiss(); model.actions.showSettings() }
                    Row(title: setupTitle, detail: nil, enabled: true) { dismiss(); model.actions.setUp() }
                    Row(title: "Check for Updates…", detail: model.updateVersion, enabled: model.canCheckForUpdates) {
                        dismiss(); model.actions.checkForUpdates()
                    }
                    Row(title: "Reload Live Windows…", detail: nil, enabled: model.canReload) { dismiss(); model.actions.reloadLiveWindows() }
                    if model.takeoverRunning {
                        Row(title: "Release the Mac…", detail: nil, enabled: true) { dismiss(); model.actions.release() }
                    } else {
                        Row(title: "Take Over the Mac…", detail: nil, enabled: model.canTakeOver) { dismiss(); model.actions.takeOver() }
                    }
                    Divider().padding(.vertical, 4).padding(.horizontal, 6)
                    Row(title: "Quit Sunlight", detail: "⌘Q", enabled: true) { dismiss(); model.actions.quit() }
                }
            }
        }
    }

    private var setupTitle: String {
        if let p = model.setupProgress, p.done < p.total { return "Finish Setting Up Sunlight…" }
        return "Set Up Sunlight…"
    }

    private struct Arrangement: Identifiable {
        let columns: Int
        let rows: Int
        var title: String { rows == 1 ? "\(columns)" : "\(columns)×\(rows)" }
        var help: String { rows == 1 ? "\(columns) columns ⌃⌥\(columns)" : "\(columns)×\(rows)" }
        var id: String { title }
    }

    private static let arrangements = [Arrangement(columns: 2, rows: 1), Arrangement(columns: 3, rows: 1),
                                       Arrangement(columns: 4, rows: 1), Arrangement(columns: 2, rows: 2)]

    /// Arrange: the screen's windows in columns, as ⌃⌥2 3 4, or a 2×2 grid.
    private var arrangeRow: some View {
        HStack(spacing: 6) {
            Text("Arrange")
            Spacer(minLength: 6)
            ForEach(Self.arrangements) { a in
                Button(a.title) {
                    model.actions.arrange(a.columns, a.rows)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help(a.help)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .disabled(!model.canArrange)
        .opacity(model.canArrange ? 1 : 0.45)
    }
}

// MARK: - Pieces

/// A rounded block on the panel's glass, like Control Center's modules.
private struct Tile<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MenuBarPanelView.tileRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: MenuBarPanelView.tileRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            )
    }
}

/// A round icon, filled with the accent (or a tint) while on, as Control Center's.
private struct CircleGlyph: View {
    let symbol: String
    let on: Bool
    var tint: Color = .accentColor
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(on ? (tint == .yellow ? Color.black.opacity(0.75) : .white) : .primary)
            .frame(width: size, height: size)
            .background(Circle().fill(on ? tint : Color.primary.opacity(0.1)))
    }
}

/// Minimap, ⌘Tab, Desktop and Tidy: a round control, accent-filled while on, its name under it, as
/// Control Center's.
private struct SmallTile: View {
    let title: String
    let symbol: String
    let on: Bool
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                CircleGlyph(symbol: symbol, on: on, size: MenuBarPanelView.roundSize)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 10))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// A saved layout: a round button, its name under it. The ⌘ number shows on hover.
private struct LayoutButton: View {
    let layout: MenuBarPanelModel.Layout
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                CircleGlyph(symbol: "rectangle.3.group", on: false, size: MenuBarPanelView.roundSize)
                Text(layout.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 10))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(layout.key.map { "\(layout.name) \($0)" } ?? layout.name)
        .accessibilityLabel(layout.name)
    }
}

/// "More ›": a row that unfolds (`open` says which way the chevron points) or, with `open` nil,
/// leads on to another screen.
private struct HeaderRow: View {
    let title: String
    let detail: String?
    let open: Bool?
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open == true ? 90 : 0))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 9))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// "‹ More": back to the main screen.
private struct BackRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 9))
        .keyboardShortcut(.cancelAction)
    }
}

/// A plain row: a name, and a key or a note at the right.
private struct Row: View {
    let title: String
    let detail: String?
    let enabled: Bool
    var accent = false
    /// Set like a header, for a row that sits among the header rows.
    var bold = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .fontWeight(accent || bold ? .semibold : .regular)
                    .foregroundStyle(accent ? Color.accentColor : .primary)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(radius: 8))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A row with a small switch at the right.
private struct SwitchRow: View {
    let title: String
    let keys: String?
    let on: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let keys { Text(keys).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Toggle(title, isOn: Binding(get: { on }, set: { _ in action() }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { action() } }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .padding(.horizontal, 6)
    }
}

/// Lights up under the pointer and while pressed, as Control Center's rows do.
private struct HoverButtonStyle: ButtonStyle {
    let radius: CGFloat
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
            )
            .onHover { hovering = $0 }
    }
}
