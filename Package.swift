// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aeropeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AeroPeek"),
        .testTarget(name: "AeroPeekTests", dependencies: ["AeroPeek"]),
    ],
    swiftLanguageModes: [.v5]
)
