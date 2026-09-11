import Testing
import Foundation
import CryptoKit
@testable import FetchKit
import FetchPluginAPI

@Suite struct TorrentFileTests {

    private func bencode(_ value: Any) -> Data {
        switch value {
        case let n as Int:
            return Data("i\(n)e".utf8)
        case let s as String:
            let bytes = Data(s.utf8)
            return Data("\(bytes.count):".utf8) + bytes
        case let dict as [(String, Any)]:
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

    private func expectedInfoHash(_ data: Data) -> String {
        let range = Bencode.infoDictionaryRange(in: data)!
        return Insecure.SHA1.hash(data: data[range])
            .map { String(format: "%02x", $0) }.joined()
    }


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

    @Test func filePathsAreRootPrefixed() throws {
        let torrent = try #require(TorrentFile.parse(multiFileTorrent()))

        #expect(torrent.files.map(\.path).sorted() == [
            "container/aacid__28258526__ACdUy",
            "container/sub/second.epub",
        ])
    }


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


    @Test func theMagnetCarriesTheInfoHashAndName() throws {
        let data = multiFileTorrent()
        let torrent = try #require(TorrentFile.parse(data))
        let magnet = try #require(torrent.magnet)

        #expect(magnet.infoHash.hex == expectedInfoHash(data))
        #expect(magnet.raw.contains("dn=container"))
    }

    @Test func theMagnetCarriesTheAnnounceURL() throws {
        let torrent = try #require(TorrentFile.parse(multiFileTorrent()))
        let magnet = try #require(torrent.magnet)

        #expect(magnet.raw.contains("tracker.opentrackr.org"))
    }

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

        let range = try #require(Bencode.infoDictionaryRange(in: data))
        #expect(torrent.infoHash.hex == InfoHash.sha1Hex(data[range]).lowercased())

        #expect(!torrent.name.isEmpty)
        #expect(!torrent.files.isEmpty)
        #expect(torrent.totalLength > 0)

        #expect(torrent.files.allSatisfy { $0.path.hasPrefix(torrent.name) })

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
