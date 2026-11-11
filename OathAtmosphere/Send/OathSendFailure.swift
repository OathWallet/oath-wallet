import Foundation
import OathAnkr
import OathBitcoin
import OathDatabase
import OathDiagnostics

/// Only localized copy and allowlisted protocol codes reach the UI. Provider messages
/// and underlying database errors can contain user input or request contents.
struct OathSendFailure: Equatable {
    let key: OathStringKey
    let code: String?

    init(_ key: OathStringKey, code: String? = nil) {
        self.key = key
        self.code = code
    }

    static func reason(_ error: any Error, fallback: OathStringKey) -> Self {
        if let reported = error as? ReportedDiagnosticFailure { return reason(reported.underlying, fallback: fallback) }
        if let known = error as? any OathSendFailureProviding { return known.sendFailure }
        if error is SendFeeFundingError { return .init(.sendNativeFeeRequired) }
        if error is CancellationError { return .init(.sendReviewChanged) }
        if error is DecodingError { return .init(.sendInvalidResponse) }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet: return .init(.wcConnectionOfflineTitle)
            case .timedOut: return .init(.wcConnectionRelayTimeoutTitle)
            case .cannotParseResponse, .badServerResponse, .cannotDecodeRawData, .cannotDecodeContentData:
                return .init(.sendInvalidResponse)
            case .cancelled: return .init(.sendReviewChanged)
            default: return .init(.scannerWCUnavailable)
            }
        }
        if let wallet = error as? OathWalletError {
            switch wallet {
            case .locked: return .init(.wcConnectionLockedTitle)
            case .wrongPasscode: return .init(.unlockIncorrect)
            case .throttled: return .init(.unlockWait)
            case .derivationFailed, .invalidPrivateKey: return .init(.sendSigningFailed)
            default: return .init(.wcWalletUnavailable)
            }
        }
        if (error as NSError).domain == "GRDB.DatabaseError" { return .init(.sendLoadFailed) }
        return .init(fallback)
    }

    static func canRetryFeeCheck(after key: OathStringKey) -> Bool {
        [.scannerWCUnavailable, .wcConnectionRelayTimeoutTitle, .wcConnectionOfflineTitle,
         .sendNodeRejected, .sendInvalidResponse, .sendFeeEstimateFailed].contains(key)
    }

    static func http(_ status: Int) -> Self {
        let key: OathStringKey = switch status {
        case 408, 504: .wcConnectionRelayTimeoutTitle
        case 502, 503: .scannerWCUnavailable
        default: .sendNodeRejected
        }
        return .init(key, code: "HTTP \(status)")
    }

    static func rpc(_ code: Int) -> Self { .init(.sendNodeRejected, code: "RPC \(code)") }

    fileprivate static func xrpl(_ raw: String, fallback: OathStringKey) -> Self {
        if let number = Int(raw) { return .rpc(number) }
        let code = XrplSendClient.safeCode(raw)
        let key: OathStringKey = switch code {
        case "tecDST_TAG_NEEDED": .xrplTagRequired
        case "tecUNFUNDED_PAYMENT": .sendInsufficient
        case "tecNO_DST", "tecNO_DST_INSUF_XRP": .xrplRecipientUnfunded
        case "tecINSUFFICIENT_RESERVE", "tecINSUF_RESERVE_LINE": .xrplReserveRequired
        case "tecFROZEN": .sendAssetFrozen
        case "temBAD_AMOUNT": .sendAmountInvalid
        case "tefBAD_SIGNATURE", "temBAD_SIGNATURE": .sendSigningFailed
        case "tefMAX_LEDGER": .permissionExpired
        case "noNetwork", "tooBusy", "notReady": .scannerWCUnavailable
        default: fallback
        }
        return .init(key, code: code == "UNKNOWN" ? nil : code)
    }

    fileprivate static func tron(_ raw: String) -> Self {
        if let number = Int(raw) { return .rpc(number) }
        let code = TronSendClient.safeCode(raw)
        let key: OathStringKey = switch code {
        case "SIGERROR": .sendSigningFailed
        case "CONTRACT_VALIDATE_ERROR": .tronSimulationFailed
        case "CONTRACT_EXE_ERROR": .tronSendFailed
        case "TOO_BIG_TRANSACTION_ERROR": .sendTransactionTooLarge
        case "TRANSACTION_EXPIRATION_ERROR": .permissionExpired
        case "SERVER_BUSY": .scannerWCUnavailable
        default: .sendNodeRejected
        }
        return .init(key, code: code == "UNKNOWN" ? nil : code)
    }
}

