// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "OathBrowser", platforms: [.iOS(.v17), .macOS("15.5")],
    products: [.library(name: "OathBrowser", targets: ["OathBrowser"])],
    dependencies: [.package(path: "../OathDiagnostics")],
    targets: [.target(name: "OathBrowser", dependencies: ["OathDiagnostics"]),
              .testTarget(name: "OathBrowserTests", dependencies: ["OathBrowser"])], swiftLanguageModes: [.v6])
