import Foundation

public enum NetworkError: Error, Sendable {
    /// A plugin tried to reach a host it did not declare (§3 rule 4).
    case hostNotPermitted(String)
    case transport(URLError)
    case http(status: Int, body: String?)
    case rateLimited(retryAfter: TimeInterval?)
    /// `raw` is a truncated, key-scrubbed body snippet. Decoding failures
    /// against a live API are otherwise undebuggable.
    case decoding(String, raw: String?)
    case invalidURL
    case cancelled
}

extension NetworkError: CustomStringConvertible {
    /// Never renders a URLError's userInfo, which contains the failing URL
    /// (and therefore any API key in its query string).
    public var description: String {
        switch self {
        case .transport(let e):        "transport(\(e.code.rawValue))"
        case .http(let status, _):     "http(\(status))"
        case .rateLimited(let after):  "rateLimited(retryAfter: \(after.map { String($0) } ?? "nil"))"
        case .decoding(let why, _):    "decoding(\(why))"
        case .hostNotPermitted(let h): "hostNotPermitted(\(h))"
        case .invalidURL:              "invalidURL"
        case .cancelled:               "cancelled"
        }
    }
}

extension NetworkError {
    /// Known boundary: this is keyword-anchored, so a bare secret with no
    /// adjacent key name (`invalid session sk-live-abc for user`) is not
    /// redactable by construction. It defends against the shapes our
    /// providers actually emit; it is not a general secret scanner.
    /// Truncate to 2 KB and scrub anything resembling an API key before a body
    /// snippet is retained in an error (global constraint: secrets never leak).
    static func scrub(_ body: String?) -> String? {
        guard let body else { return nil }
        let truncated = String(body.prefix(2048))
        return truncated.replacingOccurrences(
            of: #"(?i)(api[_-]?key|token|authorization)["'\s:=]*(?:[A-Za-z][A-Za-z0-9_-]*\s+)?[^"'\s,&}]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
    }
}
