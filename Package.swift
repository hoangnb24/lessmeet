// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LessMeet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LessMeet", targets: ["LessMeet"])],
    targets: [
        .executableTarget(name: "LessMeet"),
        .testTarget(name: "LessMeetTests", dependencies: ["LessMeet"])
    ],
    swiftLanguageModes: [.v5]
)
