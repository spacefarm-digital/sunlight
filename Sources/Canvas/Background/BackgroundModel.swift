import AppKit
import Combine

/// The background as the user sets it: holds the spec, saves it, tells the canvas to show it, and keeps
/// undo. The settings pane and the right-click menu both go through here. Pictures for the settings'
/// tiles are made on the renderer's pipeline queue and published as they arrive.
@MainActor
final class BackgroundModel: ObservableObject {
    @Published private(set) var spec: BackgroundSpec
    @Published private(set) var lightColor: NSColor
    @Published private(set) var darkColor: NSColor
    @Published private(set) var appearance: Settings.Appearance
    /// Small pictures for the Source row, by key: `BackgroundModel.wallpaperKey`, an imported picture's
    /// name, or a gradient's id.
    @Published private(set) var tiles: [String: NSImage] = [:]
    @Published private(set) var importedImages: [String] = []

    let renderer: BackgroundRenderer
    /// The canvas window's, so ⌘Z on the canvas undoes a background change.
    weak var undoManager: UndoManager?
    /// The spec (or a colour) changed: show it, cross-faded unless the colour panel is being tracked.
    var onChanged: ((_ animated: Bool) -> Void)?
    /// Settings › Background, for "Customise…".
    var onCustomise: (() -> Void)?
    private let photoPicker = PhotoPicker()
    lazy var menuBuilder = BackgroundMenu(model: self)

    static let wallpaperKey = "mac-wallpaper"
    static let appearances = Settings.Appearance.allCases
    static let tileSize = BackgroundRenderer.thumbnailSize

    init(renderer: BackgroundRenderer) {
        self.renderer = renderer
        spec = Settings.backgroundSpec
        lightColor = Settings.lightBackground
        darkColor = Settings.darkBackground
        appearance = Settings.appearance
        importedImages = BackgroundSources.importedImages
        // Written down once, so the default needn't be worked out again on every read.
        Settings.backgroundSpec = spec
        renderer.onThumbnailsChanged = { [weak self] in self?.objectWillChange.send() }
    }

    /// The styled previews for the Style row, nil until the picture is in.
    var styleThumbnails: [BackgroundSpec.Style: CGImage]? { renderer.styleThumbnails }
    /// The picture's own tint, for the tint well's "From the picture" state.
    var dominantTint: NSColor? { renderer.dominantTint }

    // MARK: Changing it

