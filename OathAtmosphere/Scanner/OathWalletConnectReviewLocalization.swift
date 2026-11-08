import Foundation
import OathAnkr

/// App-authored labels use the selected language. Addresses, method names,
/// amounts and arguments are data: never translate or rewrite their contents.
enum OathWalletConnectReviewLocalization {
    static func nearAction(_ action: WalletConnectNearTransaction.Action, strings: OathLocalizer) -> String {
        guard let display = action.display else { return strings.text(.wcDecodedUnavailable) }
        var lines: [String] = []
        func title(_ key: OathStringKey) { lines.append(strings.text(key)) }
        func field(_ key: OathStringKey, _ value: String) {
            lines.append(strings.text(key) + ": " + strings.invariant(value))
        }
        func units(_ value: String) -> String { (OathSendAmount.units(value, decimals: 24) ?? value) + " NEAR" }
        switch action.kind {
        case 0: title(.wcNearCreateAccount)
        case 1:
            title(.wcNearDeployContract)
            if let hash = display.codeHash { lines.append(strings.invariant("SHA256: " + hash)) }
        case 2:
            title(.wcContractCall)
            if let method = display.method { field(.wcCallMethod, method) }
            field(.wcDeposit, units(action.deposit))
            field(.wcGasLimit, String(action.gas))
            if let arguments = display.arguments {
                if let text = String(data: arguments, encoding: .utf8),
                   !text.unicodeScalars.contains(where: { $0.properties.isBidiControl || ($0.value < 32 && ![9, 10, 13].contains($0.value)) }) {
                    field(.wcArguments, text)
                } else { field(.wcArguments, "base64: " + arguments.base64EncodedString()) }
            }
        case 3: title(.send); field(.sendAmount, units(action.deposit))
        case 4: title(.wcNearStake); field(.sendAmount, units(action.deposit))
        case 5:
            title(.wcNearAddKey)
            if action.fullAccess { title(.wcNearFullAccess) }
            else {
                if let contract = display.contract { field(.wcContractAddress, contract) }
                if let methods = display.methods {
                    if methods.isEmpty { title(.wcAllMethods) }
                    else { field(.wcAllowedMethods, methods.joined(separator: ", ")) }
                }
                if let allowance = display.allowance { field(.wcGasAllowance, units(allowance)) }
                else { title(.permissionUnlimited) }
            }
        case 6: title(.wcNearDeleteKey)
        case 7:
            title(.wcNearDeleteAccount)
            if let beneficiary = display.beneficiary { field(.wcRemainingBalance, beneficiary) }
        default: title(.wcDecodedUnavailable)
        }
        if let key = display.publicKey { field(.wcPublicKey, key) }
        return lines.joined(separator: "\n")
    }

    static func suiChange(_ row: String, tokens: [String: SuiToken], strings: OathLocalizer) -> String {
        let lines = row.components(separatedBy: "\n")
        guard lines.count == 2, let range = lines[1].range(of: " atomic ") else {
            // Only a malformed legacy presentation can reach here, not a new
            // provider response. Preserve its data under a translated label.
            return strings.text(.wcTransactionData) + ": " + strings.invariant(row)
        }
        let amount = String(lines[1][..<range.lowerBound]), type = String(lines[1][range.upperBound...])
        if let reference = try? SuiIdentity.reference(type), let token = tokens[reference] {
            let negative = amount.hasPrefix("-")
            if let units = OathSendAmount.units(negative ? String(amount.dropFirst()) : amount, decimals: token.decimals) {
                return strings.invariant((negative ? "−" : "+") + units + " " + token.symbol) + "\n" + strings.invariant(lines[0])
            }
        }
        return strings.text(.wcAtomicAmount) + ": " + strings.invariant(amount) + "\n" + strings.invariant(type) + "\n" + strings.invariant(lines[0])
    }
    static func suiAuthorityWarning(_ authority: WalletConnectSuiAuthority) -> OathStringKey? {
        switch authority {
        case .mint: .wcSuiMintAuthority
        case .upgrade: .wcSuiUpgradeAuthority
        case .unknown: .wcSuiUnknownAuthority
        case .coin, .package: nil
        }
    }

    /// Canonical command data, without the English connective prose retained in
    /// legacy reviews. Keep resolved recipients and object IDs on the approval
    /// surface, alongside the original protocol references.
    static func suiActions(_ transaction: WalletConnectSuiTransaction) throws -> [String] {
        guard let commands = transaction.displayData["commands"].array else { throw SuiSendError.malformed }
        var transfers = transaction.transfers.makeIterator()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try commands.map { command in
            var value = command
            if case .object(var fields) = command, case .object(var transfer) = fields["TransferObjects"] {
                guard let resolved = transfers.next() else { throw SuiSendError.malformed }
                transfer["objects"] = .array(resolved.objects.map(NearJSON.string))
                if let recipient = resolved.recipient { transfer["recipient"] = .string(recipient) }
                fields["TransferObjects"] = .object(transfer)
                value = .object(fields)
            }
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }

    static func suiObjectFields(_ change: WalletConnectSuiObjectChange, strings: OathLocalizer) -> [(title: String, value: String, leftToRight: Bool)] {
        var fields = [(strings.text(.wcSuiObjectID), change.id, true),
                      (strings.text(.assetType), change.type ?? "MovePackage", true)]
        func appendOwner(_ owner: WalletConnectSuiObjectOwner?, title: OathStringKey) {
            guard let owner else {
                fields.append((strings.text(title), strings.text(.wcSuiRemoved), false)); return
            }
            switch owner.kind {
            case .address, .consensusAddress:
                fields.append((strings.text(title), owner.address ?? "—", true))
            case .object:
                fields.append((strings.text(title) + " · " + strings.text(.wcSuiObjectOwner), owner.address ?? "—", true))
            case .shared:
                fields.append((strings.text(title), strings.text(.wcSuiShared), false))
            case .immutable:
                fields.append((strings.text(title), strings.text(.wcSuiImmutable), false))
            }
        }
        if let before = change.before { appendOwner(before.owner, title: .transactionFrom) }
        appendOwner(change.after?.owner, title: .sendRecipient)
        return fields
    }

}
