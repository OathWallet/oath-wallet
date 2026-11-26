import Foundation
import Observation
import OathAnkr
import OathDatabase

/// Both transports own their consent/origin checks. This shared coordinator
/// owns the same immutable preparation, authentication and journal submission.
enum OathDAppEVMCoordinator {
    static func quote(_ request: WalletConnectEVMRequest, requestID: String, walletID: String,
                      accountID: String, vault: OathWalletVault) async throws -> OathEVMQuote {
        try await OathEVMSendService.shared.walletConnectQuote(request, requestID: requestID, walletID: walletID, accountID: accountID, vault: vault)
    }
    static func submit(_ quote: OathEVMQuote, vault: OathWalletVault, digits: [UInt8]?, reason: String,
                       requestID: String, authorization: @escaping @Sendable () async throws -> Void) async throws -> OathBitcoinSubmission {
        try await OathEVMSendService.shared.submit(quote, vault: vault, digits: digits, reason: reason,
            walletConnectRequestID: requestID, authorization: authorization)
    }
    static func signMessage(walletID: String, accountID: String, message: Data, vault: OathWalletVault,
                            digits: [UInt8]?, reason: String) async throws -> String {
        try await vault.signWalletConnectMessage(walletID: walletID, accountID: accountID, message: message, digits: digits, reason: reason)
    }
    static func signTypedData(walletID: String, accountID: String, data: WalletConnectTypedData, vault: OathWalletVault,
                              digits: [UInt8]?, reason: String) async throws -> String {
        try data.validatePermissionTime()
        return try await vault.signWalletConnectTypedData(walletID: walletID, accountID: accountID, data: data, digits: digits, reason: reason)
    }
    @concurrent nonisolated static func thorchainReview(_ request: WalletConnectEVMRequest) async throws -> ThorchainEVMSwapReview? {
        guard let deposit = ThorchainEVMDeposit(request),
              let source = EVMSendNetwork.allCases.first(where: { $0.chainID == request.chainID }) else { return nil }
        let client = try await OathEVMSendService.shared.connection(source)
        let decimals = try await client.thorchainDepositDecimals(deposit)
        guard let review = try await ThorchainClient().walletConnectEVMSwapReview(deposit, decimals: decimals) else { return nil }
        let memo = review.quote.memo
        guard let destination = OathImportChain(rawValue: memo.networkID),
              OathScanAddress.decode(memo.destination, chain: destination) != nil else { throw WalletConnectEVMRequest.Failure.malformed }
        return review
    }
}

@MainActor @Observable final class OathDAppApprovalGate {
    static let shared = OathDAppApprovalGate()
    private(set) var browserRequest: UUID?
    func claim(_ id: UUID) -> Bool {
        let relay = OathWalletConnectService.shared
        guard browserRequest == nil, !relay.needsPresentation, !relay.presentationOpen,
              !relay.preparingRequest, !relay.working else { return false }
        browserRequest = id; return true
    }
    func release(_ id: UUID) {
        guard browserRequest == id else { return }
        browserRequest = nil
        OathWalletConnectService.shared.resumeRequests()
    }
}
