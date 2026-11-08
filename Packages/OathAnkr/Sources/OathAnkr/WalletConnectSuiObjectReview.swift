import Foundation

/// Protocol values, not dApp-supplied display names. Unknown Move types must
/// never be described as harmless merely because their name lacks "Cap".
public enum WalletConnectSuiAuthority: String, Codable, Sendable {
    case mint, upgrade, unknown, coin, package
}
public struct WalletConnectSuiObjectOwner: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case address, object, shared, immutable, consensusAddress }
    public let kind: Kind
    public let address: String?
}
public struct WalletConnectSuiObjectState: Codable, Equatable, Sendable {
    public let version: UInt64
    public let digest: String
    public let type: String?
    public let owner: WalletConnectSuiObjectOwner
}
public struct WalletConnectSuiObjectChange: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let created: Bool
    public let deleted: Bool
    public let before: WalletConnectSuiObjectState?
    public let after: WalletConnectSuiObjectState?
    public var type: String? { after?.type ?? before?.type }
    public var authority: WalletConnectSuiAuthority {
        guard let type else { return .package }
        let outer = String(type.prefix(while: { $0 != "<" }))
        if outer == "0x2::coin::Coin", type.hasSuffix(">") { return .coin }
        if outer == "0x2::coin::TreasuryCap", type.hasSuffix(">") { return .mint }
        if type == "0x2::package::UpgradeCap" { return .upgrade }
        return .unknown
    }
    public var changesOwner: Bool { before?.owner != after?.owner }
}
public struct WalletConnectSuiTransfer: Sendable, Equatable {
    let commandIndex: Int
    /// Object IDs where known; protocol result references for created values.
    public let objects: [String]
    let directObjectIDs: [String]
    public let recipient: String?
}
struct SuiConnectObjectReference: Sendable {
    let id: String, version: UInt64, digest: String
    var summary: String { id + " @ " + String(version) + " / " + digest }
}
enum SuiConnectArgument {
    case gasCoin, input(Int), result(Int), nestedResult(Int, Int)
    var inputIndex: Int? { if case .input(let i) = self { return i }; return nil }
    var summary: String {
        switch self {
        case .gasCoin: "GasCoin"
        case .input(let i): "Input[\(i)]"
        case .result(let i): "Result[\(i)]"
        case .nestedResult(let i, let n): "Result[\(i),\(n)]"
        }
    }
}

extension WalletConnectSuiTransaction {
    var reviewActions: [String] {
        commands.enumerated().map { index, command in
            guard let transfer = transfers.first(where: { $0.commandIndex == index }) else { return command }
            // Show actual pure-address recipients instead of base64 input values.
            // Dynamic result recipients remain protocol references; the object
            // cards always show their resolved final owners from simulation.
            if let recipient = transfer.recipient {
                return "TransferObjects " + transfer.objects.joined(separator: ", ") + " → " + recipient
            }
            return command
        }
    }
    func validateObjectReview(_ changes: [WalletConnectSuiObjectChange]) throws {
        guard changes.count <= 512, Set(changes.map(\.id)).count == changes.count else { throw SuiSendError.malformed }
        let byID = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        for transfer in transfers {
            let candidates = changes.filter { change in
                guard let owner = change.after?.owner, [.address, .consensusAddress].contains(owner.kind),
                      transfer.recipient == nil || owner.address == transfer.recipient else { return false }
                // Gas payment alone must not satisfy a missing result-object
                // transfer. An explicit GasCoin transfer is itself reviewable.
                return !gasObjectIDs.contains(change.id) || transfer.objects.contains("GasCoin") || change.changesOwner
            }
            guard candidates.count >= transfer.objects.count else { throw SuiSendError.changed }

            // A direct owned-object transfer must appear in the simulation, even
            // when the coin balance array is empty. Result-based and MoveCall
            // transfers are covered by the complete simulated object change set.
            for id in transfer.directObjectIDs {
                guard let change = byID[id], let input = ownedObjectInputs[id], let before = change.before,
                      before.version == input.version, before.digest == input.digest,
                      let after = change.after else { throw SuiSendError.malformed }
                if let recipient = transfer.recipient {
                    guard [.address, .consensusAddress].contains(after.owner.kind),
                          after.owner.address == recipient else { throw SuiSendError.changed }
                }
            }
        }
    }
}

