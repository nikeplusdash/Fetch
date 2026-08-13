import Foundation
import FetchPluginAPI

/// The request-shaping the three built-in debrids share: one credential, one
/// base URL, one client, and one place `NetworkError` becomes `DebridError`.
///
/// **Why a struct and not a protocol.** Swift protocols cannot supply stored
/// properties or an initialiser, so a `TokenAuthenticatedProvider` protocol
/// would have left all three providers still declaring the same
/// `apiKey`/`client`/`baseURL` triple and the same three-line init — which was
/// the largest of the four duplications. Composition gets that; inheritance
/// does not.
///
/// **Why not in `FetchPluginAPI`.** It names `Endpoint`, `NetworkError`,
/// `HTTPClientProtocol` and `Redacted`, all of which live in `FetchKit`.
/// Moving them down to the plugin boundary would invert the dependency that
/// target exists to prevent, and would freeze "here is how you build a Bearer
/// header" into the contract third parties conform to. A plugin brings its own
/// transport; it owes us DTOs, not a request builder.
struct DebridTransport: Sendable {
    let apiKey: Redacted<String>
    let client: any HTTPClientProtocol
    let baseURL: URL

    /// Statuses this service gives a meaning more specific than "network".
    ///
    /// Real-Debrid is the only one with a service-wide entry: it alone maps
    /// 404 to `.fileNotFound`. For TorBox and Premiumize a missing resource
    /// has no such reading, and inventing one would make a poller drop a live
    /// download.
    let statusOverrides: [Int: DebridError]

    init(
        apiKey: Redacted<String>,
        client: any HTTPClientProtocol,
        baseURL: URL,
        statusOverrides: [Int: DebridError] = [:]
    ) {
        self.apiKey = apiKey
        self.client = client
        self.baseURL = baseURL
        self.statusOverrides = statusOverrides
    }

    /// Spelled out so the one legitimate read of the secret stays greppable.
    var token: String { apiKey.exposedValue }

    var authHeaders: [String: String] { ["Authorization": "Bearer \(token)"] }
}

// MARK: - Sending

extension DebridTransport {
    /// Sends, decodes, and converts any `NetworkError` on the way out.
    ///
    /// `extraStatusOverrides` is per-call rather than per-provider because
    /// TorBox's "500 means this id does not exist" rule holds for
    /// `torrents/mylist?id=` and `webdl/mylist?id=` and **nowhere else**: a
    /// 500 from `createtorrent` is an outage, and mapping it to
    /// `.fileNotFound` would report a transient failure as a permanent one.
    func send<T: Decodable & Sendable>(
        _ endpoint: Endpoint,
        as type: T.Type,
        extraStatusOverrides: [Int: DebridError] = [:]
    ) async throws -> T {
        do {
            return try await client.send(endpoint, as: type)
        } catch let error as NetworkError {
            throw mapNetworkError(error, extra: extraStatusOverrides)
        }
    }

    /// For endpoints with nothing to decode — Real-Debrid answers 204 to
    /// `selectFiles` and `delete`.
    @discardableResult
    func sendRaw(
        _ endpoint: Endpoint, extraStatusOverrides: [Int: DebridError] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await client.sendRaw(endpoint)
        } catch let error as NetworkError {
            throw mapNetworkError(error, extra: extraStatusOverrides)
        }
    }

    func mapNetworkError(
        _ error: NetworkError, extra: [Int: DebridError] = [:]
    ) -> DebridError {
        Self.mapNetworkError(error, overrides: statusOverrides, extra: extra)
    }

    /// Per-call overrides win over the provider's, which win over the shared
    /// rules. No override currently names 401 or 403, so authentication still
    /// reads the same for every service.
    static func mapNetworkError(
        _ error: NetworkError,
        overrides: [Int: DebridError],
        extra: [Int: DebridError] = [:]
    ) -> DebridError {
        switch error {
        case .http(let status, _):
            if let mapped = extra[status] ?? overrides[status] { return mapped }
            if status == 401 || status == 403 { return .unauthorized }
            return .network(String(describing: error))
        case .rateLimited:
            return .network("rate limited")
        default:
            return .network(String(describing: error))
        }
    }
}

// MARK: - Endpoint builders

extension DebridTransport {
    func get(
        _ path: String, query: [URLQueryItem] = [], isRetryable: Bool = true
    ) -> Endpoint {
        Endpoint(
            baseURL: baseURL, path: path, queryItems: query,
            headers: authHeaders, isRetryable: isRetryable)
    }

    /// Not retryable by default: re-sending a delete that already succeeded
    /// asks the service about something that is gone.
    func delete(_ path: String, isRetryable: Bool = false) -> Endpoint {
        Endpoint(
            method: .delete, baseURL: baseURL, path: path,
            headers: authHeaders, isRetryable: isRetryable)
    }

    /// No `Authorization` header. TorBox's `requestdl` authenticates with a
    /// `token` query item instead, and sending both is not what was verified
    /// against the live API.
    func unauthenticated(_ path: String, query: [URLQueryItem]) -> Endpoint {
        Endpoint(baseURL: baseURL, path: path, queryItems: query)
    }

    /// `application/x-www-form-urlencoded`. Real-Debrid extracted this once;
    /// Premiumize inlined the same three lines four times.
    func form(
        _ method: Endpoint.Method = .post,
        _ path: String,
        fields: [URLQueryItem],
        isRetryable: Bool = true
    ) -> Endpoint {
        var headers = authHeaders
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        return Endpoint(
            method: method, baseURL: baseURL, path: path,
            headers: headers, body: Self.formBody(fields), isRetryable: isRetryable)
    }

    /// A single-field `multipart/form-data` body. TorBox's `createtorrent`
    /// (`magnet`) and `createwebdownload` (`link`) are this and nothing else.
    ///
    /// Not retryable by default: both create something, and re-sending on a
    /// transient error submits twice.
    func multipart(
        _ path: String, field: String, value: String, isRetryable: Bool = false
    ) -> Endpoint {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))

        var headers = authHeaders
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        return Endpoint(
            method: .post, baseURL: baseURL, path: path,
            headers: headers, body: body, isRetryable: isRetryable)
    }

    func json(
        _ path: String, body: Data, isRetryable: Bool = false
    ) -> Endpoint {
        var headers = authHeaders
        headers["Content-Type"] = "application/json"
        return Endpoint(
            method: .post, baseURL: baseURL, path: path,
            headers: headers, body: body, isRetryable: isRetryable)
    }

    /// `URLComponents` is what percent-encodes a form body correctly here —
    /// hand-rolled escaping is how a `+` in an API key becomes a space.
    static func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

// MARK: - Cache helpers

extension Array {
    /// Splits into chunks of at most `size`, preserving order.
    ///
    /// Shared by the two providers that batch cache lookups. Their chunk
    /// *sizes* stay separate — same number today, but they answer to two
    /// different services' URL limits — and so do their driving loops: TorBox
    /// runs chunks concurrently with a 4-way bound, Premiumize serially.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
