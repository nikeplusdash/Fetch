import Foundation
import FetchPluginAPI

/**
 Probes the candidates `TorznabEndpoint` derives from a user-typed URL and
 keeps the first that answers with a real `<caps>` document.

 Resolution happens **once**, when the endpoint is tested or saved, and the
 resolved URL is what gets persisted — so searching stays a single request
 per provider and no probe cost is paid per query.
 */
public enum TorznabEndpointResolver {
    public struct Resolved: Sendable {
        public let url: URL
        public let capabilities: ProviderCapabilities
    }

    public static func resolve(
        url: URL,
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol
    ) async throws -> Resolved {
        let candidates = TorznabEndpoint.candidates(for: url)
        var tried: [String] = []
        var transportFailure: SearchError?

        for candidate in candidates {
            tried.append(candidate.absoluteString)
            let provider = TorznabProvider(
                id: SearchProviderID(rawValue: "endpoint-probe"),
                displayName: "probe",
                baseURL: candidate,
                apiKey: apiKey,
                client: client
            )

            do {
                return Resolved(url: candidate, capabilities: try await provider.capabilities())
            } catch SearchError.unauthorized {
                throw SearchError.unauthorized
            } catch let error as SearchError {
                if case .network(.transport) = error, transportFailure == nil {
                    transportFailure = error
                }
                continue
            } catch {
                continue
            }
        }

        if let transportFailure { throw transportFailure }
        throw SearchError.notATorznabEndpoint(tried: tried)
    }
}
