import Foundation
import CryptoKit
import OathBrowser
import OathAnkr
import OathDatabase
import OathDiagnostics

struct OathBrowserReview: Identifiable {
    enum Payload {
        case connect
        case network
        case message(Data, WalletConnectSignIn?)
        case typed(WalletConnectTypedData)
        case transaction(WalletConnectEVMRequest, OathEVMQuote, WalletConnectApprovalToken?, ThorchainEVMSwapReview?)
    }
    let id: UUID
    let context: DAppRequestOrigin
    let account: AccountRecord
    let network: EVMSendNetwork
    let method: String
    let sendID: String
    var payload: Payload
}

extension OathBrowserController {
    func beginApproval(method: String, data: Data, context: DAppRequestOrigin, reply: @escaping ([String: Any]) -> Void) {
        let id = UUID()
        guard OathDAppApprovalGate.shared.claim(id) else { reply(Self.error(.busy)); return }
        approvalID = id; approvalOrigin = context; approvalWalletID = session?.displayedProfile?.id.uuidString
        approvalScope = session?.selectedHomeAccount; pendingReply = reply; preparing = true; approvalCancelled = false
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try validateApproval(id)
                let item = try await prepare(method: method, data: data, context: context, id: id)
                try validateApproval(id); review = item; preparing = false
            } catch is CancellationError { if approvalID == id { cancelApproval() } }
            catch let error as BrowserRPCError {
                // diagnostics: browser-peer-validation
                finishApproval(id, response: Self.error(error)) }
            catch {
                // Malformed peer JSON/sign-in/typed requests are expected validation, never telemetry payloads.
                if !(error is DecodingError) && !(error is WalletConnectJSON.Failure) && !(error is WalletConnectEVMRequest.Failure) && !(error is WalletConnectTypedData.Failure) && !(error is WalletConnectSignIn.Failure) {
                    OathDiagnostics.record(error, component: "browser", operation: "prepare_approval")
                }
                finishApproval(id, response: Self.error(.init(-32000, "Unable to prepare this request. Check the account, network and available gas.")))
            }
        }
    }
    private func prepare(method: String, data: Data, context: DAppRequestOrigin, id: UUID) async throws -> OathBrowserReview {
        guard let session, let tab = selected, let walletID = approvalWalletID else { throw BrowserRPCError.disconnected }
        let database = try await session.vault.database()
        let accounts = try await database.walletConnectAccounts(walletID: walletID, scope: .connection).filter {
            $0.supportsActiveUse && OathImportChain(rawValue: $0.networkID)?.isEnabled == true && EVMSendNetwork(rawValue: $0.networkID)?.isTestnet == false
        }
        try validateApproval(id)
        var chainID = tab.chainID
        if method == "wallet_switchEthereumChain" {
            let supported = Set(accounts.compactMap { EVMSendNetwork(rawValue: $0.networkID)?.chainID })
            chainID = try WalletConnectNetworkRequest.chainID(params: data, supported: supported, authorized: supported)
        }
        let existing = permission(tab)
        let connecting = ["eth_requestAccounts", "wallet_requestPermissions"].contains(method)
        if !connecting { guard existing != nil else { throw BrowserRPCError.unauthorized } }
        guard let account = accounts.first(where: { EVMSendNetwork(rawValue: $0.networkID)?.chainID == chainID }) ?? (connecting ? accounts.first : nil),
              let network = EVMSendNetwork(rawValue: account.networkID) else { throw BrowserRPCError(4902, "This wallet does not support the requested network.") }
        if !connecting && method != "wallet_switchEthereumChain" {
            guard existing?.accountID == account.id, existing?.address.lowercased() == account.address.lowercased() else { throw BrowserRPCError.unauthorized }
        }
        let sendID = "browser:" + SHA256.hash(data: Data((context.documentID.uuidString + ":" + id.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        let payload: OathBrowserReview.Payload
        switch method {
        case "eth_requestAccounts":
            guard try JSONDecoder().decode([SolanaJSON].self, from: data).isEmpty else { throw BrowserRPCError.invalid }; payload = .connect
        case "wallet_requestPermissions":
            guard let params = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], params.count == 1,
                  Set(params[0].keys) == ["eth_accounts"] else { throw BrowserRPCError.unsupported }; payload = .connect
        case "wallet_switchEthereumChain": payload = .network
        case "personal_sign":
            let values = try JSONDecoder().decode([String].self, from: data)
            guard let message = OathWalletConnectPolicy.personalMessage(values, account: account.address) else { throw BrowserRPCError.invalid }
            payload = .message(message, try WalletConnectSignIn.parse(message, account: account.address, chainID: network.chainID, website: context.origin.string))
        case "eth_signTypedData_v4":
            guard let values = try JSONSerialization.jsonObject(with: data) as? [Any], values.count == 2,
                  (values[0] as? String)?.lowercased() == account.address.lowercased() else { throw BrowserRPCError.invalid }
            let raw: Data
            if let text = values[1] as? String { raw = Data(text.utf8) }
            else { raw = try JSONSerialization.data(withJSONObject: values[1]) }
            guard raw.count <= 65_536 else { throw BrowserRPCError.invalid }
            payload = .typed(try WalletConnectTypedData(json: raw, chainID: network.chainID, account: account.address))
        case "eth_sendTransaction":
            let request = try WalletConnectEVMRequest(params: data, account: account.address, chainID: network.chainID)
            async let quote = OathDAppEVMCoordinator.quote(request, requestID: sendID, walletID: walletID, accountID: account.id, vault: session.vault)
            async let token = OathDiagnostics.attemptOptional("browser_approval_metadata") { try await OathEVMSendService.shared.walletConnectApprovalToken(request) }
            async let swap = OathDAppEVMCoordinator.thorchainReview(request)
            payload = try await .transaction(request, quote, token, swap)
        default: throw BrowserRPCError.unsupported
        }
        return .init(id: id, context: context, account: account, network: network, method: method, sendID: sendID, payload: payload)
    }
    func validateApproval(_ id: UUID) throws {
        guard approvalID == id, !approvalCancelled, let origin = approvalOrigin,
              approvalWalletID == session?.displayedProfile?.id.uuidString, approvalScope == session?.selectedHomeAccount else { throw BrowserRPCError.disconnected }
        try validate(origin)
    }
    func cancelApproval(tabID: UUID? = nil) {
        guard let id = approvalID, tabID == nil || approvalOrigin?.tabID == tabID else { return }
        approvalCancelled = true; review = nil; preparing = false
        if signing { return } // The durable submission owner determines whether bytes were committed.
        preparationTask?.cancel(); preparationTask = nil
        finishApproval(id, response: Self.error(.rejected))
    }
    func finishApproval(_ id: UUID, response: [String: Any]) {
        guard approvalID == id else { return }
        let reply = pendingReply; pendingReply = nil; approvalID = nil; approvalOrigin = nil; approvalWalletID = nil
        review = nil; preparing = false; preparationTask = nil; signing = false
        reply?(response); OathDAppApprovalGate.shared.release(id)
    }
    func reviseApproval(amount: String) async throws {
        guard !signing, let item = review, let session,
              case .transaction(let request, let oldQuote, let token, _) = item.payload else { throw BrowserRPCError.invalid }
        try validateApproval(item.id)
        let revised = try request.replacingApprovalAmount(amount)
        let quote = try await OathDAppEVMCoordinator.quote(revised, requestID: item.sendID, walletID: item.account.walletID,
            accountID: item.account.id, vault: session.vault)
        try validateApproval(item.id)
        guard !signing, case .transaction(_, let current, _, _) = review?.payload, current == oldQuote else { throw BrowserRPCError.disconnected }
        var updated = item; updated.payload = .transaction(revised, quote, token, nil); review = updated
    }
    func approve(digits: [UInt8]?, reason: String) async throws {
        guard !signing, let item = review, let session else { throw BrowserRPCError.disconnected }
        try validateApproval(item.id); signing = true
        defer { signing = false }
        do {
            let value: Any
            switch item.payload {
            case .connect, .network:
                try await session.vault.authenticateSecurityAccess(digits: digits, reason: reason)
                try validateApproval(item.id)
                let db = try await session.vault.database()
                guard try await db.walletConnectAccounts(walletID: item.account.walletID, scope: .connection).contains(where: { $0.id == item.account.id && $0.address == item.account.address && $0.supportsActiveUse }) else { throw BrowserRPCError.unauthorized }
                try validateApproval(item.id)
                guard let tab = selected else { throw BrowserRPCError.disconnected }
                grant(.init(origin: item.context.origin, walletID: item.account.walletID, accountID: item.account.id,
                    address: item.account.address, chainID: item.network.chainID), tab: tab)
                switch item.payload {
                case .network: value = NSNull()
                default: value = item.method == "wallet_requestPermissions" ? [["parentCapability": "eth_accounts"]] as Any : [item.account.address] as Any
                }
            case .message(let message, let signIn):
                try signIn?.validateTime()
                value = try await OathDAppEVMCoordinator.signMessage(walletID: item.account.walletID, accountID: item.account.id,
                    message: message, vault: session.vault, digits: digits, reason: reason)
                try validateApproval(item.id); try signIn?.validateTime()
            case .typed(let data):
                value = try await OathDAppEVMCoordinator.signTypedData(walletID: item.account.walletID, accountID: item.account.id,
                    data: data, vault: session.vault, digits: digits, reason: reason)
                try validateApproval(item.id); try data.validatePermissionTime()
            case .transaction(let request, let quote, _, let swap):
                guard request.matches(quote.plan) else { throw EVMSendError.changed }
                if let swap {
                    guard swap.quote.expires > .now, swap.deposit.expiry.map({ Double($0) > Date.now.timeIntervalSince1970 }) ?? true else { throw EVMSendError.expired }
                }
                let submission = try await OathDAppEVMCoordinator.submit(quote, vault: session.vault, digits: digits, reason: reason,
                    requestID: item.sendID, authorization: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.validateApproval(item.id)
                    })
                // A committed transaction remains a success even if the page closed during broadcast.
                finishApproval(item.id, response: ["result": submission.txid]); return
            }
            try validateApproval(item.id); finishApproval(item.id, response: ["result": value])
        } catch {
            // diagnostics: browser-approval-propagation
            // Native review owns the final error boundary.
            // Authentication fallback is handled by the native review; changed quotes require fresh consent.
            if approvalCancelled { finishApproval(item.id, response: Self.error(.rejected)); throw CancellationError() }
            if error as? EVMSendError == .expired || error as? EVMSendError == .changed,
               case .transaction(let request, _, _, _) = item.payload {
                async let quote = OathDAppEVMCoordinator.quote(request, requestID: item.sendID, walletID: item.account.walletID, accountID: item.account.id, vault: session.vault)
                async let token = OathDiagnostics.attemptOptional("browser_approval_metadata") { try await OathEVMSendService.shared.walletConnectApprovalToken(request) }
                async let swap = OathDAppEVMCoordinator.thorchainReview(request)
                var updated = item; updated.payload = try await .transaction(request, quote, token, swap)
                try validateApproval(item.id); review = updated
                throw OathWalletConnectService.ReviewFailure.quoteUpdated
            }
            throw error
        }
    }
}
