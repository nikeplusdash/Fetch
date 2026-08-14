import Foundation

/// Centralized formatting so downloads, file pickers, and search results agree.
public enum ByteCount {
    private static func makeFormatter(allowedUnits: ByteCountFormatter.Units = .useAll) -> ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        f.allowedUnits = allowedUnits
        return f
    }

    public static func format(_ bytes: Int64) -> String {
        makeFormatter().string(fromByteCount: bytes)
    }

    /// The single unit a download's transferred/total figures should be
    /// pinned to for the life of that download, chosen once from its total
    /// size. `format(_:)` alone recomputes the "best" unit for whatever
    /// value it's handed, so a byte count hovering near a boundary (say,
    /// 998 KB while the total is ~1 MB) oscillates between "998 KB" and
    /// "1.1 MB" tick to tick — a string-length change that visibly shoves
    /// the row's layout on every progress update. Deriving the unit from
    /// the (fixed) total instead and reusing it for every intermediate
    /// value keeps the string's shape stable throughout the transfer.
    public static func pinnedUnit(for totalBytes: Int64) -> ByteCountFormatter.Units {
        for (threshold, unit) in unitThresholds where totalBytes >= threshold {
            return unit
        }
        return .useBytes
    }

    /// Binary-count-style thresholds (1024-based), largest first, matching
    /// what `ByteCountFormatter(countStyle: .binary)` itself would choose
    /// for a value of that magnitude.
    private static let unitThresholds: [(threshold: Int64, unit: ByteCountFormatter.Units)] = [
        (1 << 40, .useTB),
        (1 << 30, .useGB),
        (1 << 20, .useMB),
        (1 << 10, .useKB),
    ]

    /// `format(_:)` restricted to a single unit — see `pinnedUnit(for:)`.
    public static func format(_ bytes: Int64, pinnedTo unit: ByteCountFormatter.Units) -> String {
        makeFormatter(allowedUnits: unit).string(fromByteCount: bytes)
    }

    public static func rate(_ bytesPerSecond: Int64) -> String {
        "\(format(bytesPerSecond))/s"
    }

    /// Nil when the rate is non-positive — an ETA of infinity is not useful
    /// to show, and callers should render a placeholder instead.
    public static func eta(remaining: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0, remaining > 0 else { return nil }
        let seconds = Double(remaining) / bytesPerSecond
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: seconds)
    }
}
