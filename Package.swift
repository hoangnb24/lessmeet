// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LessMeet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LessMeet", targets: ["LessMeet"])],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.5.5"),
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", exact: "5.90.2"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", revision: "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"),
        .package(url: "https://github.com/soniqo/speech-swift", revision: "cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa")
    ],
    targets: [
        .executableTarget(name: "LessMeet", dependencies: [
            .product(name: "ClerkKit", package: "clerk-ios"),
            .product(name: "RevenueCat", package: "purchases-ios-spm"),
            .product(name: "WhisperKit", package: "WhisperKit"),
            .product(name: "SpeechVAD", package: "speech-swift")
        ]),
        .testTarget(name: "LessMeetTests", dependencies: ["LessMeet"], exclude: [
            "BILLING_ADMISSION_HANDOFF.md", "BILLING_ADMISSION_SHA256.json",
            "LONG_CAPTURE_HANDOFF.md"
        ])
    ],
    swiftLanguageModes: [.v5]
)
