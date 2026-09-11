import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

@Suite struct PluginRegistryTests {
    private func manifest(
        id: String, kind: ExtensionKind, template: String? = nil,
        subfolder: String? = nil, match: RoutingRule.Match? = nil
    ) throws -> PluginManifest {
        var fields: [String] = [
            "\"id\":\"\(id)\"", "\"name\":\"\(id)\"", "\"version\":\"1.0.0\"",
            "\"apiVersion\":\(currentAPIVersion)", "\"kind\":\"\(kind.rawValue)\"",
        ]
        if let template { fields.append("\"template\":\"\(template)\"") }
        if let subfolder { fields.append("\"subfolder\":\"\(subfolder)\"") }
        if let kind = match?.mediaKind {
            let encoded = String(
                data: try JSONEncoder().encode([kind]), encoding: .utf8)!
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]\""))
            fields.append("\"match\":{\"mediaKind\":\"\(encoded)\"}")
        }
        return try PluginManifest.decode(Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func tvMetadata() -> ReleaseMetadata {
        var m = ReleaseMetadata.unparsed
        m.mediaKind = .tv
        m.title = "The Expanse"
        m.season = 3
        m.episodes = [5]
        m.provenance = [.title: .titleParse, .season: .titleParse, .episodes: .titleParse]
        return m
    }


    @Test func anEmptyRegistryChangesNothing() {
        let registry = PluginRegistry(plugins: [])

        #expect(registry.routingRules(builtIn: RoutingRule.defaults) == RoutingRule.defaults)
        #expect(registry.namingTemplate(for: .tv, builtIn: "{Title}") == "{Title}")
    }


    @Test func aNamingPluginOverridesTheBuiltInTemplate() throws {
        let registry = PluginRegistry(plugins: [
            try manifest(id: "a.anime", kind: .namingStrategy,
                         template: "{Title} EP{Episode:00}", match: .init(mediaKind: .tv))
        ])

        #expect(registry.namingTemplate(for: .tv, builtIn: "{Title}") == "{Title} EP{Episode:00}")
        #expect(registry.namingTemplate(for: .movie, builtIn: "{Title}") == "{Title}")
    }

    @Test func thePluginTemplateChangesTheRenderedPath() throws {
        let registry = PluginRegistry(plugins: [
            try manifest(id: "a.flat", kind: .namingStrategy,
                         template: "{Title} S{Season:00}E{Episode:00}",
                         match: .init(mediaKind: .tv))
        ])
        let strategy = NamingStrategy.template(
            registry.namingTemplate(for: .tv, builtIn: NamingStrategy.defaultTemplate(for: .tv)))

        #expect(strategy.relativePath(for: tvMetadata(), originalFilename: "raw.mkv")
                == "The Expanse S03E05.mkv")
    }

    @Test func anUnmatchedNamingPluginAppliesEverywhere() throws {
        let registry = PluginRegistry(plugins: [
            try manifest(id: "a.all", kind: .namingStrategy, template: "{Title}")
        ])
        #expect(registry.namingTemplate(for: .movie, builtIn: "x") == "{Title}")
        #expect(registry.namingTemplate(for: .book, builtIn: "x") == "{Title}")
    }


    @Test func pluginRoutingRulesRunAfterTheUsersOwn() throws {
        let userRules = [RoutingRule(match: .init(mediaKind: .tv), subfolder: "My TV")]
        let registry = PluginRegistry(plugins: [
            try manifest(id: "a.tv", kind: .routingRule,
                         subfolder: "Plugin TV", match: .init(mediaKind: .tv))
        ])

        let combined = registry.routingRules(builtIn: userRules)
        #expect(Routing.subfolder(for: tvMetadata(), rules: combined) == "My TV")
        #expect(combined.count == 2, "the plugin rule is present, just lower")
    }

    @Test func aPluginRuleAppliesWhereNoUserRuleMatches() throws {
        let registry = PluginRegistry(plugins: [
            try manifest(id: "a.anime", kind: .routingRule,
                         subfolder: "Anime", match: .init(mediaKind: .anime))
        ])
        var anime = ReleaseMetadata.unparsed
        anime.mediaKind = .anime

        #expect(Routing.subfolder(for: anime, rules: registry.routingRules(builtIn: [])) == "Anime")
    }


    @Test func aDisabledPluginContributesNothing() throws {
        var registry = PluginRegistry(plugins: [
            try manifest(id: "a.one", kind: .namingStrategy, template: "{Title} one"),
        ])
        registry.disable("a.one", reason: "timed out")

        #expect(registry.namingTemplate(for: .movie, builtIn: "built-in") == "built-in")
        #expect(registry.disabledReasons["a.one"] == "timed out")
    }

    @Test func disablingOnePluginLeavesTheOthers() throws {
        var registry = PluginRegistry(plugins: [
            try manifest(id: "a.bad", kind: .routingRule,
                         subfolder: "Bad", match: .init(mediaKind: .movie)),
            try manifest(id: "a.good", kind: .routingRule,
                         subfolder: "Good", match: .init(mediaKind: .anime)),
        ])
        registry.disable("a.bad", reason: "threw")

        var anime = ReleaseMetadata.unparsed
        anime.mediaKind = .anime
        #expect(Routing.subfolder(for: anime, rules: registry.routingRules(builtIn: [])) == "Good")
    }


    @Test func aHostIsPermittedOnlyByThePluginThatDeclaredIt() throws {
        let allowed = try PluginManifest.decode(Data("""
        {"id":"a.b","name":"n","version":"1.0.0","apiVersion":\(currentAPIVersion),
         "kind":"namingStrategy","allowedHosts":["api.example.com"],
         "template":"{Title}"}
        """.utf8))
        let registry = PluginRegistry(plugins: [allowed])

        #expect(registry.permits(host: "api.example.com", forPlugin: "a.b"))
        #expect(!registry.permits(host: "evil.example.com", forPlugin: "a.b"))
        #expect(!registry.permits(host: "api.example.com", forPlugin: "ghost"))
    }

    @Test func aDisabledPluginLosesItsHostPermissions() throws {
        var registry = PluginRegistry(plugins: [
            try PluginManifest.decode(Data("""
            {"id":"a.b","name":"n","version":"1.0.0","apiVersion":\(currentAPIVersion),
             "kind":"namingStrategy","allowedHosts":["api.example.com"],
             "template":"{Title}"}
            """.utf8))
        ])
        registry.disable("a.b", reason: "misbehaved")

        #expect(!registry.permits(host: "api.example.com", forPlugin: "a.b"))
    }
}
