import Foundation
import OathDiagnostics

/// Shared across chain clients and asset-detail screens. Public market quotas
/// belong to the IP, not to a wallet, asset, or URLSession. Never used for RPC,
/// signing, broadcasting, authenticated requests, or account data.
public actor PublicMarketRequests {
    public enum Priority: Int, Sendable { case interactive = 0, discovery = 1 }
    public struct Response: Sendable {
        public let data: Data
        public let status: Int
        public let retryAfter: String?
        public let cacheAllowed: Bool
        public init(data: Data, status: Int, retryAfter: String? = nil, cacheAllowed: Bool = true) {
            self.data = data; self.status = status; self.retryAfter = retryAfter; self.cacheAllowed = cacheAllowed
        }
    }
    public static let shared = PublicMarketRequests()
    private struct Cached {
        let response: Response
        let expires: ContinuousClock.Instant
        var lastUsed: ContinuousClock.Instant
    }
    private var cache: [URL: Cached] = [:]
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<Response, Error>]
    }
    private var flights: [URL: Flight] = [:]
    private var cooldown: [String: ContinuousClock.Instant] = [:]
    private var next: [String: ContinuousClock.Instant] = [:]
    private var gates: [String: PublicMarketPermit] = [:]
    private let spacing: Duration
    private let transportCooldown: Duration
    public init(spacing: Duration = .milliseconds(2100)) {
        self.spacing = spacing
        transportCooldown = .seconds(15)
    }
    init(spacing: Duration, transportCooldown: Duration) {
        self.spacing = spacing
        self.transportCooldown = min(.seconds(60), max(.zero, transportCooldown))
    }

    public static func accepts(_ request: URLRequest) -> Bool {
        guard request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, let url = request.url, url.scheme == "https",
              isPublicMarketURL(url),
              request.allHTTPHeaderFields?.keys.allSatisfy({ ["accept", "user-agent"].contains($0.lowercased()) }) ?? true,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name.lowercased().contains("key") }) else { return false }
        return true
    }

    private static func isPublicMarketURL(_ url: URL) -> Bool {
        // This exact anonymous bulk route contains only public token quotes;
        // never admit account, holder, authenticated or arbitrary Intear routes.
        if url.host == "li.quest" { return LifiTokenMetadata.accepts(url) }
        if url == URL(string: "https://prices.intear.tech/list-token-price")! { return true }
        if url.host == "api.kraken.com" {
            return ["XDGUSD", "XBTUSD", "OKBUSD", "TRXUSD"].contains { pair in
                url == URL(string: "https://api.kraken.com/0/public/OHLC?pair=\(pair)&interval=60")!
            }
        }
        if ["api.coingecko.com", "tokens.coingecko.com", "api.geckoterminal.com", "api.dexscreener.com", "coins.llama.fi"].contains(url.host) { return true }
        // Admit only anonymous market routes, never Coinbase account APIs.
        if url.host == "api.coinbase.com" {
            return url.query == nil && url.path.range(of: #"^/v2/prices/[A-Z0-9]+-USD/spot$"#, options: .regularExpression) != nil
        }
        if url.host == "api.coinlore.net" {
            return ["/api/tickers", "/api/movers"].contains(url.path)
        }
        if url.host == "api.dexpaprika.com" { return url.path == "/tokens/search" }
        if url.host == "api.llama.fi" {
            return url.path.range(of: #"^/tvl/[a-z0-9-]+$"#, options: .regularExpression) != nil
        }
        if url.host == "api.coinpaprika.com" {
            if url.path == "/v1/tickers", url.query == "quotes=USD" { return true }
            if url.port == nil, url.fragment == nil,
               url.path.range(of: #"^/v1/tickers/[a-z0-9][a-z0-9-]{0,127}/historical$"#, options: .regularExpression) != nil,
               let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count == 2,
               let start = items.first(where: { $0.name == "start" })?.value,
               start.range(of: #"^[0-9]{1,11}$"#, options: .regularExpression) != nil,
               let interval = items.first(where: { $0.name == "interval" })?.value,
               ["1h", "1d"].contains(interval) { return true }
            if url.query == nil, url.path.range(of: #"^/v1/coins/[a-z0-9-]+$"#, options: .regularExpression) != nil { return true }
            return url.query == nil && url.port == nil && url.fragment == nil &&
                ["/v1/coins/rune-thorchain", "/v1/tickers/rune-thorchain",
                 "/v1/coins/doge-dogecoin", "/v1/tickers/doge-dogecoin",
                 "/v1/coins/btc-bitcoin", "/v1/tickers/btc-bitcoin",
                 "/v1/coins/bch-bitcoin-cash", "/v1/tickers/bch-bitcoin-cash",
                 "/v1/coins/sui-sui", "/v1/tickers/sui-sui",
                 "/v1/coins/apt-aptos", "/v1/tickers/apt-aptos",
                 "/v1/coins/okb-okb", "/v1/tickers/okb-okb",
                 "/v1/tickers/tlos-telos", "/v1/tickers/ftm-fantom",
                 "/v1/tickers/ltc-litecoin"].contains(url.path)
        }
        return VerifiedEVMTokenCatalog.independentURLs.contains(url)
    }

    private static func cacheKey(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Different clients construct identical public queries in different orders.
        parts.queryItems = parts.queryItems?.map { item in
            if ["ids", "contract_addresses"].contains(item.name), let value = item.value {
                return URLQueryItem(name: item.name, value: Set(value.split(separator: ",").map(String.init)).sorted().joined(separator: ","))
            }
            return item
        }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        return parts.url!
    }

    public func send(_ request: URLRequest, priority: Priority = .interactive, operation: @escaping @Sendable () async throws -> Response) async throws -> Response {
        guard Self.accepts(request), let originalURL = request.url, let host = originalURL.host else { return try await operation() }
        let url = Self.cacheKey(originalURL)
        try Task.checkCancellation()
        cache = cache.filter { $0.value.expires > .now }
        if var cached = cache[url] {
            cached.lastUsed = .now; cache[url] = cached
            return cached.response
        }
        let consumer = UUID()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var pending = flights[url] {
                    pending.consumers[consumer] = continuation; flights[url] = pending
                    return
                }
                // Bound queued work as well as retained payloads. Local quota
                // deferrals are not another failed remote request.
                guard !(cooldown[host].map { $0 > .now } ?? false) else {
                    continuation.resume(throwing: DiagnosticDeferral.publicMarketCooldown); return
                }
                guard flights.count < 32 else {
                    continuation.resume(throwing: DiagnosticDeferral.publicMarketCapacity); return
                }
                let gate = gates[host] ?? PublicMarketPermit(); gates[host] = gate
                let id = UUID()
                let task = Task {
                    let result: Result<Response, Error>
                    do { result = .success(try await self.execute(url, host: host, gate: gate, priority: priority, operation: operation)) }
                    catch {
                        // diagnostics: market-flight-propagation
                        // execute records real failures at the request boundary;
                        // local quota/cancellation outcomes are expected control flow.
                        result = .failure(error)
                    }
                    self.finish(url, flightID: id, result: result)
                }
                flights[url] = Flight(id: id, task: task, consumers: [consumer: continuation])
            }
        } onCancel: {
            Task { await self.cancel(url, consumer: consumer) }
        }
        try Task.checkCancellation()
        // Preserve a typed unavailable quote through every client wrapper so
        // validated alternative providers can run. Do not turn arbitrary 404s
        // into availability or ever cache/use the stale value as a price.
        if host == "api.coinbase.com",
           DiagnosticHTTP.expectedMarketDataAbsence(response.data, status: response.status, request: request) {
            throw DiagnosticDeferral.publicMarketQuoteUnavailable
        }
        return response
    }

    private func finish(_ url: URL, flightID: UUID, result: Result<Response, Error>) {
        guard let flight = flights[url], flight.id == flightID else { return }
        flights[url] = nil
        for continuation in flight.consumers.values { continuation.resume(with: result) }
    }

    private func cancel(_ url: URL, consumer: UUID) {
        guard var flight = flights[url], let continuation = flight.consumers.removeValue(forKey: consumer) else { return }
        // Resume this consumer immediately even while another screen still
        // needs the producer. A cancelled price race must not await that screen.
        continuation.resume(throwing: CancellationError())
        if flight.consumers.isEmpty {
            flights[url] = nil
            // A losing quote provider must not occupy the queue after everybody
            // has left. Another consumer still protects a shared request.
            flight.task.cancel()
        } else { flights[url] = flight }
    }

    private func execute(_ url: URL, host: String, gate: PublicMarketPermit, priority: Priority,
                         operation: @escaping @Sendable () async throws -> Response) async throws -> Response {
        try await gate.acquire(priority: priority)
        var didRequest = false
        do {
            try Task.checkCancellation()
            if let until = cooldown[host], until > .now { throw DiagnosticDeferral.publicMarketCooldown }
            if let instant = next[host], instant > .now { try await Task.sleep(until: instant, clock: .continuous) }
            let interval: Duration
            if spacing == .zero { interval = .zero } // Deterministic host tests.
            else { switch host {
            case "api.geckoterminal.com": interval = max(spacing, .milliseconds(7500))
            case "api.dexscreener.com": interval = max(spacing, .seconds(1))
            case "api.dexpaprika.com", "api.llama.fi": interval = max(spacing, .seconds(10))
            case "coins.llama.fi": interval = min(spacing, .milliseconds(500))
            default: interval = spacing
            } }
            next[host] = .now.advanced(by: interval)
            didRequest = true
            let response = try await operation()
            try Task.checkCancellation()
            if response.status == 429 {
                cooldown[host] = .now.advanced(by: .seconds(Self.retryDelay(response.retryAfter)))
            } else if response.status == 402 {
                cooldown[host] = .now.advanced(by: .seconds(86400))
            } else if response.status == 200, response.cacheAllowed, response.data.count <= 16 * 1024 * 1024 {
                let lifetime: Double = url.path == "/api/v3/coins/list" || host == "tokens.coingecko.com" || VerifiedEVMTokenCatalog.independentURLs.contains(url) ? 3600 : 30
                retain(response, for: url, lifetime: lifetime)
            }
            await gate.release()
            return response
        } catch {
            if didRequest {
                // A DNS/connectivity outage affects every symbol on this host.
                // Record the attempted request, then let queued assets recover
                // through their existing fallbacks without repeating the outage.
                // Certificate failures also affect every symbol on this host.
                // Defer briefly without bypassing TLS or blocking other hosts.
                // Cancellation and malformed quote data never poison host health.
                if !Task.isCancelled, Self.isTransportOutage(error) {
                    cooldown[host] = .now.advanced(by: transportCooldown)
                }
                OathDiagnostics.record(error, operation: "public_market_request", context: ["host": host])
            }
            await gate.release(); throw error
        }
    }

    private static func isTransportOutage(_ error: Error) -> Bool {
        if error as? AnkrError == .transport { return true }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                .networkConnectionLost, .notConnectedToInternet,
                .secureConnectionFailed, .serverCertificateUntrusted,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid].contains(error.code)
    }

    private func retain(_ response: Response, for url: URL, lifetime: Double) {
        let now = ContinuousClock.now
        cache = cache.filter { $0.value.expires > now }
        cache[url] = nil
        var retainedBytes = cache.values.reduce(0) { $0 + $1.response.data.count }
        // Evict only enough least-recently-used responses to satisfy both
        // bounds. Clearing the entire cache on the 65th search result (or one
        // large catalog) repeatedly fetched otherwise fresh cross-chain data.
        // Cache pressure/expiry is normal local lifecycle, not an app failure.
        while cache.count >= 64 || retainedBytes + response.data.count > 24 * 1024 * 1024 {
            guard let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
            retainedBytes -= oldest.value.response.data.count
            cache[oldest.key] = nil
        }
        cache[url] = Cached(response: response, expires: now.advanced(by: .seconds(lifetime)), lastUsed: now)
    }

    static func retryDelay(_ header: String?, now: Date = .now) -> Double {
        if let header, let seconds = Double(header), seconds.isFinite { return min(3600, max(60, seconds)) }
        if let header {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return min(3600, max(60, date.timeIntervalSince(now))) }
        }
        return 60
    }
}

/// FIFO within each lane; queued discovery never overtakes a wallet quote.
actor PublicMarketPermit {
    private var occupied = false
    private var waiters: [(UUID, PublicMarketRequests.Priority, CheckedContinuation<Void, Error>)] = []
    func acquire(priority: PublicMarketRequests.Priority) async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, priority, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        guard let index = waiters.indices.min(by: { waiters[$0].1.rawValue < waiters[$1].1.rawValue }) else { occupied = false; return }
        waiters.remove(at: index).2.resume()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).2.resume(throwing: CancellationError())
    }
}
