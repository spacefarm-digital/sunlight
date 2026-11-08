import AppKit

/// The first-launch offer to move Sunlight into the Applications folder. The background helper and the
/// login item register with launchd where the app bundle lives, so a copy run from the disk image, from
/// Downloads (where Gatekeeper runs a quarantined app translocated, from a random read-only path) or
/// anywhere else that gets moved or ejected stops working the next time it's opened, and leaves the
/// person turning things off and on in Login Items. `verdict` is the pure part, tested without a Mac;
/// `offerIfNeeded` asks once at launch, before anything else comes up, copies the bundle, opens the copy
/// and quits. A build run from a source checkout (`make run`) and the `--setup-preview` review never
/// see it, and Not Now is remembered for that copy.
enum MoveToApplications {
    /// Where this copy is and what it was started with, read once.
    struct Situation: Equatable, Sendable {
        var bundlePath: String
        var home: String
        /// A `.app`: not the bare binary `swift build` makes.
        var isAppBundle: Bool
        /// A folder above the bundle holds `Package.swift`: a developer's build, in a checkout.
        var insideSourceCheckout: Bool
        var arguments: [String]
        /// The bundle path the person chose Not Now for, if any.
        var declinedFor: String?
    }

    /// Where the copy is running from: what the offer says.
    enum Place: Equatable, Sendable {
        /// Under /Volumes: the disk image, or another disk that can be ejected.
        case volume
        case downloads
        /// Gatekeeper's app translocation.
        case translocated
        case elsewhere
    }

    enum Verdict: Equatable, Sendable {
        case offer(Place)
        /// Why not, for the log.
        case stay(String)
    }

    static func verdict(for situation: Situation) -> Verdict {
        if situation.arguments.contains("--setup-preview") { return .stay("review mode") }
        guard situation.isAppBundle else { return .stay("not an app bundle") }
        if isInApplications(situation.bundlePath, home: situation.home) { return .stay("already in Applications") }
        if situation.insideSourceCheckout { return .stay("a developer build") }
        if situation.declinedFor == situation.bundlePath { return .stay("declined for this copy") }
        return .offer(place(of: situation.bundlePath, home: situation.home))
    }

    static func isInApplications(_ path: String, home: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    static func place(of path: String, home: String) -> Place {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .volume }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        return .elsewhere
    }

    /// Whether a folder above `bundle` holds `Package.swift`: the app was built here by someone working
    /// on it, and belongs where it is.
    static func isInsideSourceCheckout(_ bundle: URL, fileManager: FileManager = .default) -> Bool {
        var folder = bundle.standardizedFileURL.deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    /// /Applications when it can be written to, else the user's own Applications folder.
    static func destinationFolder(home: String, systemFolderWritable: Bool) -> URL {
        systemFolderWritable ? URL(fileURLWithPath: "/Applications", isDirectory: true)
                             : URL(fileURLWithPath: home).appendingPathComponent("Applications", isDirectory: true)
    }

    // MARK: At launch

    private static let declinedKey = "MoveToApplicationsDeclinedFor"

    @MainActor
    static func currentSituation() -> Situation {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        return Situation(bundlePath: bundle.path, home: NSHomeDirectory(), isAppBundle: bundle.pathExtension == "app",
                         insideSourceCheckout: isInsideSourceCheckout(bundle), arguments: Array(CommandLine.arguments.dropFirst()),
                         declinedFor: UserDefaults.standard.string(forKey: declinedKey))
    }

    /// Before the canvas comes up. True when this copy is on its way out: the person chose to move it (or
    /// to open the copy already in Applications), that copy opens once this one has quit, and it's quitting.
    @MainActor
    static func offerIfNeeded() -> Bool {
        let situation = currentSituation()
        switch verdict(for: situation) {
        case .stay(let why):
            Log.note("Move: staying in \(situation.bundlePath) (\(why))")
            return false
        case .offer(let place):
            return offer(from: place, situation: situation)
        }
    }

    @MainActor
    private static func offer(from place: Place, situation: Situation) -> Bool {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: situation.bundlePath)
        let folder = destinationFolder(home: situation.home, systemFolderWritable: fm.isWritableFile(atPath: "/Applications"))
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        // Translocated, the bundle to leave behind is the one in Downloads, not the mount it runs from.
        let original = place == .translocated ? originalPath(ofTranslocated: source) : source
        let trashesDownloads = original.map { Self.place(of: $0.path, home: situation.home) == .downloads } ?? false
        let whereItIs: String = switch place {
        case .volume: "the disk image"
        case .downloads: "your Downloads folder"
        case .translocated: "where it was downloaded"
        case .elsewhere: "outside the Applications folder"
        }
        SetupJournal.note("Move: offering; running from \(whereItIs) (\(situation.bundlePath))")
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage

        if fm.fileExists(atPath: destination.path) {
            alert.messageText = "Sunlight is already in the Applications folder."
            alert.informativeText = "This copy is running from \(whereItIs). Open the installed one instead? Sunlight's background helper and login item follow the copy in \(folder.path)."
            alert.addButton(withTitle: "Open the Installed Copy")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return decline(situation) }
            SetupJournal.note("Move: opening the copy in \(folder.path) instead")
            return leave(for: destination)
        }

