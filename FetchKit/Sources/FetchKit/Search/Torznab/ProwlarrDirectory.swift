import Foundation
import FetchPluginAPI

/// Asks a Prowlarr server which indexers it has.
///
/// Prowlarr exposes Torznab **per indexer** (`/{id}/api`) and offers no
/// aggregate — unlike Jackett's `/indexers/all/…`. Its own aggregate search
/// lives on a different, non-Torznab API (`/api/v1/search`, JSON), which this
/// app has no parser for. So the only way to make a pasted Prowlarr root
/// usable is to enumerate its indexers and configure one Torznab provider per
/// indexer, which is exactly the fan-out `SearchAggregator` already does.
public enum ProwlarrDirectory {
    public struct Indexer: Sendable, Equatable {
        public let id: Int
        public let name: String

        /// This indexer's Torznab endpoint — the spec's documented
        /// `http://host:9696/{id}/api` shape.
        public func torznabURL(root: URL) -> URL {
            var base = root
            if base.path.hasSuffix("/"), var components = URLComponents(
                url: base, resolvingAgainstBaseURL: false
            ) {
                components.path = String(components.path.dropLast())
                base = components.url ?? base
            }
            return base.appendingPathComponent("\(id)/api")
        }
    }

    /// Only the fields this app uses. Prowlarr sends ~30 more per indexer;
    /// `Decodable` ignores the rest, so a Prowlarr upgrade adding fields
    /// cannot break discovery.
    private struct Payload: Decodable {
        let id: Int
        let name: String
        let enable: Bool?
    }

    /// Enabled indexers only, in the order Prowlarr returned them. A disabled
    /// indexer would answer every search with an error, so configuring one
    /// would only manufacture a permanent entry in the failure banner.
    public static func discover(
        root: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol
    ) async throws -> [Indexer] {
        let endpoint = Endpoint(
            baseURL: root,
            path: "api/v1/indexer",
            queryItems: [URLQueryItem(name: "apikey", value: apiKey.exposedValue)],
            // A 404 here is the expected answer from Jackett, and the caller
            // treats it as "not Prowlarr" — retrying it would only add delay
            // to the common fallback path.
            isRetryable: false
        )

        do {
            let payloads = try await client.send(endpoint, as: [Payload].self)
            return payloads
                .filter { $0.enable ?? true }
                .map { Indexer(id: $0.id, name: $0.name) }
        } catch let error as NetworkError {
            throw TorznabProvider.mapNetworkError(error)
        }
    }
}

/// Works out what to configure from whatever URL the user typed — the single
/// entry point Settings calls.
public enum IndexerSetup {
    public enum Plan: Sendable {
        /// One Torznab endpoint, already verified by `t=caps`.
        case single(url: URL, capabilities: ProviderCapabilities)
        /// A Prowlarr server: one endpoint per discovered indexer.
        case prowlarr(root: URL, indexers: [ProwlarrDirectory.Indexer])
        /// A Jackett server: one endpoint per configured indexer, rather than
        /// the single aggregate that used to stand in for all of them.
        case jackett(root: URL, indexers: [JackettDirectory.Indexer])
    }

    public static func plan(
        url: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol
    ) async throws -> Plan {
        // A complete endpoint is taken at its word — including a Prowlarr
        // per-indexer URL the user copied themselves.
        guard TorznabEndpoint.isServiceRoot(url) else {
            // **Except the Jackett aggregate, which is a complete endpoint and
            // also eleven indexers.** Every Jackett configured before discovery
            // existed is stored as exactly this URL, so a plan that took it at
            // its word could never split one apart — the user would have to
            // delete the server and re-add it by host to get their trackers
            // listed. `t=indexers` costs 52ms and settles it.
            if JackettDirectory.isJackettShaped(url),
               let indexers = try? await JackettDirectory.discover(
                   root: url, apiKey: apiKey, client: client),
               !indexers.isEmpty
            {
                return .jackett(root: JackettDirectory.serviceRoot(of: url), indexers: indexers)
            }
            let resolved = try await TorznabEndpointResolver.resolve(
                url: url, apiKey: apiKey, client: client)
            return .single(url: resolved.url, capabilities: resolved.capabilities)
        }

        // Discovery first: it is one request and definitive. Only Prowlarr
        // answers `/api/v1/indexer` with a JSON array; Jackett 404s.
        do {
            let indexers = try await ProwlarrDirectory.discover(
                root: url, apiKey: apiKey, client: client)
            if !indexers.isEmpty { return .prowlarr(root: url, indexers: indexers) }
        } catch SearchError.unauthorized {
            // Authoritative, and identical on every other path — surface it
            // rather than reporting a bad URL for what is a bad key.
            throw SearchError.unauthorized
        } catch {
            // Not a Prowlarr server (or it has no indexers). Fall through.
        }

        // Then Jackett, by the same logic and at the same cost: one request,
        // definitive, and it answers with the roster rather than with the
        // aggregate that hides it.
        do {
            let indexers = try await JackettDirectory.discover(
                root: url, apiKey: apiKey, client: client)
            if !indexers.isEmpty {
                return .jackett(root: JackettDirectory.serviceRoot(of: url), indexers: indexers)
            }
        } catch SearchError.unauthorized {
            throw SearchError.unauthorized
        } catch {
            // Not a Jackett server either. Fall through to the single endpoint
            // path, which is still right for a bare Torznab implementation.
        }

        let resolved = try await TorznabEndpointResolver.resolve(
            url: url, apiKey: apiKey, client: client)
        return .single(url: resolved.url, capabilities: resolved.capabilities)
    }
}
