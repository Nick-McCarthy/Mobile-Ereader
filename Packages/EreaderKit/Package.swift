// swift-tools-version: 6.2
// Domain modules for the Ereader app. See docs/ARCHITECTURE.md#module-layout.
// Direct dependencies are pinned with `exact:`; transitive ones are pinned by the committed Package.resolved.
import PackageDescription

// Warnings are errors in our modules only; dependencies are unaffected.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "EreaderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "EPUBMetadata", targets: ["EPUBMetadata"]),
        .library(name: "RemoteSources", targets: ["RemoteSources"]),
        .library(name: "BookStorage", targets: ["BookStorage"]),
        .library(name: "LibraryServices", targets: ["LibraryServices"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        // Readium's fork of ZIPFoundation (async API with pluggable DataSource). Use it instead of
        // weichsel/ZIPFoundation: both packages have the identity "zipfoundation", so they can't coexist.
        .package(url: "https://github.com/readium/ZIPFoundation.git", exact: "3.0.2"),
    ],
    targets: [
        .target(name: "Core", swiftSettings: strict),
        .target(
            name: "Persistence",
            dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .target(
            name: "EPUBMetadata",
            dependencies: ["Core", .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: strict
        ),
        .target(name: "RemoteSources", dependencies: ["Core"], swiftSettings: strict),
        // Test doubles (FakeRemoteSource) shared by test targets. Not linked into the app.
        .target(name: "RemoteSourcesTesting", dependencies: ["Core", "RemoteSources"], swiftSettings: strict),
        .target(name: "BookStorage", dependencies: ["Core"], swiftSettings: strict),
        // Workflows that span modules: importing, and later sync's parse-and-insert.
        .target(
            name: "LibraryServices",
            dependencies: ["Core", "Persistence", "EPUBMetadata", "BookStorage", "RemoteSources"],
            swiftSettings: strict
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"], swiftSettings: strict),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "EPUBMetadataTests",
            dependencies: ["Core", "EPUBMetadata", .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "RemoteSourcesTests",
            dependencies: ["RemoteSources", "RemoteSourcesTesting"],
            swiftSettings: strict
        ),
        .testTarget(name: "BookStorageTests", dependencies: ["BookStorage"], swiftSettings: strict),
        .testTarget(
            name: "LibraryServicesTests",
            dependencies: [
                "LibraryServices", "Persistence", "BookStorage", "RemoteSources", "RemoteSourcesTesting",
                .product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: strict
        ),
    ]
)
