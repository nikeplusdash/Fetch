import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// `DebridKind` had no tests at all. It is a hand-maintained table describing
/// three provider types, and the app compares its `displayName` against a
/// live provider's to decide whether a debrid can be removed — so a drift
/// between the two is not cosmetic, it is a download that can never be
/// cancelled or a provider torn down under a running transfer.
@Suite struct DebridKindTests {
    private let client = HTTPClient()

    /// The load-bearing one. Every field of every kind must match the provider
    /// that kind builds.
    @Test(arguments: DebridKind.all)
    func everyKindAgreesWithTheProviderItBuilds(_ kind: DebridKind) {
        let provider = kind.makeProvider(Redacted("test-token"), client)

        #expect(provider.id == kind.id)
        // Guards `AppModel.hasActiveDownloads(on:)`, which compares the name
        // stored at routing time against the name in this table.
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

    /// Real-Debrid is the one service that cannot answer a cache check, and
    /// Settings renders that fact for a provider the user has not configured
    /// — which is why the table exists rather than being derived from a live
    /// instance.
    /// Every service can now answer *something* about what is ready.
    ///
    /// Real-Debrid was the exception, because `instantAvailability` was
    /// withdrawn — but it will still say what the account already holds, and a
    /// torrent downloaded there is instantly available to that user, which is
    /// what the badge is asking. See `RealDebridProvider.checkCached`.
    @Test func everyServiceCanReportSomethingAboutReadiness() {
        #expect(DebridKind.all.allSatisfy { $0.canReportCacheStatus })
    }

    /// Each service must point somewhere distinct, and at a real page — a kind
    /// whose "Get my API key" opens another service's account page is worse
    /// than no button.
    @Test func everyServiceHasItsOwnAPIKeyPage() {
        let pages = Set(DebridKind.all.map(\.apiKeyPageURL))
        #expect(pages.count == DebridKind.all.count)
        for kind in DebridKind.all {
            #expect(kind.apiKeyPageURL.scheme == "https")
        }
    }

    /// TorBox's page URL was a bare literal in the table while the other two
    /// referenced their provider's static, because `TorBoxProvider` never
    /// declared one. It does now.
    @Test func torBoxDeclaresItsOwnAPIKeyPage() {
        #expect(DebridKind.torbox.apiKeyPageURL == TorBoxProvider.apiKeyPageURL)
    }
}
