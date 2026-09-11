import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct PluginManifestTests {
    private func json(_ body: String) -> Data { Data(body.utf8) }


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


    @Test func declaredHostsAreCarried() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"namingStrategy","allowedHosts":["api.example.com"],
         "template":"{Title}"}
        """))
        #expect(manifest.allowedHosts == ["api.example.com"])
    }

    @Test func anIndexerPluginIsRefusedForNow() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"searchProvider","baseURL":"https://api.example.com/torznab"}
            """))
        }
    }

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
        #expect(!manifest.permits(host: "sub.api.example.com"))
    }
}

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

    @Test func oneMalformedManifestDisablesOnlyItself() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.good"), named: "a.good", in: root)
        write("{ this is not json", named: "a.bad", in: root)

        let outcome = PluginLoader.load(from: root)

        #expect(outcome.loaded.map(\.id) == ["a.good"])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.pluginID == "a.bad")
        #expect(outcome.failures.first?.reason.isEmpty == false)
    }

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
        #expect(outcome.failures.isEmpty)
    }

    @Test func aMissingPluginsDirectoryIsNotAnError() {
        let outcome = PluginLoader.load(
            from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(outcome.loaded.isEmpty)
        #expect(outcome.failures.isEmpty)
    }

    @Test func aDuplicateIDIsRefused() {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        write(naming("a.one"), named: "a.one", in: root)
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

@Suite struct PluginContainedFailureTests {
    private func json(_ body: String) -> Data { Data(body.utf8) }

    @Test func aTemplateWithNoTokensIsRefused() {
        #expect(throws: PluginError.self) {
            try PluginManifest.decode(json("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
             "kind":"namingStrategy","template":"my-download"}
            """))
        }
    }

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

    @Test func aNestedSubfolderIsAllowed() throws {
        let manifest = try PluginManifest.decode(json("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":1,
         "kind":"routingRule","subfolder":"TV/Anime"}
        """))
        #expect(manifest.subfolder == "TV/Anime")
    }
}
