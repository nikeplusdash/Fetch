import Foundation

/// TorBox wraps every response uniformly. `success: false` arrives with HTTP
/// 200 for several conditions, so the status code alone is not a success
/// signal — always check this flag.
struct TorBoxEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let detail: String?
    /// Machine-readable code on failure, e.g. "DATABASE_ERROR". Far more
    /// actionable than `detail`, which is generic prose.
    let error: String?
    let data: T?

    enum CodingKeys: String, CodingKey { case success, detail, error, data }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        data = try c.decodeIfPresent(T.self, forKey: .data)
    }

    /// Why a failure is being reported, preferring the machine-readable code
    /// (e.g. `"DATABASE_ERROR"`) over `detail`, which is generic prose.
    /// Verified against the live API.
    var failureDetail: String {
        error ?? detail ?? "unknown"
    }

    /// Throws unless the call succeeded — `success: false` arrives with HTTP
    /// 200, so this is the only signal that means anything.
    func requireSuccess(_ fallback: @autoclosure () -> String = "unknown") throws {
        guard success else {
            throw DebridError.providerRejected(detail: error ?? detail ?? fallback())
        }
    }

    /// The payload of a successful call, or `providerRejected`. Covers the
    /// `guard envelope.success, let data = envelope.data` shape that appears
    /// at almost every TorBox call site.
    func requireData(_ fallback: @autoclosure () -> String = "unknown") throws -> T {
        try requireSuccess(fallback())
        guard let data else {
            throw DebridError.providerRejected(detail: error ?? detail ?? fallback())
        }
        return data
    }
}
