import OathDiagnostics
import Foundation
import Observation
import OathDatabase
import OathBitcoin

/// Human-readable qualifiers are localized in the app; protocol names and BIP
/// identifiers keep their standard spelling across languages.
extension BitcoinAddressType {
    func localizedTitle(using strings: OathLocalizer) -> String {
        switch self {
        case .nativeSegwit: strings.text(.bitcoinNativeSegwit)
        case .legacy: strings.text(.bitcoinLegacy)
        case .taproot, .nestedSegwit: strings.invariant(title)
        }
    }
}

/// Public navigation state for an account's export inside Account Details.
/// Loading is replaced by the first real step, so Back never lands on a
/// completed biometric prompt. Neither the path nor a destination carries keys.
@MainActor struct OathAccountPrivateKeyNavigation {
    enum Route: Hashable { case authorization, passcode, warning, value }
    var path: [Route] = []

    mutating func begin() { path = [.authorization] }

    mutating func update(phase: OathPrivateKeyModel.Phase) {
        guard let current = path.last else { return }
        switch phase {
        case .chains:
            if current != .authorization { path = [] }
        case .authenticating: break
        case .passcode:
            if current == .authorization { path = [.passcode] }
        case .warning:
            if current == .authorization { path = [.warning] }
            else if current == .passcode { path.append(.warning) }
        case .revealed:
            if current == .warning { path.append(.value) }
        }
    }

    func reconcile(model: OathPrivateKeyModel) {
        switch path.last {
        case nil: model.returnToChains()
        case .passcode:
            if model.phase != .passcode { model.returnToPasscode() }
        case .warning: model.returnToWarning()
        case .authorization, .value: break
        }
    }
}

/// Public metadata only. Neither navigation nor the chain list carries secrets.
struct OathPrivateKeyAccount: Identifiable, Equatable, Sendable {
    let id: String
    let chain: OathImportChain
    let address: String
    let path: String
    var utxo: OathPrivateKeyUTXOOrigin? = nil
    var displayName: String {
        guard chain == .solana, let derivation = SolanaDerivation.matching(path: path) else { return chain.name }
        return chain.name + " · " + derivation.title
    }
}

struct OathPrivateKeyUTXOOrigin: Equatable, Sendable {
    let accountID: String
    let accountIndex: UInt32
    let address: BitcoinDerivedAddress
}

struct OathPrivateKeyExport: Sendable {
    let value: String
    let format: String
}

protocol OathPrivateKeyReading: Sendable {
    func privateKeyAccounts(walletID: String) async throws -> [OathPrivateKeyAccount]
    func privateKeyBranches(walletID: String, accountID: String) async throws -> [BitcoinBranch]
    func privateKeyAddresses(walletID: String, accountID: String, branchID: String, after: UInt32?, search: BitcoinAddressSearch) async throws -> [OathPrivateKeyAccount]
    func privateKey(walletID: String, accountID: String, digits: [UInt8]) async throws -> OathPrivateKeyExport
    func privateKeyWithBiometrics(walletID: String, accountID: String, reason: String) async throws -> OathPrivateKeyExport
}

// Non-UTXO readers (including isolated authentication fixtures) do not browse HD paths.
extension OathPrivateKeyReading {
    func privateKeyBranches(walletID: String, accountID: String) async throws -> [BitcoinBranch] { throw OathWalletError.unavailable }
    func privateKeyAddresses(walletID: String, accountID: String, branchID: String, after: UInt32?, search: BitcoinAddressSearch = .init()) async throws -> [OathPrivateKeyAccount] { throw OathWalletError.unavailable }
}

/// A new chain selection always authenticates before the warning. The exported
/// value stays private until acknowledgement and is discarded on leaving.
@MainActor @Observable final class OathPrivateKeyModel {
    enum Phase: Equatable { case chains, authenticating, passcode, warning, revealed }
    enum BrowserDestination: Equatable { case types, addresses, singleAddress(OathPrivateKeyAccount) }
    let walletID: String
    private(set) var accounts: [OathPrivateKeyAccount] = []
    private(set) var browserAccount: OathPrivateKeyAccount?
    private(set) var branches: [BitcoinBranch] = []
    private(set) var branch: BitcoinBranch?
    private(set) var addresses: [OathPrivateKeyAccount] = []
    private(set) var hasMoreAddresses = false
    private(set) var addressSearch = BitcoinAddressSearch()
    private(set) var selected: OathPrivateKeyAccount?
    private(set) var phase: Phase = .chains
    private(set) var key: OathPrivateKeyExport?
    private(set) var busy = false
    private(set) var loaded = false
    var notice: OathStringKey?
    @ObservationIgnored private let reader: any OathPrivateKeyReading
    @ObservationIgnored private var pendingKey: OathPrivateKeyExport?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(walletID: String, reader: any OathPrivateKeyReading) {
        self.walletID = walletID
        self.reader = reader
    }

