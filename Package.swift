// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalShot", targets: ["LocalShot"])
    ],
    targets: [
        .executableTarget(
            name: "LocalShot",
            path: "Sources/LocalShot"
        )
    ],
    swiftLanguageVersions: [.v5]
)
