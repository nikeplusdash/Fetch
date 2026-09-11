import Testing
import Foundation
@testable import FetchKit

@Suite struct RedactedTests {
    @Test func descriptionHidesValue() {
        let secret = Redacted("sk-live-abcdef123456")
        #expect("\(secret)" == "<redacted>")
        #expect(secret.debugDescription == "<redacted>")
    }

    @Test func valueIsStillReachableDeliberately() {
        #expect(Redacted("abc").exposedValue == "abc")
    }

    @Test func interpolationIntoAStringDoesNotLeak() {
        let message = "key=\(Redacted("supersecret"))"
        #expect(!message.contains("supersecret"))
    }

    @Test func dumpDoesNotLeak() {
        let secret = Redacted("sk-live-abcdef123456")
        var output = ""
        dump(secret, to: &output)
        #expect(!output.contains("sk-live-abcdef123456"))
    }

    @Test func dumpOfContainingStructDoesNotLeak() {
        struct Holder {
            let key: Redacted<String>
            let name: String
        }
        let holder = Holder(key: Redacted("sk-live-abcdef123456"), name: "torbox")
        var output = ""
        dump(holder, to: &output)
        #expect(!output.contains("sk-live-abcdef123456"))
    }

    @Test func mirrorExposesNoChildren() {
        let mirror = Mirror(reflecting: Redacted("sk-live-abcdef123456"))
        #expect(mirror.children.isEmpty)
    }
}