private protocol OathSendFailureProviding: Error {
    var sendFailure: OathSendFailure { get }
}

extension BitcoinSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .invalidAmount: .init(.sendAmountInvalid)
        case .invalidRecipient: .init(.sendAddressInvalid)
        case .invalidInput: .init(.sendInvalidInputs)
        case .duplicateInput: .init(.sendDuplicateInputs)
        case .insufficientFunds: .init(.sendInsufficient)
        case .feeUnavailable: .init(.sendFeeEstimateFailed)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .tooLarge: .init(.sendTransactionTooLarge)
        case .changed: .init(.sendReviewChanged)
        case .expired: .init(.permissionExpired)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .submissionUnknown: .init(.sendChecking)
        case .invalidOptions: .init(.sendInvalidTransaction)
        case .messageTooLarge: .init(.sendMessageTooLarge)
        }
    }
}

extension EVMSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.sendInsufficient)
        case .metadataChanged: .init(.aptosMetadataChanged)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .simulationFailed: .init(.solanaSimulationFailed)
        case .execution: .init(.wcTransactionFailedDetail)
        case .multisigSetupRequired: .init(.multisigEVMSetupNeeded)
        case .multisigFunding: .init(.multisigEVMFundingNeeded)
        case .sameRecipient: .init(.sendSelfTransferWallet)
        }
    }
}

extension ArcSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.arcAccountUnsupported)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.arcInsufficientFunds)
        case .metadataChanged: .init(.arcMetadataChanged)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .simulationFailed: .init(.arcSimulationFailed)
        case .execution: .init(.arcSendFailed)
        }
    }
}

extension SuiSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .insufficientFunds: .init(.sendInsufficient)
        case .insufficientGas: .init(.suiGasRequired)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .tooManyCoins: .init(.sendTransactionTooLarge)
        case .simulationFailed: .init(.solanaSimulationFailed)
        case .executionFailed: .init(.wcTransactionFailedDetail)
        case .signing: .init(.sendSigningFailed)
        case .changed: .init(.sendReviewChanged)
        case .expired: .init(.permissionExpired)
        case .busy: .init(.wcTransactionBusy)
        case .transport: .init(.scannerWCUnavailable)
        case .http(let code): .http(code)
        case .graphql: .init(.sendNodeRejected)
        }
    }
}

extension XrplSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .recipientMinimum: .init(.sendAdjustAmount)
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .sameRecipient: .init(.sendSelfTransferWallet)
        case .insufficientFunds: .init(.sendInsufficient)
        case .reserve: .init(.xrplReserveRequired)
        case .destinationTag: .init(.xrplTagRequired)
        case .recipientUnfunded: .init(.xrplRecipientUnfunded)
        case .unsupportedAccount: .init(.xrplAccountUnsupported)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .xrpl(code, fallback: .sendNodeRejected)
        case .simulation(let code): .xrpl(code, fallback: .xrplPaymentRestricted)
        case .execution(let code): .xrpl(code, fallback: .xrplSendFailed)
        case .tokenAlreadyEnabled: .init(.multisigXrplTokenEnabled)
        case .closureUnavailable, .closureTooSoon, .closureObligations: .init(.xrplCloseUnavailable)
        }
    }
}

extension StellarSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .recipientMinimum: .init(.sendAdjustAmount)
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.sendInsufficient)
        case .reserve: .init(.stellarReserveRequired)
        case .memoRequired: .init(.stellarMemoRequired)
        case .memoUnsupported: .init(.stellarMemoUnsupported)
        case .recipientUnfunded: .init(.stellarRecipientUnfunded)
        case .trustline, .restricted, .simulation: .init(.stellarPaymentRestricted)
        case .unsupportedAccount: .init(.stellarAccountUnsupported)
        case .feeTooHigh: .init(.stellarFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .execution: .init(.stellarSendFailed)
        case .restoreRequired: .init(.stellarRestoreRequired)
        }
    }
}

