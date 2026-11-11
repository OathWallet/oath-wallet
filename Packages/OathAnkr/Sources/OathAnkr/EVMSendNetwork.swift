import Foundation

/// Explicit chain identity and fee policies. Arc uses this adapter for Safe wallets; ordinary Arc wallets retain their adapter.
public enum EVMSendNetwork: String, Codable, CaseIterable, Sendable {
    case ethereum, arbitrum, avalanche, base, bnb, fantom, flare, somnia, story, gnosis
    case linea, optimism, polygon, chiliz, celo, monad, unichain, hyperevm, robinhood, scroll, taiko, telos, xlayer
    case filecoin, filecoinCalibration, sei, seiTestnet, zerog, zerogGalileo, iotex, iotexTestnet
    case arc, arbitrumSepolia, ethereumSepolia, celoSepolia, chilizSpicy
    case cronos, cronosTestnet, telosTestnet, somniaTestnet, flareCoston2
    case baseSepolia, optimismSepolia, unichainSepolia, lineaSepolia, monadTestnet, xlayerTestnet
    case bnbTestnet, avalancheFuji, polygonAmoy, gnosisChiado, hyperevmTestnet, robinhoodTestnet, taikoHoodi
    public var isTestnet: Bool {
        switch self {
        case .cronosTestnet, .arbitrumSepolia, .ethereumSepolia, .celoSepolia, .chilizSpicy, .filecoinCalibration,
             .seiTestnet, .zerogGalileo, .iotexTestnet, .telosTestnet, .somniaTestnet, .flareCoston2,
             .baseSepolia, .optimismSepolia, .unichainSepolia, .lineaSepolia, .monadTestnet, .xlayerTestnet,
             .bnbTestnet, .avalancheFuji, .polygonAmoy, .gnosisChiado, .hyperevmTestnet, .robinhoodTestnet, .taikoHoodi: true
        default: false
        }
    }
    var isCronos: Bool { self == .cronos || self == .cronosTestnet }
    var isIoTeX: Bool { self == .iotex || self == .iotexTestnet }
    var isFilecoin: Bool { self == .filecoin || self == .filecoinCalibration }
    var isZeroG: Bool { self == .zerog || self == .zerogGalileo }
    var isSei: Bool { self == .sei || self == .seiTestnet }
    public var chainID: UInt64 {
        switch self {
        case .taikoHoodi: 167013
        case .gnosisChiado: 10200
        case .hyperevmTestnet: 998
        case .robinhoodTestnet: 46630
        case .bnbTestnet: 97
        case .avalancheFuji: 43113
        case .polygonAmoy: 80002
        case .somniaTestnet: 50312
        case .flareCoston2: 114
        case .monadTestnet: 10143
        case .xlayerTestnet: 1952
        case .lineaSepolia: 59141
        case .baseSepolia: 84532
        case .optimismSepolia: 11155420
        case .unichainSepolia: 1301
        case .cronos: 25; case .cronosTestnet: 338; case .telosTestnet: 41
        case .iotex: 4689; case .iotexTestnet: 4690
        case .zerog: 16661; case .zerogGalileo: 16602
        case .sei: 1329; case .seiTestnet: 1328
        case .filecoin: 314; case .filecoinCalibration: 314159
        case .arc: 5042; case .ethereum: 1; case .arbitrum: 42161; case .avalanche: 43114; case .base: 8453
        case .bnb: 56; case .fantom: 250; case .flare: 14; case .somnia: 5031; case .story: 1514
        case .gnosis: 100; case .linea: 59144; case .optimism: 10; case .polygon: 137
        case .chiliz: 88888; case .celo: 42220; case .monad: 143; case .unichain: 130; case .hyperevm: 999; case .robinhood: 4663
        case .scroll: 534352; case .taiko: 167000; case .telos: 40; case .xlayer: 196
        case .chilizSpicy: 88882; case .celoSepolia: 11142220; case .arbitrumSepolia: 421614; case .ethereumSepolia: 11155111
        }
    }
    public var symbol: String {
        switch self {
        case .somniaTestnet: "STT"
        case .flareCoston2: "C2FLR"
        case .cronos: "CRO"; case .cronosTestnet: "TCRO"
        case .iotex, .iotexTestnet: "IOTX"
        case .zerog, .zerogGalileo: "0G"
        case .filecoin, .filecoinCalibration: "FIL"
        case .sei, .seiTestnet: "SEI"
        case .arc: "USDC"; case .avalanche, .avalancheFuji: "AVAX"; case .bnb, .bnbTestnet: "BNB"; case .fantom: "FTM"; case .flare: "FLR"
        case .somnia: "SOMI"; case .story: "IP"; case .gnosis, .gnosisChiado: "xDAI"; case .polygon, .polygonAmoy: "POL"
        case .chiliz, .chilizSpicy: "CHZ"; case .celo, .celoSepolia: "CELO"; case .monad, .monadTestnet: "MON"; case .hyperevm, .hyperevmTestnet: "HYPE"; case .telos, .telosTestnet: "TLOS"; case .xlayer, .xlayerTestnet: "OKB"
        default: "ETH"
        }
    }
    var opStack: Bool { [.base, .baseSepolia, .optimism, .optimismSepolia, .unichain, .unichainSepolia].contains(self) }
    var oracle: String? {
        if opStack { return "0x420000000000000000000000000000000000000f" }
        if self == .scroll { return "0x5300000000000000000000000000000000000002" }
        return nil // Arbitrum includes its parent-chain cost in eth_estimateGas.
    }
    var stateTag: String { "latest" }
    var isHyperEVM: Bool { self == .hyperevm || self == .hyperevmTestnet }
    var nonceTag: String { isHyperEVM ? "latest" : "pending" }
    // These networks expose immediate consensus finality via latest. Others use
    // finalized; never silently treat an unsupported finality query as success.
    var finalityTag: String { [.hyperevm,.hyperevmTestnet,.fantom,.telos,.telosTestnet].contains(self) ? "latest" : "finalized" }
    var minimumGas: UInt64 { isIoTeX ? 10_000 : 21_000 }
    var maximumGas: UInt64 { isFilecoin ? 10_000_000_000 : isIoTeX ? 1_000_000 : [.hyperevm,.hyperevmTestnet,.arc].contains(self) ? 2_000_000 : 5_000_000 }

    func address(_ value: String) throws -> String {
        if isIoTeX { return try IoTeXIdentity.ethereum(value) }
        return isFilecoin ? try FilecoinIdentity.ethereum(value, testnet: isTestnet) : try EVMSendIdentity.address(value)
    }
}

public enum EVMSendIdentity {
    public static func address(_ value: String) throws -> String { try IndexedEVMIdentity.address(value) }
    public static func reference(_ value: String) throws -> String { value == "native" ? value : try address(value) }
    static let transferTopic = ArcIdentity.transferTopic
}
