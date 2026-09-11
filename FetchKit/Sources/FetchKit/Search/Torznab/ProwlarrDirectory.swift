import Foundation
import FetchPluginAPI

/**
 Asks a Prowlarr server which indexers it has.

 Prowlarr exposes Torznab **per indexer** (`/{id}/api`) and offers no
 aggregate — unlike Jackett's `/indexers/all/…`. Its own aggregate search
 lives on a different, non-Torznab API (`/api/v1/search`, JSON), which this
 app has no parser for. So the only way to make a pasted Prowlarr root
 usable is to enumerate its indexers and configure one Torznab provider per
 indexer, which is exactly the fan-out `SearchAggregator` already does.
 */
public enum ProwlarrDirectory {
    public struct Indexer: Sendable, Equatable {
        public let id: Int
        public let name: String

        /**
         This indexer's Torznab endpoint — the spec's documented
         `http://host:9696/{id}/api` shape.
         */
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

    private struct Payload: Decodable {
        let id: Int
        let name: String
        let enable: Bool?
    }

    /**
     Enabled indexers only, in the order Prowlarr returned them. A disabled
     indexer would answer every search with an error, so configuring one
     would only manufacture a permanent entry in the failure banner.
     */
    public static func discover(
        root: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol
    ) async throws -> [Indexer] {
        let endpoint = Endpoint(
            baseURL: root,
            path: "api/v1/indexer",
            queryItems: [URLQueryItem(name: "apikey", value: apiKey.exposedValue)],
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

/**
 Works out what to configure from whatever URL the user typed — the single
 entry point Settings calls.
 */
public enum IndexerSetup {
    public enum Plan: Sendable {
        case single(url: URL, capabilities: ProviderCapabilities)
        case prowlarr(root: URL, indexers: [ProwlarrDirectory.Indexer])
        case jackett(root: URL, indexers: [JackettDirectory.Indexer])
    }

    public static func plan(
        url: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol
    ) async throws -> Plan {
        guard TorznabEndpoint.isServiceRoot(url) else {
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

        do {
            let indexers = try await ProwlarrDirectory.discover(
                root: url, apiKey: apiKey, client: client)
            if !indexers.isEmpty { return .prowlarr(root: url, indexers: indexers) }
        } catch SearchError.unauthorized {
            throw SearchError.unauthorized
        } catch {
        }

        do {
            let indexers = try await JackettDirectory.discover(
                root: url, apiKey: apiKey, client: client)
            if !indexers.isEmpty {
                return .jackett(root: JackettDirectory.serviceRoot(of: url), indexers: indexers)
            }
        } catch SearchError.unauthorized {
            throw SearchError.unauthorized
        } catch {
        }

        let resolved = try await TorznabEndpointResolver.resolve(
            url: url, apiKey: apiKey, client: client)
        return .single(url: resolved.url, capabilities: resolved.capabilities)
    }
}
