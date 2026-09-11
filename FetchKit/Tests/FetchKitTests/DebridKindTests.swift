import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct DebridKindTests {
    private let client = HTTPClient()

    @Test(arguments: DebridKind.all)
    func everyKindAgreesWithTheProviderItBuilds(_ kind: DebridKind) {
        let provider = kind.makeProvider(Redacted("test-token"), client)

        #expect(provider.id == kind.id)
        #expect(provider.displayName == kind.displayName)
        #expect(provider.canReportCacheStatus == kind.canReportCacheStatus)
    }

    @Test func kindLookupFindsEachServiceByID() {
        for kind in DebridKind.all {
            #expect(DebridKind.kind(for: kind.id) == kind)
        }
    }

    @Test func anUnknownIDHasNoKind() {
        #expect(DebridKind.kind(for: DebridProviderID(rawValue: "nope")) == nil)
    }

    @Test func everyServiceCanReportSomethingAboutReadiness() {
        #expect(DebridKind.all.allSatisfy { $0.canReportCacheStatus })
    }

    @Test func everyServiceHasItsOwnAPIKeyPage() {
        let pages = Set(DebridKind.all.map(\.apiKeyPageURL))
        #expect(pages.count == DebridKind.all.count)
        for kind in DebridKind.all {
            #expect(kind.apiKeyPageURL.scheme == "https")
        }
    }

    @Test func torBoxDeclaresItsOwnAPIKeyPage() {
        #expect(DebridKind.torbox.apiKeyPageURL == TorBoxProvider.apiKeyPageURL)
    }
}
