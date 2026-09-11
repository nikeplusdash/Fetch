import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct DebridHomePageTests {

    @Test func everyServiceHasSomewhereToOpen() {
        for kind in DebridKind.all {
            #expect(kind.homePageURL.scheme == "https", "\(kind.displayName) is not https")
            #expect(!(kind.homePageURL.host ?? "").isEmpty)
        }
    }

    @Test func theThreeHomePagesAreDistinct() {
        let urls = Set(DebridKind.all.map(\.homePageURL))
        #expect(urls.count == DebridKind.all.count)
    }

    @Test func eachKindLooksUpByItsProviderID() {
        for kind in DebridKind.all {
            #expect(DebridKind.kind(for: kind.id)?.homePageURL == kind.homePageURL)
        }
    }
}
