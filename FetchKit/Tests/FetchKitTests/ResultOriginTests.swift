import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Stage 7a of the sources amendment: a result reachable more than one way.
///
/// The v1 model made `SearchResult.id` *be* an `InfoHash`, so anything without
/// one was dropped in the Torznab parser before it could render. These types
/// replace that with an ordered candidate list where a torrent is one case
/// rather than the case.
@Suite struct ResultOriginTests {
    private func magnet(_ hex: String) -> MagnetLink {
        MagnetLink("magnet:?xt=urn:btih:\(hex)")!
    }
    private let hex = String(repeating: "ab", count: 20)

    // MARK: - ResultID

    /// A torrent's identity is still its infohash, unchanged — dedup across
    /// indexers depends on two trackers listing the same torrent collapsing to
    /// one row, and that has to keep working exactly as it does today.
    @Test func aTorrentIsIdentifiedByItsInfoHash() {
        let id = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil))
        #expect(id.rawValue == "btih:\(hex)")
    }

    /// Two indexers listing the same torrent still collapse to one result.
    @Test func theSameTorrentFromTwoIndexersSharesAnID() {
        let lower = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil))
        let upper = ResultID(origin: .torrent(
            infoHash: InfoHash(hex.uppercased())!,
            magnet: magnet(hex.uppercased()), targetPath: nil))
        #expect(lower == upper)
    }

    /// Two files inside one collection torrent are different results — this is
    /// the AACID case (§6.1), where a 300 GB container holds thousands of
    /// separately-wanted books.
    @Test func twoTargetPathsInOneTorrentAreDifferentResults() {
        let a = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: "a.epub"))
        let b = ResultID(origin: .torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: "b.epub"))
        #expect(a != b)
    }

    @Test func aDirectURLIsIdentifiedByItsURL() {
        let id = ResultID(origin: .direct(url: URL(string: "https://archive.org/x/y.epub")!))
        #expect(id.rawValue.hasPrefix("url:"))
    }

    /// URLs that differ only in case of scheme/host, or in a trailing slash,
    /// are the same file. Without normalisation the same Gutenberg book listed
    /// twice would render as two rows.
    @Test func urlIdentityIsNormalised() {
        let a = ResultID(origin: .direct(url: URL(string: "https://Archive.ORG/x/y.epub")!))
        let b = ResultID(origin: .direct(url: URL(string: "https://archive.org/x/y.epub")!))
        #expect(a == b)
    }

    /// Different files must not collide. Stated because the ID is a hash and a
    /// collision here would silently merge two unrelated downloads.
    @Test func differentURLsGetDifferentIDs() {
        let a = ResultID(origin: .direct(url: URL(string: "https://archive.org/a.epub")!))
        let b = ResultID(origin: .direct(url: URL(string: "https://archive.org/b.epub")!))
        #expect(a != b)
    }

    /// A hosted link and a direct link to the same URL are the same file — the
    /// difference is only how Fetch reaches it.
    @Test func hostedAndDirectShareIdentityForTheSameURL() {
        let url = URL(string: "https://mediafire.com/file/x")!
        #expect(ResultID(origin: .direct(url: url))
                == ResultID(origin: .hosted(url: url, host: HostID(rawValue: "mediafire"))))
    }

    // MARK: - Candidate ordering

    /// §4's resolution order. `.direct` deliberately outranks `.hosted`:
    /// unrestricting costs debrid quota and a round trip for a file Fetch can
    /// simply GET.
    @Test func directOutranksHosted() {
        let direct = ResultOrigin.direct(url: URL(string: "https://archive.org/a")!)
        let hosted = ResultOrigin.hosted(
            url: URL(string: "https://mediafire.com/a")!, host: HostID(rawValue: "mediafire"))
        #expect(direct.preferenceRank < hosted.preferenceRank)
    }

    /// A torrent ranks below both here, because at *parse* time Fetch does not
    /// yet know whether it is cached. §4's "cached torrent wins" is decided
    /// later, once the cache check has answered.
    @Test func anUncheckedTorrentRanksBelowDirect() {
        let direct = ResultOrigin.direct(url: URL(string: "https://archive.org/a")!)
        let torrent = ResultOrigin.torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil)
        #expect(direct.preferenceRank < torrent.preferenceRank)
    }

    // MARK: - Scheme safety (amendment §8)

    /// Origins come from untrusted search sources. A `file:` URL would make a
    /// search result able to name a path on the user's own disk.
    @Test func aNonHTTPSchemeIsRefused() {
        #expect(ResultOrigin.direct(url: URL(string: "file:///etc/passwd")!).isUsable == false)
        #expect(ResultOrigin.direct(url: URL(string: "ftp://example.com/x")!).isUsable == false)
    }

    @Test func httpsIsUsable() {
        #expect(ResultOrigin.direct(url: URL(string: "https://archive.org/x")!).isUsable)
    }

    /// Plain http stays usable because §13 allows it for LAN indexers, and a
    /// user's own Jackett at 10.0.0.181 is the reason that rule exists.
    @Test func plainHTTPIsUsable() {
        #expect(ResultOrigin.direct(url: URL(string: "http://10.0.0.181/x")!).isUsable)
    }
}

