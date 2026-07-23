// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Switchyard",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Switchyard", targets: ["Switchyard"]),
        .executable(name: "switchyard-runner", targets: ["SwitchyardRunner"]),
        .executable(name: "switchyard-url-handler", targets: ["SwitchyardURLHandler"]),
        .executable(name: "switchyard-shortcut-handler", targets: ["SwitchyardShortcutHandler"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "JobEngine", targets: ["JobEngine"]),
        .library(name: "RuntimeCatalog", targets: ["RuntimeCatalog"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "SwitchyardLocalization", targets: ["SwitchyardLocalization"])
    ],
    targets: [
        .target(
            name: "SwitchyardLocalization",
            path: "app/Packages/SwitchyardLocalization",
            exclude: [
                "Resources/Localizable.xcstrings"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .target(
            name: "AppCore",
            dependencies: ["SwitchyardLocalization"],
            path: "app/Packages/AppCore"
        ),
        .target(
            name: "RuntimeCatalog",
            dependencies: ["AppCore", "SwitchyardLocalization"],
            path: "app/Packages/RuntimeCatalog"
        ),
        .target(
            name: "Persistence",
            dependencies: ["AppCore", "SwitchyardLocalization"],
            path: "app/Packages/Persistence"
        ),
        .target(
            name: "JobEngine",
            dependencies: ["AppCore", "RuntimeCatalog", "SwitchyardLocalization"],
            path: "app/Packages/JobEngine"
        ),
        .executableTarget(
            name: "Switchyard",
            dependencies: [
                "AppCore",
                "JobEngine",
                "RuntimeCatalog",
                "Persistence",
                "SwitchyardLocalization"
            ],
            path: "app/Switchyard"
        ),
        .executableTarget(
            name: "SwitchyardRunner",
            dependencies: ["AppCore"],
            path: "runtime/runner"
        ),
        .executableTarget(
            name: "SwitchyardURLHandler",
            dependencies: ["AppCore"],
            path: "runtime/url-handler"
        ),
        .executableTarget(
            name: "SwitchyardShortcutHandler",
            dependencies: ["AppCore"],
            path: "runtime/shortcut-handler"
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
        ),
        .testTarget(
            name: "SwitchyardTests",
            dependencies: ["AppCore", "Switchyard", "SwitchyardLocalization"],
            path: "Tests/SwitchyardTests"
        ),
        .testTarget(
            name: "SwitchyardLocalizationTests",
            dependencies: ["SwitchyardLocalization"],
            path: "Tests/SwitchyardLocalizationTests"
        )
    ]
)
