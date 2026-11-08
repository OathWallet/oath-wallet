import Foundation
import OathAnkr
import OathDatabase

/// Runs with CheckSendRecipient.py against the actual link parser, inbox, send
/// model and SQLite store. All addresses are deterministic public test vectors.
/// No app, provider, signing, simulator or user wallet is involved.
@MainActor enum SharedPaymentLinkChecks {
    static func run(addresses: [OathImportChain: String], recipients: [OathImportChain: String], defaults: UserDefaults) async throws -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        func request(_ address: String, _ chain: OathImportChain, _ reference: String = "native") -> (URL, OathScannedRecipient) {
            guard let url = OathWalletLink.paymentURL(address: address, chain: chain, reference: reference),
                  case .payment(let recipient) = OathWalletLink.parse(url) else { preconditionFailure("Share/parse round trip: " + chain.id) }
            return (url, recipient)
        }
        func modified(_ url: URL, _ changes: [String: String?]) -> URL {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var items = parts.queryItems!
            for (key, value) in changes {
                items.removeAll { $0.name == key }
                if let value { items.append(.init(name: key, value: value)) }
            }
            parts.queryItems = items; return parts.url!
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-payment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let chains = OathImportChain.enabledCases
        for chain in chains {
            let decimals = [OathImportChain.bitcoin, .bitcoincash, .litecoin, .dogecoin, .aptos].contains(chain) ? 8 : 6 // Synthetic test metadata.
            try await database.seed(networks: [.init(id: chain.id, name: chain.name, family: "account", symbol: "TEST",
                decimals: decimals, derivationPath: "fixture", logo: "test", sortOrder: 0)],
                assets: [.init(id: chain.id + ":native", networkID: chain.id, reference: "native", name: chain.name, symbol: "TEST", decimals: decimals)])
        }
        let wallet = "shared-payments"
        try await database.importWalletIfNeeded(.init(id: wallet, name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: chains.map { .init(id: wallet + $0.id, walletID: wallet, networkID: $0.id, address: addresses[$0]!, derivationPath: "fixture") })
        var snapshot = try await database.snapshot(walletID: wallet, currency: "USD")
        let nativeOnly: Set<OathImportChain> = [.bitcoin, .bitcoincash, .litecoin, .dogecoin]
        let memoChains: Set<OathImportChain> = [.xrpl, .stellar]
        for chain in chains {
            let (url, shared) = request(recipients[chain]!, chain)
            let native = snapshot.holdings.first { $0.networkID == chain.id && $0.reference == "native" }!
            check(shared.networks == [chain] && shared.decoded(on: chain)?.address == OathScanAddress.decode(recipients[chain]!, chain: chain)?.address, "Native link binds network/address: " + chain.id)
            check(shared.amount == nil, "Receive link never invents an amount")
            let model = OathSendModel(walletID: wallet, scannedRecipient: shared, preferences: defaults)
            model.prepareInitialSelection(from: snapshot)
            if nativeOnly.contains(chain) {
                check(model.path == [.amount] && model.holdingID == native.id, "Native-only chain opens Amount: " + chain.id)
            } else if memoChains.contains(chain) {
                check(model.path == [.recipient] && model.holdingID == native.id, "Memo chain opens Recipient: " + chain.id)
            } else {
                check(model.path.isEmpty && model.holdingID == nil, "Native token network opens Select Asset: " + chain.id)
                check(model.holdings.allSatisfy { $0.networkID == chain.id }, "Picker cannot escape shared network")
                model.choose(native, from: snapshot)
                check(model.path == [.amount], "Explicit native choice advances to Amount")
            }
            check(model.address == shared.decoded(on: chain)?.address, "Recipient survives selection")
            check(!model.prepareReview(locale: Locale(identifier: "en_US_POSIX")), "Link never authorizes an empty payment")
            model.path = []
            model.prepareInitialSelection(from: snapshot)
            check(model.path.isEmpty, "Balance refresh/back must not redirect a second time")
            for key in ["v", "uri", "network", "scope"] {
                check(OathWalletLink.parse(URL(string: url.absoluteString + "&" + key + "=duplicate")!) == nil, "Duplicate fields rejected")
            }
        }

        // Same ticker on another chain or another contract must never substitute.
        var references: [OathImportChain: String] = [
            .bnb: "0x55d398326f99059ff775485246999027b3197955",
            .ethereum: "0xdac17f958d2ee523a2206206994597c13d831ec7",
            .solana: "So11111111111111111111111111111111111111112",
            .stellar: try StellarIdentity.contract(code: "USD", issuer: addresses[.stellar]!),
            .xrpl: "USD." + addresses[.xrpl]!, .ton: addresses[.ton]!, .tron: TronIdentity.usdt,
            .near: "wrap.near", .aptos: "0x1::coin::Token", .sui: "0x1::coin::Token",
            .polkadot: "1984", .thorchain: "THOR.TEST"]
        for chain in chains where chain.isEVM && references[chain] == nil {
            references[chain] = "0x4444444444444444444444444444444444444444"
        }
        for (chain, reference) in references where chain.isEnabled {
            let (_, shared) = request(recipients[chain]!, chain, reference)
            let canonical = shared.token!
            try await database.trackAsset(.init(id: chain.id + ":" + canonical, networkID: chain.id, reference: canonical,
                name: "Fixture token", symbol: "SAME", decimals: 6), walletID: wallet)
            snapshot = try await database.snapshot(walletID: wallet, currency: "USD")
            let target = snapshot.holdings.first { $0.networkID == chain.id && $0.reference == canonical }!
            let model = OathSendModel(walletID: wallet, scannedRecipient: shared, preferences: defaults)
            model.prepareInitialSelection(from: snapshot)
            check(model.holdingID == target.id && model.path == (memoChains.contains(chain) ? [.recipient] : [.amount]), "Exact token routes without an amount: " + chain.id)
            check(model.holdings.count == 1 && model.holdings.first?.id == target.id, "Exact shared token cannot substitute another holding")
            let candidates = shared.prioritized(snapshot.holdings, network: { $0.networkID }, reference: { $0.reference }, symbol: { $0.symbol })
            check(candidates.map(\.id) == [target.id], "Picker enforces exact token identity")
            let native = snapshot.holdings.first { $0.networkID == chain.id && $0.reference == "native" }!
            model.choose(native, from: snapshot)
            check(model.holdingID == target.id, "Manual selection cannot silently drop shared token")
            if memoChains.contains(chain) {
                var withMemo = shared; withMemo.memo = "42"; withMemo.memoType = chain == .stellar ? "id" : nil
                let review = OathSendModel(walletID: wallet, scannedRecipient: withMemo, preferences: defaults)
                review.prepareInitialSelection(from: snapshot)
                check(review.path == [.recipient] && review.memo == "42", "Shared issued token always requires tag/memo review")
                check(review.validateRecipient(), "Recipient can explicitly continue with valid tag/memo")
                withMemo.memo = nil; withMemo.memoType = nil
                let noMemo = OathSendModel(walletID: wallet, scannedRecipient: withMemo, preferences: defaults)
                noMemo.prepareInitialSelection(from: snapshot)
                check(noMemo.validateRecipient() && !noMemo.validateScannedRecipient(), "Blank optional memo still requires an explicit Recipient step")
            }
        }
        // An ETH native share remains open to ETH tokens, despite the portfolio
        // containing one native coin and a same-symbol token on many networks.
        let (_, ethereum) = request(recipients[.ethereum]!, .ethereum)
        let ethModel = OathSendModel(walletID: wallet, scannedRecipient: ethereum, preferences: defaults)
        ethModel.prepareInitialSelection(from: snapshot)
        let ethToken = snapshot.holdings.first { $0.networkID == "ethereum" && $0.reference != "native" }!
        ethModel.choose(ethToken, from: snapshot)
        check(ethModel.path == [.amount] && ethModel.holdingID == ethToken.id && ethModel.address == recipients[.ethereum], "Network-wide share can pay in a selected token")

        let (bnbURL, bnbRequest) = request(recipients[.bnb]!, .bnb, references[.bnb]!)
        for changes: [String: String?] in [
            ["v": "2"], ["v": nil], ["scope": nil], ["scope": "unknown"], ["asset": nil], ["asset": "USDT"],
            ["asset": ""], ["asset": "0x123"], ["asset": "\u{202E}USDT"], ["asset": "native\n"],
            ["network": nil], ["network": "unknown"], ["network": "bitcoin"], ["scope": "network"],
            ["uri": "ethereum:" + recipients[.bnb]! + "?amount=1"], ["uri": bnbURL.absoluteString], ["uri": "https://example.com/request"],
            ["uri": recipients[.bnb]! + "?memo=42"], ["asset": String(repeating: "x", count: 4_097)]] {
            check(OathWalletLink.parse(modified(bnbURL, changes)) == nil, "Malformed or contradictory versioned payment rejected")
        }
        check(OathWalletLink.paymentURL(address: recipients[.bitcoin]!, chain: .bitcoin, reference: references[.bnb]!) == nil, "Native-only token requests are rejected")
        check(OathWalletLink.paymentURL(address: recipients[.ethereum]!, chain: .bitcoin) == nil, "Wrong address network rejected")
        let (_, canonicalBNB) = request(recipients[.bnb]!, .bnb, "0x" + String(references[.bnb]!.dropFirst(2)).uppercased())
        check(canonicalBNB.token == bnbRequest.token, "EVM checksum spelling normalizes to exact identity")
        let (_, ton) = request(recipients[.ton]!, .ton, try TonIdentity.friendly(addresses[.ton]!, bounceable: false))
        check(ton.matchesAsset(networkID: "ton", reference: addresses[.ton]!), "TON friendly and raw references identify the same jetton")
        let (_, trc10) = request(recipients[.tron]!, .tron, "1002000")
        check(trc10.token == "1002000", "TRC-10 numeric token identity survives sharing")
        let (_, stellarAlias) = request(recipients[.stellar]!, .stellar, "USD:" + addresses[.stellar]!)
        check(stellarAlias.token == references[.stellar], "Stellar code and issuer normalize to exact contract")

        // An unsaved token resolves by identity; failed lookup stays actionable.
        let (_, unknown) = request(recipients[.ethereum]!, .ethereum, "0x5555555555555555555555555555555555555555")
        let account = snapshot.accounts.first { $0.networkID == "ethereum" }!
        let preview = Holding.catalogPreview(account: account, address: account.address, assetID: "ethereum:" + unknown.token!, reference: unknown.token!, name: "Fixture", symbol: "SAME", logo: nil)
        func unresolved() -> OathSendModel {
            let model = OathSendModel(walletID: wallet, scannedRecipient: unknown, preferences: defaults)
            model.prepareInitialSelection(from: snapshot)
            check(model.scannedAssetResolution?.accountID == account.id && model.holdings.isEmpty, "Unsaved token schedules lookup without offering other tokens")
            return model
        }
        let missing = unresolved()
        await missing.resolveScannedAsset { _, _ in nil }
        check(missing.scannedAssetUnavailable && missing.path.isEmpty, "Unresolved token exposes retry and never selects native")
        missing.retrySharedPaymentAsset()
        check(missing.scannedAssetResolution != nil && !missing.scannedAssetUnavailable, "Lookup is retryable")
        await missing.resolveScannedAsset { _, current in (preview, current) }
        check(missing.path.isEmpty && missing.scannedAssetUnavailable, "Shared link cannot strand Amount on a metadata-only preview")
        check(!missing.prepareReview(locale: Locale(identifier: "en_US_POSIX")), "Preview cannot prepare a transaction")
        try await database.trackAsset(.init(id: preview.assetID, networkID: "ethereum", reference: preview.reference, name: "Fixture", symbol: "SAME", decimals: 6), walletID: wallet)
        let resolvedSnapshot = try await database.snapshot(walletID: wallet, currency: "USD")
        let resolvedHolding = resolvedSnapshot.holdings.first { $0.id == preview.id }!
        missing.retrySharedPaymentAsset()
        await missing.resolveScannedAsset { _, _ in (resolvedHolding, resolvedSnapshot) }
        check(missing.path == [.amount] && missing.holding?.isCatalogPreview == false, "Persisted token metadata completes direct Amount navigation")
        for action in 0..<6 {
            let stale = unresolved()
            await stale.resolveScannedAsset { _, current in
                switch action {
                case 0: stale.query = "manual search"
                case 1: stale.selectWallet("other")
                case 2: stale.cancelScannedAssetResolution()
                case 3: stale.path = [.recipient]; stale.path = []
                case 4: return (ethToken, current)
                default: return (current.holdings.first { $0.networkID == "bnb" }!, current)
                }
                return (resolvedHolding, resolvedSnapshot)
            }
            check(stale.holdingID == nil && !stale.path.contains(.amount), "Stale or mismatched completion cannot navigate")
        }
        let cancelled = unresolved()
        let pending = Task { await cancelled.resolveScannedAsset { _, current in
            withUnsafeCurrentTask { $0?.cancel() }; return (resolvedHolding, resolvedSnapshot)
        } }
        await pending.value
        check(cancelled.holdingID == nil && cancelled.path.isEmpty, "Cancelled asynchronous resolution cannot navigate")

        // Multiple accounts require a visible sender choice, including when the
        // requested token is already saved on both accounts.
        let multi = "shared-multiple"
        let accounts = [account.address, recipients[.ethereum]!].enumerated().map { index, address in
            AccountRecord(id: multi + String(index), walletID: multi, networkID: "ethereum", address: address, derivationPath: "fixture", accountIndex: index)
        }
        try await database.importWalletIfNeeded(.init(id: multi, name: "Fixture", kind: "hd", vaultReference: multi, createdAt: 1), accounts: accounts)
        let multiSnapshot = try await database.snapshot(walletID: multi, currency: "USD")
        let multiple = OathSendModel(walletID: multi, scannedRecipient: unknown, preferences: defaults)
        multiple.prepareInitialSelection(from: multiSnapshot)
        check(multiple.needsSharedPaymentAccount && multiple.scannedAssetResolution == nil && multiple.path.isEmpty, "Ambiguous sender is never guessed")
        multiple.selectSharedPaymentAccount(accounts[0].id)
        check(multiple.scannedAssetResolution?.accountID == accounts[0].id, "Explicit sender scopes token lookup")
        try await database.trackAsset(.init(id: preview.assetID, networkID: "ethereum", reference: preview.reference, name: "Fixture", symbol: "SAME", decimals: 6), walletID: multi)
        let savedMulti = try await database.snapshot(walletID: multi, currency: "USD")
        let selectedHolding = savedMulti.holdings.first { $0.accountID == accounts[0].id && $0.reference == preview.reference }!
        await multiple.resolveScannedAsset { _, _ in (selectedHolding, savedMulti) }
        check(multiple.holding?.accountID == accounts[0].id && multiple.path == [.amount], "Resolved token retains selected account")
        multiple.path = []
        check(multiple.needsSharedPaymentAccount, "Back permits choosing a different sender without auto-navigation")
        multiple.selectSharedPaymentAccount(accounts[1].id)
        check(multiple.holding?.accountID == accounts[1].id && multiple.path == [.recipient] && multiple.selfTransferRestriction != nil,
              "Shared link cannot bypass self-transfer rules after sender change")
        let savedChoice = OathSendModel(walletID: multi, scannedRecipient: unknown, preferences: defaults)
        savedChoice.prepareInitialSelection(from: savedMulti)
        check(savedChoice.needsSharedPaymentAccount && savedChoice.path.isEmpty, "Saved holdings still require explicit sender")
        savedChoice.selectSharedPaymentAccount(accounts[0].id)
        check(savedChoice.path == [.amount] && savedChoice.holding?.accountID == accounts[0].id && savedChoice.holding?.isCatalogPreview == false,
              "Selecting a saved account uses its persisted holding")

        for chain in memoChains {
            let routedAddress: String
            if chain == .xrpl {
                routedAddress = OathScanAddress.base58Encode(Data([0x05, 0x44]) + (try XrplIdentity.accountBytes(recipients[chain]!)) + Data([1, 42, 0, 0, 0, 0, 0, 0, 0]), alphabet: OathScanAddress.rippleAlphabet)
            } else {
                routedAddress = OathScanAddress.strKey(Data(try StellarIdentity.bytes(recipients[chain]!, version: 48)) + Data([0, 0, 0, 0, 0, 0, 0, 42]), version: 96)
            }
            let (_, tagged) = request(routedAddress, chain)
            let payer = OathSendModel(walletID: wallet, scannedRecipient: tagged, preferences: defaults)
            payer.prepareInitialSelection(from: snapshot)
            check(payer.path == [.recipient] && payer.memo == "42" && payer.validateRecipient(), "Embedded routing tag survives link but still requires review")
            var legacy = URLComponents(string: "oathwallet://pay")!
            legacy.queryItems = [.init(name: "uri", value: (chain == .xrpl ? "xrp:" : "stellar:") + recipients[chain]! + "?amount=1&memo=42"), .init(name: "network", value: chain.id)]
            guard case .payment(let old)? = OathWalletLink.parse(legacy.url!) else { preconditionFailure("Legacy memo link") }
            let oldPayer = OathSendModel(walletID: wallet, scannedRecipient: old, preferences: defaults)
            oldPayer.prepareInitialSelection(from: snapshot)
            check(oldPayer.path == [.recipient] && oldPayer.memo == "42", "Legacy Oath shares also preserve explicit memo review")
        }
        for chain in OathImportChain.allCases where !chain.isEnabled {
            check(OathWalletLink.paymentURL(address: recipients[.ethereum]!, chain: chain) == nil, "Disabled chain cannot be re-enabled by link")
        }

        // Real inbox delivery exercises cold start/unlock deferral, coalescing,
        // active sheets and expiry without depending on scene callback order.
        let inbox = OathWalletLinkInbox(), now = Date.now
        inbox.receive(bnbURL, now: now)
        let delivery = inbox.pending?.id
        inbox.receive(bnbURL, now: now)
        check(inbox.pending?.id == delivery, "Duplicate scene/SwiftUI delivery coalesces")
        check(inbox.take(now: now, walletConnectOnly: true) == nil && inbox.pending != nil, "Other flow cannot consume queued payment")
        guard case .payment(let delivered)? = inbox.take(now: now)?.route else { preconditionFailure("Unlock delivery") }
        let payer = OathSendModel(walletID: wallet, scannedRecipient: delivered, preferences: defaults)
        payer.prepareInitialSelection(from: snapshot)
        check(payer.path == [.amount] && payer.holding?.reference == references[.bnb] && payer.holding?.networkID == "bnb", "Receive→URL→inbox→send opens the exact BNB USDT amount screen")
        check(inbox.take(now: now) == nil, "Consumed payment cannot reopen")
        inbox.receive(bnbURL, now: now.addingTimeInterval(4))
        check(inbox.pending == nil, "Active send does not queue duplicates")
        inbox.didDismiss(); inbox.receive(bnbURL, now: now.addingTimeInterval(4))
        check(inbox.pending != nil, "Later explicit link open remains possible")
        check(inbox.take(now: now.addingTimeInterval(305)) == nil, "Expired queued payment discarded")
        print("Passed \(count) shared-payment integration checks (real parser, inbox, send model and SQLite).")
        return count
    }
}
