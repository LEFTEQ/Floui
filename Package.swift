// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Floui",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "FlouiCore", targets: ["FlouiCore"]),
        .library(name: "WorkspaceCore", targets: ["WorkspaceCore"]),
        .library(name: "StatusPills", targets: ["StatusPills"]),
        .library(name: "TerminalHost", targets: ["TerminalHost"]),
        .library(name: "BrowserOrchestrator", targets: ["BrowserOrchestrator"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .executable(name: "FlouiApp", targets: ["FlouiApp"]),
        .executable(name: "floui-cli", targets: ["floui-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.0"),
    ],
    targets: [
        .target(name: "FlouiCore"),
        .target(
            name: "WorkspaceCore",
            dependencies: [
                "FlouiCore",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "StatusPills",
            dependencies: ["FlouiCore"]
        ),
        .target(
            name: "TerminalHost",
            dependencies: ["FlouiCore", "StatusPills"]
        ),
        .target(
            name: "BrowserOrchestrator",
            dependencies: ["FlouiCore", "WorkspaceCore"]
        ),
        .target(
            name: "Permissions",
            dependencies: ["FlouiCore"]
        ),
        .executableTarget(
            name: "FlouiApp",
            dependencies: [
                "FlouiCore",
                "WorkspaceCore",
                "StatusPills",
                "TerminalHost",
                "BrowserOrchestrator",
                "Permissions",
                .product(name: "Yams", package: "Yams"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/FlouiApp"
        ),
        .executableTarget(
            name: "floui-cli",
            dependencies: ["StatusPills"],
            path: "Sources/floui-cli"
        ),
        .testTarget(
            name: "FlouiCoreTests",
            dependencies: ["FlouiCore"]
        ),
        .testTarget(
            name: "WorkspaceCoreTests",
            dependencies: ["WorkspaceCore", "FlouiCore"]
        ),
        .testTarget(
            name: "StatusPillsTests",
            dependencies: ["StatusPills", "FlouiCore"]
        ),
        .testTarget(
            name: "TerminalHostTests",
            dependencies: ["TerminalHost", "FlouiCore", "StatusPills"]
        ),
        .testTarget(
            name: "BrowserOrchestratorTests",
            dependencies: ["BrowserOrchestrator", "FlouiCore", "WorkspaceCore"]
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", "FlouiCore"]
        ),
        .testTarget(
            name: "FlouiAppTests",
            dependencies: [
                "FlouiApp",
                "WorkspaceCore",
                "Permissions",
            ]
        ),
        .testTarget(
            name: "E2EHybridTests",
            dependencies: [
                "FlouiCore",
                "WorkspaceCore",
                "StatusPills",
                "TerminalHost",
                "BrowserOrchestrator",
                "Permissions",
            ]
        ),
        .testTarget(
            name: "E2ERealTests",
            dependencies: [
                "FlouiCore",
                "WorkspaceCore",
                "StatusPills",
                "TerminalHost",
                "BrowserOrchestrator",
                "Permissions",
            ]
        ),
    ]
)
