import Testing
import FetchPluginAPI
@testable import FetchKit

@Suite struct HostSearchTests {
    private let hosts = [
        DebridHost(id: HostID(rawValue: "1fichier"), displayName: "1fichier",
                   domains: ["1fichier.com", "alterupload.com"]),
        DebridHost(id: HostID(rawValue: "rapidgator"), displayName: "Rapidgator",
                   domains: ["rapidgator.net"]),
        DebridHost(id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
                   domains: ["mediafire.com"], isActive: false),
    ]

    @Test func anEmptyQueryKeepsEverything() {
        #expect(HostSearch.filter(hosts, matching: "").count == 3)
        #expect(HostSearch.filter(hosts, matching: "   ").count == 3)
    }

    @Test func matchesOnDisplayNameCaseInsensitively() {
        #expect(HostSearch.filter(hosts, matching: "rapid").map(\.displayName) == ["Rapidgator"])
        #expect(HostSearch.filter(hosts, matching: "RAPID").map(\.displayName) == ["Rapidgator"])
    }

    @Test func matchesOnAnyDomain() {
        #expect(HostSearch.filter(hosts, matching: "alterupload").map(\.displayName)
            == ["1fichier"])
    }

    @Test func matchesAPastedURL() {
        #expect(HostSearch.filter(hosts, matching: "https://rapidgator.net/file/abc")
            .map(\.displayName) == ["Rapidgator"])
    }

    @Test func aQueryThatMatchesNothingReturnsNothing() {
        #expect(HostSearch.filter(hosts, matching: "zzzz").isEmpty)
    }

    @Test func orderIsPreserved() {
        #expect(HostSearch.filter(hosts, matching: "fi").map(\.displayName)
            == ["1fichier", "MediaFire"])
    }

    @Test func anInactiveHostIsStillFound() {
        #expect(HostSearch.filter(hosts, matching: "mediafire").map(\.isActive) == [false])
    }
}
