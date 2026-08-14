import Testing
import Foundation
@testable import FetchKit

/// Bencode, the format `.torrent` files are written in.
///
/// §16 put bencode parsing out of scope for v1. That is reversed deliberately:
/// it is the only way to list a torrent's files without either adding it to a
/// debrid account or joining the swarm, and joining the swarm is the one thing
/// a debrid client must never do — it would expose the user's IP to every peer
/// sharing the torrent.
///
/// This parses bytes off the internet, so every malformed case here matters as
/// much as the well-formed ones.
@Suite struct BencodeTests {
    private func parse(_ text: String) -> Bencode? {
        Bencode.parse(Data(text.utf8))
    }

    // MARK: - Scalars

    @Test func integersParse() {
        #expect(parse("i42e")?.integer == 42)
        #expect(parse("i0e")?.integer == 0)
        #expect(parse("i-13e")?.integer == -13)
    }

    @Test func stringsParse() {
        #expect(parse("4:spam")?.string == "spam")
        #expect(parse("0:")?.string == "")
    }

    /// A torrent's `pieces` field is raw SHA-1 digests, not text. Decoding
    /// strings as UTF-8 unconditionally would fail on every real torrent.
    @Test func binaryStringsSurviveIntact() {
        var data = Data("4:".utf8)
        data.append(contentsOf: [0x00, 0xFF, 0xFE, 0x80])
        let parsed = Bencode.parse(data)
        #expect(parsed?.bytes == Data([0x00, 0xFF, 0xFE, 0x80]))
        // Not valid UTF-8, so `string` must decline rather than mangle it.
        #expect(parsed?.string == nil)
    }

    // MARK: - Containers

    @Test func listsParse() {
        let list = parse("l4:spami42ee")?.list
        #expect(list?.count == 2)
        #expect(list?.first?.string == "spam")
        #expect(list?.last?.integer == 42)
    }

    @Test func dictionariesParse() {
        let dict = parse("d3:cow3:moo4:spam4:eggse")?.dictionary
        #expect(dict?["cow"]?.string == "moo")
        #expect(dict?["spam"]?.string == "eggs")
    }

    @Test func nestedStructuresParse() {
        let dict = parse("d4:infod4:name4:test6:lengthi1024eee")?.dictionary
        #expect(dict?["info"]?.dictionary?["name"]?.string == "test")
        #expect(dict?["info"]?.dictionary?["length"]?.integer == 1024)
    }

    @Test func anEmptyDictionaryParses() {
        #expect(parse("de")?.dictionary?.isEmpty == true)
    }

    // MARK: - Malformed input
    //
    // These come off the internet. Every one of them must return nil rather
    // than crash, hang, or read past the buffer.

    @Test func truncatedInputIsRejected() {
        #expect(parse("i42") == nil)
        #expect(parse("4:spa") == nil)
        #expect(parse("l4:spam") == nil)
        #expect(parse("d3:cow") == nil)
    }

    @Test func aStringLongerThanTheBufferIsRejected() {
        #expect(parse("100:short") == nil)
    }

    @Test func garbageIsRejected() {
        #expect(parse("") == nil)
        #expect(parse("x") == nil)
        #expect(parse("i4x2e") == nil)
        #expect(parse("-1:x") == nil)
    }

    /// A length prefix big enough to overflow or to allocate wildly must be
    /// refused, not attempted.
    @Test func anAbsurdLengthPrefixIsRejected() {
        #expect(parse("99999999999999999999:x") == nil)
    }

    /// Deeply nested input must not recurse until the stack dies.
    @Test func pathologicalNestingIsRejectedRatherThanCrashing() {
        let deep = String(repeating: "l", count: 10_000) + String(repeating: "e", count: 10_000)
        #expect(parse(deep) == nil)
    }

    // MARK: - Torrent extraction
    //
    // Fixtures are built rather than hand-written: bencode prefixes every
    // string with its byte length, and miscounting one produces input that
    // fails for a reason unrelated to what the test is about. (It did.)

