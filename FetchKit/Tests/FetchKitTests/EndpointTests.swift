import Testing
import Foundation
@testable import FetchKit

@Suite struct EndpointTests {
    @Test func emptyPathDoesNotAppendATrailingSlash() throws {
        let endpoint = Endpoint(
            baseURL: URL(string: "http://localhost:9117/api/v2.0/indexers/all/results/torznab/api")!,
            path: "",
            queryItems: [URLQueryItem(name: "t", value: "caps")]
        )
        let request = try endpoint.makeRequest()
        #expect(request.url?.absoluteString ==
            "http://localhost:9117/api/v2.0/indexers/all/results/torznab/api?t=caps")
    }

    @Test func nonEmptyPathIsStillAppendedNormally() throws {
        let endpoint = Endpoint(
            baseURL: URL(string: "https://api.torbox.app")!,
            path: "/v1/api/user/me"
        )
        let request = try endpoint.makeRequest()
        #expect(request.url?.absoluteString == "https://api.torbox.app/v1/api/user/me")
    }
}
