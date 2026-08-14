import Foundation
import FetchPluginAPI

/// Probes the candidates `TorznabEndpoint` derives from a user-typed URL and
/// keeps the first that answers with a real `<caps>` document.
///
/// Resolution happens **once**, when the endpoint is tested or saved, and the
/// resolved URL is what gets persisted — so searching stays a single request
/// per provider and no probe cost is paid per query.
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
        /// Kept so a host that never answered is not reported as a wrong path.
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
                // A rejected key is authoritative and identical on every
                // candidate — trying the rest would only repeat it, and
                // reporting "bad URL" would send the user to fix the one
                // thing that is probably right.
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

        // Every candidate failing at the transport layer means nothing was
        // reached to judge — saying "that URL is the web UI" would be a guess
        // about a server that never answered, and points the user at the one
        // thing that may well be correct.
        if let transportFailure { throw transportFailure }
        throw SearchError.notATorznabEndpoint(tried: tried)
    }
}
