import Foundation

/// A parsed `magnet:` URI.
///
/// `raw` is retained verbatim and is what gets submitted to a debrid provider.
/// Never reconstruct a magnet from the parsed parts — trackers this parser
/// dropped may still matter to the provider.
public struct MagnetLink: Sendable, Hashable, Codable {
    public let infoHash: InfoHash
    public let displayName: String?
    public let trackers: [URL]
    public let raw: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:?") else { return nil }

        // URLComponents drops `+` semantics, so split manually.
        let query = String(trimmed.dropFirst("magnet:?".count))
        var xts: [String] = []
        var name: String?
        var trackers: [URL] = []

        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).lowercased()
            let rawValue = String(parts[1])

            switch key {
            case "xt": xts.append(Self.decode(rawValue, plusIsSpace: false))
            case "dn": name = Self.decode(rawValue, plusIsSpace: true)
            case "tr":
                let decoded = Self.decode(rawValue, plusIsSpace: false)
                if let url = URL(string: decoded), url.scheme != nil { trackers.append(url) }
            default: continue
            }
        }

        // Scan every xt for the first v1 (btih) hash; ignore btmh/v2 values.
        let prefix = "urn:btih:"
        guard let hash = xts.lazy
            .filter({ $0.lowercased().hasPrefix(prefix) })
            .compactMap({ InfoHash(String($0.dropFirst(prefix.count))) })
            .first
        else { return nil }

        self.infoHash = hash
        self.displayName = name
        self.trackers = trackers
        self.raw = trimmed
    }

    private static func decode(_ value: String, plusIsSpace: Bool) -> String {
        let prepared = plusIsSpace ? value.replacingOccurrences(of: "+", with: " ") : value
        return prepared.removingPercentEncoding ?? prepared
    }
}
