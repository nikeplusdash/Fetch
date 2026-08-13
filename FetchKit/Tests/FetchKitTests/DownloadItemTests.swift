import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// `DownloadItem` lived in the app target, which has no test bundle, so none
/// of this arithmetic had ever been exercised — including the divide-by-zero
/// guard that decides whether the Downloads row draws a determinate bar.
@Suite struct DownloadItemTests {
    private func item(
        downloaded: Int64 = 0, total: Int64 = 0, rate: Double = 0
    ) -> DownloadItem {
        DownloadItem(
            id: DownloadID(),
            displayName: "movie.mkv",
            bytesDownloaded: downloaded,
            totalBytes: total,
            bytesPerSecond: rate,
            state: .downloading,
            pinnedUnit: .useGB)
    }

    // MARK: - fraction

    /// The guard that matters. An unknown total is `nil`, **not** 0% — a
    /// determinate bar at zero claims the size is known and nothing has
    /// arrived, which is a different and wrong statement.
    @Test func anUnknownTotalHasNoFraction() {
        #expect(item(downloaded: 0, total: 0).fraction == nil)
        #expect(item(downloaded: 500, total: 0).fraction == nil)
    }

    @Test func fractionIsTransferredOverTotal() throws {
        #expect(try #require(item(downloaded: 50, total: 100).fraction) == 0.5)
        #expect(try #require(item(downloaded: 0, total: 100).fraction) == 0.0)
        #expect(try #require(item(downloaded: 100, total: 100).fraction) == 1.0)
    }

    /// A negative total is nonsense the guard also has to absorb, since
    /// `totalBytes` is a plain Int64 fed from provider payloads.
    @Test func aNegativeTotalHasNoFraction() {
        #expect(item(downloaded: 10, total: -1).fraction == nil)
    }

    /// Over-delivery happens: a provider can report more bytes than it
    /// promised. It must not trap, and the caller clamps for display.
    @Test func transferringMoreThanTheTotalDoesNotTrap() throws {
        #expect(try #require(item(downloaded: 150, total: 100).fraction) == 1.5)
    }

    // MARK: - etaText

    /// A stalled transfer has no meaningful estimate. Reporting one would
    /// count down against a rate that is not happening.
    @Test func aStalledTransferHasNoETA() {
        #expect(item(downloaded: 10, total: 100, rate: 0).etaText == nil)
    }

    @Test func aFinishedTransferHasNoETA() {
        #expect(item(downloaded: 100, total: 100, rate: 1000).etaText == nil)
    }

    @Test func aRunningTransferHasAnETA() {
        #expect(item(downloaded: 0, total: 1_000_000, rate: 1000).etaText != nil)
    }

    // MARK: - Identity

    /// Rows are matched by id when events arrive, so two items that differ
    /// only in progress must stay the same row.
    @Test func identityIsTheDownloadIDAlone() {
        let id = DownloadID()
        var a = item(downloaded: 0, total: 100)
        var b = item(downloaded: 99, total: 100)
        a = DownloadItem(
            id: id, displayName: "a", bytesDownloaded: 0, totalBytes: 100,
            state: .downloading, pinnedUnit: .useGB)
        b = DownloadItem(
            id: id, displayName: "b", bytesDownloaded: 99, totalBytes: 100,
            state: .completed, pinnedUnit: .useGB)
        #expect(a.id == b.id)
    }
}
