// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KnowledgeBaseKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KnowledgeBaseKit", targets: ["KnowledgeBaseKit"]),
        .library(name: "KnowledgeBaseKitMCP", targets: ["KnowledgeBaseKitMCP"]),
        .executable(name: "kb", targets: ["kb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "release/6.3"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        // sqlite-vec, compiled directly into the package. See Storage/Database.swift
        // for why this is registered per-connection rather than via sqlite3_auto_extension.
        .target(
            name: "CSQLiteVec",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
            ]
        ),
        .target(
            name: "KnowledgeBaseKit",
            dependencies: [
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KnowledgeBaseKitMCP",
            dependencies: [
                "KnowledgeBaseKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "kb",
            dependencies: [
                "KnowledgeBaseKit",
                "KnowledgeBaseKitMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KnowledgeBaseKitTests",
            dependencies: ["KnowledgeBaseKit", "KnowledgeBaseKitMCP"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
