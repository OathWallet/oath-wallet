import Foundation
import XCTest
@testable import OathAnkr

private actor ArchiveFixtureTransport: AnkrTransport {
    let listing: SolanaJSON
    let details: [String: SolanaJSON]
    private(set) var calls = 0
    init(listing: SolanaJSON, details: [String: SolanaJSON]) { self.listing = listing; self.details = details }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        calls += 1
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://runescan.io")
        let url = try XCTUnwrap(request.url)
        let response = url.path.contains("/addresses/") ? listing : try XCTUnwrap(details[url.lastPathComponent])
        return (try JSONEncoder().encode(response), 200)
    }
}

final class ThorchainArchivedHistoryTests: XCTestCase {
    let owner = "thor172egzpvhpe4pgd69ql4fjr6sjrlrftkgat79m2"
    let other = "thor1c3nw2k7qag6j707hzda9nvh4ke032rh9cw7pq4"
    let txHash = String(repeating: "A", count: 64)
    func json(_ value: String) throws -> SolanaJSON { try JSONDecoder().decode(SolanaJSON.self, from: Data(value.utf8)) }
    func send(code: Int = 0, denom: String = "THOR.RUNE", amount: String = "123456789012345678901234567890") throws -> SolanaJSON {
        try json("""
        {"hash":"\(txHash)","height":123,"timestamp":1700000000000,"code":\(code),"status":"\(code == 0 ? "success" : "error")","signer":"\(owner)","msgs":[{"@type":"/types.MsgSend","from_address":"\(owner)","to_address":"\(other)","amount":[{"denom":"\(denom)","amount":"\(amount)"}]}]}
        """)
    }
    func listing(_ rows: [SolanaJSON], total: Int? = nil, page: Int = 1) -> SolanaJSON {
        let count = total ?? rows.count
        return .object(["docs": .array(rows), "total": .number(String(count)), "pages": .number(String((count + 24) / 25)), "page": .number(String(page))])
    }
    func testNativeTokenSelfAndFailedSendAmountsAreExact() throws {
        for denom in ["THOR.RUNE", "x/ruji", "btc-btc"] {
            let row = try send(denom: denom)
            let events = try ThorchainClient.decodeArchivedTransaction(row, owner: owner, upperHeight: 123)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].amount, "123456789012345678901234567890")
            XCTAssertEqual(events[0].direction, "outgoing")
            let incoming = try ThorchainClient.decodeArchivedTransaction(row, owner: other, upperHeight: 123)
            XCTAssertEqual(incoming[0].direction, "incoming")
        }
        let failed = try ThorchainClient.decodeArchivedTransaction(send(code: 99), owner: owner, upperHeight: 123)
        XCTAssertEqual(failed[0].amount, "0"); XCTAssertEqual(failed[0].state, "failed")
        XCTAssertThrowsError(try ThorchainClient.decodeArchivedTransaction(send(amount: "1.1"), owner: owner, upperHeight: 123))
        XCTAssertThrowsError(try ThorchainClient.decodeArchivedTransaction(send(), owner: owner, upperHeight: 122))
        let selfRow = try json(String(decoding: JSONEncoder().encode(send()), as: UTF8.self).replacingOccurrences(of: other, with: owner))
        XCTAssertEqual(try ThorchainClient.decodeArchivedTransaction(selfRow, owner: owner, upperHeight: 123)[0].direction, "self")
    }
    func testBondAssociationIsAnActionAndArbitraryMemoCannotClaimOwnership() throws {
        let row = try json("""
        {"hash":"\(txHash)","height":123,"timestamp":1700000000000,"code":0,"status":"success","signer":"\(other)","msgs":[{"@type":"/types.MsgDeposit","memo":"BOND:\(other):\(owner):300","coins":[{"asset":"THOR.RUNE","amount":"100000000"}]}]}
        """)
        XCTAssertEqual(try ThorchainClient.decodeArchivedTransaction(row, owner: owner, upperHeight: 123)[0].amount, "0")
        let unrelated = try json(String(decoding: JSONEncoder().encode(row), as: UTF8.self).replacingOccurrences(of: "BOND:", with: "SWAP:"))
        XCTAssertThrowsError(try ThorchainClient.decodeArchivedTransaction(unrelated, owner: owner, upperHeight: 123))
    }
    func testLegacyBondAndMalformedOwnedFailedMemoRemainVisibleWithoutTransfers() throws {
        let legacy = try json("""
        {"hash":"\(txHash)","height":123,"timestamp":1700000000000,"code":0,"status":"success","signer":"\(other)","types":["node","bond"],"memo":{"raw":"bond:\(other):\(owner):300"},"msgs":[{"@type":"/types.MsgSend","from_address":"\(other)","to_address":"thor1g3mlm0r5xtv8e4z2yu66gpuefpslfyn799e8ya","amount":[{"denom":"rune","amount":"10000000"}]}]}
        """)
        XCTAssertEqual(try ThorchainClient.decodeArchivedTransaction(legacy, owner: owner, upperHeight: 123)[0].amount, "0")
        let failed = try json("""
        {"hash":"\(txHash)","height":123,"timestamp":1700000000000,"code":99,"status":"error","signer":"\(owner)","msgs":[{"@type":"/types.MsgDeposit","memo":"BOND: invalid-node-address"}]}
        """)
        let event = try ThorchainClient.decodeArchivedTransaction(failed, owner: owner, upperHeight: 123)[0]
        XCTAssertEqual(event.amount, "0"); XCTAssertEqual(event.state, "failed")
    }
    func testActualOutboundIgnoresEstimatesAndUnrelatedRows() throws {
        let row = try json("""
        {"hash":"\(txHash)","height":123,"timestamp":1700000000000,"estimate":{"amount":"99999999999999"},"outbounds":[{"chain":"THOR","from":"\(other)","to":"\(owner)","asset":"THOR.RUNE","amount":"456","height":124,"timestamp":1700000006000}]}
        """)
        let events = try ThorchainClient.decodeArchivedTransaction(row, owner: owner, upperHeight: 124)
        XCTAssertEqual(events[0].amount, "456")
        XCTAssertEqual(events[0].direction, "incoming")
        let unrelated = try send()
        XCTAssertThrowsError(try ThorchainClient.decodeArchivedTransaction(unrelated, owner: "thor1g3mlm0r5xtv8e4z2yu66gpuefpslfyn799e8ya", upperHeight: 123))
    }
    func testPaginationRejectsDuplicatesTruncationAndWrongPage() throws {
        XCTAssertThrowsError(try ThorchainClient.archiveListing(listing([send(), send()]), page: 1))
        XCTAssertThrowsError(try ThorchainClient.archiveListing(listing([send()], total: 26), page: 1))
        XCTAssertThrowsError(try ThorchainClient.archiveListing(listing([send()], page: 2), page: 1))
        XCTAssertNoThrow(try ThorchainClient.archiveListing(listing([], page: 0), page: 1))
    }
    func testPageUsesValidatedTransactionFieldsWithoutPerTransactionFanout() async throws {
        let row = try send()
        let transport = ArchiveFixtureTransport(listing: listing([row]), details: [:])
        let page = try await ThorchainClient(transport: transport).history(owner: owner, stream: "archive", height: 123)
        XCTAssertEqual(page.events.count, 1)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
        do {
            _ = try await ThorchainClient(transport: transport).history(owner: "thor1g3mlm0r5xtv8e4z2yu66gpuefpslfyn799e8ya", stream: "archive", height: 123)
            XCTFail("Foreign transaction must not advance the page")
        } catch { XCTAssertEqual(error as? ThorchainError, .wrongOwner) }
    }
    func testPinnedViewSkipsNewRowsWithoutSkippingNextPage() async throws {
        let row = try send()
        let transport = ArchiveFixtureTransport(listing: listing([row]), details: [:])
        let page = try await ThorchainClient(transport: transport).history(owner: owner, stream: "archive", height: 122)
        XCTAssertTrue(page.events.isEmpty)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testLivePublicArchivesMatchEveryListedHashAndBankAmount() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THOR_HISTORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only history") }
        let client = ThorchainClient(), height = try await client.latestHeight()
        for address in [owner, other, "thor17tkmm7rpqx94dk2vyurle708t4phjp0m4mwv2h", "thor1m4mkgn97q9zj07qzan66n9hz7ddzsnks6efhac"] {
            var number = 1, hashes = Set<String>(), events: [ThorchainEvent] = [], expected = Set<String>(), total = 0
            while true {
                try await Task.sleep(for: .seconds(2))
                var request = URLRequest(url: URL(string: "https://api.viewblock.io/thorchain/addresses/\(address)/txs?page=\(number)")!)
                request.setValue("https://runescan.io", forHTTPHeaderField: "Origin")
                request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                let raw = try JSONDecoder().decode(SolanaJSON.self, from: data)
                total = try XCTUnwrap(raw["total"].text.flatMap(Int.init))
                let rows = try XCTUnwrap(raw["docs"].array)
                expected.formUnion(rows.compactMap { $0["hash"].string?.uppercased() })
                try await Task.sleep(for: .seconds(2))
                let page = try await client.history(owner: address, stream: "archive", height: height, page: number)
                hashes.formUnion(page.events.map(\.hash)); events += page.events
                for row in rows where row["code"].integer == 0 {
                    for msg in row["msgs"].array ?? [] where msg["@type"].string == "/types.MsgSend" {
                        guard msg["from_address"].string == address || msg["to_address"].string == address else { continue }
                        for coin in msg["amount"].array ?? [] {
                            XCTAssertTrue(page.events.contains { $0.hash == row["hash"].string && $0.amount == coin["amount"].string }, "Exact public bank amount missing")
                        }
                    }
                }
                guard let next = page.next.flatMap(Int.init) else { break }
                number = next
                guard number <= 20 else { XCTFail("Unexpected public history growth"); break }
            }
            XCTAssertEqual(hashes, expected)
            XCTAssertEqual(hashes.count, total)
            XCTAssertEqual(Set(events.map(\.id)).count, events.count)
            print("THOR archive verified: \(total) hashes, \(number) pages, \(events.count) activities")
        }
    }
}
