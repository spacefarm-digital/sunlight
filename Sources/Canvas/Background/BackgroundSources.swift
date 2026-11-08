import AppKit
import PhotosUI
import UniformTypeIdentifiers

/// Where pictures come from: the Mac's wallpaper, and pictures copied into Application Support so a file
/// moved or deleted later never leaves the canvas blank. Nothing here needs the main thread, so the
/// pipeline can resolve a file name on its queue.
enum BackgroundSources {
    /// ~/Library/Application Support/Sunlight/Backgrounds/, beside the layouts.
    nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sunlight/Backgrounds", isDirectory: true)
    }()

    nonisolated static func imageURL(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// The imported pictures, newest first.
    nonisolated static var importedImages: [String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let dated = urls.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.map { $0.0.lastPathComponent }
    }

    /// Copies a picture in and returns its name. The copy keeps the original's extension and gets a fresh
    /// name, so two pictures with the same file name never collide.
    nonisolated static func importImage(from url: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: imageURL(name))
        return name
    }

    nonisolated static func removeImage(_ name: String) {
        try? FileManager.default.removeItem(at: imageURL(name))
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// The main display's wallpaper, and when its file last changed, so a swap in System Settings is
    /// noticed. Nil when it's a folder of pictures or something that can't be read.
    @MainActor
    static func macWallpaper() -> (URL?, Date?) {
        guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return (nil, nil) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return (nil, nil) }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (url, date)
    }

    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @MainActor static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    /// An open panel for a picture file. `completion` gets the imported name, or nil.
    @MainActor
    static func chooseFile(from window: NSWindow?, completion: @escaping @MainActor (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the canvas background."
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return completion(nil) }
            completion(try? importImage(from: url))
        }
        if let window {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(panel.runModal())
        }
    }
}

/// The Photos picker, as a sheet on the settings window. Needs no photo library permission: the picker
/// runs out of process and hands over a file for the one picture chosen.
@MainActor
final class PhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private var completion: (@MainActor (String?) -> Void)?
    private weak var presenter: NSViewController?

    func present(from presenter: NSViewController, completion: @escaping @MainActor (String?) -> Void) {
        self.completion = completion
        self.presenter = presenter
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter.presentAsSheet(picker)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(picker, results) }
        }
    }

    private func finish(_ picker: PHPickerViewController, _ results: [PHPickerResult]) {
        presenter?.dismiss(picker)
        guard let provider = results.first?.itemProvider else {
            completion?(nil)
            completion = nil
            return
        }
        let completion = self.completion
        self.completion = nil
        // The file exists only for the length of the callback, so the copy happens inside it.
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
            let name = url.flatMap { try? BackgroundSources.importImage(from: $0) }
            if name == nil { Log.note("Background: Photos picker gave no file (\(error?.localizedDescription ?? "no error"))") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion?(name) }
            }
        }
    }
}
