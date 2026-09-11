import Foundation

public enum NetworkError: Error, Sendable {
    case hostNotPermitted(String)
    case transport(URLError)
    case http(status: Int, body: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(String, raw: String?)
    case invalidURL
    case cancelled
}

extension NetworkError: CustomStringConvertible {
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
