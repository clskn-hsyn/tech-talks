// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NarratorCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NarratorCore", targets: ["NarratorCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.19")),
    ],
    targets: [
        .target(name: "NarratorCore", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "NarratorCoreTests", dependencies: ["NarratorCore", "ZIPFoundation"]),
    ]
)
