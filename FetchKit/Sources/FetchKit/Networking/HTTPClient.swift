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

    /// How long a request may take before it is given up on.
    ///
    /// **Configurable because indexers are not all fast.** Thirty seconds is
    /// comfortable for a hosted Prowlarr and short for a self-hosted Jackett
    /// asking a dozen trackers on someone else's schedule — and the failure
    /// looks identical to an indexer being down, so the honest answer is to let
    /// the user say how long they are willing to wait.
    public static let defaultRequestTimeout: TimeInterval = 30
    /// The ceiling the settings stepper offers. Past this a search that is
    /// never going to answer stops being distinguishable from one that has
    /// hung, and the app has nothing better to say either way.
    public static let maximumRequestTimeout: TimeInterval = 180

    /// What "Give up after" starts at, which is **not** the general default.
    ///
    /// A debrid call talks to one host and 30 seconds is generous. An indexer
    /// request talks to a server that then fans out to a dozen trackers on
    /// their schedule — the reporting install's Jackett spent 13.1s inside a
    /// single tracker on a one-word query — so 30 there is a stopwatch on
    /// somebody else's work.
    public static let defaultIndexerTimeout: TimeInterval = 60

    /// A session timeout that will not fire before an outer clock set to
    /// `deadline`.
    ///
    /// **Two clocks set to the same number is a race, not a policy.** A search
    /// is bounded twice: `SearchAggregator.perProviderTimeout` cancels the
    /// provider from outside, and `URLSession` bounds the request. Handing both
    /// the user's number means whichever notices first decides, and they decide
    /// differently — the outer one reports `providerTimeout`, naming the
    /// setting the user chose, while the session raises `-1001`, which
    /// `RetryPolicy` treats as transient and **retries**. That retry starts a
    /// fresh request with none of the budget left, so the user waits the full
    /// time and is told the indexer had a transport error.
    ///
    /// Giving the session headroom makes the cancellable clock the only one
    /// that can end a search, so "give up after 60s" means that and says so.
    public static func sessionTimeout(outlasting deadline: TimeInterval) -> TimeInterval {
        deadline + 30
    }

    /// How many connections Fetch will hold open to one indexer server.
    ///
    /// **This is the throttle, and it only exists because the session is
    /// shared.** A Jackett with eleven indexers is eleven providers in the
    /// fan-out, and each used to build its own `URLSession` — so the per-host
    /// limit applied eleven times over, to eleven separate connection pools,
    /// and meant nothing. Eleven TCP and TLS handshakes per search, against a
    /// server that is frequently a Raspberry Pi.
    ///
    /// One session for the whole server pools and reuses those connections and
    /// makes this number real. It is set above a typical roster on purpose: the
    /// work behind a search is Jackett scraping trackers, which is identical
    /// whether Fetch asks once or eleven times, so throttling below the roster
    /// size would add wall-clock without removing load. Twelve is "keep the
    /// fan-out parallel, and queue anything past a plausible indexer count".
    public static let maximumIndexerConnections = 12

    /// A session for talking to one indexer server.
    ///
    /// Shared across every indexer under that server — see
    /// `maximumIndexerConnections` for why that matters.
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
        // MUST stay false. When true, URLSession does not fail a request it
        // considers unreachable — it parks the task indefinitely, and
        // `timeoutIntervalForRequest` does NOT apply while it waits, only the
        // 300s `timeoutIntervalForResource`. macOS reports a LAN address the
        // app lacks local-network permission for as "not connected" (-1009),
        // so an indexer on 10.x hung the Settings "Test" spinner forever with
        // no socket opened and no error raised. Failing fast is what lets the
        // user see the real reason; RetryPolicy still covers transient drops.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        // The whole exchange, including retries and redirects. Kept well above
        // the per-request value so raising that one does not silently collide
        // with this one.
        config.timeoutIntervalForResource = max(300, requestTimeout * 4)
        config.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
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
