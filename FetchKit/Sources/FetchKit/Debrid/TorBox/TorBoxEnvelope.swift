import Foundation

struct TorBoxEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let detail: String?
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

    var failureDetail: String {
        error ?? detail ?? "unknown"
    }

    func requireSuccess(_ fallback: @autoclosure () -> String = "unknown") throws {
        guard success else {
            throw DebridError.providerRejected(detail: error ?? detail ?? fallback())
        }
    }

    func requireData(_ fallback: @autoclosure () -> String = "unknown") throws -> T {
        try requireSuccess(fallback())
        guard let data else {
            throw DebridError.providerRejected(detail: error ?? detail ?? fallback())
        }
        return data
    }
}