    /// Shows and saves `new`. `undoable` registers the step with ⌘Z (not for tracking a colour panel, or
    /// restoring a layout).
    func set(_ new: BackgroundSpec, animated: Bool = true, undoable: Bool = true) {
        guard new != spec else { return }
        let old = spec
        if undoable, let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.set(old, animated: true, undoable: true) }
            }
            undoManager.setActionName("Change Background")
        }
        spec = new
        Settings.backgroundSpec = new
        onChanged?(animated)
    }

    func update(animated: Bool = true, undoable: Bool = true, _ change: (inout BackgroundSpec) -> Void) {
        var new = spec
        change(&new)
        set(new, animated: animated, undoable: undoable)
    }

    func useMacWallpaper() { update { $0.source = .macWallpaper } }
    func useColor() { update { $0.source = .color } }
    func useGradient(_ id: String) { update { $0.source = .gradient(id) } }
    func useImage(_ name: String) { update { $0.source = .image(light: name, dark: nil) } }
    func setStyle(_ style: BackgroundSpec.Style) { update { $0.style = style } }
    func setBlur(_ blur: BackgroundSpec.Blur) { update { $0.blur = blur } }

    /// A picture dropped on the canvas or chosen from a file: copied in and shown.
    func useImportedPicture(at url: URL) {
        guard BackgroundSources.isImageFile(url) else { return }
        do {
            let name = try BackgroundSources.importImage(from: url)
            importedImages = BackgroundSources.importedImages
            useImage(name)
            loadTiles()
        } catch {
            Log.note("Background: couldn't copy \(url.lastPathComponent) in: \(error.localizedDescription)")
        }
    }

    /// The Photos picker, as a sheet on `presenter`'s window. `forDark` makes the pick the dark variant of
    /// the current picture instead of a new background.
    func choosePhoto(from presenter: NSViewController, forDark: Bool = false) {
        photoPicker.present(from: presenter) { [weak self] name in
            guard let self, let name else { return }
            self.imported(name, forDark: forDark)
        }
    }

    /// The open panel, as a sheet on `window` when there is one.
    func chooseFile(from window: NSWindow?, forDark: Bool = false) {
        BackgroundSources.chooseFile(from: window) { [weak self] name in
            guard let self, let name else { return }
            self.imported(name, forDark: forDark)
        }
    }

    private func imported(_ name: String, forDark: Bool) {
        importedImages = BackgroundSources.importedImages
        if forDark, case .image(let light, _) = spec.source {
            update { $0.source = .image(light: light, dark: name) }
        } else {
            useImage(name)
        }
        loadTiles()
    }

    /// Back to one picture for both appearances (dimmed for dark).
    func useSamePictureForDark() {
        guard case .image(let light, let dark) = spec.source, let dark else { return }
        update { $0.source = .image(light: light, dark: nil) }
        if !importedImages.contains(dark) { return }
        // The dark picture stays in the list; it can be picked again or removed there.
    }

    func removeImported(_ name: String) {
        BackgroundSources.removeImage(name)
        importedImages = BackgroundSources.importedImages
        tiles[name] = nil
        if case .image(let light, let dark) = spec.source {
            if light == name {
                update { $0.source = .color }
            } else if dark == name {
                update { $0.source = .image(light: light, dark: nil) }
            }
        }
    }

    // MARK: Colours and appearance

    /// Tracks the colour panel live: no cross-fade, no undo step per tick.
    func setLightColor(_ color: NSColor) {
        lightColor = color
        Settings.lightBackground = color
        onChanged?(false)
    }

    func setDarkColor(_ color: NSColor) {
        darkColor = color
        Settings.darkBackground = color
        onChanged?(false)
    }

    func resetColors() {
        Settings.resetBackgrounds()
        lightColor = Settings.lightBackground
        darkColor = Settings.darkBackground
        onChanged?(true)
    }

    func setAppearance(_ new: Settings.Appearance) {
        guard new != appearance else { return }
        appearance = new
        Settings.appearance = new
        onChanged?(true)
    }

    // MARK: Tiles for the settings

    /// Makes the small pictures the Source row shows, the ones that aren't made yet.
    func loadTiles() {
        let size = BackgroundModel.tileSize
        let pipeline = renderer.pipeline
        var jobs: [(key: String, make: @Sendable () -> CGImage?)] = []
        let dark = renderer.isDark
        if tiles[BackgroundModel.wallpaperKey] == nil, let url = BackgroundSources.macWallpaper().0 {
            jobs.append((BackgroundModel.wallpaperKey, {
                pipeline.decode(url, frame: pipeline.dynamicDesktopFrame(url, dark: dark), pixelSize: size)
            }))
        }
        for name in importedImages where tiles[name] == nil {
            let url = BackgroundSources.imageURL(name)
            jobs.append((name, { pipeline.decode(url, pixelSize: size) }))
        }
        for g in Gradients.all where tiles[g.id] == nil {
            let id = g.id
            jobs.append((id, { Gradients.render(id: id, dark: dark, pixelSize: size) }))
        }
        guard !jobs.isEmpty else { return }
        pipeline.queue.async {
            for job in jobs {
                guard let image = job.make() else { continue }
                let nsImage = NSImage(cgImage: image, size: NSSize(width: size.width / 2, height: size.height / 2))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.tiles[job.key] = nsImage }
                }
            }
        }
    }

    /// The appearance flipped: the wallpaper and gradient tiles are for the other one now.
    func appearanceFlipped() {
        tiles[BackgroundModel.wallpaperKey] = nil
        for g in Gradients.all { tiles[g.id] = nil }
        loadTiles()
    }
}
