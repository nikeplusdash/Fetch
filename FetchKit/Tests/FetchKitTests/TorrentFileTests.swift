import Testing
import Foundation
import CryptoKit
@testable import FetchKit
import FetchPluginAPI

/// A `.torrent` the user chose from their own disk.
///
/// **Reading one is not P2P.** No peer is contacted and no announce is made —
/// it is parsing a local file. The magnet it yields goes to a debrid exactly
/// as a pasted one does, and the debrid does any swarm work.
@Suite struct TorrentFileTests {
    // MARK: - Fixtures, built here so the bytes are known

    private func bencode(_ value: Any) -> Data {
        switch value {
        case let n as Int:
            return Data("i\(n)e".utf8)
        case let s as String:
            let bytes = Data(s.utf8)
            return Data("\(bytes.count):".utf8) + bytes
        // Dictionaries are checked first: `[(String, Any)]` also casts to
        // `[Any]`, so testing the list case first sends every dict down the
        // list branch and then chokes on a tuple.
        case let dict as [(String, Any)]:
            // Ordered pairs: bencode requires sorted keys, and a Swift
            // dictionary would not preserve that.
            return Data("d".utf8)
                + dict.map { bencode($0.0) + bencode($0.1) }.reduce(Data(), +)
                + Data("e".utf8)
        case let list as [Any]:
            return Data("l".utf8) + list.map(bencode).reduce(Data(), +) + Data("e".utf8)
        default:
            fatalError("unbencodable fixture")
        }
    }

    private func multiFileTorrent() -> Data {
        bencode([
            ("announce", "udp://tracker.opentrackr.org:1337/announce"),
            ("info", [
                ("files", [
                    [("length", 937_813), ("path", ["aacid__28258526__ACdUy"])] as [(String, Any)],
                    [("length", 2_062_384), ("path", ["sub", "second.epub"])] as [(String, Any)],
                ] as [Any]),
                ("name", "container"),
                ("piece length", 262_144),
                ("pieces", "0123456789abcdefghij"),
            ] as [(String, Any)]),
        ] as [(String, Any)])
    }

    private func singleFileTorrent() -> Data {
        bencode([
            ("announce", "udp://tracker.example:1337/announce"),
            ("info", [
                ("length", 4_472_950),
                ("name", "one-book.epub"),
                ("piece length", 262_144),
                ("pieces", "0123456789abcdefghij"),
            ] as [(String, Any)]),
        ] as [(String, Any)])
    }

