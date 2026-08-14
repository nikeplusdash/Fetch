import Foundation

/// Torznab's in-band error document.
///
/// **A rejected API key arrives as HTTP 200.** Verified against a live Jackett:
/// a wrong key answers `t=indexers` with status 200 and an 89-byte body,
///
/// ```xml
/// <?xml version="1.0" encoding="UTF-8"?>
/// <error code="100" description="Invalid API Key" />
/// ```
///
/// which is well-formed XML containing no indexers, no categories and no items.
/// Every parser here therefore *succeeded* on it and returned an empty result,
/// and each caller drew its own wrong conclusion from that: endpoint resolution
/// saved a server with zero capabilities and called it connected, Jackett
/// discovery reported "no configured indexers" and silently fell back to the
/// one-row aggregate, and a search reported the indexer as having found
/// nothing. Three different symptoms, one unread error.
///
/// So it is read. Each parser captures a root `<error>` and throws instead of
/// returning what the document does not contain — in the same pass, since the
/// document being empty is exactly what makes a second pass tempting and
/// wasteful on a 1.4 MB feed.
enum TorznabErrorDocument {
    /// The Torznab error codes that mean "your credentials, not your request".
    /// 100 is the one a wrong key produces; 101 and 102 are its neighbours and
    /// send the user to the same place.
    private static let credentialCodes: Set<Int> = [100, 101, 102]

    /// The error a captured `<error>` element should be reported as.
    static func error(code: Int, description: String) -> SearchError {
        let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if credentialCodes.contains(code) { return .unauthorized }
        return .malformedFeed(
            reason: detail.isEmpty ? "indexer error \(code)" : "\(detail) (\(code))")
    }

    /// Reads the attributes off an `<error>` element as they arrive.
    /// A missing or non-numeric `code` still produces an error — the element's
    /// presence is the signal, not its attributes.
    static func error(from attributes: [String: String]) -> SearchError {
        error(
            code: attributes["code"].flatMap(Int.init) ?? 900,
            description: attributes["description"] ?? "")
    }
}
