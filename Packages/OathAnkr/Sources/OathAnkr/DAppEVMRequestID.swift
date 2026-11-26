import Foundation

public enum DAppEVMRequestID {
    /// Separate transport namespaces preserve existing relay IDs and journal recovery.
    public static func isValid(_ value: String) -> Bool {
        guard let prefix = ["wc:", "browser:"].first(where: value.hasPrefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

extension EVMSendClient {
    /// Browser adapter only. Never expose the general RPC transport or broadcast routes to JavaScript.
    public func browserRead(method: String, parameters: Data) async throws -> Data {
        let allowed: Set<String> = ["net_version", "eth_blockNumber", "eth_getBalance", "eth_getCode", "eth_call",
            "eth_estimateGas", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory", "eth_getTransactionCount",
            "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getBlockByNumber", "eth_getBlockByHash"]
        guard allowed.contains(method), parameters.count <= 65_536 else { throw EVMSendError.malformed }
        let params = try JSONDecoder().decode([SolanaJSON].self, from: parameters)
        guard params.count <= 3 else { throw EVMSendError.malformed }
        let data = try JSONEncoder().encode(await rpc(method, params))
        guard data.count <= 1_000_000 else { throw EVMSendError.malformed }
        return data
    }
}
