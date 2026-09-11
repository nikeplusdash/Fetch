import Foundation
import OSLog

public protocol HTTPClientProtocol: Sendable {
    func send<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type) async throws -> T
    func sendRaw(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse)
}

public actor HTTPClient: HTTPClientProtocol {
    private let session: URLSession
    private let policy: RetryPolicy
    private let clock: any RetryClock
    private let log = Logger(subsystem: "app.fetch", category: "network")

    private let allowedHosts: Set<String>?

    public init(
        session: URLSession = HTTPClient.makeDefaultSession(),
        policy: RetryPolicy = RetryPolicy(),
        clock: any RetryClock = SystemRetryClock(),
        allowedHosts: Set<String>? = nil
    ) {
        self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
        self.session = session
        self.policy = policy
        self.clock = clock
    }

    private func assertHostPermitted(_ endpoint: Endpoint) throws {
        guard let allowedHosts else { return }
        let host = (try endpoint.makeRequest().url?.host()?.lowercased()) ?? ""
        guard allowedHosts.contains(host) else {
            throw NetworkError.hostNotPermitted(host)
        }
    }

    public static let defaultRequestTimeout: TimeInterval = 30
    public static let maximumRequestTimeout: TimeInterval = 180

    public static let defaultIndexerTimeout: TimeInterval = 60

    /**
     A session timeout that will not fire before an outer clock set to
     `deadline`.

     **Two clocks set to the same number is a race, not a policy.** A search
     is bounded twice: `SearchAggregator.perProviderTimeout` cancels the
     provider from outside, and `URLSession` bounds the request. Handing both
     the user's number means whichever notices first decides, and they decide
     differently — the outer one reports `providerTimeout`, naming the
     setting the user chose, while the session raises `-1001`, which
     `RetryPolicy` treats as transient and **retries**. That retry starts a
     fresh request with none of the budget left, so the user waits the full
     time and is told the indexer had a transport error.

     Giving the session headroom makes the cancellable clock the only one
     that can end a search, so "give up after 60s" means that and says so.
     */
    public static func sessionTimeout(outlasting deadline: TimeInterval) -> TimeInterval {
        deadline + 30
    }

    public static let maximumIndexerConnections = 12

    /**
     A session for talking to one indexer server.

     Shared across every indexer under that server — see
     `maximumIndexerConnections` for why that matters.
     */
    public static func makeIndexerSession(
        requestTimeout: TimeInterval = defaultIndexerTimeout
    ) -> URLSession {
        makeDefaultSession(
            requestTimeout: requestTimeout,
            maximumConnectionsPerHost: maximumIndexerConnections)
    }

    public static func makeDefaultSession(
        requestTimeout: TimeInterval = defaultRequestTimeout,
        maximumConnectionsPerHost: Int = 6
    ) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = max(300, requestTimeout * 4)
        config.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        config.httpAdditionalHeaders = ["User-Agent": "Fetch/1.0 (macOS)"]
        return URLSession(configuration: config)
    }

    public func send<T: Decodable & Sendable>(
        _ endpoint: Endpoint, as type: T.Type
    ) async throws -> T {
        let (data, _) = try await sendRaw(endpoint)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(
                String(describing: error),
                raw: NetworkError.scrub(String(data: data, encoding: .utf8))
            )
        }
    }

    public func sendRaw(_ endpoint: Endpoint) async throws -> (Data, HTTPURLResponse) {
        try assertHostPermitted(endpoint)
        var attempt = 1
        while true {
            do {
                let (data, response) = try await session.data(for: endpoint.makeRequest())
                guard let http = response as? HTTPURLResponse else {
                    throw NetworkError.transport(URLError(.badServerResponse))
                }

                if (200...299).contains(http.statusCode) { return (data, http) }

                let retryAfter = Self.retryAfter(from: http)
                let outcome = RetryOutcome.status(http.statusCode, retryAfter: retryAfter)

                if endpoint.isRetryable {
                    let decision = policy.decide(outcome, attempt: attempt)
                    if decision.shouldRetry {
                        try await clock.sleep(for: decision.delay)
                        attempt += 1
                        continue
                    }
                }

                if http.statusCode == 429 {
                    throw NetworkError.rateLimited(retryAfter: retryAfter)
                }
                throw NetworkError.http(
                    status: http.statusCode,
                    body: NetworkError.scrub(String(data: data, encoding: .utf8))
                )
            } catch let rawError as URLError {
                let error = URLError(rawError.code)
                if error.code == .cancelled { throw NetworkError.cancelled }

                if endpoint.isRetryable {
                    let decision = policy.decide(.transport(error), attempt: attempt)
                    if decision.shouldRetry {
                        try await clock.sleep(for: decision.delay)
                        attempt += 1
                        continue
                    }
                }
                throw NetworkError.transport(error)
            }
        }
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
