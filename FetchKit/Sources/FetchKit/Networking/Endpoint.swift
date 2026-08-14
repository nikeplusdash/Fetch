import Foundation

public struct Endpoint: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST", delete = "DELETE" }

    public var method: Method
    public var baseURL: URL
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval?
    public var isRetryable: Bool

    public init(
        method: Method = .get,
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        isRetryable: Bool = true
    ) {
        self.method = method
        self.baseURL = baseURL
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.isRetryable = isRetryable
    }

    public func makeRequest() throws -> URLRequest {
        // `appendingPathComponent("")` adds a trailing slash even though
        // there is nothing to append — harmless for callers that always pass
        // a real path segment (e.g. TorBox), but wrong for a caller like
        // Torznab whose `baseURL` is already the complete, user-typed
        // endpoint and only adds query items.
        let url = path.isEmpty ? baseURL : baseURL.appendingPathComponent(path)
        guard var components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        ) else { throw NetworkError.invalidURL }

        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }
}
