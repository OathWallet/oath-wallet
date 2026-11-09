import XCTest
@testable import OathAnkr

final class SendReviewAmountsTests: XCTestCase {
    func testNewBalanceCannotEnlargeEnteredOrReviewedMaximum() {
        XCTAssertTrue(SendReviewAmounts.isWithinRequestedAmount("91300",requested:"91647"))
        XCTAssertTrue(SendReviewAmounts.isWithinRequestedAmount("91647",requested:"91647"))
        XCTAssertFalse(SendReviewAmounts.isWithinRequestedAmount("91648",requested:"91647"))
        XCTAssertFalse(SendReviewAmounts.isWithinRequestedAmount("1"+String(repeating:"0",count:96),requested:String(repeating:"9",count:96)))
    }
    func testBitcoinAdjustedMaximumAndFeeInclusiveTotal() {
        let p = SendReviewAmounts(amount: "91300", decimals: 8, symbol: "BTC", native: true, fee: "347", nativeDecimals: 8, nativeSymbol: "BTC")
        XCTAssertEqual(p.sent.units, "0.000913"); XCTAssertEqual(p.fee.units, "0.00000347")
        XCTAssertEqual(p.totals[0].atomic, "91647")
        XCTAssertEqual(p.totalValue(assetPrice: 75000, nativePrice: 75000), Decimal(string: "68.73525"))
    }
    func testTokenPriceIsNeverUsedForNativeFeeAndMissingPricesKeepUnits() {
        let p = SendReviewAmounts(amount: "1234500", decimals: 6, symbol: "USDT", native: false, fee: "1000000000000000", nativeDecimals: 18, nativeSymbol: "ETH")
        XCTAssertEqual(p.totalValue(assetPrice: 1, nativePrice: 2000), Decimal(string: "3.2345"))
        XCTAssertNil(p.totalValue(assetPrice: 1, nativePrice: nil)); XCTAssertNil(p.totalValue(assetPrice: nil, nativePrice: 2000))
        XCTAssertEqual(p.totals.map(\.units), ["1.2345", "0.001"])
        // Selected-currency prices are already converted independently by Send.
        XCTAssertEqual(p.totalValue(assetPrice: Decimal(string:"0.709"), nativePrice: 1418), Decimal(string:"2.2932605"))
    }
    func testRentActivationAndStorageAreIncludedWithoutInflatingNetworkFee() {
        for (symbol, decimals) in [("SOL",9),("TRX",6),("NEAR",24)] {
            let p = SendReviewAmounts(amount:"100",decimals:6,symbol:"TOKEN",native:false,fee:"5",nativeCost:"26",nativeDecimals:decimals,nativeSymbol:symbol)
            XCTAssertEqual(p.fee.atomic,"5"); XCTAssertEqual(p.totals[1].atomic,"26")
        }
    }
    func testIssuedTransferChargeAndLargeAtomicArithmeticAreExact() {
        let xrp = SendReviewAmounts(amount:"100",assetDebit:"102",decimals:2,symbol:"USD",native:false,fee:"12",nativeDecimals:6,nativeSymbol:"XRP")
        XCTAssertEqual(xrp.sent.units,"1"); XCTAssertEqual(xrp.totals[0].units,"1.02")
        let huge = "999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999"
        let p = SendReviewAmounts(amount:huge,decimals:96,symbol:"USD",native:true,fee:"1",nativeDecimals:96,nativeSymbol:"USD")
        XCTAssertEqual(p.totals[0].atomic,"1"+String(repeating:"0",count:96)); XCTAssertEqual(p.totals[0].units,"1")
    }
}
