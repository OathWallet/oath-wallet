import XCTest
import OathAnkr
@testable import OathMarketData

final class NativeCoinPriceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2000)
    private func asset(_ network: String, reference: String = "native", decimals: Int? = nil) -> MarketAsset {
        .init(id: network + ":" + reference, networkID: network, reference: reference, decimals: decimals ?? NativeCoinPrice.supported[network]!.decimals)
    }
    private func row(_ network: String) -> [String: Any] {
        let identity = NativeCoinPrice.supported[network]!.identity
        return ["id": identity.id, "name": identity.name, "symbol": identity.symbol,
         "last_updated": "1970-01-01T00:31:40Z", "quotes": ["USD": ["price": "0.014687440861021719"]]]
    }
    private func data(_ row: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: row) }

    func testOnlyExactNativeIdentitiesAndAnonymousTickerURLsAreAdmitted() throws {
        for network in NativeCoinPrice.supported.keys {
            let identity = try XCTUnwrap(NativeCoinPrice.identity(for: asset(network)))
            XCTAssertTrue(NativeCoinPrice.accepts(identity.tickerURL))
            XCTAssertTrue(PublicMarketRequests.accepts(URLRequest(url: identity.tickerURL)))
            XCTAssertNil(NativeCoinPrice.identity(for: asset(network, reference: "0x1111111111111111111111111111111111111111")))
            XCTAssertNil(NativeCoinPrice.identity(for: asset(network, decimals: 6)))
            XCTAssertFalse(NativeCoinPrice.accepts(URL(string: identity.tickerURL.absoluteString + "?quotes=USDT")!))
            XCTAssertFalse(NativeCoinPrice.accepts(URL(string: identity.tickerURL.absoluteString + "/history")!))
        }
        XCTAssertNil(NativeCoinPrice.identity(for: asset("ethereum", decimals: 18)))
        XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: "https://api.coinpaprika.com/v1/tickers/tlos-impostor")!)))
        XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: "https://api.coinpaprika.com/v1/tickers/tlos-telos?key=private")!)))
    }

    func testUSDPriceRetainsPrecisionAndProviderTimestamp() throws {
        for network in NativeCoinPrice.supported.keys {
            let quote = try NativeCoinPrice.decode(data(row(network)), for: asset(network), now: now)
            XCTAssertEqual(quote.quote.usd, "0.014687440861021719")
            XCTAssertEqual(quote.quote.code, NativeCoinPrice.supported[network]!.identity.symbol)
            XCTAssertEqual(quote.date.timeIntervalSince1970, 1900)
            XCTAssertEqual(quote.source, "CoinPaprika")
        }
    }

    func testWrongProjectOrCurrencyAndInvalidOrStalePricesAreRejected() throws {
        for network in NativeCoinPrice.supported.keys {
            for field in ["id", "name", "symbol"] {
                var changed = row(network); changed[field] = "impostor"
                XCTAssertThrowsError(try NativeCoinPrice.decode(data(changed), for: asset(network), now: now))
            }
            for price: Any in ["0", "-1", "NaN", true, "", NSNull()] {
                var changed = row(network); changed["quotes"] = ["USD": ["price": price]]
                XCTAssertThrowsError(try NativeCoinPrice.decode(data(changed), for: asset(network), now: now))
            }
            for time in ["invalid", "1970-01-01T00:01:00Z", "1970-01-01T01:00:00Z"] {
                var changed = row(network); changed["last_updated"] = time
                XCTAssertThrowsError(try NativeCoinPrice.decode(data(changed), for: asset(network), now: now))
            }
            var changed = row(network); changed["quotes"] = ["USDT": ["price": 100]]
            XCTAssertThrowsError(try NativeCoinPrice.decode(data(changed), for: asset(network), now: now))
            XCTAssertThrowsError(try NativeCoinPrice.decode(Data(repeating: 32, count: 100_001), for: asset(network), now: now))
        }
    }
}
