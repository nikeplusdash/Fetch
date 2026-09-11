import Foundation
import FetchPluginAPI

struct DebridTransport: Sendable {
    let apiKey: Redacted<String>
    let client: any HTTPClientProtocol
    let baseURL: URL

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

    var token: String { apiKey.exposedValue }

    var authHeaders: [String: String] { ["Authorization": "Bearer \(token)"] }
}


extension DebridTransport {
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


extension DebridTransport {
    func get(
        _ path: String, query: [URLQueryItem] = [], isRetryable: Bool = true
    ) -> Endpoint {
        Endpoint(
            baseURL: baseURL, path: path, queryItems: query,
            headers: authHeaders, isRetryable: isRetryable)
    }

    func delete(_ path: String, isRetryable: Bool = false) -> Endpoint {
        Endpoint(
            method: .delete, baseURL: baseURL, path: path,
            headers: authHeaders, isRetryable: isRetryable)
    }

    func unauthenticated(_ path: String, query: [URLQueryItem]) -> Endpoint {
        Endpoint(baseURL: baseURL, path: path, queryItems: query)
    }

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

    static func formBody(_ items: [URLQueryItem]) -> Data {
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}


extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [Array(self)] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
