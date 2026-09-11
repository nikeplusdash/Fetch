import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct PastedLinkTests {
    private let mediafire = DebridHost(
        id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
        domains: ["mediafire.com"], isActive: true)
    private var mediafireDown: DebridHost {
        DebridHost(
            id: HostID(rawValue: "mediafire"), displayName: "MediaFire",
            domains: ["mediafire.com"], isActive: false)
    }

    private let torbox = DebridProviderID(rawValue: "torbox")

    private func resolve(
        _ text: String, coverage: [DebridProviderID: [DebridHost]] = [:],
        configured: [DebridProviderID] = [DebridProviderID(rawValue: "torbox")]
    ) -> PastedLink {
        PastedLink.resolve(text, configured: configured, coverage: coverage)
    }


    @Test func aMagnetIsStillAMagnet() {
        let hash = String(repeating: "ab", count: 20)
        let resolution = resolve("magnet:?xt=urn:btih:\(hash)")

        guard case .magnet(let link) = resolution else {
            Issue.record("expected a magnet, got \(resolution)")
            return
        }
        #expect(link.infoHash.hex == hash)
    }

    @Test func aMagnetSurroundedByWhitespaceStillParses() {
        let hash = String(repeating: "ab", count: 20)
        if case .magnet = resolve("  magnet:?xt=urn:btih:\(hash)\n") { return }
        Issue.record("whitespace broke magnet parsing")
    }


    @Test func aCoveredHostResolvesToTheProviderThatCoversIt() {
        let resolution = resolve(
            "https://www.mediafire.com/file/abc/movie.mkv",
            coverage: [torbox: [mediafire]])

        guard case .hosted(_, let host, let provider) = resolution else {
            Issue.record("expected hosted, got \(resolution)")
            return
        }
        #expect(host.id == HostID(rawValue: "mediafire"))
        #expect(provider == torbox)
    }

    @Test func anUncoveredHostReportsTheHostName() {
        let resolution = resolve(
            "https://somerandomhost.com/x", coverage: [torbox: [mediafire]])

        guard case .unsupportedHost(_, let hostName) = resolution else {
            Issue.record("expected unsupportedHost, got \(resolution)")
            return
        }
        #expect(hostName == "somerandomhost.com")
    }

    @Test func aCoveredButDownHostIsItsOwnAnswer() {
        let resolution = resolve(
            "https://mediafire.com/file/x", coverage: [torbox: [mediafireDown]])

        guard case .hostDown(_, let host) = resolution else {
            Issue.record("expected hostDown, got \(resolution)")
            return
        }
        #expect(host.displayName == "MediaFire")
    }

    @Test func withNoDebridConfiguredItSaysSo() {
        let resolution = resolve("https://mediafire.com/file/x", configured: [])

        guard case .noDebridConfigured = resolution else {
            Issue.record("expected noDebridConfigured, got \(resolution)")
            return
        }
    }

    @Test func coverageNotYetLoadedIsNotARefusal() {
        let resolution = resolve("https://mediafire.com/file/x", coverage: [:])

        guard case .checkingCoverage = resolution else {
            Issue.record("expected checkingCoverage, got \(resolution)")
            return
        }
    }


    @Test func somethingThatIsNeitherIsInvalid() {
        guard case .invalid = resolve("hello world") else {
            Issue.record("expected invalid")
            return
        }
    }

    @Test func anEmptyFieldIsEmptyNotInvalid() {
        guard case .empty = resolve("   ") else {
            Issue.record("expected empty")
            return
        }
    }

    @Test func aNonHTTPURLIsInvalid() {
        guard case .invalid = resolve(
            "file:///etc/passwd", coverage: [torbox: [mediafire]]) else {
            Issue.record("a file: URL must never resolve to a download")
            return
        }
    }

    @Test func amongCoveringProvidersTheFirstConfiguredWins() {
        let first = DebridProviderID(rawValue: "first")
        let second = DebridProviderID(rawValue: "second")
        let resolution = resolve(
            "https://mediafire.com/file/x",
            coverage: [first: [mediafire], second: [mediafire]],
            configured: [first, second])

        guard case .hosted(_, _, let provider) = resolution else {
            Issue.record("expected hosted, got \(resolution)")
            return
        }
        #expect(provider == first)
    }
}
