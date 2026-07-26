// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GameServerKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "GameServerKit", targets: ["GameServerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
    ],
    targets: [
        .target(name: "GameServerKit", dependencies: [
            .product(name: "Vapor", package: "vapor"),
        ]),
        .testTarget(name: "GameServerKitTests", dependencies: ["GameServerKit"]),
    ]
)
