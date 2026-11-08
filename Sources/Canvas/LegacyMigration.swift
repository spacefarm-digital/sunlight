import AppKit

/// Sunlight was called Canvas, with the bundle ID com.spacefarm.canvas-spike. The first Sunlight launch
/// copies that defaults domain and ~/Library/Application Support/Canvas across, so settings, the
/// remembered canvas, saved layouts and any takeover snapshot carry over. The old copies stay where they are, so an old Canvas.app still finds them.
enum LegacyMigration {
    static let legacyBundleID = "com.spacefarm.canvas-spike"
    private static let doneKey = "migratedFromCanvas"

    static func run() {
        let defaults = UserDefaults.standard
        copyIfMissing(from: "Canvas Backgrounds", to: "Sunlight/Backgrounds")   // pictures from a build before the rename
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != legacyBundleID,
              !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: legacyBundleID), !old.isEmpty {
            // Anything Sunlight already wrote wins over the old value.
            let current = defaults.persistentDomain(forName: bundleID) ?? [:]
            defaults.setPersistentDomain(old.merging(current) { _, new in new }, forName: bundleID)
            Log.note("Migration: copied \(old.count) settings from \(legacyBundleID)")
        }
        copySupportFolder()
        defaults.set(true, forKey: doneKey)
        defaults.synchronize()
    }

    private static func copySupportFolder() {
        copyIfMissing(from: "Canvas", to: "Sunlight")
    }

    /// Copies one Application Support folder to another name, once: only while the new one doesn't exist.
    private static func copyIfMissing(from oldName: String, to newName: String) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(oldName, isDirectory: true)
        let new = support.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: old, to: new)
            Log.note("Migration: copied \(old.path) to \(new.path)")
        } catch {
            Log.note("Migration: couldn't copy \(old.path) — \(error.localizedDescription)")
        }
    }
}
