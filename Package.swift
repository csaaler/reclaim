// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StorageCore", targets: ["StorageCore"]),
        .library(name: "StorageDefinitions", targets: ["StorageDefinitions"]),
        .library(name: "StorageInspectors", targets: ["StorageInspectors"]),
        .library(name: "StorageTestKit", targets: ["StorageTestKit"]),
        .executable(name: "ReclaimApp", targets: ["ReclaimApp"]),
    ],
    targets: [
        .target(name: "StorageCore"),
        .target(name: "StorageDefinitions", dependencies: ["StorageCore"]),
        .target(name: "StorageInspectors", dependencies: ["StorageCore"]),
        .target(name: "StorageTestKit", dependencies: ["StorageCore"]),
        .executableTarget(
            name: "ReclaimApp",
            dependencies: ["StorageCore", "StorageDefinitions", "StorageInspectors"],
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore", "StorageTestKit"]),
        .testTarget(name: "StorageDefinitionsTests", dependencies: ["StorageDefinitions", "StorageTestKit"]),
        .testTarget(
            name: "StorageInspectorsTests",
            dependencies: ["StorageInspectors", "StorageDefinitions", "StorageTestKit"]),
    ]
)
