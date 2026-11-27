// swift-tools-version: 6.0
// Domain modules for the Ereader app. See docs/ARCHITECTURE.md#module-layout.
// Direct dependencies are pinned with `exact:`; transitive ones are pinned by the committed Package.resolved.
import PackageDescription

let package = Package(
    name: "EreaderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "EPUBMetadata", targets: ["EPUBMetadata"]),
        .library(name: "RemoteSources", targets: ["RemoteSources"]),
        .library(name: "BookStorage", targets: ["BookStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        // Readium's fork of ZIPFoundation (async API with pluggable DataSource). Use it instead of
        // weichsel/ZIPFoundation: both packages have the identity "zipfoundation", so they can't coexist.
        .package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.2"),
    ],
    targets: [
        .target(name: "Core"),
        .target(
            name: "Persistence",
            dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "EPUBMetadata",
            dependencies: ["Core", .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")]
        ),
        .target(name: "RemoteSources", dependencies: ["Core"]),
        .target(name: "BookStorage", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "EPUBMetadataTests",
            dependencies: ["EPUBMetadata", .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")]
        ),
    ]
)
