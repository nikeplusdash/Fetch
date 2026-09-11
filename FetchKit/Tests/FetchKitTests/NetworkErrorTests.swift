import Testing
import Foundation
@testable import FetchKit

@Suite struct NetworkErrorScrubTests {
    @Test(arguments: [
        (#"{"api_key":"sk-live-abc123"}"#, "sk-live-abc123"),
        ("Authorization: Bearer sk-live-SECRET", "sk-live-SECRET"),
        (#"{"token":"tok-XYZ"}"#, "tok-XYZ"),
        (#"{"apikey":"k-999"}"#, "k-999"),
        ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
        ("Authorization: Token sk-live-S2", "sk-live-S2"),
        ("Authorization: Digest sk-live-S3", "sk-live-S3"),
    ]) func redactsSecrets(_ body: String, _ secret: String) throws {
        let scrubbed = try #require(NetworkError.scrub(body))
        #expect(!scrubbed.contains(secret))
    }

    @Test func truncatesLongBodies() {
        let long = String(repeating: "x", count: 5000)
        #expect((NetworkError.scrub(long)?.count ?? 0) <= 2048)
    }

    @Test func nilBodyStaysNil() {
        #expect(NetworkError.scrub(nil) == nil)
    }
}
