import Foundation
import FetchPluginAPI

extension RealDebridProvider {
    /**
     Every host Real-Debrid can unrestrict.

     `/hosts` returns a domain-keyed object rather than a list, and carries
     no up/down flag — RD publishes status separately and this does not ask,
     so every host reports `isActive: true`. Claiming a host is up is the
     safe direction: the failure surfaces at submit with the service's own
     message, rather than Fetch refusing a link that would have worked.
     */
    public func supportedHosts() async throws -> [DebridHost] {
        let raw = try await transport.send(
            transport.get("hosts"), as: [String: RealDebridHost].self)

        return raw.map { domain, host in
            DebridHost(
                id: HostID(rawValue: (host.id ?? domain).lowercased()),
                displayName: host.name ?? domain,
                domains: [domain],
                isActive: true)
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func resolveHostedLink(_ link: String) async throws -> URL {
        try await unrestrict(link: link)
    }
}

struct RealDebridHost: Decodable, Sendable {
    let id: String?
    let name: String?
}
