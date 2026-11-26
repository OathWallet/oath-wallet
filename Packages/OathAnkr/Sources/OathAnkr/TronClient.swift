import OathDiagnostics
import Foundation

/// ANKR mainnet node for state/receipts; TronGrid's public index for discovery.
/// No keys, credentials or secret material are sent to the index or market APIs.
public actor TronClient {
    private let network: TronSendNetwork
    private let rpc: URL
    private let node: URL
    private let transport: any AnkrTransport
    private let permits = AnkrPermits(count: 4)
    private let indexPermit = AnkrPermits(count: 1)
    private var lastIndex = Date.distantPast
    private var verified = false
    private var recoveryVerified = false
    private var solid: (height: Int64, time: Date)?
    private var metadata: [String: TronToken] = [:]
    public init(apiKey: String, network: TronSendNetwork = .mainnet, transport: any AnkrTransport = AnkrHTTPTransport()) throws {
        guard !apiKey.isEmpty, apiKey.count <= 256, apiKey.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw TronError.configuration }
        self.network = network
        rpc = network == .nile ? network.endpoint.appendingPathComponent("jsonrpc") : URL(string: "https://rpc.ankr.com/tron_jsonrpc")!.appendingPathComponent(apiKey)
        node = network == .nile ? network.endpoint : URL(string: "https://rpc.ankr.com/premium-http/tron")!.appendingPathComponent(apiKey)
        self.transport = transport
    }
    private func request(_ url: URL, body: TronJSON? = nil, index: Bool = false) async throws -> TronJSON {
        // Recovery shares the existing public-provider budget with discovery.
        let publicRequest = index || network == .mainnet && url.host == network.endpoint.host
        let gate = publicRequest ? indexPermit : permits
        try await gate.acquire()
        var failureReported = false
        do {
            var req = URLRequest(url: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            if let body { req.httpMethod = "POST"; req.httpBody = try JSONEncoder().encode(body) }
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if publicRequest {
                    let delay = 1.1 - Date().timeIntervalSince(lastIndex)
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    lastIndex = .now
                }
                do {
                    let (data, status) = try await transport.sendPreservingTransportError(req)
                    guard status == 200 else { throw TronError.http(status) }
                    guard data.count <= 32 * 1024 * 1024 else { throw TronError.malformed }
                    let value = try JSONDecoder().decode(TronJSON.self, from: data)
                    guard value["Error"].isNull, value["error"].isNull, value["success"] != .bool(false) else { throw TronError.incomplete }
                    await gate.release(); return value
                } catch {
                    if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    failureReported = true
                    OathDiagnostics.record(error, component: "provider", operation: "tron_read",
                        context: ["chain": "tron", "host": url.host ?? "", "attempt": String(attempt + 1)])
                    let retry: Bool
                    switch error { case TronError.http(let c): retry = c == 429 || c >= 500
                    default: retry = AnkrReadRetry.transientTransport(error) }
                    if retry && attempt < 2 { try await Task.sleep(for: .seconds(index ? 6 * (1 << attempt) : 1 << attempt)); continue }
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if let error = error as? TronError { throw error }
                    if error is DecodingError { throw TronError.malformed }
                    if error is URLError { throw TronError.transport }
                    if case AnkrError.transport = error { throw TronError.transport }
                    throw error
                }
            }
            throw TronError.transport
        } catch {
            // Only pre-request preparation failures lack an owning report.
            if !failureReported { OathDiagnostics.record(error) }
            await gate.release(); throw error
        }
    }
    public func verifyNetwork() async throws {
        if verified { return }
        let result = try await batch([("eth_chainId", [])])
        guard result[0].string == (network == .mainnet ? "0x2b6653dc" : "0xcd8690dc") else { throw TronError.wrongNetwork }
        verified = true
    }
    /// Every member is matched by ID. An RPC error cannot become a zero balance.
    func batch(_ calls: [(String, [TronJSON])]) async throws -> [TronJSON] {
        do { return try await batch(calls, at: rpc) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A standalone decimals() read follows the failed metadata batch
            // and NFT probe. Confirm a primary rejection on the verified node
            // before declaring the historical token unreadable.
            let confirmDecimals = error as? TronError == .rpc(-32000) && calls.count == 1
                && calls[0].0 == "eth_call" && calls[0].1.first?["data"].string == "0x313ce567"
            guard network == .mainnet, Self.canRecover(error) || confirmDecimals,
                  calls.allSatisfy({ ["eth_chainId", "eth_call"].contains($0.0) }) else { throw error }
            OathDiagnostics.record(error, component: "provider", operation: "tron_read_recovery",
                context: ["chain": "tron", "stage": confirmDecimals ? "token_decimals" : "rpc_read", "host": network.endpoint.host!])
            try await verifyRecoveryNetwork()
            return try await batch(calls, at: network.endpoint.appendingPathComponent("jsonrpc"))
        }
    }
    private static func canRecover(_ error: any Error) -> Bool {
        switch error {
        case TronError.transport: true
        case TronError.http(let status): status == 429 || (500...599).contains(status)
        default: false
        }
    }
    private func verifyRecoveryNetwork() async throws {
        if recoveryVerified { return }
        let identity = try await batch([("eth_chainId", [])], at: network.endpoint.appendingPathComponent("jsonrpc"))
        guard identity[0].string == "0x2b6653dc" else { throw TronError.wrongNetwork }
        let genesis = try await request(network.endpoint.appendingPathComponent("wallet/getblockbynum"), body: .object(["num": .number("0")]))
        guard genesis["blockID"].string == network.genesisID else { throw TronError.wrongNetwork }
        try Task.checkCancellation()
        recoveryVerified = true
    }
    private func batch(_ calls: [(String, [TronJSON])], at endpoint: URL) async throws -> [TronJSON] {
        guard !calls.isEmpty, calls.count <= 80 else { throw TronError.malformed }
        let body = TronJSON.array(calls.enumerated().map { i, call in
            .object(["jsonrpc": .string("2.0"), "id": .number(String(i)), "method": .string(call.0), "params": .array(call.1)])
        })
        var labelRequest = URLRequest(url: endpoint)
        labelRequest.httpMethod = "POST"
        if DiagnosticHTTP.optionalEVMTokenLabels { labelRequest.httpBody = try JSONEncoder().encode(body) }
        for attempt in 0..<3 {
            let value = try await request(endpoint, body: body)
            try Task.checkCancellation()
            guard let rows = value.array, rows.count == calls.count else { throw TronError.malformed }
            var results: [Int: TronJSON] = [:]; var transient = false
            var absentLabels = Set<Int>()
            for row in rows {
                guard row["jsonrpc"].string == "2.0", let n = row["id"].integer, n < calls.count, results[Int(n)] == nil else { throw TronError.malformed }
                if !row["error"].isNull {
                    guard let code = row["error"]["code"].text.flatMap(Int.init) else { throw TronError.malformed }
                    if DiagnosticHTTP.optionalEVMTokenLabels,
                       DiagnosticHTTP.expectedEVMTokenLabelAbsence(try JSONEncoder().encode(row), status: 200, request: labelRequest) {
                        // Only a reply-ID-matched name/symbol revert is absent
                        // metadata. Keep required decimals in this same batch.
                        results[Int(n)] = .null; absentLabels.insert(Int(n)); continue
                    }
                    OathDiagnostics.record(NSError(domain: "TronRPC", code: code,
                        userInfo: [NSLocalizedDescriptionKey: row["error"]["message"].string ?? "RPC rejected read"]),
                        component: "provider", operation: "tron_read_envelope",
                        context: ["chain": "tron", "rpc_code": String(code), "host": endpoint.host ?? ""])
                    if [429,-32603,-32005,-32090,-32055].contains(code) { transient = true }
                    else { throw TronError.rpc(code) }
                }
                results[Int(n)] = row["result"]
            }
            if transient {
                if attempt < 2 { try await Task.sleep(for: .seconds(1 << attempt)); continue }
                throw TronError.incomplete
            }
            return try calls.indices.map {
                guard let r = results[$0], !r.isNull || absentLabels.contains($0) else { throw TronError.malformed }
                return r
            }
        }
        throw TronError.incomplete
    }
    private func post(_ method: String, _ params: [String: TronJSON]) async throws -> TronJSON {
        do { return try await request(node.appendingPathComponent(method), body: .object(params)) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            guard network == .mainnet, Self.canRecover(error),
                  ["wallet/getaccount", "wallet/getassetissuebyid", "wallet/getassetissuebyname",
                   "walletsolidity/getnowblock", "wallet/gettransactionbyid", "wallet/gettransactioninfobyid"].contains(method) else { throw error }
            OathDiagnostics.record(error, component: "provider", operation: "tron_read_recovery",
                context: ["chain": "tron", "stage": "node_read", "host": network.endpoint.host!])
            try await verifyRecoveryNetwork()
            let result = try await request(network.endpoint.appendingPathComponent(method), body: .object(params))
            try Task.checkCancellation()
            return result
        }
    }
    private func indexed(_ owner: String, path: String = "", params: [String: String] = [:]) async throws -> TronJSON {
        _ = try TronIdentity.bytes(owner)
        var url = URLComponents(string: network.endpoint.absoluteString + "/v1/accounts/" + owner + path)!
        url.queryItems = params.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        let result = try await request(url.url!, index: true)
        guard result["success"] == .bool(true), result["data"].array != nil else { throw TronError.malformed }
        return result
    }
    public func token(_ reference: String) async throws -> TronToken {
        try await OathDiagnostics.withChain("tron") { try await readToken(reference) }
    }

    private func readToken(_ reference: String) async throws -> TronToken {
        if reference == "native" { return .init(reference: reference, name: "TRON", symbol: "TRX", decimals: 6) }
        if let info = metadata[reference] { return info }
        try await verifyNetwork()
        let token: TronToken
        if TronIdentity.isTRC10(reference) {
            let data = try await post("wallet/getassetissuebyid", ["value": .string(reference)])
            guard data["id"].string == reference else { throw TronError.malformed }
            guard data["precision"].isNull || data["precision"].integer != nil else { throw TronError.malformed }
            let decimals = data["precision"].integer ?? 0
            guard decimals <= 255, let name = data["name"].string, let symbol = data["abbr"].string,
                  let n = String(data: try TronIdentity.hex(name), encoding: .utf8),
                  let s = String(data: try TronIdentity.hex(symbol), encoding: .utf8) else { throw TronError.malformed }
            token = .init(reference: reference, name: (try? TronIdentity.clean(n)) ?? "TRC-10 " + reference, symbol: (try? TronIdentity.clean(s, limit: 64)) ?? reference, decimals: Int(decimals))
        } else {
            let address = try TronIdentity.callAddress(reference)
            let calls = ["06fdde03", "95d89b41", "313ce567"].map { selector in
                ("eth_call", [TronJSON.object(["to": .string(address), "data": .string("0x" + selector)]), .string("latest")])
            }
            let data: [TronJSON]
            do { data = try await DiagnosticHTTP.$optionalEVMTokenLabels.withValue(true) { try await batch(calls) } }
            catch { OathDiagnostics.record(error);
                try Task.checkCancellation()
                // Name/symbol are optional metadata in the fungible standard.
                // Keep usable balances when a legacy token omits either one.
                let supportsNFT = try? await batch([("eth_call",[.object(["to":.string(address),"data":.string("0x01ffc9a780ac58cd" + String(repeating:"0",count:56))]),.string("latest")])])[0]
                if let word = supportsNFT?.string, (try? TronIdentity.uint256(word)) == "1" { throw TronError.nonFungible }
                let decimals = try await batch([calls[2]])[0]
                let name = await OathDiagnostics.attempt("tron_token_name") {
                    try await DiagnosticHTTP.$optionalEVMTokenLabels.withValue(true) { try await batch([calls[0]])[0] }
                }
                let symbol = await OathDiagnostics.attempt("tron_token_symbol") {
                    try await DiagnosticHTTP.$optionalEVMTokenLabels.withValue(true) { try await batch([calls[1]])[0] }
                }
                data = [name ?? .null,symbol ?? .null,decimals]
            }
            let decodedDecimals = data[2].string.flatMap { try? TronIdentity.uint256($0) }.flatMap(UInt64.init)
            guard let decimals = decodedDecimals, decimals <= 255 else {
                let check = try? await batch([("eth_call",[.object(["to":.string(address),"data":.string("0x01ffc9a780ac58cd" + String(repeating:"0",count:56))]),.string("latest")])])[0]
                if let word = check?.string, (try? TronIdentity.uint256(word)) == "1" { throw TronError.nonFungible }
                throw TronError.malformed
            }
            let name = data[0].string.flatMap { try? TronIdentity.abiString($0) }
            let symbol = data[1].string.flatMap { try? TronIdentity.abiString($0) }
            token = .init(reference: reference, name: name ?? String(reference.prefix(6))+"…"+String(reference.suffix(4)), symbol: symbol ?? "TRC-20", decimals: Int(decimals))
        }
        try Task.checkCancellation()
        metadata[reference] = token
        return token
    }
    public func inventory(owner: String, additionalTokens: [String] = []) async throws -> TronInventory {
        try await OathDiagnostics.withChain("tron") {
            try await readInventory(owner: owner, additionalTokens: additionalTokens)
        }
    }
    private func readInventory(owner: String, additionalTokens: [String]) async throws -> TronInventory {
        _ = try TronIdentity.bytes(owner); try await verifyNetwork()
        let tracked = Set(additionalTokens.filter(TronIdentity.isAddress))
        guard tracked.count <= 30_000 else { throw TronError.incomplete }
        let ownerHex = String(try TronIdentity.callAddress(owner).dropFirst(2))
        // Completion time cannot make a state read before finality current.
        let observedAt = Date.now
        async let state = post("wallet/getaccount", ["address": .string(owner), "visible": .bool(true)])
        async let discovery = await OathDiagnostics.attempt("token_discovery") { try await indexed(owner) }
        // Saved/tracked contracts do not depend on index discovery or activation.
        // Structured child tasks retain cancellation and the shared HTTP budgets.
        async let trackedValues = tokenHoldings(contracts: tracked, known: [:], ownerHex: ownerHex)
        let account = try await state
        try Task.checkCancellation()
        if !account["address"].isNull { guard account["address"].string == owner else { throw TronError.wrongOwner } }
        else { guard account.fields?.isEmpty == true else { throw TronError.malformed } }
        let native = try TronIdentity.quantity(account["balance"].isNull ? .number("0") : account["balance"])
        guard account["assetV2"].isNull || account["assetV2"].array != nil else { throw TronError.malformed }
        var known: [String: String] = [:]
        for row in account["assetV2"].array ?? [] {
            guard let id = row["key"].string, TronIdentity.isTRC10(id), known[id] == nil else { throw TronError.malformed }
            known[id] = try TronIdentity.quantity(row["value"])
        }
        let legacyCount = known.count
        guard legacyCount + tracked.count <= 30_000 else { throw TronError.incomplete }
        async let legacyValues = tokenHoldings(contracts: [], known: known, ownerHex: ownerHex)
        let index = await discovery
        try Task.checkCancellation()
        let entries = index?["data"].array ?? []
        guard entries.count <= 1 else { throw TronError.malformed }
        if let first = entries.first {
            guard let address = first["address"].string, try TronIdentity.address(address) == owner else { throw TronError.wrongOwner }
            guard first["trc20"].isNull || first["trc20"].array != nil else { throw TronError.malformed }
        }
        var contracts = Set<String>()
        for item in entries.first?["trc20"].array ?? [] {
            guard let fields = item.fields, fields.count == 1, let pair = fields.first, TronIdentity.isAddress(pair.key) else { throw TronError.malformed }
            _ = try TronIdentity.quantity(pair.value); contracts.insert(pair.key)
        }
        var discoveryComplete = index != nil
        if account["address"].isNull {
            // TRC-20 receipts do not activate a TRON account. TronGrid can return
            // data:[] here even when contracts hold funds for this address.
            // Discover incoming contracts independently of the account object;
            // amounts still come exclusively from balanceOf, never event sums.
            let incoming = try await unactivatedTokenContracts(owner: owner)
            contracts.formUnion(incoming.contracts)
            discoveryComplete = incoming.complete
        }
        guard legacyCount + contracts.union(tracked).count <= 30_000 else { throw TronError.incomplete }
        // Only new contracts need a second pass. Indexed amounts are never
        // authoritative, and a tracked/indexed contract is read exactly once.
        async let discoveredValues = tokenHoldings(contracts: contracts.subtracting(tracked), known: [:], ownerHex: ownerHex)
        let (saved, legacy, discovered) = try await (trackedValues, legacyValues, discoveredValues)
        try Task.checkCancellation()
        let holdings = [TronHolding(token: try await token("native"), amount: native)] + saved.holdings + legacy.holdings + discovered.holdings
        let failed = Set(saved.failed + legacy.failed + discovered.failed).sorted()
        let excluded = Set(saved.excluded + legacy.excluded + discovered.excluded).sorted()
        return .init(owner: owner, holdings: holdings, failedReferences: failed, excludedNFTs: excluded, discoveryComplete: discoveryComplete, observedAt: observedAt,
                     raw: try JSONEncoder().encode(TronJSON.object(["node": account, "discovery": index ?? .null])))
    }

    private func unactivatedTokenContracts(owner: String) async throws -> (contracts: Set<String>, complete: Bool) {
        var contracts = Set<String>()
        var cursors = Set<String>()
        // Keep one fixed window across every fingerprint. Include recent,
        // unconfirmed receipts, since balanceOf reads the latest node state.
        var params = ["min_timestamp": "0", "max_timestamp": String(Int64(Date().timeIntervalSince1970 * 1000)),
                      "limit": "200", "order_by": "block_timestamp,desc", "only_to": "true", "only_confirmed": "false"]
        do {
            // At most 30,000 indexed records, matching the inventory budget.
            // Requests retain the shared public-provider pacing/cancellation.
            // Truncation or a failed later page must preserve earlier findings
            // and remain incomplete, so storage never clears unseen balances.
            for _ in 0..<150 {
                try Task.checkCancellation()
                let page = try await indexed(owner, path: "/transactions/trc20", params: params)
                let rows = page["data"].array!
                guard rows.count <= 200 else { throw TronError.malformed }
                var found = Set<String>()
                for row in rows {
                    guard let type = row["type"].string else { throw TronError.malformed }
                    // The endpoint also returns approvals. They do not establish
                    // a token holding; NFT classification stays in tokenHoldings.
                    if type == "Approval" { continue }
                    guard type == "Transfer", let recipient = row["to"].string,
                          try TronIdentity.address(recipient) == owner else { throw TronError.wrongOwner }
                    guard let reference = row["token_info"]["address"].string else { throw TronError.malformed }
                    found.insert(try TronIdentity.address(reference))
                }
                contracts.formUnion(found)
                guard !page["meta"]["fingerprint"].isNull else { return (contracts, true) }
                guard let next = page["meta"]["fingerprint"].string, !next.isEmpty, next.count < 4096,
                      !rows.isEmpty, cursors.insert(next).inserted else { throw TronError.paginationLoop }
                params["fingerprint"] = next
            }
            throw TronError.incomplete
        } catch {
            try Task.checkCancellation()
            if OathDiagnostics.isExpectedCancellation(error) { throw CancellationError() }
            OathDiagnostics.record(error, component: "tron_inventory", operation: "unactivated_token_discovery",
                                   context: ["chain": "tron", "stage": "transfer_index"])
            return (contracts, false)
        }
    }

    private struct InventoryTokens: Sendable {
        var holdings: [TronHolding] = []
        var failed: [String] = []
        var excluded: [String] = []
    }
    private func tokenHoldings(contracts: Set<String>, known: [String: String], ownerHex: String) async throws -> InventoryTokens {
        let references = (Array(known.keys) + Array(contracts)).sorted()
        guard !references.isEmpty else { return InventoryTokens() }
        // Metadata and balanceOf are independent reads. Overlap them without
        // increasing the four-request node limit or the public-provider budget.
        async let balances = contractBalances(contracts.sorted(), ownerHex: ownerHex)
        var tokens: [String: TronToken] = [:]
        var excluded = Set<String>()
        await withTaskGroup(of: (String, TronToken?, Bool).self) { group in
            var next = 0
            func enqueue() {
                guard next < references.count, !Task.isCancelled else { return }; let ref = references[next]; next += 1
                group.addTask {
                    do { return (ref, try await self.token(ref), false) }
                    catch TronError.nonFungible {
                        // ERC165-confirmed NFTs are not fungible balance failures.
                        return (ref, nil, true)
                    } catch { OathDiagnostics.record(error); return (ref, nil, false) }
                }
            }
            for _ in 0..<4 { enqueue() }
            for await (ref, token, nft) in group {
                if let token { tokens[ref] = token }
                if nft { excluded.insert(ref) }
                enqueue()
            }
        }
        let (amounts, failures) = try await balances
        try Task.checkCancellation()
        let quantities = known.merging(amounts) { _, new in new }
        var result = InventoryTokens(failed: failures)
        for ref in references {
            guard let amount = quantities[ref] else { result.failed.append(ref); continue }
            if let token = tokens[ref] { result.holdings.append(.init(token: token, amount: amount)) }
            else if excluded.contains(ref) { result.excluded.append(ref) }
            else { result.failed.append(ref) }
        }
        return result
    }
    private func contractBalances(_ contracts: [String], ownerHex: String) async throws -> ([String: String], [String]) {
        var balances: [String: String] = [:], failed: [String] = []
        // Twenty tokens per batch, three bounded workers. A failed token keeps
        // the existing individual-read isolation and is never treated as zero.
        let batches = stride(from: 0, to: contracts.count, by: 20).map { Array(contracts[$0..<min($0+20,contracts.count)]) }
        try await withThrowingTaskGroup(of: ([String:String],[String]).self) { group in
            var next = 0
            func enqueue() {
                guard next < batches.count, !Task.isCancelled else { return }
                let chunk = batches[next]; next += 1
                group.addTask { try await self.balances(chunk, ownerHex: ownerHex) }
            }
            for _ in 0..<3 { enqueue() }
            for try await (amounts, errors) in group { balances.merge(amounts) { _,new in new }; failed += errors; enqueue() }
        }
        try Task.checkCancellation()
        return (balances, failed)
    }
    private func balances(_ chunk: [String], ownerHex: String) async throws -> ([String:String],[String]) {
        let calls = try chunk.map { ref in ("eth_call", [TronJSON.object(["to": .string(try TronIdentity.callAddress(ref)), "from":.string("0x" + ownerHex), "data": .string("0x70a08231" + String(repeating: "0", count: 24) + ownerHex)]), .string("latest")]) }
        var balances: [String:String] = [:], failed: [String] = []
        do {
            let values = try await batch(calls)
            for (ref,value) in zip(chunk,values) { guard let text = value.string else { throw TronError.malformed }; balances[ref] = try TronIdentity.uint256(text) }
        } catch { OathDiagnostics.record(error);
            try Task.checkCancellation()
            // A reverting or nonstandard token cannot hide healthy neighbors.
            for (ref,call) in zip(chunk,calls) {
                do { let value = try await batch([call]); guard let text = value[0].string else { throw TronError.malformed }; balances[ref] = try TronIdentity.uint256(text) }
                catch { OathDiagnostics.record(error); try Task.checkCancellation(); failed.append(ref) }
            }
        }
        return (balances,failed)
    }
    public func history(owner: String, stream: TronStream, start: Int64, end: Int64, cursor: String? = nil, limit: Int = 50, confirmedOnly: Bool = true) async throws -> TronHistoryPage {
        guard start >= 0, end >= start, (1...200).contains(limit), cursor?.count ?? 0 < 4096 else { throw TronError.malformed }
        let path: String
        switch stream { case .transactions: path = "/transactions"; case .trc20: path = "/transactions/trc20"; case .internalTransactions: path = "/internal-transactions" }
        var params = ["min_timestamp": String(start), "max_timestamp": String(end), "limit": String(limit), "order_by": "block_timestamp,desc", "only_confirmed": confirmedOnly ? "true" : "false"]
        if let cursor { params["fingerprint"] = cursor }
        let value = try await indexed(owner, path: path, params: params)
        let rows = value["data"].array!
        guard rows.count <= limit else { throw TronError.malformed }
        var hashes: [String] = []
        for row in rows {
            let key = stream == .transactions ? "txID" : stream == .trc20 ? "transaction_id" : "tx_id"
            guard let hash = row[key].string, TronIdentity.hash(hash) else { throw TronError.malformed }
            hashes.append(hash)
        }
        let next = value["meta"]["fingerprint"].string
        // An empty data page with a continuation cannot safely be treated as EOF.
        guard next != cursor || next == nil, next == nil || (!next!.isEmpty && !rows.isEmpty) else { throw TronError.paginationLoop }
        return .init(hashes: Array(Set(hashes)).sorted(), cursor: next, raw: try JSONEncoder().encode(value))
    }
    private func solidHeight() async throws -> Int64 {
        if let solid, Date().timeIntervalSince(solid.time) < 15 { return solid.height }
        let value = try await post("walletsolidity/getnowblock", [:])
        guard let height = value["block_header"]["raw_data"]["number"].integer, height <= Int64.max else { throw TronError.malformed }
        solid = (Int64(height),.now); return Int64(height)
    }
    public func transaction(_ hash: String) async throws -> TronTransaction {
        guard TronIdentity.hash(hash) else { throw TronError.malformed }; try await verifyNetwork()
        async let body = post("wallet/gettransactionbyid", ["value": .string(hash)])
        async let receipt = post("wallet/gettransactioninfobyid", ["value": .string(hash)])
        async let height = solidHeight()
        let transaction = try await body
        var legacy: [String:String] = [:]
        for contract in transaction["raw_data"]["contract"].array ?? [] where contract["type"].string == "TransferAssetContract" {
            guard let name = contract["parameter"]["value"]["asset_name"].string else { throw TronError.malformed }
            let decoded = (try? TronIdentity.hex(name)).flatMap { String(data:$0,encoding:.utf8) } ?? ""
            if !TronIdentity.isTRC10(name), !TronIdentity.isTRC10(decoded) {
                // Before TRON proposal 14, transfers used unique asset names.
                // Resolve that historic name to the canonical numeric token ID.
                let asset = try await post("wallet/getassetissuebyname", ["value":.string(name)])
                guard asset["name"].string?.lowercased() == name.lowercased(),
                      let id = asset["id"].string, TronIdentity.isTRC10(id) else { throw TronError.incomplete }
                legacy[name] = id
            }
        }
        return try await TronDecoding.transaction(hash: hash, body: transaction, receipt: receipt, solidHeight: height, legacyAssetIDs: legacy)
    }
}
