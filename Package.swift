// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Switchyard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Switchyard", targets: ["Switchyard"]),
        .executable(name: "switchyard-runner", targets: ["SwitchyardRunner"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "JobEngine", targets: ["JobEngine"]),
        .library(name: "RuntimeCatalog", targets: ["RuntimeCatalog"]),
        .library(name: "Persistence", targets: ["Persistence"])
    ],
    targets: [
        .target(
            name: "AppCore",
            path: "app/Packages/AppCore"
        ),
        .target(
            name: "RuntimeCatalog",
            dependencies: ["AppCore"],
            path: "app/Packages/RuntimeCatalog"
        ),
        .target(
            name: "Persistence",
            dependencies: ["AppCore"],
            path: "app/Packages/Persistence"
        ),
        .target(
            name: "JobEngine",
            dependencies: ["AppCore", "RuntimeCatalog"],
            path: "app/Packages/JobEngine"
        ),
        .executableTarget(
            name: "Switchyard",
            dependencies: ["AppCore", "JobEngine", "RuntimeCatalog", "Persistence"],
            path: "app/Switchyard"
        ),
        .executableTarget(
            name: "SwitchyardRunner",
            dependencies: ["AppCore"],
            path: "runtime/runner"
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            path: "Tests/AppCoreTests"
        ),
        .testTarget(
            name: "RuntimeCatalogTests",
            dependencies: ["AppCore", "RuntimeCatalog"],
            path: "Tests/RuntimeCatalogTests"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["AppCore", "Persistence"],
            path: "Tests/PersistenceTests"
        ),
        .testTarget(
            name: "JobEngineTests",
            dependencies: ["AppCore", "JobEngine", "RuntimeCatalog"],
            path: "Tests/JobEngineTests"
        )
    ]
)
