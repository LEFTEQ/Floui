import Foundation

struct CommandExecutionResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol CommandOutputRunning: Sendable {
    func run(
        _ launchPath: String,
        _ arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> CommandExecutionResult
}

struct LocalCommandOutputRunner: CommandOutputRunning {
    func run(
        _ launchPath: String,
        _ arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> CommandExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        if let workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CommandExecutionResult(
                    exitCode: terminatedProcess.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum ComposeServiceRuntimeState: String, Equatable, Sendable {
    case running
    case stopped
    case restarting
    case paused
    case unknown

    var label: String {
        rawValue
    }
}

struct ComposeServiceRuntime: Identifiable, Equatable, Sendable {
    let id: String
    let serviceName: String
    let containerName: String?
    let state: ComposeServiceRuntimeState
    let health: String?
    let portsDescription: String?

    init(
        serviceName: String,
        containerName: String? = nil,
        state: ComposeServiceRuntimeState,
        health: String? = nil,
        portsDescription: String? = nil
    ) {
        id = serviceName
        self.serviceName = serviceName
        self.containerName = containerName
        self.state = state
        self.health = health
        self.portsDescription = portsDescription
    }
}

struct ComposeRuntimeCatalog: Identifiable, Equatable, Sendable {
    let id: String
    let paneID: String
    let repositoryName: String
    let repositoryRoot: String
    let services: [ComposeServiceRuntime]
    let lastError: String?

    init(
        paneID: String,
        repositoryName: String,
        repositoryRoot: String,
        services: [ComposeServiceRuntime],
        lastError: String? = nil
    ) {
        id = paneID
        self.paneID = paneID
        self.repositoryName = repositoryName
        self.repositoryRoot = repositoryRoot
        self.services = services
        self.lastError = lastError
    }

    var runningServiceCount: Int {
        services.filter { $0.state == .running }.count
    }

    var stoppedServiceCount: Int {
        services.filter { $0.state == .stopped }.count
    }

    var statusSummary: String {
        if let lastError, !lastError.isEmpty {
            return "inspection failed"
        }

        if services.isEmpty {
            return "no services"
        }

        if stoppedServiceCount == 0 {
            return "\(runningServiceCount) running"
        }

        return "\(runningServiceCount) running · \(stoppedServiceCount) stopped"
    }
}

struct ComposeRuntimeSnapshot: Equatable, Sendable {
    let catalogs: [ComposeRuntimeCatalog]

    static let empty = ComposeRuntimeSnapshot(catalogs: [])

    func catalog(for paneID: String) -> ComposeRuntimeCatalog? {
        catalogs.first { $0.paneID == paneID }
    }
}

struct ComposeRuntimeInspectionService: Sendable {
    private let commandRunner: any CommandOutputRunning

    init(commandRunner: any CommandOutputRunning = LocalCommandOutputRunner()) {
        self.commandRunner = commandRunner
    }

    func inspect(catalogs: [DeveloperTerminalTaskCatalog]) async -> ComposeRuntimeSnapshot {
        var inspectedCatalogs: [ComposeRuntimeCatalog] = []
        inspectedCatalogs.reserveCapacity(catalogs.count)

        for catalog in catalogs where catalog.capabilities.contains(.dockerCompose) {
            guard let runtime = await inspect(catalog: catalog) else {
                continue
            }
            inspectedCatalogs.append(runtime)
        }

        return ComposeRuntimeSnapshot(
            catalogs: inspectedCatalogs.sorted { lhs, rhs in
                lhs.repositoryName.localizedCaseInsensitiveCompare(rhs.repositoryName) == .orderedAscending
            }
        )
    }

    private func inspect(catalog: DeveloperTerminalTaskCatalog) async -> ComposeRuntimeCatalog? {
        guard let composeFileName = catalog.composeFileName else {
            return nil
        }

        do {
            let result = try await commandRunner.run(
                "/usr/bin/env",
                ["docker", "compose", "-f", composeFileName, "ps", "--format", "json"],
                workingDirectory: catalog.executionDirectory,
                environment: [:]
            )

            guard result.exitCode == 0 else {
                return ComposeRuntimeCatalog(
                    paneID: catalog.context.paneID,
                    repositoryName: catalog.repositoryName,
                    repositoryRoot: catalog.repositoryRoot,
                    services: [],
                    lastError: normalizedErrorMessage(result.stderr)
                )
            }

            return ComposeRuntimeCatalog(
                paneID: catalog.context.paneID,
                repositoryName: catalog.repositoryName,
                repositoryRoot: catalog.repositoryRoot,
                services: parseComposeServices(
                    result.stdout,
                    fallbackServices: catalog.composeServices
                )
            )
        } catch {
            return ComposeRuntimeCatalog(
                paneID: catalog.context.paneID,
                repositoryName: catalog.repositoryName,
                repositoryRoot: catalog.repositoryRoot,
                services: [],
                lastError: "Unable to inspect docker compose runtime."
            )
        }
    }

    private func normalizedErrorMessage(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "docker compose ps failed."
        }
        return trimmed
    }

    private func parseComposeServices(
        _ stdout: String,
        fallbackServices: [String]
    ) -> [ComposeServiceRuntime] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[]" {
            return fallbackServices.map {
                ComposeServiceRuntime(serviceName: $0, state: .stopped)
            }
        }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data)
        {
            if let array = payload as? [[String: Any]] {
                let parsed = array.compactMap(parseComposeService)
                if !parsed.isEmpty {
                    return mergedServices(parsed, fallbackServices: fallbackServices)
                }
            }

            if let object = payload as? [String: Any], let parsed = parseComposeService(object) {
                return mergedServices([parsed], fallbackServices: fallbackServices)
            }
        }

