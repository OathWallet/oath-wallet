import OathDiagnostics
import OathAnkr
import Foundation

public protocol MarketTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

public actor URLSessionMarketTransport: MarketTransport {
    private let session: URLSession
    private let publicRequests: PublicMarketRequests
    private var cooldown: [String: ContinuousClock.Instant] = [:]
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        publicRequests = .shared
    }
    init(session: URLSession) { self.session = session; publicRequests = PublicMarketRequests() }
    public func data(from url: URL) async throws -> Data {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              ["api.coinbase.com", "api.exchange.coinbase.com", "api.coingecko.com", "api.geckoterminal.com", "api.dexscreener.com", "coins.llama.fi"].contains(url.host) || Self.exploreURL(url) || LifiTokenMetadata.accepts(url) || ThorchainChart.accepts(url) || NativeInformation.accepts(url) || NativeCoinPrice.accepts(url) || KrakenNativeChart.accepts(url) else {
            throw MarketDataError.invalidResponse
        }
        let host = url.host!
        if let until = cooldown[host], until > .now { throw DiagnosticDeferral.publicMarketCooldown }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(host == "api.geckoterminal.com" ? "application/json;version=20230203" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
        if ThorchainChart.accepts(url) { request.setValue("oath-wallet", forHTTPHeaderField: "x-client-id") }
        let prepared = request
        let discovery = (host == "api.coinpaprika.com" && url.path == "/v1/tickers") ||
            ["api.coinlore.net", "api.dexpaprika.com", "api.llama.fi"].contains(host) ||
            url.path.hasSuffix("/trending_pools") || (host == "api.coinpaprika.com" && url.path.hasPrefix("/v1/coins/"))
        let response: PublicMarketRequests.Response
        do { response = try await publicRequests.send(prepared, priority: discovery ? .discovery : .interactive) { try await self.fetch(prepared) } }
        catch AnkrError.http(429) { throw MarketDataError.rateLimited }
        switch response.status {
        case 200: break
        case 400, 404:
            guard DiagnosticHTTP.expectedMarketDataAbsence(response.data, status: response.status, request: prepared) else {
                throw MarketDataError.unavailable
            }
            throw MarketDataError.notListed
        case 402:
            cooldown[host] = .now.advanced(by: .seconds(86400))
            throw MarketDataError.rateLimited
        case 429:
            // The keyless limit belongs to the provider/IP, not to one asset.
            // Moving to another coin must not issue another throttled request.
            let seconds = min(3_600, max(60, Double(response.retryAfter ?? "") ?? 60))
            cooldown[host] = .now.advanced(by: .seconds(seconds))
            throw MarketDataError.rateLimited
        default: throw MarketDataError.unavailable
        }
        return response.data
    }
    private static func exploreURL(_ url: URL) -> Bool {
        guard ["api.coinpaprika.com", "api.coinlore.net", "api.dexpaprika.com", "api.llama.fi"].contains(url.host) else { return false }
        return PublicMarketRequests.accepts(URLRequest(url: url))
    }
    private func fetch(_ request: URLRequest) async throws -> PublicMarketRequests.Response {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse }
        let limit = request.url?.host == "api.coinpaprika.com" && request.url?.path == "/v1/tickers" ? 4_000_000 : 2_000_000
        guard response.expectedContentLength <= limit else { throw MarketDataError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw MarketDataError.invalidResponse }
            data.append(byte)
        }
        DiagnosticHTTP.response(data, status: http.statusCode, request: request)
        return .init(data: data, status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            cacheAllowed: !(http.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().contains("no-store"))
    }
}
