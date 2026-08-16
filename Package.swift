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
    // Exact pins rather than `from:` ranges. Determinism is worth more here than resolver
    // flexibility: swift-markdown is the parser, and a dependency moving underneath the
    // package can shift chunk boundaries, which feeds the chunker version key and triggers
    // re-indexing. Move these deliberately with `swift package update`.
    //
    // swift-markdown must be pinned to a *tagged version* rather than a release branch:
    // SwiftPM refuses to resolve a package released at a stable version if it depends on a
    // branch or revision, so a branch here would make this package unusable as a versioned
    // dependency for anyone else.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
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
