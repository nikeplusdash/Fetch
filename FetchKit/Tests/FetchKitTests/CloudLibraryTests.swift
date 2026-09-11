import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite("Cloud library")
struct CloudLibraryTests {
    private func item(
        _ provider: String, hash: String?, name: String, id: String,
        size: Int64 = 1, files: [String] = []
    ) -> DebridCloudItem {
        DebridCloudItem(
            provider: DebridProviderID(rawValue: provider),
            origin: .torrent(DebridTorrentID(rawValue: id)),
            name: name, size: size, infoHashHex: hash, addedAt: nil,
            files: files.map {
                DebridFile(
                    id: DebridFileID(rawValue: $0), name: $0,
                    shortName: ($0 as NSString).lastPathComponent,
                    size: 1, mimeType: nil)
            })
    }

    @Test("the same infohash on two services collapses to one row keeping both providers")
    func dedupByInfohash() {
        let rows = CloudLibrary.rows(from: [
            item("torbox", hash: "AA", name: "Movie", id: "1"),
            item("rd", hash: "aa", name: "Movie", id: "2"),
        ])

        #expect(rows.count == 1)
        #expect(rows[0].providers.map(\.rawValue) == ["torbox", "rd"])
        #expect(rows[0].members.count == 2)
    }

    @Test("items without an infohash never dedup against each other")
    func webItemsStayDistinct() {
        let rows = CloudLibrary.rows(from: [
            item("pm", hash: nil, name: "A", id: "1"),
            item("pm", hash: nil, name: "B", id: "2"),
        ])

        #expect(rows.count == 2)
    }

    @Test("two items with no hash and the same name are still two rows")
    func sameNameNoHashDoesNotCollapse() {
        let rows = CloudLibrary.rows(from: [
            item("pm", hash: nil, name: "Same", id: "1"),
            item("pm", hash: nil, name: "Same", id: "2"),
        ])

        #expect(rows.count == 2)
    }

    @Test("the first item of a dedup group is the representative")
    func firstIsRepresentative() {
        let rows = CloudLibrary.rows(from: [
            item("torbox", hash: "AA", name: "Preferred", id: "1"),
            item("rd", hash: "aa", name: "Other", id: "2"),
        ])

        #expect(rows[0].name == "Preferred")
    }

    @Test("one service holding a thing twice names that service once")
    func providersAreDistinct() {
        let rows = CloudLibrary.rows(from: [
            item("torbox", hash: "AA", name: "Movie", id: "1"),
            item("torbox", hash: "aa", name: "Movie", id: "2"),
        ])

        #expect(rows[0].providers.map(\.rawValue) == ["torbox"])
        #expect(rows[0].members.count == 2)
    }

    @Test("rows arrive in the order their group was first seen")
    func orderIsStable() {
        let rows = CloudLibrary.rows(from: [
            item("rd", hash: "cc", name: "Third", id: "3"),
            item("rd", hash: "aa", name: "First", id: "1"),
            item("rd", hash: "bb", name: "Second", id: "2"),
        ])

        #expect(rows.map(\.name) == ["Third", "First", "Second"])
    }

    @Test("a row's kind comes from its files, and is other when none have arrived")
    func kindFollowsTheFiles() {
        let rows = CloudLibrary.rows(from: [
            item("rd", hash: "aa", name: "Show", id: "1", files: ["Show/ep1.mkv"]),
            item("rd", hash: "bb", name: "Unknown", id: "2"),
        ])

        #expect(rows[0].kind != .other)
        #expect(rows[1].kind == .other)
    }

    @Test("nothing in is nothing out")
    func emptyIsEmpty() {
        #expect(CloudLibrary.rows(from: []).isEmpty)
        #expect(CloudLibrary.sections([]).isEmpty)
    }

    @Test("sections bucket rows by kind the way the on-disk library does")
    func sectionsMatchTheLibrary() {
        let rows = CloudLibrary.rows(from: [
            item("rd", hash: "aa", name: "Show", id: "1", files: ["Show/ep1.mkv"]),
            item("rd", hash: "bb", name: "Nothing", id: "2"),
        ])
        let sections = CloudLibrary.sections(rows)

        #expect(sections.reduce(0) { $0 + $1.rows.count } == 2)
        #expect(Set(sections.map(\.kind)).count == sections.count)
    }
}
