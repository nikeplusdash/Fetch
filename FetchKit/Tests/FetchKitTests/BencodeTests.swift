import Testing
import Foundation
@testable import FetchKit

@Suite struct BencodeTests {
    private func parse(_ text: String) -> Bencode? {
        Bencode.parse(Data(text.utf8))
    }


    @Test func integersParse() {
        #expect(parse("i42e")?.integer == 42)
        #expect(parse("i0e")?.integer == 0)
        #expect(parse("i-13e")?.integer == -13)
    }

    @Test func stringsParse() {
        #expect(parse("4:spam")?.string == "spam")
        #expect(parse("0:")?.string == "")
    }

    @Test func binaryStringsSurviveIntact() {
        var data = Data("4:".utf8)
        data.append(contentsOf: [0x00, 0xFF, 0xFE, 0x80])
        let parsed = Bencode.parse(data)
        #expect(parsed?.bytes == Data([0x00, 0xFF, 0xFE, 0x80]))
        #expect(parsed?.string == nil)
    }


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

    @Test func anAbsurdLengthPrefixIsRejected() {
        #expect(parse("99999999999999999999:x") == nil)
    }

    @Test func pathologicalNestingIsRejectedRatherThanCrashing() {
        let deep = String(repeating: "l", count: 10_000) + String(repeating: "e", count: 10_000)
        #expect(parse(deep) == nil)
    }


    private func str(_ value: String) -> String { "\(value.utf8.count):\(value)" }
    private func dict(_ pairs: [(String, String)]) -> String {
        "d" + pairs.map { str($0.0) + $0.1 }.joined() + "e"
    }
    private func list(_ items: [String]) -> String { "l" + items.joined() + "e" }
    private func int(_ value: Int64) -> String { "i\(value)e" }

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

@Suite struct InfoHashVerificationTests {
    private func str(_ v: String) -> String { "\(v.utf8.count):\(v)" }

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

    @Test func aTorrentForADifferentHashIsRejected() {
        #expect(TorrentMetadata.parse(
            torrent, expectedInfoHash: "1111111111111111111111111111111111111111") == nil)
    }

    @Test func verificationIsCaseInsensitive() {
        #expect(TorrentMetadata.parse(torrent, expectedInfoHash: infoHash.uppercased()) != nil)
    }

    @Test func omittingTheExpectationSkipsVerification() {
        #expect(TorrentMetadata.parse(torrent) != nil)
    }
}
