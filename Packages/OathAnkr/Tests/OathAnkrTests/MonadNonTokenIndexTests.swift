import Foundation
import XCTest
@testable import OathAnkr

private let nonTokenOwner = "0x1111111111111111111111111111111111111111"
private let nonTokenRef = "0x2222222222222222222222222222222222222222"
private let nonTokenHash = "0x" + String(repeating: "a", count: 64)

private actor NonTokenIndexFeed: AnkrTransport {
    enum Fault { case none, positiveIndex, positiveBalance, validDelegatedToken, ordinaryCode, differentCode, wrongChain, wrongBlock, failedProof, reorg }
    let fault: Fault
    var proofReads = 0
    init(_ fault: Fault = .none) { self.fault = fault }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
        if let call = body as? [String: Any] {
            XCTAssertEqual(call["method"] as? String, "alchemy_getTokenBalances")
            return (try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1,
                "result":["address":nonTokenOwner, "tokenBalances":[["contractAddress":nonTokenRef, "tokenBalance":fault == .positiveIndex ? "0x1":"0x0"]]]]), 200)
        }
        let calls = try XCTUnwrap(body as? [[String: Any]])
        let proof = calls.contains { $0["method"] as? String == "eth_getCode" }
        let secondary = request.url?.host == "monad-mainnet.g.alchemy.com"
        if proof { proofReads += 1 }
        if secondary && fault == .failedProof { return (Data(), 401) }
        let rows = calls.map { call -> [String: Any] in
            let method = call["method"] as! String, params = call["params"] as! [Any]
            let value: Any
            switch method {
            case "eth_chainId": value = secondary && fault == .wrongChain ? "0x1" : "0x8f"
            case "eth_getBlockByNumber":
                let changed = (secondary && fault == .wrongBlock) || (fault == .reorg && proofReads > 0 && !proof)
                value = ["number":"0x64", "hash": changed ? "0x" + String(repeating:"b",count:64) : nonTokenHash]
            case "eth_getBalance": value = "0x123"
            case "eth_getCode":
                value = fault == .ordinaryCode ? "0x60006000" : "0xef0100" + String(repeating: secondary && fault == .differentCode ? "4":"3", count:40)
                XCTAssertEqual(params.last as? String, "0x64")
            case "eth_call":
                let selector = (params[0] as! [String: Any])["data"] as! String
                if fault == .validDelegatedToken { value = selector == "0x313ce567" ? "0x12" : selector.hasPrefix("0x70a08231") ? "0x7" : "0x" }
                else if fault == .positiveBalance && selector.hasPrefix("0x70a08231") { value = "0x7" }
                else { value = "0x" }
                if proof { XCTAssertEqual(params.last as? String, "0x64") }
            default: value = NSNull()
            }
            return ["jsonrpc":"2.0", "id":call["id"]!, "result":value]
        }
        return (try JSONSerialization.data(withJSONObject: rows),200)
    }
}

final class MonadNonTokenIndexTests: XCTestCase, @unchecked Sendable {
    func testIndependentlyVerifiedNonTokenEntryDoesNotMakeInventoryIncomplete() async throws {
        let feed = NonTokenIndexFeed()
        let value = try await IndexedEVMClient(chain:.monad,apiKey:"fixture",alchemyAPIKey:"fixture",transport:feed).inventory(owner:nonTokenOwner)
        XCTAssertTrue(value.complete)
        XCTAssertEqual(value.holdings.count,1)
        XCTAssertEqual(value.holdings.first?.amount,"291")
        let reads = await feed.proofReads
        XCTAssertEqual(reads,2)
    }
    func testAmbiguousAndFundedReferencesRemainIncomplete() async throws {
        for fault in [NonTokenIndexFeed.Fault.positiveIndex,.positiveBalance,.ordinaryCode,.differentCode,.wrongChain,.wrongBlock,.failedProof] {
            let value = try await IndexedEVMClient(chain:.monad,apiKey:"fixture",alchemyAPIKey:"fixture",transport:NonTokenIndexFeed(fault)).inventory(owner:nonTokenOwner)
            XCTAssertFalse(value.complete,"\(fault)")
            XCTAssertEqual(value.holdings.first { $0.token.reference == "native" }?.amount,"291")
        }
    }
    func testTrackedHoldingIsNeverDiscardedAsNonToken() async throws {
        let token = try IndexedEVMToken(reference:nonTokenRef,name:"Saved",symbol:"T",decimals:18)
        let feed = NonTokenIndexFeed()
        let value = try await IndexedEVMClient(chain:.monad,apiKey:"fixture",alchemyAPIKey:"fixture",transport:feed).inventory(owner:nonTokenOwner,tracked:[token])
        XCTAssertFalse(value.complete)
        let saved = try XCTUnwrap(value.holdings.first { $0.token.reference == nonTokenRef })
        XCTAssertEqual(saved.token,token); XCTAssertNil(saved.amount)
        let reads = await feed.proofReads; XCTAssertEqual(reads,0)
    }
    func testDelegatedERC20WithValidBalanceIsKept() async throws {
        let value = try await IndexedEVMClient(chain:.monad,apiKey:"fixture",alchemyAPIKey:"fixture",transport:NonTokenIndexFeed(.validDelegatedToken)).inventory(owner:nonTokenOwner)
        XCTAssertTrue(value.complete)
        XCTAssertEqual(value.holdings.first { $0.token.reference == nonTokenRef }?.amount,"7")
    }
    func testReorgRejectsWholeProof() async throws {
        do {
            _ = try await IndexedEVMClient(chain:.monad,apiKey:"fixture",alchemyAPIKey:"fixture",transport:NonTokenIndexFeed(.reorg)).inventory(owner:nonTokenOwner)
            XCTFail("Changed pinned block accepted")
        } catch { XCTAssertEqual(error as? AnkrError,.invalidResponse) }
    }
}
