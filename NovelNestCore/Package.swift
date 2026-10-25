// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NovelNestCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NovelNestCore", targets: ["NovelNestCore"]),
    ],
    dependencies: [
        // HTML parsing and CSS selectors for book-source rules (MIT).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(name: "NovelNestCore", dependencies: ["SwiftSoup"]),
        .testTarget(name: "NovelNestCoreTests", dependencies: ["NovelNestCore"]),
    ]
)
