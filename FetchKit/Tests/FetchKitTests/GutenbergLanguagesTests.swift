import Testing
import Foundation
@testable import FetchKit

/// Stage 7c §6. Following the system's languages is an implicit default —
/// results change based on state the user is not looking at. The mitigation is
/// that the Settings row states exactly what it resolved to, which requires
/// the resolution to be a value, not a side effect.
@Suite struct GutenbergLanguagesTests {
    @Test func regionalTagsReduceToISO639_1() {
        #expect(GutenbergLanguages.codes(from: ["en-US", "fr-CA"]) == ["en", "fr"])
    }

    /// macOS lists `en-US` and `en-GB` separately; Gutendex wants one `en`.
    @Test func duplicatesCollapseAndOrderIsPreserved() {
        #expect(GutenbergLanguages.codes(from: ["en-GB", "hi-IN", "en-US"]) == ["en", "hi"])
    }

    @Test func scriptSubtagsAreDropped() {
        #expect(GutenbergLanguages.codes(from: ["zh-Hans-CN"]) == ["zh"])
    }

    /// An empty result must mean "no filter", never "filter to nothing" —
    /// sending `languages=` would return an empty catalogue.
    @Test func nothingUsableYieldsNoCodesRatherThanAnEmptyFilter() {
        #expect(GutenbergLanguages.codes(from: []).isEmpty)
        #expect(GutenbergLanguages.codes(from: ["", "   "]).isEmpty)
    }
}
