import XCTest
@testable import OathAnkr

final class TokenMetadataNameTests: XCTestCase {
    func testMissingNamesUseIdentityInsteadOfEnglishPlaceholder() {
        XCTAssertEqual(TokenMetadataName.name("", symbol: "USDC", reference: "contract.near"), "USDC")
        XCTAssertEqual(TokenMetadataName.name("\u{202E}unsafe", symbol: "SUI", reference: "0x2::sui::SUI"), "SUI")
        XCTAssertEqual(TokenMetadataName.name("", symbol: "", reference: "contract.near"), "contract.near")
        let reference = "0x" + String(repeating: "a", count: 64)
        XCTAssertEqual(TokenMetadataName.name("", symbol: "", reference: reference), String(reference.prefix(12)) + "…" + String(reference.suffix(8)))
    }
    func testRealNamesArePreservedIncludingToken() throws {
        for name in ["Token", "رمز", "トークン", "My Asset"] {
            XCTAssertEqual(TokenMetadataName.name(name, symbol: "SYM", reference: "contract.near"), name)
        }
        let aptos = try AptosToken.decode(.object(["name":.string(""),"symbol":.string("APTOKEN"),"decimals":.number("6")]), reference:"0xa::coin::Token")
        XCTAssertEqual(aptos.name, "APTOKEN")
        let sui = try SuiToken.decode(.object(["name":.string(""),"symbol":.string("SUI"),"decimals":.number("9")]), reference:"0x2::sui::SUI")
        XCTAssertEqual(sui.name, "SUI")
    }
}