extension TronSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .activationFunds: .init(.accountRequiredFees)
        case .senderInactive, .unsupportedAccount: .init(.tronAccountUnsupported)
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.sendInsufficient)
        case .feeTooHigh: .init(.tronFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .simulation: .init(.tronSimulationFailed)
        case .execution: .init(.tronSendFailed)
        case .http(let code): .http(code)
        case .rpc(let code): .tron(code)
        }
    }
}

extension TonSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.tonAccountUnsupported)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.tonInsufficientFunds)
        case .metadataChanged: .init(.tonMetadataChanged)
        case .feeTooHigh: .init(.tonFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .simulationFailed: .init(.tonSimulationFailed)
        case .execution: .init(.tonSendFailed)
        }
    }
}

extension SolanaSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .recipientMinimum: .init(.sendAdjustAmount)
        case .accountRent, .storageBalance, .insufficientFunds: .init(.solanaInsufficientFunds)
        case .multisigFunding: .init(.multisigSolanaFundingNeeded)
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.solanaAccountUnsupported)
        case .amount: .init(.sendAmountInvalid)
        case .metadataChanged: .init(.solanaMetadataChanged)
        case .unsupportedToken, .frozen: .init(.solanaTokenUnsupported)
        case .feeTooHigh: .init(.solanaFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .simulationFailed: .init(.solanaSimulationFailed)
        case .execution: .init(.solanaSendFailed)
        }
    }
}

extension AptosSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.aptosAccountUnsupported)
        case .amount: .init(.sendAmountInvalid)
        case .sameRecipient: .init(.sendSelfTransferWallet)
        case .insufficientFunds: .init(.aptosInsufficientFunds)
        case .metadataChanged: .init(.aptosMetadataChanged)
        case .feeTooHigh: .init(.aptosFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .simulationFailed: .init(.aptosSimulationFailed)
        case .execution: .init(.aptosSendFailed)
        }
    }
}

extension ThorchainSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.thorchainAccountUnsupported)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.thorchainInsufficientFunds)
        case .metadataChanged: .init(.thorchainMetadataChanged)
        case .feeTooHigh: .init(.thorchainFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rejected(let code): .init(.sendNodeRejected, code: String(code))
        case .execution: .init(.thorchainSendFailed)
        case .halted: .init(.thorchainHalted)
        case .moduleRecipient: .init(.sendChangeAddress)
        }
    }
}

extension PolkadotSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.sendInsufficient)
        case .locked, .frozen: .init(.sendAssetFrozen)
        case .minimumBalance, .recipientMinimum, .recipientNeedsNative: .init(.sendAdjustAmount)
        case .metadataChanged: .init(.aptosMetadataChanged)
        case .runtimeUnsupported: .init(.wcUnsupportedTitle)
        case .feeTooHigh: .init(.arcFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .execution: .init(.wcTransactionFailedDetail)
        }
    }
}

extension NearSendError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .malformed: .init(.sendInvalidTransaction)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .amount: .init(.sendAmountInvalid)
        case .insufficientFunds: .init(.nearInsufficientFunds)
        case .recipientMissing: .init(.nearRecipientMissing)
        case .unsupportedAccount: .init(.nearAccountUnsupported)
        case .metadataChanged: .init(.nearMetadataChanged)
        case .storageUnsupported: .init(.nearStorageUnsupported)
        case .storageFunds: .init(.nearStorageDeposit)
        case .feeTooHigh: .init(.nearFeeTooHigh)
        case .expired: .init(.permissionExpired)
        case .changed: .init(.sendReviewChanged)
        case .signing: .init(.sendSigningFailed)
        case .busy: .init(.wcTransactionBusy)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .execution: .init(.nearSendFailed)
        }
    }
}

extension BitcoinError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .invalidKey: .init(.sendSigningFailed)
        case .unsupportedKeyScope: .init(.sendWrongAccount)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .invalidResponse: .init(.sendInvalidResponse)
        case .inconsistentSnapshot, .cancelled: .init(.sendReviewChanged)
        case .timeout: .init(.wcConnectionRelayTimeoutTitle)
        case .disconnected, .tls, .unavailable: .init(.scannerWCUnavailable)
        case .batchUnsupported: .init(.wcUnsupportedTitle)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .server(let code): .rpc(code)
        case .discoveryLimit: .init(.sendInvalidInputs)
        }
    }
}

