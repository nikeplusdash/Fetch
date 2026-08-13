import Foundation
import FetchPluginAPI

/// Folds the flat `[SearchProviderConfig]` list into servers.
///
/// **This reads and never deletes.** The caller writes the result under a new
/// defaults key and leaves the old one in place, so rolling back to a previous
/// build finds its data intact. Two data-loss incidents on 2026-08-01 — a
/// credential store switch and a bundle-identifier change that moved the
/// UserDefaults domain — both stranded live user state by writing somewhere new
/// and never reading the old location again.
public enum IndexerServerMigration {
    /// Folds the legacy configs and moves each server's API key from its N
    /// per-indexer credential entries to a single per-server entry.
    ///
    /// The legacy entries are read and left alone. They become unreferenced,
    /// which Settings § Search surfaces as an explicit "Remove unused keys"
    /// action rather than deleting them as an invisible side effect of launch.
    public static func migrate(
        legacy: [SearchProviderConfig], credentials: any CredentialStore
    ) -> [IndexerServerConfig] {
        let servers = fold(legacy)
        for server in servers {
            // Not every indexer necessarily has a key — a legacy fan-out that
            // failed partway through leaves some without. Take the first that
            // does rather than giving up on the whole server.
            let existing = server.indexers.lazy
                .compactMap { try? credentials.read(for: account(for: $0.id)) }
                .first { !$0.isEmpty }
            guard let existing else { continue }
            try? credentials.store(existing, for: account(for: server.id))
        }
        return servers
    }

    static func account(for id: SearchProviderID) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: id.rawValue)
    }

    static func account(for id: IndexerServerID) -> CredentialAccount {
        CredentialAccount(layer: "search", providerID: id.rawValue)
    }

    /// Groups by endpoint origin (scheme + host + port), because the URL is
    /// authoritative and the display name is whatever the user typed. Two
    /// indexers on one Prowlarr can carry disagreeing name prefixes; they are
    /// still one server.
    ///
    /// Order follows the input, so the settings list matches what was there
    /// rather than reshuffling on each launch with dictionary iteration order.
    public static func fold(_ legacy: [SearchProviderConfig]) -> [IndexerServerConfig] {
        var groups: [String: [SearchProviderConfig]] = [:]
        var order: [String] = []

        for config in legacy {
            let key = origin(of: config.baseURL)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(config)
        }

        return order.compactMap { key in
            guard let members = groups[key], let first = members.first else { return nil }
            return server(origin: key, members: members, root: first.baseURL)
        }
    }

    private static func server(
        origin key: String, members: [SearchProviderConfig], root: URL
    ) -> IndexerServerConfig {
        let names = members.map { split($0.displayName) }

        // The server name is the prefix shared by the members that have one.
        // Falling back to the first member's whole name covers the standalone
        // endpoint, whose name has no separator to split on.
        let serverName = names.compactMap(\.server).first ?? names[0].indexer

        let indexers = zip(members, names).map { config, name in
            SubIndexer(
                // Keeping the legacy id is not cosmetic: credentials are stored
                // under it, so a fresh id would strand every key — precisely the
                // failure this migration exists to avoid repeating.
                id: config.id,
                name: name.indexer,
                torznabURL: config.baseURL,
                isEnabled: config.isEnabled
            )
        }

        return IndexerServerConfig(
            id: IndexerServerID(rawValue: key),
            displayName: serverName,
            rootURL: URL(string: key) ?? root,
            // The legacy model had no server-level flag. Inventing "off" here —
            // say, because every indexer happens to be disabled — would silently
            // kill a working setup on upgrade.
            isEnabled: true,
            indexers: indexers
        )
    }

    /// `"Prowlarr — The Pirate Bay"` → server `"Prowlarr"`, indexer `"The Pirate
    /// Bay"`. A name without the separator is a standalone endpoint, and is its
    /// own indexer name.
    static func split(_ displayName: String) -> (server: String?, indexer: String) {
        guard let range = displayName.range(of: " — ") else {
            return (nil, displayName)
        }
        let server = String(displayName[displayName.startIndex..<range.lowerBound])
        let indexer = String(displayName[range.upperBound...])
        return (
            server.trimmingCharacters(in: .whitespaces),
            indexer.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Scheme, host and port — the identity of a server, with the per-indexer
    /// path (`/6/api`) dropped.
    static func origin(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}
