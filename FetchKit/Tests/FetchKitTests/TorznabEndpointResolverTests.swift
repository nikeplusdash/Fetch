import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite(.serialized, .usesStubURLProtocol) struct TorznabEndpointResolverTests {

    static let capsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <caps>
      <limits max="100"/>
      <searching><search available="yes" supportedParams="q"/></searching>
      <categories><category id="2000" name="Movies"/></categories>
    </caps>
    """

    static let loginPageHTML = """
    <!DOCTYPE html>
    <html lang="en">
      <head><meta charset="utf-8" /><title>Prowlarr</title></head>
      <body><div id="root"></div></body>
    </html>
    """

    private static func html(_ body: String) -> StubURLProtocol.Response {
        StubURLProtocol.Response(
            status: 200, headers: ["Content-Type": "text/html"], body: Data(body.utf8))
    }

    private static func xml(_ body: String) -> StubURLProtocol.Response {
        StubURLProtocol.Response(
            status: 200,
            headers: ["Content-Type": "application/rss+xml"],
            body: Data(body.utf8))
    }

    private func makeClient() -> HTTPClient {
        HTTPClient(
            session: StubURLProtocol.makeSession(),
            policy: RetryPolicy(maxAttempts: 1),
            clock: TestClock())
    }

    private func resolve(_ raw: String) async throws -> TorznabEndpointResolver.Resolved {
        try await TorznabEndpointResolver.resolve(
            url: URL(string: raw)!, apiKey: Redacted("test-key"), client: makeClient())
    }


    @Test func resolutionNeverInventsAProwlarrAggregatePath() async throws {
        StubURLProtocol.reset([Self.xml(Self.capsXML)])

        let resolved = try await resolve("http://10.0.0.181:9696")

        #expect(!resolved.url.absoluteString.hasSuffix("/0/api"))
    }

    @Test func jackettRootResolvesToTheAggregateTorznabPath() async throws {
        StubURLProtocol.reset([Self.xml(Self.capsXML)])

        let resolved = try await resolve("http://10.0.0.181:9117")

        #expect(resolved.url.absoluteString
            == "http://10.0.0.181:9117/api/v2.0/indexers/all/results/torznab/api")
    }

    @Test func aCandidateAnsweringWithALoginPageIsSkipped() async throws {
        StubURLProtocol.reset([Self.html(Self.loginPageHTML), Self.xml(Self.capsXML)])

        let resolved = try await resolve("http://nas.local/indexers")

        let tried = StubURLProtocol.recordedRequests().compactMap { $0.url?.path }
        #expect(tried.count >= 2, "resolution stopped at the HTML response")
        #expect(resolved.capabilities.supportedModes.contains(.search))
    }

    @Test func anAlreadyCompleteEndpointIsProbedOnce() async throws {
        StubURLProtocol.reset([Self.xml(Self.capsXML)])

        let resolved = try await resolve("http://10.0.0.181:9696/6/api")

        #expect(resolved.url.absoluteString == "http://10.0.0.181:9696/6/api")
        #expect(StubURLProtocol.recordedRequests().count == 1)
    }

    @Test func theAPIKeyIsSentOnEveryProbe() async throws {
        StubURLProtocol.reset([Self.xml(Self.capsXML)])

        _ = try await resolve("http://10.0.0.181:9696")

        let query = try #require(StubURLProtocol.recordedRequests().first?.url?.query)
        #expect(query.contains("t=caps"))
        #expect(query.contains("apikey=test-key"))
    }


    @Test func everyCandidateServingHTMLReportsAWebUINotAnXMLParseError() async throws {
        StubURLProtocol.reset([Self.html(Self.loginPageHTML)])

        do {
            _ = try await resolve("http://10.0.0.181:9696")
            Issue.record("expected resolution to fail")
        } catch let error as SearchError {
            guard case .notATorznabEndpoint = error else {
                Issue.record("got \(error), want .notATorznabEndpoint")
                return
            }
            let message = error.localizedDescription
            #expect(message.lowercased().contains("torznab"))
            #expect(!message.contains("NSXMLParserErrorDomain"))
        }
    }

    @Test func aCookieWallAlsoReportsAWebUI() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(
                status: 400,
                headers: ["Content-Type": "text/plain"],
                body: Data("Cookies required".utf8))
        ])

        do {
            _ = try await resolve("http://10.0.0.181:9117")
            Issue.record("expected resolution to fail")
        } catch let error as SearchError {
            guard case .notATorznabEndpoint = error else {
                Issue.record("got \(error), want .notATorznabEndpoint")
                return
            }
        }
    }

    @Test func aRejectedKeyIsReportedAsUnauthorizedNotAsABadEndpoint() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(status: 401, headers: [:], body: Data())
        ])

        do {
            _ = try await resolve("http://10.0.0.181:9696/0/api")
            Issue.record("expected resolution to fail")
        } catch let error as SearchError {
            guard case .unauthorized = error else {
                Issue.record("got \(error), want .unauthorized")
                return
            }
        }
    }

    @Test func anUnreachableHostIsReportedAsUnreachableNotAsABadPath() async throws {
        StubURLProtocol.reset([
            StubURLProtocol.Response(error: URLError(.notConnectedToInternet))
        ])

        do {
            _ = try await resolve("http://10.0.0.181:9117")
            Issue.record("expected resolution to fail")
        } catch let error as SearchError {
            guard case .network(.transport(let urlError)) = error else {
                Issue.record("got \(error), want .network(.transport)")
                return
            }
            #expect(urlError.code == .notConnectedToInternet)
        }
    }

    @Test func aLocalNetworkDenialNamesThePrivacySettingToChange() {
        let message = SearchError.network(.transport(URLError(.notConnectedToInternet)))
            .errorDescription ?? ""

        #expect(message.contains("Local Network"))
        #expect(message.contains("Privacy & Security"))
    }
}
