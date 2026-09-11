import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct DownloadGroupKeyTests {

    @Test func twoAttemptsAtTheSameContentAreDifferentRows() {
        let first = DownloadGroupKey(content: "btih:abc")
        let second = DownloadGroupKey(content: "btih:abc")

        #expect(first != second)
        #expect(first.rawValue != second.rawValue)
        #expect(first.content == second.content)
    }

    @Test func oneKeyReusedAcrossABatchKeepsItsFilesInOneRow() {
        let group = DownloadGroupKey(content: "btih:abc")
        let keys = (0..<3).map { _ in group.rawValue }

        #expect(Set(keys).count == 1)
    }

    @Test func theRawValueRoundTrips() {
        let key = DownloadGroupKey(content: "btih:abc")
        let parsed = DownloadGroupKey(rawValue: key.rawValue)

        #expect(parsed == key)
        #expect(parsed.content == "btih:abc")
    }

    @Test func aURLContentKeySurvivesTheRoundTrip() {
        let url = "https://archive.org/details/goody?x=1#fragment:2/3"
        let key = DownloadGroupKey(content: url)
        let parsed = DownloadGroupKey(rawValue: key.rawValue)

        #expect(parsed.content == url)
        #expect(parsed.attempt == key.attempt)
    }

    @Test func aKeyWrittenBeforeAttemptsExistedGroupsByContent() {
        let legacy = DownloadGroupKey(rawValue: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")

        #expect(legacy.content == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(legacy.attempt.isEmpty)
        #expect(legacy.rawValue == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
    }

    @Test func unattemptedKeysForTheSameContentMatch() {
        #expect(DownloadGroupKey.unattempted("btih:abc")
                == DownloadGroupKey.unattempted("btih:abc"))
    }

    @Test func aRequestWithNoKeyGivenGroupsByContentAlone() {
        let request = makeRequest(infoHash: "abc", groupKey: nil)
        #expect(request.groupKey == .unattempted("abc"))
    }

    @Test func aRequestKeepsTheKeyItWasGiven() {
        let group = DownloadGroupKey(content: "abc")
        #expect(makeRequest(infoHash: "abc", groupKey: group).groupKey == group)
    }

    private func makeRequest(infoHash: String, groupKey: DownloadGroupKey?) -> DownloadRequest {
        DownloadRequest(
            providerID: DebridProviderID(rawValue: "fake"),
            torrentID: DebridTorrentID(rawValue: "1"),
            file: DebridFile(
                id: DebridFileID(rawValue: "0"), name: "a.mkv",
                shortName: "a.mkv", size: 10, mimeType: nil),
            infoHashHex: infoHash,
            subfolder: nil,
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            groupKey: groupKey)
    }
}

@Suite struct AttemptRowTests {
    private struct File: Equatable {
        let name: String
        let key: DownloadGroupKey
    }

    @Test func repeatedAttemptsDoNotPileIntoOneRow() {
        let content = "btih:abc"
        let attempts = (0..<6).map { index in
            File(name: "Fresh.Off.The.Boat.S02E01.mkv#\(index)",
                 key: DownloadGroupKey(content: content))
        }

        let rows = DownloadGrouping.rows(attempts) { $0.key }

        #expect(rows.count == 6)
        #expect(rows.allSatisfy { $0.members.count == 1 })
    }

    @Test func oneAttemptsFilesShareARow() {
        let key = DownloadGroupKey(content: "btih:abc")
        let files = [File(name: "E01.mkv", key: key),
                     File(name: "E02.mkv", key: key),
                     File(name: "E03.mkv", key: key)]

        let rows = DownloadGrouping.rows(files) { $0.key }

        #expect(rows.count == 1)
        #expect(rows[0].members.map(\.name) == ["E01.mkv", "E02.mkv", "E03.mkv"])
        #expect(rows[0].key == key)
    }

    @Test func rowsKeepTheOrderTheirFirstFileArrivedIn() {
        let first = DownloadGroupKey(content: "one")
        let second = DownloadGroupKey(content: "two")
        let files = [File(name: "a", key: first),
                     File(name: "b", key: second),
                     File(name: "c", key: first)]

        let rows = DownloadGrouping.rows(files) { $0.key }

        #expect(rows.map(\.key) == [first, second])
        #expect(rows[0].members.map(\.name) == ["a", "c"])
    }

    @Test func nothingQueuedIsNoRows() {
        #expect(DownloadGrouping.rows([File]()) { $0.key }.isEmpty)
    }

    @Test func aCancelledAttemptCannotInflateALiveOne() {
        let dead = DownloadGroupKey(content: "btih:abc")
        let live = DownloadGroupKey(content: "btih:abc")
        let sizes: [DownloadGroupKey: Int64] = [dead: 1_150_000_000, live: 1_150_000_000]

        let rows = DownloadGrouping.rows(
            [File(name: "x", key: dead), File(name: "x", key: live)]) { $0.key }

        #expect(rows.count == 2)
        let liveRow = try? #require(rows.first { $0.key == live })
        #expect(liveRow?.members.count == 1)
        #expect(sizes[live] == 1_150_000_000)
    }
}

@Suite struct MissingFileTests {

    @Test func aCompletedDownloadWhoseFileIsGoneIsMissingNotFailed() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 1_000, expectedSize: 1_000,
            finalSize: nil, partialSize: nil)

        #expect(outcome.state == .missing)
    }

    @Test func aMissingFileThatComesBackIsCompletedAgain() {
        let outcome = LaunchRecovery.reconcile(
            state: .missing, recordedBytes: 1_000, expectedSize: 1_000,
            finalSize: 1_000, partialSize: nil)

        #expect(outcome.state == .completed)
    }

    @Test func aCompletedDownloadStillOnDiskStaysCompleted() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 1_000, expectedSize: 1_000,
            finalSize: 1_000, partialSize: nil)

        #expect(outcome.state == .completed)
        #expect(outcome.bytesDownloaded == 1_000)
    }

    @Test func aCancelledDownloadIsNotMissing() {
        let outcome = LaunchRecovery.reconcile(
            state: .cancelled, recordedBytes: 400, expectedSize: 1_000,
            finalSize: nil, partialSize: nil)

        #expect(outcome.state == .cancelled)
    }

    @Test func missingIsTerminalButFailedIsNot() {
        #expect(DownloadState.missing.isTerminal)
        #expect(!DownloadState.failed.isTerminal)
    }

    @Test func theThreeStatesThatNeedAttention() {
        let flagged = DownloadState.allCases.filter(\.needsAttention)
        #expect(Set(flagged) == [.failed, .cancelled, .missing])
    }

    @Test func onlySettledFilesCanBeRequeued() {
        let allowed = DownloadState.allCases.filter(\.canBeRequeued)
        #expect(Set(allowed) == [.failed, .cancelled, .missing, .completed])
    }

    @Test func liveWorkIsNeverOfferedForRequeueing() {
        for state in [DownloadState.queued, .preparing, .downloading, .paused] {
            #expect(!state.canBeRequeued, "\(state) should not be requeueable")
        }
    }

    @Test func aMissingFileSendsItsRowToTheFailedSection() {
        #expect(DownloadGrouping.section(for: [.missing]) == .failed)
        #expect(DownloadGrouping.section(for: [.completed, .missing]) == .failed)
    }

    @Test func aMissingFileAlongsideRunningWorkStaysActive() {
        #expect(DownloadGrouping.section(for: [.downloading, .missing]) == .active)
    }
}
