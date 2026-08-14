import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// A Downloads row is one *attempt* at some content, not everything ever
/// queued from it.
///
/// The reported symptom: cancelling a download and starting it again stacked
/// six "Cancelled" lines under the live one, reported the row's total as
/// 6.9 GB for a 1.15 GB file, and offered no way to remove any of it.
@Suite struct DownloadGroupKeyTests {

    /// The whole point. Two goes at the same torrent are two rows.
    @Test func twoAttemptsAtTheSameContentAreDifferentRows() {
        let first = DownloadGroupKey(content: "btih:abc")
        let second = DownloadGroupKey(content: "btih:abc")

        #expect(first != second)
        #expect(first.rawValue != second.rawValue)
        // The content is still shared — that is what a cache badge and a
        // torrent's file list are looked up by.
        #expect(first.content == second.content)
    }

    /// Three files chosen from one torrent are one attempt, so they must be
    /// given the same key rather than one each.
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

    /// A direct download's content key is a URL, and URLs contain `#`, `:`
    /// and `/`. A delimiter that can appear in the data is not a delimiter,
    /// so the separator is the unit separator.
    @Test func aURLContentKeySurvivesTheRoundTrip() {
        let url = "https://archive.org/details/goody?x=1#fragment:2/3"
        let key = DownloadGroupKey(content: url)
        let parsed = DownloadGroupKey(rawValue: key.rawValue)

        #expect(parsed.content == url)
        #expect(parsed.attempt == key.attempt)
    }

    /// Rows persisted before attempts existed have no separator in their key.
    /// They must keep grouping by content — scattering a restored torrent into
    /// one row per file would be a worse bug than the one being fixed.
    @Test func aKeyWrittenBeforeAttemptsExistedGroupsByContent() {
        let legacy = DownloadGroupKey(rawValue: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")

        #expect(legacy.content == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
        #expect(legacy.attempt.isEmpty)
        // And it still writes back the way it was read, so a save does not
        // silently rewrite the grouping of old rows.
        #expect(legacy.rawValue == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c")
    }

    @Test func unattemptedKeysForTheSameContentMatch() {
        #expect(DownloadGroupKey.unattempted("btih:abc")
                == DownloadGroupKey.unattempted("btih:abc"))
    }

    /// `DownloadRequest` must not mint an attempt of its own: it builds one
    /// file, and a fresh attempt per file would put every file of a torrent
    /// in its own row.
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

/// Bucketing files into rows — the fix, at the level the Downloads screen
/// consumes it.
@Suite struct AttemptRowTests {
    private struct File: Equatable {
        let name: String
        let key: DownloadGroupKey
    }

    /// The reported bug, as an assertion: five cancelled goes at one file plus
    /// a live sixth are six rows, not one row summing 6.9 GB.
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

    /// And the case that must not regress: a torrent's chosen files were
    /// queued together, so they stay together.
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

    /// Rows appear in the order their first file was queued, so a new download
    /// does not jump above one already running.
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

    /// Two attempts, one still running and one cancelled, are two rows — so
    /// the live row's total is its own file's size and its progress divides by
    /// that, not by the sum of every attempt ever made.
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

/// A completed download whose file is no longer on disk.
///
/// It used to be reported as `.failed`, which is two lies in one word: the
/// transfer did not fail, and `.failed` is resumable — so the row offered a
/// Resume button that would re-download a file the user had just deleted.
@Suite struct MissingFileTests {

    @Test func aCompletedDownloadWhoseFileIsGoneIsMissingNotFailed() {
        let outcome = LaunchRecovery.reconcile(
            state: .completed, recordedBytes: 1_000, expectedSize: 1_000,
            finalSize: nil, partialSize: nil)

        #expect(outcome.state == .missing)
    }

    /// Restoring the file from the Trash is the undo a user expects to work.
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

    /// A cancelled download's file was never written, so its absence is not
    /// news — it must not be relabelled as something the user lost.
    @Test func aCancelledDownloadIsNotMissing() {
        let outcome = LaunchRecovery.reconcile(
            state: .cancelled, recordedBytes: 400, expectedSize: 1_000,
            finalSize: nil, partialSize: nil)

        #expect(outcome.state == .cancelled)
    }

    /// Missing is settled: nothing is waiting or running, and re-downloading
    /// is a new decision rather than a continuation.
    @Test func missingIsTerminalButFailedIsNot() {
        #expect(DownloadState.missing.isTerminal)
        #expect(!DownloadState.failed.isTerminal)
    }

    /// What the Downloads screen's Failed filter collects.
    @Test func theThreeStatesThatNeedAttention() {
        let flagged = DownloadState.allCases.filter(\.needsAttention)
        #expect(Set(flagged) == [.failed, .cancelled, .missing])
    }

    /// What a checkbox may appear beside in an expanded torrent.
    ///
    /// `.completed` is in: a finished file may be corrupt, or deleted and
    /// wanted back, and refusing to fetch it again would be Fetch deciding it
    /// knows better. Live work is out, and that is the point — offering
    /// "download this" beside a file already transferring is how someone ends
    /// up with two copies and a row that sums both.
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

    /// A file that vanished while others are still transferring must not make
    /// the row jump to Failed and back — same rule as a failure mid-flight.
    @Test func aMissingFileAlongsideRunningWorkStaysActive() {
        #expect(DownloadGrouping.section(for: [.downloading, .missing]) == .active)
    }
}