/// `DownloadSource` — what a queued download actually points at.
///
/// §6's rule that **no CDN URL is ever persisted** still holds for the two
/// debrid cases: they store identifiers and re-resolve. `.directHTTP` persists
/// its URL because there the URL *is* the identity — it is not a credentialed,
/// expiring link.
@Suite struct DownloadSourceTests {
    @Test func debridSourcesDoNotCarryAURL() throws {
        let source = DownloadSource.debridTorrent(
            provider: DebridProviderID(rawValue: "torbox"),
            torrent: DebridTorrentID(rawValue: "1"),
            file: DebridFileID(rawValue: "2"))

        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!encoded.contains("http"))
    }

    /// The one case where persisting a URL is correct, asserted so a later
    /// change cannot quietly make it round-trip to nothing.
    @Test func aDirectSourceRoundTripsItsURL() throws {
        let url = URL(string: "https://archive.org/download/x/y.epub")!
        let source = DownloadSource.directHTTP(url: url)
        let decoded = try JSONDecoder().decode(
            DownloadSource.self, from: try JSONEncoder().encode(source))
        #expect(decoded == source)
    }

    /// `.directHTTP` skips `preparing` — there is nothing to submit and
    /// nothing to poll. This is the whole speed argument for direct sources.
    @Test func onlyDebridSourcesNeedPreparing() {
        #expect(DownloadSource.directHTTP(
            url: URL(string: "https://archive.org/x")!).needsPreparing == false)
        #expect(DownloadSource.debridTorrent(
            provider: DebridProviderID(rawValue: "t"),
            torrent: DebridTorrentID(rawValue: "1"),
            file: DebridFileID(rawValue: "2")).needsPreparing)
        #expect(DownloadSource.debridHosted(
            provider: DebridProviderID(rawValue: "t"),
            download: DebridDownloadID(rawValue: "1")).needsPreparing)
    }
}

/// `SearchResult` becomes source-polymorphic (amendment §3).
///
/// The constraint that shapes these: **the torrent path must not change.**
/// Everything that works today — dedup across indexers, cache badges, the file
/// picker — is keyed on an infohash, and stage 7a is the only stage that can
/// regress it.
@Suite struct PolymorphicSearchResultTests {
    private let hex = String(repeating: "cd", count: 20)

    private func torrentResult(hex: String, title: String = "T") -> SearchResult {
        SearchResult(
            infoHashHex: hex, title: title, size: 1, seeders: 1, peers: 0,
            grabs: nil, fileCount: nil, category: nil, publishDate: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hex)", sources: [], rawAttributes: [:])
    }

