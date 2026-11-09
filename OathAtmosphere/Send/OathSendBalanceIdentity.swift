import Foundation

/// Public identity only, scoped to one flow. Never serialized or logged.
struct OathSendBalanceIdentity: Hashable, Sendable {
    let session: UUID
    let wallet: String
    let account: String
    let chain: String
    let asset: String
    let reference: String
    let decimals: Int
    let sender: String
    let publicPolicy: String
    let observation: Double?
    let pending: Int
}
