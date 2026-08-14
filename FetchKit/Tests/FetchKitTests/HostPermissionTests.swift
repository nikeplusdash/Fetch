import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// §3 rule 4: "A plugin declares the hosts it may reach; `HTTPClient` enforces
/// the allowlist rather than trusting the plugin to respect it."
///
/// The enforcement has to live in the client, not in the calling code, or it
/// is advice rather than a permission — a plugin that ignored it would simply
/// work.
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

    /// The acceptance criterion, directly (§15).
    @Test func anUndeclaredHostIsBlockedBeforeAnyRequest() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: ["api.example.com"])
                .sendRaw(self.endpoint("https://evil.example.com/x"))
        }
        // Blocked *before* the request, not after: a request that reached the
        // host has already leaked that the user is running this plugin.
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    /// A subdomain of a declared host is a different host. Allowing them
    /// implicitly is the standard way an allowlist becomes decorative.
    @Test func aSubdomainOfADeclaredHostIsNotImplied() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: ["example.com"])
                .sendRaw(self.endpoint("https://sub.example.com/x"))
        }
        #expect(StubURLProtocol.recordedRequests().isEmpty)
    }

    /// Declaring an empty list means no network at all, not unrestricted —
    /// the same default-closed rule the manifest uses.
    @Test func anEmptyAllowlistPermitsNothing() async {
        StubURLProtocol.reset([.json("{}")])

        await #expect(throws: NetworkError.self) {
            _ = try await self.client(allowing: []).sendRaw(self.endpoint("https://any.example/x"))
        }
    }

    /// Core code passes no allowlist and is unrestricted. Enforcement applies
    /// to plugins, which is what "declared permissions" means — the app's own
    /// indexers and debrids are configured by the user, not declared by a
    /// third party.
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