/// Query typed before/after states in the simulation's execution scope, never
/// look up a current object separately and attach it to an older simulation.
/// https://docs.sui.io/develop/accessing-data/graphql/query-with-graphql
/// https://docs.sui.io/references/sui-api/sui-graphql/beta/reference/types/objects/object-change
struct SuiObjectReview {
    static let stateFields = """
        address version digest
        owner { __typename
          ... on AddressOwner { address { address } }
          ... on ObjectOwner { address { address } }
          ... on ConsensusAddressOwner { address { address } }
        }
        asMoveObject { contents { type { repr } } }
        asMovePackage { address }
        """
    static let fields = """
        objectChanges(first:512) {
          nodes { address idCreated idDeleted
            inputState { \(stateFields) }
            outputState { \(stateFields) }
          }
          pageInfo { hasNextPage }
        }
        """
    static func decode(_ connection: SuiJSON, transaction: WalletConnectSuiTransaction) throws -> [WalletConnectSuiObjectChange] {
        guard connection["pageInfo"]["hasNextPage"] == .bool(false),
              let nodes = connection["nodes"].array, nodes.count <= 512 else { throw SuiSendError.malformed }
        let result = try nodes.map { node -> WalletConnectSuiObjectChange in
            guard case .object(let fields) = node, fields["inputState"] != nil, fields["outputState"] != nil,
                  let id = node["address"].string,
                  case .bool(let created) = node["idCreated"], case .bool(let deleted) = node["idDeleted"] else { throw SuiSendError.malformed }
            let address = try SuiIdentity.address(id)
            let before = try state(node["inputState"], id: address), after = try state(node["outputState"], id: address)
            guard before != nil || after != nil,
                  !created || before == nil, !deleted || after == nil,
                  before == nil || after == nil || before?.type == after?.type else { throw SuiSendError.malformed }
            return .init(id: address, created: created, deleted: deleted, before: before, after: after)
        }.sorted { $0.id < $1.id }
        try transaction.validateObjectReview(result)
        return result
    }
    private static func state(_ value: SuiJSON, id: String) throws -> WalletConnectSuiObjectState? {
        if case .null = value { return nil }
        guard let address = value["address"].string, try SuiIdentity.address(address) == id,
              let versionText = value["version"].text, let version = UInt64(versionText),
              let digest = value["digest"].string, try SuiSendCrypto.unbase58(digest).count == 32,
              let kind = value["owner"]["__typename"].string else { throw SuiSendError.malformed }
        let ownerKind: WalletConnectSuiObjectOwner.Kind
        switch kind {
        case "AddressOwner": ownerKind = .address
        case "ObjectOwner": ownerKind = .object
        case "ConsensusAddressOwner": ownerKind = .consensusAddress
        case "Shared": ownerKind = .shared
        case "Immutable": ownerKind = .immutable
        default: throw SuiSendError.malformed
        }
        let ownerAddress: String?
        if [.address, .object, .consensusAddress].contains(ownerKind) {
            guard let address = value["owner"]["address"]["address"].string else { throw SuiSendError.malformed }
            ownerAddress = try SuiIdentity.address(address)
        } else { ownerAddress = nil }
        let type: String?
        if let raw = value["asMoveObject"]["contents"]["type"]["repr"].string {
            type = try SuiIdentity.coinType(raw)
        } else {
            guard case .null = value["asMoveObject"], let package = value["asMovePackage"]["address"].string,
                  try SuiIdentity.address(package) == id, ownerKind == .immutable else { throw SuiSendError.malformed }
            type = nil
        }
        return .init(version: version, digest: digest, type: type, owner: .init(kind: ownerKind, address: ownerAddress))
    }
}
