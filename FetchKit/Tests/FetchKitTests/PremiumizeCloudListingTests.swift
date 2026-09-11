import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol)
struct PremiumizeCloudListingTests {
    private func premiumize() -> PremiumizeProvider {
        PremiumizeProvider(
            apiKey: Redacted("test-token"),
            client: HTTPClient(session: StubURLProtocol.makeSession()))
    }

    private let listJSON = """
    {"status":"success","transfers":[
      {"id":"t-1","name":"Album","status":"finished","progress":1,"folder_id":"f-9"},
      {"id":"t-2","name":"Still Going","status":"running","progress":0.4,"folder_id":"f-3"}
    ]}
    """

    @Test("only finished transfers become cloud items")
    func onlyFinished() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await premiumize().listAccountContents()

        #expect(items.count == 1)
        #expect(items[0].name == "Album")
    }

    @Test("a folder-backed transfer is identified by its folder, which is what files(in:) takes")
    func folderBackedUsesFolderID() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await premiumize().listAccountContents()

        if case .torrent(let id) = items[0].origin {
            #expect(id.rawValue == "f-9")
        } else {
            Issue.record("not a torrent origin")
        }
        #expect(items[0].files.isEmpty)
    }

    @Test("a single-file transfer carries that file already, having no folder to list")
    func singleFileCarriesItsFile() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","transfers":[
          {"id":"t-5","name":"Documentary.mkv","status":"finished","progress":1,"file_id":"x-7"}]}
        """)])
        let items = try await premiumize().listAccountContents()

        #expect(items.count == 1)
        if case .torrent(let id) = items[0].origin {
            #expect(id.rawValue == "x-7")
        } else {
            Issue.record("not a torrent origin")
        }
        #expect(items[0].files.count == 1)
        #expect(items[0].files[0].id.rawValue == "x-7")
        #expect(items[0].files[0].name == "Documentary.mkv")
    }

    @Test("a finished transfer holding neither a folder nor a file is dropped")
    func nothingToPointAtIsDropped() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","transfers":[
          {"id":"t-6","name":"Empty","status":"finished","progress":1}]}
        """)])
        let items = try await premiumize().listAccountContents()

        #expect(items.isEmpty)
    }

    @Test("Premiumize items carry no infohash, so they never dedup against another service")
    func noInfohash() async throws {
        StubURLProtocol.reset([.json(listJSON)])
        let items = try await premiumize().listAccountContents()

        #expect(items[0].infoHashHex == nil)
    }

    @Test("an empty account lists nothing")
    func emptyAccount() async throws {
        StubURLProtocol.reset([.json("""
        {"status":"success","transfers":[]}
        """)])
        let items = try await premiumize().listAccountContents()

        #expect(items.isEmpty)
    }
}
