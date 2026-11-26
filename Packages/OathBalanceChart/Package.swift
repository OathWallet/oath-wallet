// swift-tools-version: 6.1
import PackageDescription

let package = Package(name: "OathBalanceChart", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathBalanceChart", targets: ["OathBalanceChart"])],
    dependencies: [.package(path: "../OathDiagnostics")],
    targets: [.target(name: "OathBalanceChart", dependencies: ["OathDiagnostics"]),
              .testTarget(name: "OathBalanceChartTests", dependencies: ["OathBalanceChart"])],
    swiftLanguageModes: [.v6])
