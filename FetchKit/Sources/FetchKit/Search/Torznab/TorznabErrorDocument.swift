import Foundation

enum TorznabErrorDocument {
    private static let credentialCodes: Set<Int> = [100, 101, 102]

    static func error(code: Int, description: String) -> SearchError {
        let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if credentialCodes.contains(code) { return .unauthorized }
        return .malformedFeed(
            reason: detail.isEmpty ? "indexer error \(code)" : "\(detail) (\(code))")
    }

    static func error(from attributes: [String: String]) -> SearchError {
        error(
            code: attributes["code"].flatMap(Int.init) ?? 900,
            description: attributes["description"] ?? "")
    }
}
