import Darwin
import Foundation
import os

/// Sunlight's log. Every line goes where `NSLog` sent it (the unified log, and stderr under `make run`)
/// and to a file the person can open: ~/Library/Logs/Sunlight/Sunlight.log, about 2 MB, with the one
/// before it kept as Sunlight.1.log. In the unified log every line reads `<private>` without sudo, and
/// a copy opened from Finder has its stderr on /dev/null, so until the file there was no readable log
/// on anyone's Mac.
///
/// The file names apps and windows, as the log lines always have, so it stays on the Mac: Diagnose
/// says where it is rather than carrying it.
///
/// The message is passed to `NSLog` as an argument, never as its format: a window title with a % in it
/// ("100% done", "%s") read as a format would make `NSLog` read arguments that aren't there, and crash.
///
/// Each line is written to the file before `note` returns (one `write` on a descriptor opened with
/// O_APPEND), so the lines before a crash are on disk when it comes. Any thread.
enum Log {
    nonisolated static let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Sunlight", isDirectory: true)
    nonisolated static var fileURL: URL { folder.appendingPathComponent("Sunlight.log") }
    nonisolated static var previousURL: URL { folder.appendingPathComponent("Sunlight.1.log") }
    nonisolated static let maxBytes = 2_000_000

    /// Not from the unit tests, which would fill the real log with their made-up windows.
    nonisolated static let writesFile = NSClassFromString("XCTestCase") == nil
        && ProcessInfo.processInfo.environment["SUNLIGHT_NO_LOG_FILE"] == nil

    private struct File: Sendable {
        var fd: Int32 = -1
        var size = 0
        /// When opening the file last failed: tried again a minute later, not at every line.
        var failedAt: TimeInterval?
    }
    nonisolated static let retryAfter: TimeInterval = 60
    private static let file = OSAllocatedUnfairLock(initialState: File())

    nonisolated static func note(_ message: String) {
        NSLog("%@", message as NSString)
        guard writesFile else { return }
        append(line(message, at: Date(), pid: getpid()))
    }

    /// "2026-11-07 19:50:01.123 [4521] Rendering: …", newline included.
    nonisolated static func line(_ message: String, at date: Date, pid: pid_t) -> String {
        "\(stamp(date)) [\(pid)] \(message)\n"
    }

    /// Whether a file of `size` bytes takes `adding` more before it is rotated.
    nonisolated static func needsRotation(size: Int, adding: Int, limit: Int = maxBytes) -> Bool {
        size > 0 && size + adding > limit
    }

    private nonisolated static func append(_ text: String) {
        let data = Data(text.utf8)
        let now = Date().timeIntervalSinceReferenceDate
        file.withLock { f in
            if let failedAt = f.failedAt, now - failedAt < retryAfter { return }
            if f.fd < 0 {
                openFile(&f)
                guard f.fd >= 0 else { f.failedAt = now; return }
                f.failedAt = nil
            }
            if needsRotation(size: f.size, adding: data.count) {
                Darwin.close(f.fd)
                f.fd = -1
                Darwin.rename(fileURL.path, previousURL.path)
                openFile(&f)
                guard f.fd >= 0 else { f.failedAt = now; return }
            }
            let written = data.withUnsafeBytes { Darwin.write(f.fd, $0.baseAddress, $0.count) }
            if written > 0 { f.size += written }
        }
    }

    private nonisolated static func openFile(_ f: inout File) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard f.fd >= 0 else { return }
        var info = stat()
        f.size = fstat(f.fd, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Local time to the millisecond, the same whatever the Mac's clock format.
    nonisolated static func stamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        let ms = Int((date.timeIntervalSince1970 - Double(seconds)) * 1000)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
                      Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec), min(max(ms, 0), 999))
    }

    /// The last `count` lines of the log file, for a look from the command line or a test of the writer.
    nonisolated static func tail(_ count: Int, of url: URL = fileURL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }
}