    /// The existing torrent initialiser still produces a torrent candidate, so
    /// every provider and test that builds results today keeps working.
    @Test func theTorrentInitialiserProducesATorrentCandidate() {
        let result = torrentResult(hex: hex)
        #expect(result.candidates.count == 1)
        #expect(result.infoHashHex == hex)
        #expect(result.magnetURI?.contains(hex) == true)
    }

    /// Identity for a torrent is unchanged, so dedup across indexers keeps
    /// collapsing the same torrent into one row.
    @Test func aTorrentResultKeepsItsInfoHashIdentity() {
        #expect(torrentResult(hex: hex).id.rawValue == "btih:\(hex)")
    }

    /// A direct result has no infohash and must not pretend to. Returning ""
    /// would key the cache-state dictionary on an empty string and badge every
    /// direct result with whatever the last one resolved to.
    @Test func aDirectResultHasNoInfoHash() {
        let result = SearchResult(
            candidates: [.direct(url: URL(string: "https://archive.org/x.epub")!)],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.infoHashHex == nil)
        #expect(result.magnetURI == nil)
        #expect(result.id.rawValue.hasPrefix("url:"))
    }

    /// The amended drop rule (§3): dropped only when there are no candidates,
    /// not for want of an infohash.
    @Test func aResultWithNoUsableCandidateIsNotUsable() {
        let result = SearchResult(
            candidates: [.direct(url: URL(string: "file:///etc/passwd")!)],
            title: "Nope", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])
        #expect(!result.isUsable)
    }

    @Test func aResultWithOneUsableCandidateIsUsable() {
        #expect(torrentResult(hex: hex).isUsable)
    }

    /// Candidates are held best-first so the availability badge and the
    /// download both read the same order rather than each picking their own.
    @Test func candidatesAreOrderedBestFirst() {
        let result = SearchResult(
            candidates: [
                .hosted(url: URL(string: "https://mediafire.com/a")!,
                        host: HostID(rawValue: "mediafire")),
                .direct(url: URL(string: "https://archive.org/a")!),
            ],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.candidates.first?.preferenceRank == 0)
    }

    /// A multi-candidate result that includes a torrent takes the torrent's
    /// identity, even though `.direct` sorts first. Otherwise the same torrent
    /// found once with a mirror and once without would be two rows — the exact
    /// duplication dedup exists to prevent.
    @Test func aTorrentCandidateDefinesIdentityEvenWhenNotRankedFirst() {
        let result = SearchResult(
            candidates: [
                .direct(url: URL(string: "https://archive.org/a")!),
                .torrent(infoHash: InfoHash(hex)!,
                         magnet: MagnetLink("magnet:?xt=urn:btih:\(hex)")!,
                         targetPath: nil),
            ],
            title: "Book", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [], rawAttributes: [:])

        #expect(result.id.rawValue == "btih:\(hex)")
        #expect(result.infoHashHex == hex)
    }

    /// Two results that are both unreachable stay two results.
    ///
    /// Found by a fixture passing a short hash: every candidate-less result
    /// took one shared identity and deduped into a single row, so a parser
    /// producing ten broken results would look like it produced one.
    @Test func twoUnreachableResultsDoNotCollapseIntoOne() {
        func broken(_ title: String) -> SearchResult {
            SearchResult(
                candidates: [], title: title, size: nil, seeders: nil, peers: nil,
                category: nil, publishDate: nil, sources: [], rawAttributes: [:])
        }
        #expect(broken("A").id != broken("B").id)
    }
}

/// Stage 7d §3.3–3.4. Format preference moves out of the provider and into
/// the ranking, which means a candidate has to know what format it is, and a
/// result's identity has to stop depending on which candidate sorts first.
@Suite struct CandidateFormatAndIdentityTests {
    private func magnet(_ hex: String) -> MagnetLink {
        MagnetLink("magnet:?xt=urn:btih:\(hex)")!
    }
    private let hex = String(repeating: "cd", count: 20)

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - A candidate carries its format

