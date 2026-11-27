// swift-tools-version: 6.0
// Domain modules for the Ereader app. See docs/ARCHITECTURE.md#module-layout.
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
    targets: [
        .target(name: "Core"),
        .target(name: "Persistence", dependencies: ["Core"]),
        .target(name: "EPUBMetadata", dependencies: ["Core"]),
        .target(name: "RemoteSources", dependencies: ["Core"]),
        .target(name: "BookStorage", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
