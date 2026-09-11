import Testing
import Foundation
@testable import FetchKit

@Suite struct GutenbergLanguagesTests {
    @Test func regionalTagsReduceToISO639_1() {
        #expect(GutenbergLanguages.codes(from: ["en-US", "fr-CA"]) == ["en", "fr"])
    }

    @Test func duplicatesCollapseAndOrderIsPreserved() {
        #expect(GutenbergLanguages.codes(from: ["en-GB", "hi-IN", "en-US"]) == ["en", "hi"])
    }

    @Test func scriptSubtagsAreDropped() {
        #expect(GutenbergLanguages.codes(from: ["zh-Hans-CN"]) == ["zh"])
    }

    @Test func nothingUsableYieldsNoCodesRatherThanAnEmptyFilter() {
        #expect(GutenbergLanguages.codes(from: []).isEmpty)
        #expect(GutenbergLanguages.codes(from: ["", "   "]).isEmpty)
    }
}