    /// `GutenbergProvider` knows each candidate's format and used to throw it
    /// away at `.map { .direct(url:) }`. The ranking reorders candidates
    /// *within* a result, so it has to be able to see this.
    @Test func aDirectCandidateCarriesItsDocumentFormat() {
        let candidate = ResultOrigin.direct(url: url("https://x/84.epub"), format: .epub)
        #expect(candidate.documentFormat == .epub)
    }

    /// A torrent has no document format — it is a container, not an edition.
    @Test func aTorrentCandidateHasNoDocumentFormat() {
        let candidate = ResultOrigin.torrent(
            infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil)
        #expect(candidate.documentFormat == nil)
    }

    // MARK: - Identity no longer moves with candidate order

    /// The known gap, stated. `ResultID` for a direct result was
    /// `url:<digest of candidates[0]>`, so reordering candidates by format
    /// preference changed the book's *identity* — the same book became a
    /// different row after a re-search.
    @Test func aSourceKeyedResultKeepsItsIDWhenCandidatesReorder() {
        let epubFirst = SearchResult(
            candidates: [
                .direct(url: url("https://x/84.epub"), format: .epub),
                .direct(url: url("https://x/84.pdf"), format: .pdf),
            ],
            title: "Frankenstein", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [SearchProviderID(rawValue: "gutenberg")],
            sourceKey: "gutenberg:84", rawAttributes: [:])

        let pdfFirst = SearchResult(
            candidates: [
                .direct(url: url("https://x/84.pdf"), format: .pdf),
                .direct(url: url("https://x/84.epub"), format: .epub),
            ],
            title: "Frankenstein", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [SearchProviderID(rawValue: "gutenberg")],
            sourceKey: "gutenberg:84", rawAttributes: [:])

        #expect(epubFirst.id == pdfFirst.id)
    }

    /// A source key must not collapse two genuinely different books.
    @Test func differentSourceKeysAreDifferentResults() {
        func book(_ key: String) -> SearchResult {
            SearchResult(
                candidates: [.direct(url: url("https://x/\(key).epub"), format: .epub)],
                title: "Book", size: nil, seeders: nil, peers: nil,
                category: nil, publishDate: nil, sources: [], sourceKey: key,
                rawAttributes: [:])
        }
        #expect(book("gutenberg:84").id != book("gutenberg:1342").id)
    }

    /// A torrent candidate still defines identity even when a source key is
    /// present. An Internet Archive item carries both, and it must keep
    /// collapsing against a Torznab listing of that same torrent — which is
    /// keyed on the infohash and knows nothing about IA's identifier.
    @Test func aTorrentCandidateStillOutranksASourceKeyForIdentity() {
        let item = SearchResult(
            candidates: [
                .direct(url: url("https://archive.org/download/goody/goody.mp4")),
                .torrent(infoHash: InfoHash(hex)!, magnet: magnet(hex), targetPath: nil),
            ],
            title: "Goody", size: nil, seeders: nil, peers: nil,
            category: nil, publishDate: nil, sources: [],
            sourceKey: "internet-archive:goody", rawAttributes: [:])

        #expect(item.id.rawValue == "btih:\(hex)")
    }

    /// Without a source key nothing changes: identity is still the first
    /// candidate's URL, so every existing non-torrent result keeps its ID.
    @Test func withoutASourceKeyIdentityIsUnchanged() {
        let withKey = SearchResult(
            candidates: [.direct(url: url("https://x/a.epub"), format: .epub)],
            title: "A", size: nil, seeders: nil, peers: nil, category: nil,
            publishDate: nil, sources: [], rawAttributes: [:])

        #expect(withKey.id == ResultID(origin: .direct(url: url("https://x/a.epub"))))
    }

    /// A format is not part of a candidate's identity. The same file reached
    /// by the same URL is the same file however it was labelled.
    @Test func formatDoesNotAffectAnOriginsIdentity() {
        let labelled = ResultID(origin: .direct(url: url("https://x/a.epub"), format: .epub))
        let bare = ResultID(origin: .direct(url: url("https://x/a.epub")))
        #expect(labelled == bare)
    }
}
