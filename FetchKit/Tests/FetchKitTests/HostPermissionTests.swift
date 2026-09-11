import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct HostPermissionTests {
    private func client(allowing hosts: [String]?) -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            allowedHosts: hosts.map(Set.init))
    }

    private func endpoint(_ url: String) -> Endpoint {
        Endpoint(baseURL: URL(string: url)!, path: "")
    }

    @Test func aDeclaredHostIsReached() async throws {
        StubURLProtocol.reset([.json("{}")])
        _ = try await client(allowing: ["api.example.com"])
            .sendRaw(endpoint("https://api.example.com/x"))
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func anUndeclaredHostIsBlockedBeforeAnyRequest() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: ["api.example.com"])
                .sendRaw(self.endpoint("https://evil.example.com/x"))
        }
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func aSubdomainOfADeclaredHostIsNotImplied() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: ["example.com"])
                .sendRaw(self.endpoint("https://sub.example.com/x"))
        }
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    @Test func anEmptyAllowlistPermitsNothing() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: []).sendRaw(self.endpoint("https://any.example/x"))
        }
    }

    @Test func coreCodeWithNoAllowlistIsUnrestricted() async throws {
        StubURLProtocol.reset([.json("{}")])
        _ = try await client(allowing: nil).sendRaw(endpoint("https://anything.example/x"))
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func hostMatchingIsCaseInsensitive() async throws {
        StubURLProtocol.reset([.json("{}")])
        _ = try await client(allowing: ["API.Example.com"])
            .sendRaw(endpoint("https://api.example.com/x"))
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }
}
