import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

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


    @Test func anUnknownTotalHasNoFraction() {
        #expect(item(downloaded: 0, total: 0).fraction == nil)
        #expect(item(downloaded: 500, total: 0).fraction == nil)
    }

    @Test func fractionIsTransferredOverTotal() throws {
        #expect(try #require(item(downloaded: 50, total: 100).fraction) == 0.5)
        #expect(try #require(item(downloaded: 0, total: 100).fraction) == 0.0)
        #expect(try #require(item(downloaded: 100, total: 100).fraction) == 1.0)
    }

    @Test func aNegativeTotalHasNoFraction() {
        #expect(item(downloaded: 10, total: -1).fraction == nil)
    }

    @Test func transferringMoreThanTheTotalDoesNotTrap() throws {
        #expect(try #require(item(downloaded: 150, total: 100).fraction) == 1.5)
    }


    @Test func aStalledTransferHasNoETA() {
        #expect(item(downloaded: 10, total: 100, rate: 0).etaText == nil)
    }

    @Test func aFinishedTransferHasNoETA() {
        #expect(item(downloaded: 100, total: 100, rate: 1000).etaText == nil)
    }

    @Test func aRunningTransferHasAnETA() {
        #expect(item(downloaded: 0, total: 1_000_000, rate: 1000).etaText != nil)
    }


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