        let lineObjects = trimmed
            .split(separator: "\n")
            .compactMap { line -> ComposeServiceRuntime? in
                guard let data = String(line).data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return nil
                }
                return parseComposeService(payload)
            }

        return mergedServices(lineObjects, fallbackServices: fallbackServices)
    }

    private func mergedServices(
        _ parsed: [ComposeServiceRuntime],
        fallbackServices: [String]
    ) -> [ComposeServiceRuntime] {
        var servicesByName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.serviceName, $0) })
        for service in fallbackServices where servicesByName[service] == nil {
            servicesByName[service] = ComposeServiceRuntime(serviceName: service, state: .stopped)
        }

        return servicesByName.values.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return stateRank(lhs.state) < stateRank(rhs.state)
            }
            return lhs.serviceName.localizedCaseInsensitiveCompare(rhs.serviceName) == .orderedAscending
        }
    }

    private func stateRank(_ state: ComposeServiceRuntimeState) -> Int {
        switch state {
        case .running:
            return 0
        case .restarting:
            return 1
        case .paused:
            return 2
        case .stopped:
            return 3
        case .unknown:
            return 4
        }
    }

    private func parseComposeService(_ payload: [String: Any]) -> ComposeServiceRuntime? {
        guard let serviceName = firstString(payload, keys: ["Service", "service"]), !serviceName.isEmpty else {
            return nil
        }

        let state = parseState(firstString(payload, keys: ["State", "state"]) ?? "")
        let health = firstString(payload, keys: ["Health", "health"])
        let portsDescription = parsePorts(payload["Publishers"] ?? payload["publishers"])

        return ComposeServiceRuntime(
            serviceName: serviceName,
            containerName: firstString(payload, keys: ["Name", "name"]),
            state: state,
            health: normalizedOptionalString(health),
            portsDescription: portsDescription
        )
    }

    private func firstString(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                return value
            }
        }
        return nil
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseState(_ rawState: String) -> ComposeServiceRuntimeState {
        let normalized = rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("running") {
            return .running
        }
        if normalized.contains("restart") {
            return .restarting
        }
        if normalized.contains("paused") {
            return .paused
        }
        if normalized.contains("exit") || normalized.contains("dead") || normalized.contains("created") || normalized.contains("stopped") {
            return .stopped
        }
        return .unknown
    }

    private func parsePorts(_ rawValue: Any?) -> String? {
        guard let rawArray = rawValue as? [[String: Any]], !rawArray.isEmpty else {
            return nil
        }

        let ports = rawArray.compactMap { publisher -> String? in
            if let publishedPort = publisher["PublishedPort"] as? Int {
                return String(publishedPort)
            }
            if let publishedPort = publisher["PublishedPort"] as? String {
                return publishedPort
            }
            return nil
        }

        guard !ports.isEmpty else {
            return nil
        }

        return ports.joined(separator: ", ")
    }
}
