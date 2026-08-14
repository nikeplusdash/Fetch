import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/// Tier-1 plugin manifests (§3) — a directory of JSON, no code execution.
///
/// These parse files a third party wrote, so malformed input is the common
/// case rather than the exceptional one. §3's containment rule is explicit: a
/// bad plugin is disabled and surfaces an error; core functionality degrades
/// and never crashes.
@Suite struct PluginManifestTests {
    private func json(_ body: String) -> Data { Data(body.utf8) }

    // MARK: - Valid manifests

    /// The spec's own worked example (§3, Tier 1).
    @Test func theSpecsExampleManifestLoads() throws {
        let manifest = try PluginManifest.decode(json("""
        {
          "id": "dev.fetch.anime-naming",
          "name": "Anime naming",
          "version": "1.0.0",
          "apiVersion": 1,
          "kind": "namingStrategy",
          "match": { "mediaKind": "anime" },
          "template": "{Title}/{Title} - {Absolute:000} [{ReleaseGroup}]"
        }
        """))

        #expect(manifest.id == "dev.fetch.anime-naming")
        #expect(manifest.kind == .namingStrategy)
        #expect(manifest.match?.mediaKind == .anime)
    }

    @Test func aRoutingRuleManifestLoads() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"4K","version":"1.0.0","apiVersion":1,
         "kind":"routingRule","match":{"resolution":"2160p"},"subfolder":"4K"}
        """))

        #expect(manifest.kind == .routingRule)
        #expect(manifest.subfolder == "4K")
    }

    // MARK: - Rejection

    /// An apiVersion the app does not implement must be refused rather than
    /// interpreted optimistically — the whole point of versioning the boundary.
    @Test func aFutureAPIVersionIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":99,
             "kind":"namingStrategy","template":"{Title}"}
            """))
        }
    }

    @Test func anUnknownKindIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"mineBitcoin","template":"x"}
            """))
        }
    }

    /// Kind-specific requirements: a naming strategy without a template
    /// declares itself and then does nothing.
    @Test func aNamingStrategyWithoutATemplateIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"namingStrategy"}
            """))
        }
    }

    @Test func aRoutingRuleWithoutASubfolderIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"routingRule","match":{"mediaKind":"movie"}}
            """))
        }
    }

    @Test func anEmptyIDIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"namingStrategy","template":"{Title}"}
            """))
        }
    }

    @Test func garbageIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("not json at all"))
        }
    }

    // MARK: - Permissions

    /// §3 rule 4: a plugin declares the hosts it may reach, and the client
    /// enforces it rather than trusting the plugin.
    @Test func declaredHostsAreCarried() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"namingStrategy","allowedHosts":["api.example.com"],
         "template":"{Title}"}
        """))
        #expect(manifest.allowedHosts == ["api.example.com"])
    }

    /// An indexer plugin needs an API key the user supplies, so it would be a
    /// preset rather than a working source. Refused for now rather than
    /// loaded and ignored — a Settings row saying "may reach api.example.com"
    /// beside rows that do something reads as working.
    @Test func anIndexerPluginIsRefusedForNow() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"searchProvider","baseURL":"https://api.example.com/torznab"}
            """))
        }
    }

    /// Declaring no hosts means no network, not unrestricted network. A
    /// default-open permission model would make the declaration pointless.
    @Test func anAbsentHostListMeansNoNetworkAccess() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"namingStrategy","template":"{Title}"}
        """))
        #expect(manifest.allowedHosts?.isEmpty ?? true)
        #expect(!manifest.permits(host: "evil.example.com"))
    }

    @Test func onlyDeclaredHostsArePermitted() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"namingStrategy","allowedHosts":["api.example.com"],
         "template":"{Title}"}
        """))

        #expect(manifest.permits(host: "api.example.com"))
        #expect(manifest.permits(host: "API.EXAMPLE.COM"), "hosts are case-insensitive")
        #expect(!manifest.permits(host: "evil.example.com"))
        // A declared host must not imply its subdomains — "example.com" in a
        // manifest cannot silently authorise "evil.example.com".
        #expect(!manifest.permits(host: "sub.api.example.com"))
    }
}

