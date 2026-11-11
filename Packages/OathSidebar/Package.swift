// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OathSidebar",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OathSidebar", targets: ["OathSidebar"])],
    targets: [
        .target(name: "OathSidebar"),
        .testTarget(name: "OathSidebarTests", dependencies: ["OathSidebar"])
    ]
)
