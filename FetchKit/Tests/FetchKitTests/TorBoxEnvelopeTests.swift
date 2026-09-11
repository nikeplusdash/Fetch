import Testing
import Foundation
@testable import FetchKit

@Suite(.serialized) struct TorBoxEnvelopeTests {
    struct Item: Codable, Equatable { let name: String }

    @Test func decodesSuccessEnvelope() throws {
        let json = #"{"success":true,"detail":"ok","data":{"name":"x"}}"#
        let env = try JSONDecoder().decode(
            TorBoxEnvelope<Item>.self, from: Data(json.utf8)
        )
        #expect(env.success)
        #expect(env.data == Item(name: "x"))
    }

    @Test func decodesFailureEnvelopeWithNullData() throws {
        let json = #"{"success":false,"detail":"bad key","data":null}"#
        let env = try JSONDecoder().decode(
            TorBoxEnvelope<Item>.self, from: Data(json.utf8)
        )
        #expect(!env.success)
        #expect(env.detail == "bad key")
        #expect(env.data == nil)
    }

    @Test func decodesEnvelopeWithMissingDataKey() throws {
        let json = #"{"success":true,"detail":"ok"}"#
        let env = try JSONDecoder().decode(
            TorBoxEnvelope<Item>.self, from: Data(json.utf8)
        )
        #expect(env.data == nil)
    }
}
