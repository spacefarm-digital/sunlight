import SwiftUI

/// Settings › Background: the Wallpaper pane's shape, trimmed to what belongs behind windows. Every
/// control changes the canvas at once; the settings window floats at the screen's edge so the canvas
/// itself is the preview. A grouped form, so the rows, headers and corners are the system's, headed and
/// labelled like the other panes (`SectionHeader`, `RowLabel`).
struct BackgroundSettingsView: View {
    @ObservedObject var model: BackgroundModel
    /// The view controller this sits in, for the Photos sheet.
    let presenter: () -> NSViewController?
    @State private var customising = false

    private static let accent = Color(red: 0.95, green: 0.75, blue: 0.2)

    var body: some View {
        Form {
            Section {
                sourceRow
                if model.spec.isPlainColor { colourRow }
                VStack(alignment: .leading, spacing: 6) {
                    RowLabel(title: "Appearance",
                             subtitle: "Match the Mac follows System Settings.")
                    TileRow {
                        ForEach(BackgroundModel.appearances, id: \.self) { appearance in
                            PictureTile(title: appearance.title, selected: model.appearance == appearance) {
                                model.setAppearance(appearance)
                            } picture: {
                                AppearancePicture(appearance: appearance)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            } header: {
                SectionHeader(title: "Source")
            }
            if !model.spec.isPlainColor {
                Section {
                    styleRow
                    if model.spec.style.usesTint { tintRows }
                } header: {
                    SectionHeader(title: "Style")
                }
                if model.spec.source.isPicture {
                    Section {
                        Picker("Blur", selection: binding(\.blur)) {
                            ForEach(BackgroundSpec.Blur.allCases, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.segmented)
                        Toggle(isOn: binding(\.focusFollowsZoom)) {
                            RowLabel(title: "Blur and dim follow the zoom",
                                     subtitle: "Blurs and dims as you zoom out.")
                        }
                        LabeledContent(model.spec.focusFollowsZoom ? "Dim when zoomed out" : "Dim") {
                            Slider(value: Binding(get: { model.spec.dim },
                                                  set: { v in model.update(animated: false, undoable: false) { $0.dim = v } }),
                                   in: 0...0.4)
                                .frame(maxWidth: 220)
                        }
                        Toggle(isOn: binding(\.depth)) {
                            RowLabel(title: "Subtle depth", subtitle: "The picture drifts as you pan.")
                        }
                    } header: {
                        SectionHeader(title: "Focus")
                    }
                }
                Section {
                    DisclosureGroup("Customise", isExpanded: $customising) {
                        Picker("Grain", selection: binding(\.grain)) {
                            ForEach(BackgroundSpec.Grain.allCases, id: \.self) { Text($0.title) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Vignette", isOn: binding(\.vignette))
                        if model.spec.source.isGradient {
                            Toggle(isOn: binding(\.living)) {
                                RowLabel(title: "Living gradient",
                                         subtitle: "Drifts slowly. Rests in Low Power Mode.")
                            }
                        }
                        if case .image(_, let dark) = model.spec.source {
                            LabeledContent {
                                if dark == nil {
                                    Button("Choose a Picture…") { model.chooseFile(from: presenter()?.view.window, forDark: true) }
                                } else {
                                    Button("Use the Same Picture") { model.useSamePictureForDark() }
                                }
                            } label: {
                                RowLabel(title: "Dark appearance",
                                         subtitle: dark == nil ? "Dims the same picture in Dark Mode."
                                                               : "Its own picture in Dark Mode.")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear { model.loadTiles() }
    }

    // MARK: Source

    /// Every background as a tile, wrapping onto more rows as pictures are added, so none sits cut off at
    /// the edge: the Mac's wallpaper, a plain colour, the gradients, your pictures, then one tile to add a picture.
    private var sourceRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 10)], spacing: 10) {
            tile(image: model.tiles[BackgroundModel.wallpaperKey], title: "Mac Wallpaper",
                 selected: model.spec.source == .macWallpaper) { model.useMacWallpaper() }
            colourTile
            ForEach(Gradients.all) { (g: CanvasGradient) in
                tile(image: model.tiles[g.id], title: g.name, selected: model.spec.source == .gradient(g.id)) { model.useGradient(g.id) }
            }
            ForEach(model.importedImages, id: \.self) { name in
                tile(image: model.tiles[name], title: "", selected: isCurrentImage(name)) { model.useImage(name) }
                    .contextMenu {
                        Button("Use for Dark Appearance") { useForDark(name) }
                            .disabled(!model.spec.source.isImage || isCurrentImage(name))
                        Divider()
                        Button("Remove", role: .destructive) { model.removeImported(name) }
                    }
            }
            addTile
        }
        .padding(.vertical, 4)
    }

    private func isCurrentImage(_ name: String) -> Bool {
        if case .image(let light, _) = model.spec.source { return light == name }
        return false
    }

    private func useForDark(_ name: String) {
        guard case .image(let light, _) = model.spec.source else { return }
        model.update { $0.source = .image(light: light, dark: name) }
    }

    private var colourTile: some View {
        let dark = model.renderer.isDark
        let color = Color(nsColor: dark ? model.darkColor : model.lightColor)
        return tileFrame(selected: model.spec.isPlainColor) {
            RoundedRectangle(cornerRadius: 8).fill(color)
        } title: {
            // Dark on a light colour, light on a dark one: readable whatever the colour.
            Text("Colour").foregroundStyle((dark ? model.darkColor : model.lightColor).isLight ? Color.black : Color.white)
        }
        .onTapGesture { model.useColor() }
        .contextMenu { Button("Reset Colours") { model.resetColors() } }
    }

    /// One row: the colour for a light Mac and the colour for a dark one.
    private var colourRow: some View {
        LabeledContent {
            HStack(spacing: 12) {
                ColorPicker("Light", selection: Binding(get: { Color(nsColor: model.lightColor) },
                                                        set: { model.setLightColor(NSColor($0)) }), supportsOpacity: false)
                ColorPicker("Dark", selection: Binding(get: { Color(nsColor: model.darkColor) },
                                                       set: { model.setDarkColor(NSColor($0)) }), supportsOpacity: false)
            }
        } label: {
            RowLabel(title: "Colour", subtitle: "One for light, one for dark.")
        }
    }

    /// A picture from Photos or from a file, added to the tiles.
    private var addTile: some View {
        Menu {
            Button("From Photos…") { if let vc = presenter() { model.choosePhoto(from: vc) } }
            Button("From a File…") { model.chooseFile(from: presenter()?.view.window) }
        } label: {
            tileFrame(selected: false) {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.secondary))
            } title: {
                Text("Add Picture").foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Add Picture")
    }

    private func tile(image: NSImage?, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        tileFrame(selected: selected) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
        } title: {
            if !title.isEmpty {
                Text(title).foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            }
        }
        .onTapGesture(perform: action)
    }

    private func tileFrame<Fill: View, Title: View>(selected: Bool, @ViewBuilder fill: () -> Fill,
                                                    @ViewBuilder title: () -> Title) -> some View {
        ZStack(alignment: .bottomLeading) {
            fill()
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            title()
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? BackgroundSettingsView.accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Style

    private var styleRow: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(BackgroundSpec.Style.allCases, id: \.self) { style in
                VStack(spacing: 4) {
                    Group {
                        if let cg = model.styleThumbnails?[style] {
                            Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
                        }
                    }
                    .frame(width: 84, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(model.spec.style == style ? BackgroundSettingsView.accent : Color.clear, lineWidth: 2))
                    Text(style.title)
                        .font(.caption)
                        .fontWeight(model.spec.style == style ? .semibold : .regular)
                        .foregroundStyle(model.spec.style == style ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(width: 84)
                .contentShape(Rectangle())
                .onTapGesture { model.setStyle(style) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// One row: the picture's own tint, or a colour of your own beside the menu.
    private var tintRows: some View {
        LabeledContent("Tint") {
            HStack(spacing: 8) {
                if model.spec.tint != nil {
                    ColorPicker("Tint", selection: Binding(get: { Color(nsColor: model.spec.tint?.nsColor ?? .gray) },
                                                           set: { c in model.update(animated: false, undoable: false) { $0.tint = BackgroundSpec.Tint(NSColor(c)) } }),
                                supportsOpacity: false)
                        .labelsHidden()
                }
                Picker("Tint", selection: Binding(get: { model.spec.tint == nil },
                                                  set: { auto in
                    model.update { $0.tint = auto ? nil : BackgroundSpec.Tint(model.dominantTint ?? .systemYellow) }
                })) {
                    Text("From the Picture").tag(true)
                    Text("Custom").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: Helpers

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<BackgroundSpec, T>) -> Binding<T> {
        Binding(get: { model.spec[keyPath: keyPath] }, set: { v in model.update { $0[keyPath: keyPath] = v } })
    }
}

/// The pane in an AppKit window, so the settings window needn't know SwiftUI.
@MainActor
func makeBackgroundSettingsController(model: BackgroundModel) -> NSViewController {
    var presenter: (() -> NSViewController?) = { nil }
    let hosting = NSHostingController(rootView: BackgroundSettingsView(model: model, presenter: { presenter() }))
    presenter = { [weak hosting] in hosting }
    hosting.preferredContentSize = NSSize(width: 560, height: 640)
    return hosting
}