/// Loading a directory of plugins.
///
/// The acceptance criterion §15 states: "a malformed manifest disables that
/// plugin alone and surfaces an error." One bad file must not cost the user
/// their other plugins.
@Suite struct PluginLoaderTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugins-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ body: String, named id: String, in root: URL) {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(body.utf8).write(to: dir.appendingPathComponent("manifest.json"))
    }

    private func naming(_ id: String) -> String {
        """
        {"id":"\(id)","name":"\(id)","version":"1.0.0","apiVersion":1,
         "kind":"namingStrategy","template":"{Title}"}
        """
    }

    @Test func pluginsAreLoadedFromTheirDirectories() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.one"), named: "a.one", in: root)
        write(naming("a.two"), named: "a.two", in: root)

        let outcome = PluginLoader.load(from: root)
        #expect(outcome.loaded.count == 2)
        #expect(outcome.failures.isEmpty)
    }

    /// The acceptance criterion, directly.
    @Test func oneMalformedManifestDisablesOnlyItself() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.good"), named: "a.good", in: root)
        write("{ this is not json", named: "a.bad", in: root)

        let outcome = PluginLoader.load(from: root)

        #expect(outcome.loaded.map(\.id) == ["a.good"])
        #expect(outcome.failures.count == 1)
        // The failure names the plugin, or the user cannot tell which of their
        // plugins is broken.
        #expect(outcome.failures.first?.pluginID == "a.bad")
        #expect(outcome.failures.first?.reason.isEmpty == false)
    }

    /// A directory whose manifest id disagrees with its folder is refused: the
    /// folder name is how a user identifies a plugin to remove it.
    @Test func aManifestDisagreeingWithItsFolderIsRefused() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.actual"), named: "a.folder", in: root)

        let outcome = PluginLoader.load(from: root)
        #expect(outcome.loaded.isEmpty)
        #expect(outcome.failures.count == 1)
    }

    @Test func aDirectoryWithNoManifestIsSkippedQuietly() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let outcome = PluginLoader.load(from: root)
        #expect(outcome.loaded.isEmpty)
        // Not a failure worth reporting — an empty folder is not a broken
        // plugin, and reporting it would train the user to ignore the banner.
        #expect(outcome.failures.isEmpty)
    }

    @Test func aMissingPluginsDirectoryIsNotAnError() {
        let outcome = PluginLoader.load(
            from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(outcome.loaded.isEmpty)
        #expect(outcome.failures.isEmpty)
    }

    /// Two plugins claiming the same id: the second is refused rather than
    /// silently replacing the first.
    @Test func aDuplicateIDIsRefused() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.one"), named: "a.one", in: root)
        // Same declared id, different folder.
        write(
            """
            {"id":"a.one","name":"clash","version":"2.0.0","apiVersion":1,
             "kind":"namingStrategy","template":"{Title}"}
            """,
            named: "a.clash", in: root)

        let outcome = PluginLoader.load(from: root)
        #expect(outcome.loaded.count == 1)
        #expect(outcome.failures.count == 1)
    }
}

/// §3 rule 5, contained failure, for Tier 1.
///
/// Nothing executes here, so "misbehaving" cannot mean hanging or crashing —
/// it means producing a **bad value**. The two that matter are a template that
/// renders nothing and a subfolder that escapes the download directory; both
/// are caught at load rather than at the moment a file is being written, when
/// the user is watching a download and cannot act on it.
@Suite struct PluginContainedFailureTests {
    private func json(_ body: String) -> Data { Data(body.utf8) }

    /// A template with no tokens renders the same constant path for every
    /// release, so every download in a season would overwrite the last one.
    @Test func aTemplateWithNoTokensIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"namingStrategy","template":"my-download"}
            """))
        }
    }

    /// A subfolder of `../..` would file downloads outside the directory the
    /// user chose — the one place a declarative plugin can still reach out of
    /// its box.
    @Test func aSubfolderEscapingTheDownloadDirectoryIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"routingRule","subfolder":"../../../etc"}
            """))
        }
    }

    @Test func anAbsoluteSubfolderIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"routingRule","subfolder":"/Users/someone/Desktop"}
            """))
        }
    }

    /// Nested subfolders are legitimate — "TV/Anime" is a reasonable rule, and
    /// the escape check must not cost the user that.
    @Test func aNestedSubfolderIsAllowed() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"routingRule","subfolder":"TV/Anime"}
        """))
        #expect(manifest.subfolder == "TV/Anime")
    }
}
