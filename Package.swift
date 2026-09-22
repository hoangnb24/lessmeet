// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LessMeet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LessMeet", targets: ["LessMeet"])],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.5.5")
    ],
    targets: [
        .executableTarget(name: "LessMeet", dependencies: [
            .product(name: "ClerkKit", package: "clerk-ios")
        ]),
        .testTarget(name: "LessMeetTests", dependencies: ["LessMeet"])
    ],
    swiftLanguageModes: [.v5]
)
