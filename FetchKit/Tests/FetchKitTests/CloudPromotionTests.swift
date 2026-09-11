import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

@Suite struct CloudPromotionTests {

    private func torrent(
        state: DebridTorrentState, files: [DebridFile], present: Bool = false
    ) -> DebridTorrent {
        DebridTorrent(
            id: DebridTorrentID(rawValue: "t1"), infoHashHex: "abc", name: "Some Torrent",
            size: 100, progress: 1, state: state, files: files,
            seeds: nil, downloadSpeed: nil, eta: nil, filesArePresent: present)
    }

    private func file(_ id: String) -> DebridFile {
        DebridFile(id: DebridFileID(rawValue: id), name: "\(id).mkv",
                   shortName: "\(id).mkv", size: 10, mimeType: nil)
    }

    @Test func aReadyTorrentPromotesToItsFiles() {
        let answer = torrent(state: .completed, files: [file("a"), file("b")])
        #expect(CloudPromotion.outcome(for: answer) == .promote([file("a"), file("b")]))
    }

    /**
     TorBox calls a finished torrent "uploading" the moment it seeds, so
     readiness cannot be keyed on the word alone.
     */
    @Test func aSeedingTorrentWithFilesPresentAlsoPromotes() {
        let answer = torrent(state: .downloading, files: [file("a")], present: true)
        #expect(CloudPromotion.outcome(for: answer) == .promote([file("a")]))
    }

    @Test func aTorrentStillBeingFetchedKeepsWaiting() {
        let answer = torrent(state: .downloading, files: [])
        #expect(CloudPromotion.outcome(for: answer) == .keepWaiting)
    }

    /**
     A service that says ready while listing nothing has no rows to write,
     so promoting it would delete the placeholder and put nothing back.
     */
    @Test func aReadyTorrentWithNoFilesKeepsWaiting() {
        let answer = torrent(state: .completed, files: [])
        #expect(CloudPromotion.outcome(for: answer) == .keepWaiting)
    }

    /**
     The property that makes running this on a timer safe.
     */
    @Test func noAnswerAtAllKeepsWaitingAndNeverClears() {
        #expect(CloudPromotion.outcome(for: nil) == .keepWaiting)
    }

    /**
     A poll is a network call long, which is long enough for the user to
     remove the row it is about.
     */
    @Test func aRowThatWentAwayMidPollGetsNoAnswer() {
        let answer = torrent(state: .completed, files: [file("a")])
        #expect(CloudPromotion.outcome(for: answer, placeholderStillPresent: false) == .keepWaiting)
    }

    @Test func aFailedTorrentIsDiagnosedInTheRowsWords() {
        #expect(CloudPromotion.diagnosis(for: torrent(state: .failed(reason: "dead"), files: []))
                == "Nobody is seeding this torrent, so your service could not fetch it.")
        #expect(CloudPromotion.diagnosis(for: torrent(state: .failed(reason: "virus"), files: []))
                == "Your debrid service found a virus in this torrent.")
    }

    @Test func aTorrentThatIsFineHasNoDiagnosisAndNorDoesNoAnswer() {
        #expect(CloudPromotion.diagnosis(for: torrent(state: .downloading, files: [])) == nil)
        #expect(CloudPromotion.diagnosis(for: nil) == nil)
    }

    /**
     Somebody else's string, capped so an unbounded provider message
     cannot outrun the microcopy rule.
     */
    @Test func anUnknownReasonIsCappedAtAHundredCharacters() {
        let long = String(repeating: "x", count: 250)
        let text = CloudPromotion.diagnosis(for: torrent(state: .failed(reason: long), files: []))
        #expect(text?.hasSuffix("…") == true)
        #expect((text?.count ?? 0) < 160)
    }

    @Test func onlyQueuedRowsArePolledAndEachIdOnlyOnce() {
        let a = DebridTorrentID(rawValue: "a")
        let b = DebridTorrentID(rawValue: "b")
        let rows: [(torrentID: DebridTorrentID, state: DownloadState)] = [
            (a, .cloudQueued), (a, .cloudQueued), (b, .onCloud), (a, .onCloud),
        ]
        #expect(CloudPromotion.torrentsToPoll(rows: rows) == [a])
    }

    /**
     A placeholder id must never collide with a real file id.
     */
    @Test func thePlaceholderIdIsNotSomethingAServiceWouldMint() {
        #expect(CloudPromotion.isPlaceholder(CloudPromotion.placeholderFileID))
        #expect(!CloudPromotion.isPlaceholder(DebridFileID(rawValue: "0")))
        #expect(CloudPromotion.placeholderFileID.rawValue.contains("\u{1F}"))
    }

    @Test func thePlaceholderFileIsNamedAndSizedFromTheTorrent() {
        let placeholder = CloudPromotion.placeholderFile(name: "Some Torrent", size: 4096)
        #expect(placeholder.name == "Some Torrent")
        #expect(placeholder.size == 4096)
        #expect(CloudPromotion.isPlaceholder(placeholder.id))
    }
}
