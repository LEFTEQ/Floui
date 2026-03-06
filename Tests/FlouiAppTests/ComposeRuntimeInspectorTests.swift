@testable import FlouiApp
import FlouiCore
import Foundation
import Testing

private actor MockCommandOutputRunner: CommandOutputRunning {
    var resultsByDirectory: [String: CommandExecutionResult] = [:]
    var errorMessagesByDirectory: [String: String] = [:]
    private(set) var commands: [(String, [String], String?)] = []

    func setResult(_ result: CommandExecutionResult, for workingDirectory: String) {
        resultsByDirectory[workingDirectory] = result
    }

    func setErrorMessage(_ message: String, for workingDirectory: String) {
        errorMessagesByDirectory[workingDirectory] = message
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        workingDirectory: String?,
        environment _: [String: String]
    ) async throws -> CommandExecutionResult {
        commands.append((launchPath, arguments, workingDirectory))

        if let workingDirectory, let message = errorMessagesByDirectory[workingDirectory] {
            throw FlouiError.operationFailed(message)
        }

        if let workingDirectory, let result = resultsByDirectory[workingDirectory] {
            return result
        }

        return CommandExecutionResult(exitCode: 0, stdout: "[]", stderr: "")
    }
}

@Test("Compose runtime inspector parses docker compose ps output into service status cards")
func composeRuntimeInspectorParsesComposeStatus() async throws {
    let runner = MockCommandOutputRunner()
    await runner.setResult(
        CommandExecutionResult(
            exitCode: 0,
            stdout: """
            [
              {
                "Service": "app",
                "Name": "repo-app-1",
                "State": "running",
                "Health": "healthy",
                "Publishers": [
                  { "PublishedPort": 3000, "URL": "0.0.0.0" }
                ]
              },
              {
                "Service": "db",
                "Name": "repo-db-1",
                "State": "exited",
                "Health": "",
                "Publishers": []
              }
            ]
            """,
            stderr: ""
        ),
        for: "/repo"
    )

    let catalog = DeveloperTerminalTaskCatalog(
        context: DeveloperTerminalTaskContext(
            paneID: "term-1",
            workspaceID: "shipyard",
            workspaceName: "Shipyard",
            terminalTitle: "Web",
            shellCommand: ["/bin/zsh"],
            workingDirectory: "/repo/apps/web"
        ),
        repositoryName: "repo",
        repositoryRoot: "/repo",
        relativeDirectoryLabel: "apps/web",
        composeFileName: "docker-compose.yml",
        composeServices: ["app", "db"],
        capabilities: [.dockerCompose],
        tasks: []
    )

    let snapshot = await ComposeRuntimeInspectionService(commandRunner: runner).inspect(catalogs: [catalog])

    #expect(snapshot.catalogs.count == 1)
    let runtime = try #require(snapshot.catalogs.first)
    #expect(runtime.repositoryName == "repo")
    #expect(runtime.runningServiceCount == 1)
    #expect(runtime.stoppedServiceCount == 1)
    #expect(runtime.services.first?.serviceName == "app")
    #expect(runtime.services.first?.state == .running)
    #expect(runtime.services.first?.health == "healthy")
    #expect(runtime.services.first?.portsDescription == "3000")
    #expect(runtime.services.last?.serviceName == "db")
    #expect(runtime.services.last?.state == .stopped)
}

@Test("Compose runtime inspector falls back to declared services when no containers are running")
func composeRuntimeInspectorUsesDeclaredServicesAsFallback() async throws {
    let runner = MockCommandOutputRunner()
    await runner.setResult(
        CommandExecutionResult(exitCode: 0, stdout: "[]", stderr: ""),
        for: "/repo"
    )

    let catalog = DeveloperTerminalTaskCatalog(
        context: DeveloperTerminalTaskContext(
            paneID: "term-1",
            workspaceID: "shipyard",
            workspaceName: "Shipyard",
            terminalTitle: "Web",
            shellCommand: ["/bin/zsh"],
            workingDirectory: "/repo"
        ),
        repositoryName: "repo",
        repositoryRoot: "/repo",
        relativeDirectoryLabel: "repo root",
        composeFileName: "docker-compose.yml",
        composeServices: ["app", "db"],
        capabilities: [.dockerCompose],
        tasks: []
    )

    let snapshot = await ComposeRuntimeInspectionService(commandRunner: runner).inspect(catalogs: [catalog])

    let runtime = try #require(snapshot.catalogs.first)
    #expect(runtime.runningServiceCount == 0)
    #expect(runtime.stoppedServiceCount == 2)
    #expect(runtime.services.map(\.serviceName) == ["app", "db"])
    #expect(runtime.services.allSatisfy { $0.state == .stopped })
}

@Test("Compose runtime inspector surfaces command failures as actionable errors")
func composeRuntimeInspectorCapturesCommandFailures() async throws {
    let runner = MockCommandOutputRunner()
    await runner.setErrorMessage("docker unavailable", for: "/repo")

    let catalog = DeveloperTerminalTaskCatalog(
        context: DeveloperTerminalTaskContext(
            paneID: "term-1",
            workspaceID: "shipyard",
            workspaceName: "Shipyard",
            terminalTitle: "Web",
            shellCommand: ["/bin/zsh"],
            workingDirectory: "/repo"
        ),
        repositoryName: "repo",
        repositoryRoot: "/repo",
        relativeDirectoryLabel: "repo root",
        composeFileName: "docker-compose.yml",
        composeServices: ["app"],
        capabilities: [.dockerCompose],
        tasks: []
    )

    let snapshot = await ComposeRuntimeInspectionService(commandRunner: runner).inspect(catalogs: [catalog])

    let runtime = try #require(snapshot.catalogs.first)
    #expect(runtime.lastError == "Unable to inspect docker compose runtime.")
    #expect(runtime.services.isEmpty)
}
