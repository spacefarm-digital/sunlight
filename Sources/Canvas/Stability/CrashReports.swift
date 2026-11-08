import Foundation

/// The crash reports macOS writes for Sunlight and for the Dock (where the live-windows add-on runs),
/// copied into ~/Library/Logs/Sunlight/Crashes at launch before macOS retires them, and summed up for
/// Diagnose: when, which version, the exception, and the top of the crashed thread. No window titles:
/// the summary leaves out the report's application-specific text, the one part that could carry one.
enum CrashReports {
    nonisolated static var reportFolders: [URL] {
        let reports = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }
    nonisolated static var keptFolder: URL { Log.folder.appendingPathComponent("Crashes", isDirectory: true) }
    nonisolated static let keptPerApp = 20
    /// The processes whose reports are kept: the app, the guard (also "Sunlight"), and the Dock.
    nonisolated static let apps = ["Sunlight", "Dock"]

    struct Summary: Equatable, Sendable {
        var app: String
        var time: String
        var version: String?
        var os: String?
        var exception: String?
        var termination: String?
        /// "libdispatch.dylib _dispatch_assert_queue_fail", top first.
        var frames: [String]
        /// A Dock report whose images include Sunlight's add-on.
        var addOnLoaded = false
    }

    /// "Sunlight-2026-11-01-175226.ips" → "Sunlight"; nil for any other app's or kind of file.
    nonisolated static func app(ofReport name: String) -> String? {
        guard name.hasSuffix(".ips") else { return nil }
        return apps.first { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") }
    }

    /// Copies reports not kept yet, and keeps the newest `keptPerApp` of each app. Off the main thread.
    nonisolated static func collect(from folders: [URL] = reportFolders, into kept: URL = keptFolder) {
        let fm = FileManager.default
        try? fm.createDirectory(at: kept, withIntermediateDirectories: true)
        // Only each app's newest `keptPerApp`: an older one would be copied in, pruned straight away, and
        // copied again at every launch.
        var found: [String: URL] = [:]
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where app(ofReport: name) != nil {
                found[name] = folder.appendingPathComponent(name)
            }
        }
        var copied = 0
        for appName in apps {
            for name in found.keys.filter({ app(ofReport: $0) == appName }).sorted(by: >).prefix(keptPerApp) {
                let target = kept.appendingPathComponent(name)
                guard !fm.fileExists(atPath: target.path), let source = found[name] else { continue }
                if (try? fm.copyItem(at: source, to: target)) != nil { copied += 1 }
            }
        }
        guard let all = try? fm.contentsOfDirectory(atPath: kept.path) else { return }
        for appName in apps {
            let mine = all.filter { app(ofReport: $0) == appName }.sorted(by: >)
            for old in mine.dropFirst(keptPerApp) { try? fm.removeItem(at: kept.appendingPathComponent(old)) }
        }
        if copied > 0 { Log.note("Stability: kept \(copied) new crash report\(copied == 1 ? "" : "s") in \(SetupDiagnose.redactingHome(kept.path))") }
    }

    /// The kept reports of `appName`, newest first, summed up.
    nonisolated static func recent(_ appName: String, limit: Int, in kept: URL = keptFolder) -> [Summary] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: kept.path)) ?? [])
            .filter { app(ofReport: $0) == appName }.sorted(by: >)
        return names.prefix(limit).compactMap { name in
            (try? String(contentsOf: kept.appendingPathComponent(name), encoding: .utf8)).flatMap { summary(of: $0) }
        }
    }

    /// An .ips file: a line of JSON about the app, then the report as one JSON object.
    nonisolated static func summary(of text: String) -> Summary? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = json(String(text[..<newline])) else { return nil }
        let body = json(String(text[text.index(after: newline)...])) ?? [:]
        let app = header["app_name"] as? String ?? header["name"] as? String ?? "?"
        var version: String?
        if let short = header["app_version"] as? String, !short.isEmpty {
            version = (header["build_version"] as? String).map { "\(short) (\($0))" } ?? short
        }
        var exception: String?
        if let e = body["exception"] as? [String: Any] {
            exception = [e["type"] as? String, e["signal"] as? String, e["subtype"] as? String].compactMap { $0 }.joined(separator: " ")
        }
        var termination: String?
        if let t = body["termination"] as? [String: Any] {
            termination = t["indicator"] as? String ?? (t["namespace"] as? String).map { "\($0) \(t["code"] ?? "")" }
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        func imageName(_ index: Int?) -> String {
            guard let index, index >= 0, index < images.count else { return "?" }
            if let name = images[index]["name"] as? String { return name }
            return (images[index]["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "?"
        }
        var frames: [String] = []
        if let threads = body["threads"] as? [[String: Any]] {
            let faulting = body["faultingThread"] as? Int
            let thread = faulting.flatMap { $0 >= 0 && $0 < threads.count ? threads[$0] : nil }
                ?? threads.first { $0["triggered"] as? Bool == true }
            for frame in ((thread?["frames"] as? [[String: Any]]) ?? []).prefix(8) {
                let image = imageName(frame["imageIndex"] as? Int)
                let symbol = frame["symbol"] as? String ?? (frame["imageOffset"] as? Int).map { "+0x" + String($0, radix: 16) } ?? "?"
                frames.append("\(image) \(symbol)")
            }
        }
        let addOn = images.contains { image in
            ["name", "path"].contains { ((image[$0] as? String) ?? "").localizedCaseInsensitiveContains("sunlight") }
        }
        return Summary(app: app, time: header["timestamp"] as? String ?? "?", version: version, os: header["os_version"] as? String,
                       exception: exception, termination: termination, frames: frames, addOnLoaded: app == "Dock" && addOn)
    }

    /// The Diagnose lines for some summaries.
    nonisolated static func reportLines(_ summaries: [Summary]) -> [String] {
        summaries.flatMap { s -> [String] in
            var head = "\(s.app), \(s.time)"
            if let version = s.version { head += ", \(version)" }
            if s.app == "Dock" { head += s.addOnLoaded ? ", Sunlight's add-on loaded" : ", no Sunlight add-on" }
            let what = [s.exception, s.termination].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
            if !what.isEmpty { head += ": \(what)" }
            return [head] + s.frames.map { "    \($0)" }
        }
    }

    nonisolated private static func json(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
