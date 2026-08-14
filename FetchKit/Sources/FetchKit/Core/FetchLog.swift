import Foundation

/// The app's own log, on disk, safe to send to someone else.
///
/// Written here rather than to `os_log` because the point is a file the user
/// can find, read and attach. The unified log is the better tool for a
/// developer at a console and the wrong one for "something went wrong, send me
/// your log".
///
/// Everything that goes in passes through `LogRedaction` at the call site —
/// this type does not sanitise for you, because a redaction applied centrally
/// is one that has to guess what each field means. The caller knows whether a
/// string is a filename or a status word.
public actor FetchLog {
    public static let shared = FetchLog()

    /// One file, truncated from the front when it grows past this. A log that
    /// grows without bound is one that eventually fills a disk, and a log that
    /// is deleted on rotation loses the very session someone is asking about.
    static let maximumBytes = 2 * 1024 * 1024

    public enum Level: String, Sendable {
        case info = "INFO", warn = "WARN", error = "ERROR"
    }

    private let url: URL
    private var handle: FileHandle?
    private lazy var stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(directory: URL? = nil) {
        let logs = directory ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Fetch", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        self.url = logs.appendingPathComponent("fetch.log")
    }

    /// Where to send someone who asks "where is the log".
    public nonisolated var fileURL: URL { url }

    public func write(_ level: Level, _ subsystem: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) \(level.rawValue) [\(subsystem)] "
            + LogRedaction.scrub(message) + "\n"
        append(Data(line.utf8))
    }

    private func append(_ data: Data) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
        rotateIfNeeded()
    }

    /// Keeps the newest half. Truncating from the front rather than deleting
    /// keeps whatever just went wrong, which is the part being asked about.
    private func rotateIfNeeded() {
        guard let size = FileSize.of(url), size > Self.maximumBytes else { return }
        try? handle?.close()
        handle = nil
        guard let existing = try? Data(contentsOf: url) else { return }
        let kept = existing.suffix(Self.maximumBytes / 2)
        try? Data(kept).write(to: url)
    }

    /// Everything written so far, for a "copy my log" button.
    public func contents() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Convenience so a call site reads as one line rather than three.
public func fetchLog(
    _ level: FetchLog.Level = .info, _ subsystem: String, _ message: @autoclosure () -> String
) {
    let text = message()
    Task { await FetchLog.shared.write(level, subsystem, text) }
}
