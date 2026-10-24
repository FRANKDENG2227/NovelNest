// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NovelNestCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NovelNestCore", targets: ["NovelNestCore"]),
    ],
    targets: [
        .target(name: "NovelNestCore"),
        .testTarget(name: "NovelNestCoreTests", dependencies: ["NovelNestCore"]),
    ]
)
