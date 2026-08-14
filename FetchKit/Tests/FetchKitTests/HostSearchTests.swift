import Testing
import FetchPluginAPI
@testable import FetchKit

/// Finding one host among hundreds.
///
/// A debrid reports its whole catalogue — Premiumize and TorBox each list
/// several hundred — so the useful question is never "show me all of them",
/// it is "is this one covered?".
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

    /// The name a user types is usually the domain from the link they are
    /// holding, not the provider's display name — and the two differ often
    /// enough to matter: `alterupload.com` is served by "1fichier".
    @Test func matchesOnAnyDomain() {
        #expect(HostSearch.filter(hosts, matching: "alterupload").map(\.displayName)
            == ["1fichier"])
    }

    /// A pasted URL is what the user has in hand. Typing the whole thing
    /// should find the host rather than matching nothing.
    @Test func matchesAPastedURL() {
        #expect(HostSearch.filter(hosts, matching: "https://rapidgator.net/file/abc")
            .map(\.displayName) == ["Rapidgator"])
    }

    @Test func aQueryThatMatchesNothingReturnsNothing() {
        #expect(HostSearch.filter(hosts, matching: "zzzz").isEmpty)
    }

    /// Order is the provider's own. Re-sorting a filtered list would make the
    /// same host appear in a different place depending on what was typed.
    ///
    /// `fi` rather than a single letter on purpose: domains are searched too,
    /// so a needle like `e` matches every `.net` and proves nothing about
    /// ordering.
    @Test func orderIsPreserved() {
        #expect(HostSearch.filter(hosts, matching: "fi").map(\.displayName)
            == ["1fichier", "MediaFire"])
    }

    /// A host reported down is still a host the service covers — hiding it
    /// would answer "is this covered?" with "no" when the true answer is
    /// "yes, but not right now".
    @Test func anInactiveHostIsStillFound() {
        #expect(HostSearch.filter(hosts, matching: "mediafire").map(\.isActive) == [false])
    }
}