    func load() async {
        guard !loaded, !busy, phase == .chains else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let accounts = try await reader.privateKeyAccounts(walletID: walletID)
            guard isCurrent(token) else { return }
            self.accounts = accounts; loaded = true; busy = false
            if accounts.isEmpty { notice = .walletUnavailable }
        } catch { OathDiagnostics.record(error);
            guard isCurrent(token) else { return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    /// Imported wallets hold one original key. EVM imports may expose the same
    /// account on several networks; those aliases do not require a key picker.
    /// Derived accounts still use the explicit chain/address browser.
    func selectImportedKey(reason: (OathPrivateKeyAccount) -> String) async {
        let token = generation
        await load()
        guard isCurrent(token), loaded, phase == .chains, !busy,
              let account = accounts.first else { return }
        guard accounts.allSatisfy({ candidate in
            candidate.path == "imported" && candidate.utxo == nil &&
                (candidate == account || (account.chain.isEVM && candidate.chain.isEVM &&
                    candidate.address.caseInsensitiveCompare(account.address) == .orderedSame))
        }) else {
            OathDiagnostics.record(OathWalletError.unavailable, component: "private_key_reveal", operation: "select_imported_account")
            notice = .walletUnavailable
            return
        }
        select(account, reason: reason(account))
    }

    /// Account Details carries public metadata from its own wallet. Resolve it
    /// against that wallet again before authenticating; never substitute the
    /// active wallet, a default path, or a different account on the same chain.
    func selectAccount(_ account: OathPrivateKeyAccount, reason: String) async {
        await OathDiagnostics.$operationID.withValue(UUID()) {
            await OathDiagnostics.$chain.withValue(account.chain.id) {
                let token = generation
                await load()
                guard isCurrent(token), loaded, phase == .chains, !busy else { return }
                guard account.utxo == nil, account.path != "imported",
                      account.chain.isEVM || account.chain == .solana,
                      accounts.contains(account) else {
                    OathDiagnostics.record(OathWalletError.unavailable, component: "private_key_reveal", operation: "select_hd_account")
                    notice = .walletUnavailable
                    return
                }
                select(account, reason: reason)
            }
        }
    }

    func select(_ account: OathPrivateKeyAccount, reason: String) {
        guard phase == .chains, !busy, (accounts.contains(account) || addresses.contains(account)) else { return }
        selected = account; phase = .authenticating; busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let key = try await reader.privateKeyWithBiometrics(walletID: walletID, accountID: account.id, reason: reason)
                    guard let self, self.isCurrent(token) else { return }
                    self.accept(key)
                } catch {
                    // Missing/declined/unavailable biometrics intentionally offer the
                    // app PIN. Corrupt credentials and unexpected OS failures still report.
                    if (error as? OathBiometricCredentialError)?.isExpectedAuthenticationOutcome != true {
                        OathDiagnostics.record(error, operation: "authorize_private_key", context: ["stage": "biometric"])
                    }
                    guard let self, self.isCurrent(token) else { return }
                    self.busy = false; self.work = nil
                    if error is CancellationError {
                        self.returnToChains()
                    } else if error is OathBiometricCredentialError {
                        self.phase = .passcode
                    } else {
                        self.returnToChains(); self.notice = .walletUnavailable
                    }
                }
            }
        }
    }

    func submit(_ input: [UInt8]) {
        guard phase == .passcode, !busy, let selected,
              input.count == 6, input.allSatisfy({ $0 <= 9 }) else { return }
        busy = true; notice = nil
        let token = generation
        work = Task { [weak self, reader, walletID] in
            var digits = input
            defer { _ = digits.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
            do {
                let key = try await reader.privateKey(walletID: walletID, accountID: selected.id, digits: digits)
                guard let self, self.isCurrent(token) else { return }
                self.accept(key)
            } catch {
                // A rejected user-entered PIN is form feedback. Credential,
                // decryption and storage failures retain their original report.
                if error as? OathWalletError != .wrongPasscode { OathDiagnostics.record(error) }
                guard let self, self.isCurrent(token) else { return }
                self.busy = false; self.work = nil
                if error is CancellationError { return }
                switch error as? OathWalletError {
                case .wrongPasscode: self.notice = .unlockIncorrect
                case .throttled: self.notice = .unlockWait
                default: self.notice = .walletUnavailable
                }
            }
        }
    }

    func acknowledge() {
        guard phase == .warning, let pendingKey, !busy else { return }
        key = pendingKey; self.pendingKey = nil; phase = .revealed
    }

    func returnToWarning() {
        // Native Back from the key page keeps the same authorized selection.
        guard phase == .revealed else { return }
        pendingKey = key; key = nil; phase = .warning
    }

    func returnToPasscode() {
        cancelWork(); key = nil; pendingKey = nil; phase = .passcode
    }

    func returnToChains() {
        returnToBrowser()
        browserAccount = nil; branches = []; branch = nil; addresses = []; hasMoreAddresses = false
        addressSearch = .init()
    }

    func returnToBrowser() {
        cancelWork(); key = nil; pendingKey = nil; selected = nil; phase = .chains
    }

    func browse(_ account: OathPrivateKeyAccount) {
        guard phase == .chains, !busy, accounts.contains(account), UTXONetwork(rawValue: account.chain.id) != nil else { return }
        returnToChains(); browserAccount = account
    }

    /// Resolve the next screen before pushing it, so native Back never returns
    /// to a redundant single-type picker. Receive/change are branches of a type.
    func prepareBrowser(_ account: OathPrivateKeyAccount) async -> BrowserDestination? {
        guard phase == .chains, !busy, accounts.contains(account),
              UTXONetwork(rawValue: account.chain.id) != nil else { return nil }
        browse(account)
        let token = generation
        await loadBranches()
        guard isCurrent(token), browserAccount == account, !busy, phase == .chains,
              !branches.isEmpty else { return nil }
        guard Set(branches.map(\.type)).count == 1 else { return .types }
        if let first = branches.first(where: { $0.change == 0 }) ?? branches.first {
            return await prepareAddresses(first)
        }
        return nil
    }

    /// Only skip the picker when this type has one branch and its complete,
    /// unfiltered address list has one entry. A search hit or partial page is
    /// never evidence that the user has only one address to choose from.
    func prepareAddresses(_ value: BitcoinBranch) async -> BrowserDestination? {
        guard phase == .chains, !busy, browserAccount != nil, branches.contains(value) else { return nil }
        chooseBranch(value)
        setAddressSearch(.init())
        guard branches.filter({ $0.type == value.type }).count == 1 else { return .addresses }
        // Refresh even when returning to the same branch: a previous search or
        // cached page must not decide whether to start authentication.
        returnToBrowser()
        addresses = []; hasMoreAddresses = true
        let token = generation
        await loadAddresses()
        guard isCurrent(token), branch == value, phase == .chains, !busy, notice == nil else { return nil }
        if !hasMoreAddresses, addresses.count == 1, let account = addresses.first {
            return .singleAddress(account)
        }
        return .addresses
    }

    func loadBranches() async {
        guard let account = browserAccount, branches.isEmpty, !busy else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let result = try await reader.privateKeyBranches(walletID: walletID, accountID: account.id)
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            branches = result; busy = false
            if result.isEmpty { notice = .walletUnavailable }
        } catch { OathDiagnostics.record(error);
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    func chooseBranch(_ value: BitcoinBranch) {
        guard branches.contains(value), value != branch else { return }
        returnToBrowser(); branch = value; addresses = []; hasMoreAddresses = true
    }

    func setAddressSearch(_ search: BitcoinAddressSearch) {
        guard phase == .chains, addressSearch != search else { return }
        // Invalidate a previous read before resetting its page. Late results
        // from another query/branch must never replace the current list.
        returnToBrowser()
        addressSearch = search; addresses = []; hasMoreAddresses = branch != nil
    }

    func loadAddresses() async {
        guard let account = browserAccount, let branch, hasMoreAddresses, !busy, phase == .chains else { return }
        busy = true; notice = nil
        let token = generation
        do {
            let result = try await reader.privateKeyAddresses(walletID: walletID, accountID: account.id,
                branchID: branch.id, after: addresses.last?.utxo?.address.index, search: addressSearch)
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            addresses += result; hasMoreAddresses = result.count == 50; busy = false
        } catch {
            // Superseded searches and disappearing pages are expected teardown;
            // never report the user's address query or public address metadata.
            if !(error is CancellationError) {
                OathDiagnostics.record(error, component: "private_key_browser", operation: "load_addresses")
            }
            guard token == generation else { return }
            guard !Task.isCancelled else { busy = false; return }
            busy = false
            if !(error is CancellationError) { notice = .walletUnavailable }
        }
    }

    func cancelAuthentication() {
        // End secret disclosure whenever the app locks or backgrounds.
        returnToChains()
    }

    private func cancelWork() {
        generation = UUID(); work?.cancel(); work = nil; busy = false; notice = nil
    }

    private func isCurrent(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }

    private func accept(_ key: OathPrivateKeyExport) {
        busy = false; work = nil
        guard !key.value.isEmpty else { returnToChains(); notice = .walletUnavailable; return }
        pendingKey = key; phase = .warning
    }
}
