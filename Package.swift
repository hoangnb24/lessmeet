// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LessMeet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LessMeet", targets: ["LessMeet"])],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.5.5"),
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", exact: "5.90.2")
    ],
    targets: [
        .executableTarget(name: "LessMeet", dependencies: [
            .product(name: "ClerkKit", package: "clerk-ios"),
            .product(name: "RevenueCat", package: "purchases-ios-spm")
        ]),
        .testTarget(name: "LessMeetTests", dependencies: ["LessMeet"], exclude: [
            "BILLING_ADMISSION_HANDOFF.md", "BILLING_ADMISSION_SHA256.json",
            "LONG_CAPTURE_HANDOFF.md"
        ])
    ],
    swiftLanguageModes: [.v5]
)
