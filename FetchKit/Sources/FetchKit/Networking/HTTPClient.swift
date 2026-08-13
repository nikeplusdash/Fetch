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

    /// Hosts this client may reach, or nil for unrestricted.
    ///
    /// §3 rule 4 puts enforcement here rather than in calling code: a plugin
    /// asked to respect an allowlist could simply not, so the client refuses
    /// on its behalf. Core code passes nil — the app's own indexers and
    /// debrids are configured by the user, not declared by a third party.
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

    /// Exact host match only. A declared `example.com` must not authorise
    /// `evil.example.com` — implicit subdomains are the standard way an
    /// allowlist stops meaning anything.
    private func assertHostPermitted(_ endpoint: Endpoint) throws {
        guard let allowedHosts else { return }
        let host = (try endpoint.makeRequest().url?.host()?.lowercased()) ?? ""
        guard allowedHosts.contains(host) else {
            throw NetworkError.hostNotPermitted(host)
        }
    }

    public static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // MUST stay false. When true, URLSession does not fail a request it
        // considers unreachable — it parks the task indefinitely, and
        // `timeoutIntervalForRequest` does NOT apply while it waits, only the
        // 300s `timeoutIntervalForResource`. macOS reports a LAN address the
        // app lacks local-network permission for as "not connected" (-1009),
        // so an indexer on 10.x hung the Settings "Test" spinner forever with
        // no socket opened and no error raised. Failing fast is what lets the
        // user see the real reason; RetryPolicy still covers transient drops.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 6
        // TorBox sits behind Cloudflare, which 403s some default agents
        // (verified: "Python-urllib/3.9" is blocked). URLSession's default is
        // accepted, but pin an explicit one so behaviour cannot drift.
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
        // Checked before the first attempt, never after: a request that
        // reached the host has already told it the user is running this
        // plugin, whatever the response was.
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
                // URLSession puts the FULL request URL in userInfo, and the
                // requestdl endpoint carries the API key in its query string.
                // Interpolating such an error prints the key. Keep only the
                // code — that is all RetryPolicy needs and all we should hold.
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

    /// `Retry-After` is either delta-seconds or an HTTP-date.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        // Clamp: a hostile or buggy server sending "Retry-After: -1" would
        // otherwise reach UInt64(duration * 1e9) in the clock and TRAP the
        // process. RFC 7231 requires non-negative; nothing enforces it.
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
