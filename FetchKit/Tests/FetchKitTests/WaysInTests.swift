import Foundation
import Testing
@testable import FetchKit
import FetchPluginAPI

@Suite("Ways in")
struct WaysInTests {
    private static let rawMagnet =
        "magnet:?xt=urn:btih:59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3&dn=ubuntu-26.04"


    @Test("A dropped .torrent is taken")
    func dropsTorrentFile() {
        let url = URL(fileURLWithPath: "/tmp/Nosferatu.1922.2160p.torrent")
        #expect(DroppedItem.first(in: [url]) == .torrentFile(url))
    }

    @Test("The extension is matched however it is cased")
    func dropsTorrentFileAnyCase() {
        let url = URL(fileURLWithPath: "/tmp/Loud.TORRENT")
        #expect(DroppedItem.first(in: [url]) == .torrentFile(url))
    }

    @Test("A dragged magnet is taken, told apart from a file by its scheme")
    func dropsMagnet() {
        let url = URL(string: Self.rawMagnet)!
        #expect(DroppedItem.first(in: [url]) == .magnet(url.absoluteString))
    }

    @Test("A file that is not a torrent is refused")
    func refusesOtherFiles() {
        #expect(DroppedItem.first(in: [URL(fileURLWithPath: "/tmp/holiday.jpg")]) == nil)
        #expect(DroppedItem.first(in: [URL(fileURLWithPath: "/tmp/album/")]) == nil)
        #expect(DroppedItem.first(in: []) == nil)
    }

    @Test("A web address is taken, for Add Link to answer")
    func takesWebAddresses() {
        let url = URL(string: "https://example.com/a.zip")!
        #expect(DroppedItem.first(in: [url]) == .webLink(url))
        #expect(DroppedItem.first(in: [url])?.isDirectlyDownloadable == false)
        #expect(DroppedItem.first(in: [URL(fileURLWithPath: "/tmp/f.torrent")])?
            .isDirectlyDownloadable == true)
    }

    @Test("A torrent among other files is found rather than the drop refused")
    func findsTheTorrentInAMixedDrop() {
        let jpeg = URL(fileURLWithPath: "/tmp/holiday.jpg")
        let torrent = URL(fileURLWithPath: "/tmp/film.torrent")
        #expect(DroppedItem.first(in: [jpeg, torrent]) == .torrentFile(torrent))
    }

    @Test("Only the first actionable item is taken")
    func takesOnlyTheFirst() {
        let a = URL(fileURLWithPath: "/tmp/a.torrent")
        let b = URL(fileURLWithPath: "/tmp/b.torrent")
        #expect(DroppedItem.first(in: [a, b]) == .torrentFile(a))
    }

    @Test("The overlay names the file it is about to take")
    func dropDisplayName() {
        #expect(DroppedItem.torrentFile(URL(fileURLWithPath: "/tmp/Nosferatu.1922.torrent"))
            .displayName == "Nosferatu.1922.torrent")
        #expect(DroppedItem.magnet(Self.rawMagnet).displayName == "ubuntu-26.04")
    }


    @Test("A magnet in the field is recognised without asking anything")
    func detectsMagnet() {
        let offer = PastedLink.magnetOffer(from: Self.rawMagnet)
        #expect(offer?.displayName == "ubuntu-26.04")
        #expect(offer?.id == "59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3")
    }

    @Test("Surrounding whitespace does not stop it being a magnet")
    func detectsMagnetWithWhitespace() {
        #expect(PastedLink.magnetOffer(from: "\n  \(Self.rawMagnet)  \n") != nil)
    }

    @Test("A query is not a magnet, so the field goes on searching")
    func aQueryIsNotAMagnet() {
        #expect(PastedLink.magnetOffer(from: "nosferatu 1922") == nil)
        #expect(PastedLink.magnetOffer(from: "https://example.com/x.torrent") == nil)
        #expect(PastedLink.magnetOffer(from: "") == nil)
    }

    @Test("A magnet with no display name is still offered, named generically")
    func magnetWithoutDisplayName() {
        let bare = "magnet:?xt=urn:btih:59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3"
        #expect(PastedLink.magnetOffer(from: bare)?.displayName == "Magnet link")
    }

    @Test("The row shows enough hash to tell one paste from another")
    func shortHash() {
        #expect(PastedLink.magnetOffer(from: Self.rawMagnet)?.shortHash
                == "btih:59ec6454f0a8b9c1…")
    }

    @Test("Identity is the infohash, not the text")
    func identityIsTheHash() {
        let withName = PastedLink.magnetOffer(from: Self.rawMagnet)
        let withoutName = PastedLink.magnetOffer(
            from: "magnet:?xt=urn:btih:59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3")
        #expect(withName?.id == withoutName?.id)
    }


    @Test("A pasted magnet becomes the result shape the picker sheet takes")
    func pastedMagnetBecomesAResult() {
        let magnet = MagnetLink(Self.rawMagnet)!
        let result = SearchResult.pastedMagnet(magnet, source: SearchProviderID(rawValue: "pasted"))

        #expect(result.title == "ubuntu-26.04")
        #expect(result.magnetURI == magnet.raw)
        #expect(result.infoHashHex == "59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3")
        #expect(result.isUsable)
    }

    @Test("A pasted magnet has the same identity as the searched result")
    func pastedMagnetSharesIdentityWithASearchedOne() {
        let magnet = MagnetLink(Self.rawMagnet)!
        let pasted = SearchResult.pastedMagnet(
            magnet, source: SearchProviderID(rawValue: "pasted"))
        let searched = SearchResult(
            candidates: [.torrent(infoHash: magnet.infoHash, magnet: magnet, targetPath: nil)],
            title: "Ubuntu 26.04", size: 1, seeders: 2, peers: 0,
            category: nil, publishDate: nil,
            sources: [SearchProviderID(rawValue: "jackett")], rawAttributes: [:])
        #expect(pasted.id == searched.id)
    }

    @Test("A pasted magnet declares no size rather than zero")
    func pastedMagnetHasNoSize() {
        let magnet = MagnetLink(Self.rawMagnet)!
        #expect(SearchResult.pastedMagnet(
            magnet, source: SearchProviderID(rawValue: "pasted")).size == nil)
    }

    @Test("The display name is parsed, so the rules route it the same way")
    func pastedMagnetNameIsParsed() {
        let raw = "magnet:?xt=urn:btih:59ec6454f0a8b9c1d2e3f4a5b6c7d8e9f0a1b2c3"
            + "&dn=Nosferatu.1922.REMASTERED.1080p.BluRay.x264"
        let magnet = MagnetLink(raw)!
        let result = SearchResult.pastedMagnet(
            magnet, source: SearchProviderID(rawValue: "pasted"))
        #expect(result.metadata.year == 1922)
        #expect(result.metadata.title == "Nosferatu")
    }
}