        alert.messageText = "Move Sunlight to the Applications folder?"
        alert.informativeText = "Sunlight is running from \(whereItIs). Its background helper and login item register where the app lives, so a copy here stops working once it's moved or ejected. Sunlight moves itself to \(folder.path) and opens again from there."
            + (trashesDownloads ? " The copy in Downloads goes to the Trash." : "")
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return decline(situation) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        } catch {
            SetupJournal.note("Move: couldn't copy to \(destination.path): \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Sunlight couldn't be moved."
            failed.informativeText = "\(error.localizedDescription)\n\nDrag Sunlight to the Applications folder yourself, then open it from there."
            failed.runModal()
            return false
        }
        // Quarantine would have Gatekeeper translocate the copy too; it has already been checked once.
        removeQuarantine(destination)
        if trashesDownloads, let original {
            do { try fm.trashItem(at: original, resultingItemURL: nil) } catch {
                Log.note("Move: couldn't put the Downloads copy in the Trash — \(error.localizedDescription)")
            }
        }
        SetupJournal.note("Move: copied to \(destination.path); opening it")
        return leave(for: destination)
    }

    @MainActor
    private static func decline(_ situation: Situation) -> Bool {
        UserDefaults.standard.set(situation.bundlePath, forKey: declinedKey)
        SetupJournal.note("Move: not now; staying in \(situation.bundlePath)")
        return false
    }

    /// Opens `bundle` once this process has quit, and quits.
    @MainActor
    private static func leave(for bundle: URL) -> Bool {
        guard AppRelaunch.open(bundle, afterQuitOf: ProcessInfo.processInfo.processIdentifier) else {
            Log.note("Move: couldn't arrange the relaunch; staying")
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    private static func removeQuarantine(_ bundle: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", bundle.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.note("Move: xattr — \(error.localizedDescription)")
        }
    }

    /// Where a translocated bundle was opened from: Security's SPI, looked up by name so a missing
    /// symbol only means the Downloads copy stays where it is.
    static func originalPath(ofTranslocated bundle: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return unsafeBitCast(symbol, to: Original.self)(bundle as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

/// Opens an app bundle once a process has quit: Screen Recording's relaunch, and the move to
/// Applications. While the same bundle identifier is still running, `open` would only bring it forward,
/// so a shell waits for the pid first.
enum AppRelaunch {
    @discardableResult
    static func open(_ bundle: URL, afterQuitOf pid: Int32) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path, "\(pid)"]
        do {
            try task.run()
        } catch {
            Log.note("Relaunch: couldn't start the shell — \(error.localizedDescription)")
            return false
        }
        return true
    }
}
