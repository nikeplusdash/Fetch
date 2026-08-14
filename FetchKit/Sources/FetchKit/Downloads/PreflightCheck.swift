import Foundation

public enum PreflightCheck {
    public static func availableCapacity(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Fail fast rather than filling the volume mid-transfer.
    public static func assertSpace(needed: Int64, at url: URL) throws {
        let available = (try? availableCapacity(at: url)) ?? 0
        guard available >= needed else {
            throw DownloadError.diskFull(needed: needed, available: available)
        }
    }
}