extension BitcoinConnectError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .invalidRequest, .invalidPSBT: .init(.sendInvalidTransaction)
        case .wrongAccount: .init(.sendWrongAccount)
        case .unsupported: .init(.wcUnsupportedTitle)
        case .wrongInput: .init(.sendInvalidInputs)
        case .invalidFee: .init(.sendFeeEstimateFailed)
        case .insufficientFunds: .init(.sendInsufficient)
        case .changed: .init(.sendReviewChanged)
        case .unavailable: .init(.scannerWCUnavailable)
        case .tooLarge: .init(.sendTransactionTooLarge)
        case .expired: .init(.permissionExpired)
        case .busy: .init(.wcTransactionBusy)
        }
    }
}

extension AnkrError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configurationMissing, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .invalidResponse, .responseTooLarge, .paginationLoop, .incompleteInventory: .init(.sendInvalidResponse)
        case .wrongAccount: .init(.sendWrongAccount)
        case .wrongChain: .init(.wcNetworkChanged)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        }
    }
}

extension StoreError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .invalidValue: .init(.sendInvalidTransaction)
        case .missingRecord, .invalidDatabaseLocation: .init(.sendLoadFailed)
        case .conflictingIdentity, .readOnlyWallet: .init(.sendWrongAccount)
        case .staleSync, .invalidTransition: .init(.sendReviewChanged)
        case .reservationConflict: .init(.wcTransactionBusy)
        }
    }
}

extension SuiError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport, .checkpointUnavailable: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .paginationLoop: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .cursorExpired: .init(.permissionExpired)
        case .resourceExhausted, .graphql: .init(.sendNodeRejected)
        case .http(let code): .http(code)
        }
    }
}

extension SolanaError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .missingTransaction, .incompleteHistory: .init(.sendInvalidResponse)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        case .wrongOwner: .init(.sendWrongAccount)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .staleSlot, .cancelled: .init(.sendReviewChanged)
        }
    }
}

extension AptosError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .incomplete, .paginationLoop: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .http(let code): .http(code)
        case .indexer: .init(.sendNodeRejected)
        }
    }
}

extension TronError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .nonFungible: .init(.wcUnsupportedTitle)
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .incomplete, .paginationLoop: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        }
    }
}

extension NearError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .wrongBlock, .paginationLoop, .metadataUnavailable: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .accountMissing: .init(.wcWalletUnavailable)
        case .contract: .init(.sendNodeRejected)
        case .rpc(let code): .rpc(code)
        case .http(let code): .http(code)
        case .unsupportedBatch: .init(.wcUnsupportedTitle)
        }
    }
}

extension StellarError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport, .indexUnavailable: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .paginationLoop, .incompleteInventory, .incompleteHistory: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        }
    }
}

extension PolkadotError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .unavailable: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .incompleteInventory, .paginationLoop: .init(.sendInvalidResponse)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        }
    }
}

extension ThorchainError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .paginationLoop, .incomplete: .init(.sendInvalidResponse)
        case .wrongOwner: .init(.sendWrongAccount)
        case .http(let code): .http(code)
        case .transport: .init(.scannerWCUnavailable)
        case .rateLimited: .http(429)
        case .graphql: .init(.sendNodeRejected)
        case .staleHeight: .init(.sendReviewChanged)
        }
    }
}

extension TonError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport, .indexCooldown: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .wrongNetwork: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .malformed, .incomplete, .paginationLoop: .init(.sendInvalidResponse)
        case .http(let code): .http(code)
        case .rpc(let code): .rpc(code)
        }
    }
}

extension XrplError: OathSendFailureProviding {
    fileprivate var sendFailure: OathSendFailure {
        switch self {
        case .configuration, .transport: .init(.scannerWCUnavailable)
        case .invalidAddress: .init(.sendAddressInvalid)
        case .malformed, .paginationLoop, .incompleteHistory: .init(.sendInvalidResponse)
        case .wrongNetwork, .wrongLedger: .init(.wcNetworkChanged)
        case .wrongOwner: .init(.sendWrongAccount)
        case .accountMissing: .init(.wcWalletUnavailable)
        case .historyWindowExpired: .init(.permissionExpired)
        case .rpc(let code): .xrpl(code, fallback: .sendNodeRejected)
        case .http(let code): .http(code)
        }
    }
}