    private func str(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    private func dict(_ pairs: [(String, String)]) -> String {
        "d" + pairs.map { str($0.0) + $0.1 }.joined() + "e"
    }
    private func list(_ items: [String]) -> String { "l" + items.joined() + "e" }
    private func int(_ value: Int64) -> String { "i\(value)e" }

    /// Single-file torrent: `info` has `name` and `length`, no `files`.
    @Test func aSingleFileTorrentYieldsOneFile() {
        let raw = dict([("info", dict([
            ("length", int(1_460_000_000)),
            ("name", str("Show.S01E04.mkv")),
        ]))])
        let meta = TorrentMetadata.parse(Data(raw.utf8))

        #expect(meta?.name == "Show.S01E04.mkv")
        #expect(meta?.files.count == 1)
        #expect(meta?.files.first?.path == "Show.S01E04.mkv")
        #expect(meta?.files.first?.length == 1_460_000_000)
    }

    /// Multi-file: `files` is a list of dicts, each with a `path` list whose
    /// components join under the torrent's `name`.
    @Test func aMultiFileTorrentJoinsPathComponents() {
        let raw = dict([("info", dict([
            ("files", list([
                dict([("length", int(100)), ("path", list([str("Season1"), str("E01")]))]),
                dict([("length", int(200)), ("path", list([str("Season1"), str("E02")]))]),
            ])),
            ("name", str("Pack")),
        ]))])
        let meta = TorrentMetadata.parse(Data(raw.utf8))

        #expect(meta?.name == "Pack")
        #expect(meta?.files.map(\.path) == ["Pack/Season1/E01", "Pack/Season1/E02"])
        #expect(meta?.files.map(\.length) == [100, 200])
    }

    @Test func aTorrentWithoutAnInfoDictIsRejected() {
        let raw = dict([("announce", str("http://tracker.example"))])
        #expect(TorrentMetadata.parse(Data(raw.utf8)) == nil)
    }

    /// A file whose path escapes the torrent root is refused outright — the
    /// same class of attack `PathSanitizer` exists for, arriving here from a
    /// different direction.
    @Test func pathTraversalInAFileEntryIsRejected() {
        let raw = dict([("info", dict([
            ("files", list([
                dict([("length", int(100)), ("path", list([str(".."), str("passwd")]))]),
            ])),
            ("name", str("Pack")),
        ]))])
        let meta = TorrentMetadata.parse(Data(raw.utf8))
        #expect(meta?.files.isEmpty == true)
    }
}

/// Proving a fetched `.torrent` is the one that was asked for.
///
/// itorrents.org returns a byte-identical decoy for **any** unknown hash —
/// verified live: `1111…`, `DEADBEEF…` and an invented hash all produced the
/// same 45,728-byte body containing an `.exe`. Trusting it would have shown a
/// fabricated file list for every uncached torrent.
///
/// A torrent's infohash is the SHA-1 of its bencoded `info` dictionary, so the
/// claim is checkable against the bytes themselves rather than against whoever
/// served them.
@Suite struct InfoHashVerificationTests {
    private func str(_ v: String) -> String { "\(v.utf8.count):\(v)" }

    /// `info` here is `d6:lengthi3e4:name1:ae`, whose SHA-1 is fixed.
    private var torrent: Data {
        let info = "d" + "6:length" + "i3e" + "4:name" + str("a") + "e"
        return Data(("d" + "4:info" + info + "e").utf8)
    }

    private var infoHash: String {
        let info = "d" + "6:length" + "i3e" + "4:name" + str("a") + "e"
        return InfoHash.sha1Hex(Data(info.utf8))
    }

    @Test func theInfoDictionarysBytesAreLocatedExactly() throws {
        let range = try #require(Bencode.infoDictionaryRange(in: torrent))
        let slice = torrent[range]
        #expect(String(data: slice, encoding: .utf8) == "d6:lengthi3e4:name1:ae")
    }

    @Test func aMatchingHashIsAccepted() {
        #expect(TorrentMetadata.parse(torrent, expectedInfoHash: infoHash) != nil)
    }

    /// The decoy case: a well-formed torrent that is simply not the one asked
    /// for must be refused, however plausible it looks.
    @Test func aTorrentForADifferentHashIsRejected() {
        #expect(TorrentMetadata.parse(
            torrent, expectedInfoHash: "1111111111111111111111111111111111111111") == nil)
    }

    @Test func verificationIsCaseInsensitive() {
        #expect(TorrentMetadata.parse(torrent, expectedInfoHash: infoHash.uppercased()) != nil)
    }

    /// Passing no expectation still parses — the unverified path stays
    /// available for callers that already know the source.
    @Test func omittingTheExpectationSkipsVerification() {
        #expect(TorrentMetadata.parse(torrent) != nil)
    }
}
