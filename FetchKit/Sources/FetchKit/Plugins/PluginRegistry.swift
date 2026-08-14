import Foundation
import FetchPluginAPI

/// Where every extensible capability is resolved (§3, the dogfooding rule).
///
/// The architectural claim this exists to test: if the seams were drawn
/// correctly, routing every capability through the registry should be a
/// **no-op** when no plugins are installed. `PluginRegistryTests` asserts that
/// first, before anything else — an empty registry must behave exactly as the
/// built-ins did alone.
///
/// Tier 1 only, and deliberately so: these manifests are data, nothing
/// executes, and the contained-failure rule (§3 rule 5) is therefore about a
/// plugin producing a bad *value* rather than crashing the app.
public struct PluginRegistry: Sendable, Equatable {
    public private(set) var plugins: [PluginManifest]
    /// Why each disabled plugin was disabled, for the management UI to show.
    /// §3 rule 5 requires the reason be surfaced, not just the state.
    public private(set) var disabledReasons: [String: String] = [:]

    public init(plugins: [PluginManifest]) {
        self.plugins = plugins
    }

    /// Disables one plugin for the session (§3 rule 5).
    ///
    /// Per plugin, never global: one misbehaving extension must not cost the
    /// user the rest of theirs.
    public mutating func disable(_ id: String, reason: String) {
        disabledReasons[id] = reason
    }

    public func isEnabled(_ id: String) -> Bool { disabledReasons[id] == nil }

    private var active: [PluginManifest] {
        plugins.filter { isEnabled($0.id) }
    }

    // MARK: - Naming

    /// The template to use for `kind`, or the built-in when no plugin claims it.
    ///
    /// A manifest with no `match` applies to every kind; one with a `match`
    /// applies only where it matches, so a plugin cannot accidentally take over
    /// media kinds it never mentioned.
    public func namingTemplate(for kind: MediaKind, builtIn: String) -> String {
        var probe = ReleaseMetadata.unparsed
        probe.mediaKind = kind

        let claimant = active.first { manifest in
            manifest.kind == .namingStrategy
                && (manifest.match?.matches(probe) ?? true)
        }
        return claimant?.template ?? builtIn
    }

    // MARK: - Routing

    /// The user's rules followed by any plugin rules.
    ///
    /// Order is the whole semantics here — first match wins — so plugin rules
    /// sit **after** the user's own and can only fill gaps, never pre-empt a
    /// choice the user made explicitly. §3 rule 6 says extensions must not
    /// depend on registration order; where order matters it is user-facing
    /// configuration, which is exactly what this preserves.
    public func routingRules(builtIn: [RoutingRule]) -> [RoutingRule] {
        builtIn + active.compactMap { manifest in
            guard manifest.kind == .routingRule, let subfolder = manifest.subfolder
            else { return nil }
            return RoutingRule(match: manifest.match ?? .init(), subfolder: subfolder)
        }
    }

    // MARK: - Permissions

    /// Whether `pluginID` may reach `host` (§3 rule 4).
    ///
    /// An unknown plugin has declared nothing and is therefore permitted
    /// nothing; a disabled one loses its permissions along with its
    /// contributions, so a plugin disabled for misbehaving cannot keep making
    /// requests.
    public func permits(host: String, forPlugin pluginID: String) -> Bool {
        guard isEnabled(pluginID),
              let manifest = plugins.first(where: { $0.id == pluginID })
        else { return false }
        return manifest.permits(host: host)
    }
}