    /// The infohash is SHA-1 of the bencoded `info` dictionary, so the test
    /// computes it independently rather than trusting the parser's own answer.
    private func expectedInfoHash(_ data: Data) -> String {
        let range = Bencode.infoDictionaryRange(in: data)!
        return Insecure.SHA1.hash(data: data[range])
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Parsing

    @Test func aMultiFileTorrentParses() throws {
        let data = multiFileTorrent()
        let torrent = try #require(TorrentFile.parse(data))

        #expect(torrent.name == "container")
        #expect(torrent.files.count == 2)
        #expect(torrent.infoHash.hex == expectedInfoHash(data))
    }

    @Test func aSingleFileTorrentParses() throws {
        let data = singleFileTorrent()
        let torrent = try #require(TorrentFile.parse(data))

        #expect(torrent.name == "one-book.epub")
        #expect(torrent.files.count == 1)
        #expect(torrent.files.first?.length == 4_472_950)
        #expect(torrent.infoHash.hex == expectedInfoHash(data))
    }

    /// Paths carry the torrent's root name, because `DebridFile.name` does —
    /// §6's rule that a selection resolves by relative path only holds if both
    /// sides spell it the same way.
    @Test func filePathsAreRootPrefixed() throws {
        let torrent = try #require(TorrentFile.parse(multiFileTorrent()))

        #expect(torrent.files.map(\.path).sorted() == [
            "container/aacid__28258526__ACdUy",
            "container/sub/second.epub",
        ])
    }

    // MARK: - Refusals

    @Test func aNonTorrentIsRefusedRatherThanCrashing() {
        #expect(TorrentFile.parse(Data("not a torrent at all".utf8)) == nil)
    }

    @Test func anEmptyFileIsRefused() {
        #expect(TorrentFile.parse(Data()) == nil)
    }

    @Test func aTruncatedTorrentIsRefused() {
        let data = multiFileTorrent()
        #expect(TorrentFile.parse(data.prefix(data.count / 2)) == nil)
    }

    /// A path component escaping the torrent root is dropped by
    /// `TorrentMetadata`; pinned from this entry point because a dropped file
    /// is attacker-supplied in exactly the way a search result is.
    @Test func aPathEscapingTheRootIsNotCarried() throws {
        let data = bencode([
            ("info", [
                ("files", [
                    [("length", 10), ("path", ["..", "..", "escaped"])] as [(String, Any)],
                    [("length", 20), ("path", ["safe.epub"])] as [(String, Any)],
                ] as [Any]),
                ("name", "c"),
                ("piece length", 262_144),
                ("pieces", "0123456789abcdefghij"),
            ] as [(String, Any)]),
        ] as [(String, Any)])

        let torrent = try #require(TorrentFile.parse(data))
        #expect(torrent.files.map(\.path) == ["c/safe.epub"])
    }

    // MARK: - The magnet

    /// What is handed to the debrid must be what was parsed.
    @Test func theMagnetCarriesTheInfoHashAndName() throws {
        let data = multiFileTorrent()
        let torrent = try #require(TorrentFile.parse(data))
        let magnet = try #require(torrent.magnet)

        #expect(magnet.infoHash.hex == expectedInfoHash(data))
        #expect(magnet.raw.contains("dn=container"))
    }

    /// Trackers are carried where present: a debrid resolves through its own
    /// infrastructure, but a magnet with none is less likely to resolve at a
    /// service that falls back to the DHT. Fetch contacts none of them itself.
    @Test func theMagnetCarriesTheAnnounceURL() throws {
        let torrent = try #require(TorrentFile.parse(multiFileTorrent()))
        let magnet = try #require(torrent.magnet)

        #expect(magnet.raw.contains("tracker.opentrackr.org"))
    }

    /// A torrent with no announce still yields a usable magnet — the infohash
    /// is the part that matters, and refusing here would reject a valid file
    /// for missing something optional.
    @Test func aTorrentWithNoAnnounceStillYieldsAMagnet() throws {
        let data = bencode([
            ("info", [
                ("length", 10),
                ("name", "x.epub"),
                ("piece length", 262_144),
                ("pieces", "0123456789abcdefghij"),
            ] as [(String, Any)]),
        ] as [(String, Any)])

        let torrent = try #require(TorrentFile.parse(data))
        #expect(torrent.magnet != nil)
    }
}

/// Parses a real `.torrent` from disk, for when a synthetic fixture is not
/// enough — the fixtures above are bytes this test file wrote, so they prove
/// the parser agrees with itself.
///
/// Gated on `FETCH_TORRENT_FIXTURE` pointing at a `.torrent`, the same way the
/// live suites are gated on their own env vars. Nothing here reaches the
/// network; it reads a local file.
@Suite struct RealTorrentFileTests {
    private var fixture: Data? {
        guard let path = ProcessInfo.processInfo.environment["FETCH_TORRENT_FIXTURE"] else {
            return nil
        }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test func aRealTorrentParsesAndItsInfoHashIsRecomputable() throws {
        guard let data = fixture else { return }
        let torrent = try #require(TorrentFile.parse(data))

        // The infohash is recomputed from the info dict rather than trusted.
        let range = try #require(Bencode.infoDictionaryRange(in: data))
        #expect(torrent.infoHash.hex == InfoHash.sha1Hex(data[range]).lowercased())

        #expect(!torrent.name.isEmpty)
        #expect(!torrent.files.isEmpty)
        #expect(torrent.totalLength > 0)

        // Every path is rooted at the torrent name, which is what makes a
        // selection resolve against `DebridFile.name`.
        #expect(torrent.files.allSatisfy { $0.path.hasPrefix(torrent.name) })

        // And the magnet round-trips back to the same hash.
        let magnet = try #require(torrent.magnet)
        #expect(magnet.infoHash.hex == torrent.infoHash.hex)

        print("""
        [fixture] name=\(torrent.name)
        [fixture] btih=\(torrent.infoHash.hex)
        [fixture] files=\(torrent.files.count) total=\(torrent.totalLength)
        [fixture] trackers=\(torrent.trackers.count)
        """)
    }
}
