import Testing
import Foundation
@testable import FetchPluginAPI

@Suite struct IdentifierTests {
    @Test func torrentIDRoundTripsThroughCodableAsPlainString() throws {
        let id = DebridTorrentID(rawValue: "12345")
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"12345\"")
        #expect(try JSONDecoder().decode(DebridTorrentID.self, from: data) == id)
    }

    @Test func downloadIDWrapsUUID() {
        let uuid = UUID()
        #expect(DownloadID(rawValue: uuid).rawValue == uuid)
    }

    @Test func downloadIDRoundTripsAsBareString() throws {
        let id = DownloadID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-123456789012")!)
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"12345678-1234-1234-1234-123456789012\"")
        #expect(try JSONDecoder().decode(DownloadID.self, from: data) == id)
    }
}
