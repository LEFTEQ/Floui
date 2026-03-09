@testable import FlouiApp
import Foundation
import Testing
import WorkspaceCore

private struct MockDeveloperWorkspaceFileSystem: DeveloperWorkspaceFileSystem {
    var directories: Set<String>
    var files: [String: Data]
    var directoryEntries: [String: [String]]

    func fileExists(at path: String) -> Bool {
        files[path] != nil
    }

    func directoryExists(at path: String) -> Bool {
        directories.contains(path)
    }

    func contents(at path: String) throws -> Data {
        guard let data = files[path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func contentsOfDirectory(at path: String) throws -> [String] {
        directoryEntries[path] ?? []
    }
}

@Test("Global task runner discovers package scripts docker compose and make targets from terminal directories")
func globalTaskRunnerDiscoversRepositoryTasks() throws {
    let layoutState = WorkspaceLayoutState(
        activeWorkspaceID: "shipyard",
        workspaceOrder: ["shipyard"],
        workspaces: [
            "shipyard": WorkspaceManifest(
                id: "shipyard",
                name: "Shipyard",
                version: 1,
                columns: [
                    WorkspaceColumnManifest(
                        id: "col-1",
                        windows: [
                            WorkspaceMiniWindowManifest(
                                id: "win-1",
                                activeTabID: "term-1",
                                tabs: [
                                    WorkspaceTabManifest(
                                        id: "term-1",
                                        title: "Web",
                                        type: .terminal,
                                        command: ["/bin/zsh"],
                                        workingDirectory: "/repo/apps/web"
                                    ),
                                ]
                            )
                        ]
                    )
                ]
            ),
        ]
    )

    let fileSystem = MockDeveloperWorkspaceFileSystem(
        directories: [
            "/",
            "/repo",
            "/repo/apps",
            "/repo/apps/web",
        ],
        files: [
            "/repo/package.json": Data(#"{"name":"shipyard","scripts":{"dev":"vite","test":"vitest run","lint":"eslint .","build":"vite build"}}"#.utf8),
            "/repo/pnpm-lock.yaml": Data("lockfileVersion: '9.0'".utf8),
            "/repo/Package.swift": Data("import PackageDescription".utf8),
            "/repo/docker-compose.yml": Data(
                """
                services:
                  app:
                    image: node:20
                  db:
                    image: postgres:16
                """.utf8
            ),
            "/repo/Makefile": Data(
                """
                .PHONY: test lint
                test:
                \t@echo test
                lint:
                \t@echo lint
                """.utf8
            ),
        ],
        directoryEntries: [
            "/repo": ["Apps.xcodeproj", "Package.swift"],
        ]
    )

    let snapshot = GlobalTaskDiscoveryService(fileSystem: fileSystem).snapshot(from: layoutState)

    #expect(snapshot.catalogs.count == 1)
    #expect(snapshot.terminalCount == 1)

    let catalog = try #require(snapshot.catalogs.first)
    #expect(catalog.repositoryName == "shipyard")
    #expect(catalog.repositoryRoot == "/repo")
    #expect(catalog.relativeDirectoryLabel == "apps/web")
    #expect(catalog.composeFileName == "docker-compose.yml")
    #expect(catalog.composeServices == ["app", "db"])
    #expect(catalog.capabilities.contains(.nodePackageScripts))
    #expect(catalog.capabilities.contains(.dockerCompose))
    #expect(catalog.capabilities.contains(.makefile))
    #expect(catalog.capabilities.contains(.swiftPackage))
    #expect(catalog.capabilities.contains(.xcodeWorkspace))
    #expect(catalog.tasks.contains { $0.source == .packageScript && $0.title == "dev" && $0.command == "pnpm run dev" })
    #expect(catalog.tasks.contains { $0.source == .dockerCompose && $0.title == "compose up" && $0.command == "docker compose up -d" })
    #expect(catalog.tasks.contains { $0.source == .dockerCompose && $0.title == "logs app" && $0.command == "docker compose logs -f app" })
    #expect(catalog.tasks.contains { $0.source == .makeTarget && $0.title == "make test" && $0.command == "make test" })
    #expect(catalog.tasks.contains { $0.source == .swiftPackage && $0.title == "swift test" && $0.command == "swift test" })
    #expect(catalog.tasks.contains { $0.source == .xcodeWorkspace && $0.title == "Open in Xcode" && $0.command == "xed ." })
    #expect(catalog.tasks.first?.title == "dev")
}

@Test("Global task runner ignores non-shell terminal tabs and keeps empty directories out of the catalog")
func globalTaskRunnerFiltersUnsupportedTerminalContexts() {
    let layoutState = WorkspaceLayoutState(
        activeWorkspaceID: "ops",
        workspaceOrder: ["ops"],
        workspaces: [
            "ops": WorkspaceManifest(
                id: "ops",
                name: "Ops",
                version: 1,
                columns: [
                    WorkspaceColumnManifest(
                        id: "col-1",
                        windows: [
                            WorkspaceMiniWindowManifest(
                                id: "win-1",
                                activeTabID: "term-1",
                                tabs: [
                                    WorkspaceTabManifest(
                                        id: "term-1",
                                        title: "Server",
                                        type: .terminal,
                                        command: ["/usr/bin/env", "ssh", "prod"],
                                        workingDirectory: "/infra"
                                    ),
                                    WorkspaceTabManifest(
                                        id: "term-2",
                                        title: "No Dir",
                                        type: .terminal,
                                        command: ["/bin/zsh"]
                                    ),
                                ]
                            )
                        ]
                    )
                ]
            ),
        ]
    )

    let snapshot = GlobalTaskDiscoveryService(
        fileSystem: MockDeveloperWorkspaceFileSystem(
            directories: ["/", "/infra"],
            files: [:],
            directoryEntries: [:]
        )
    )
    .snapshot(from: layoutState)

    #expect(snapshot.catalogs.isEmpty)
    #expect(snapshot.totalTaskCount == 0)
}

@Test("Compose runtime quick command planner prefers logs for running services")
func composeRuntimeQuickCommandPlannerUsesRunningService() {
    let runtime = ComposeRuntimeCatalog(
        paneID: "term-1",
        repositoryName: "repo",
        repositoryRoot: "/repo",
        services: [
            ComposeServiceRuntime(serviceName: "db", state: .stopped),
            ComposeServiceRuntime(serviceName: "web", state: .running),
        ]
    )

    #expect(ComposeRuntimeQuickCommandPlanner.command(for: .composeUp, runtime: runtime) == "docker compose up -d")
    #expect(ComposeRuntimeQuickCommandPlanner.command(for: .composeDown, runtime: runtime) == "docker compose down")
    #expect(ComposeRuntimeQuickCommandPlanner.command(for: .followLogs, runtime: runtime) == "docker compose logs -f web")
}

@Test("Compose runtime quick command planner falls back when no service is running")
func composeRuntimeQuickCommandPlannerFallbacksWithoutRunningService() {
    let stoppedRuntime = ComposeRuntimeCatalog(
        paneID: "term-1",
        repositoryName: "repo",
        repositoryRoot: "/repo",
        services: [
            ComposeServiceRuntime(serviceName: "worker", state: .stopped),
            ComposeServiceRuntime(serviceName: "cache", state: .stopped),
        ]
    )

    let emptyRuntime = ComposeRuntimeCatalog(
        paneID: "term-2",
        repositoryName: "repo",
        repositoryRoot: "/repo",
        services: []
    )

    #expect(ComposeRuntimeQuickCommandPlanner.command(for: .followLogs, runtime: stoppedRuntime) == "docker compose logs -f worker")
    #expect(ComposeRuntimeQuickCommandPlanner.command(for: .followLogs, runtime: emptyRuntime) == "docker compose logs -f")
}
