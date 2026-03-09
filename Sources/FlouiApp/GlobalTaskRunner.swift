import Foundation
import WorkspaceCore
import Yams

protocol DeveloperWorkspaceFileSystem: Sendable {
    func fileExists(at path: String) -> Bool
    func directoryExists(at path: String) -> Bool
    func contents(at path: String) throws -> Data
    func contentsOfDirectory(at path: String) throws -> [String]
}

struct LocalDeveloperWorkspaceFileSystem: DeveloperWorkspaceFileSystem {
    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func directoryExists(at path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func contents(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func contentsOfDirectory(at path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }
}

enum DeveloperCapability: String, CaseIterable, Equatable, Sendable {
    case nodePackageScripts
    case dockerCompose
    case dockerfile
    case makefile
    case swiftPackage
    case xcodeWorkspace

    var label: String {
        switch self {
        case .nodePackageScripts:
            return "scripts"
        case .dockerCompose:
            return "compose"
        case .dockerfile:
            return "docker"
        case .makefile:
            return "make"
        case .swiftPackage:
            return "swift"
        case .xcodeWorkspace:
            return "xcode"
        }
    }
}

enum DeveloperTaskSource: String, Equatable, Sendable {
    case packageScript
    case dockerCompose
    case makeTarget
    case swiftPackage
    case xcodeWorkspace
}

struct DeveloperTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let command: String
    let source: DeveloperTaskSource
    let detail: String
    let priority: Int

    init(
        id: String? = nil,
        title: String,
        command: String,
        source: DeveloperTaskSource,
        detail: String,
        priority: Int
    ) {
        self.id = id ?? "\(source.rawValue):\(title):\(command)"
        self.title = title
        self.command = command
        self.source = source
        self.detail = detail
        self.priority = priority
    }
}

struct DeveloperTerminalTaskContext: Identifiable, Equatable, Sendable {
    let paneID: String
    let workspaceID: String
    let workspaceName: String
    let terminalTitle: String
    let shellCommand: [String]
    let workingDirectory: String

    var id: String {
        paneID
    }
}

struct DeveloperTerminalTaskCatalog: Identifiable, Equatable, Sendable {
    let context: DeveloperTerminalTaskContext
    let repositoryName: String
    let repositoryRoot: String
    let relativeDirectoryLabel: String
    let composeFileName: String?
    let composeServices: [String]
    let capabilities: [DeveloperCapability]
    let tasks: [DeveloperTask]

    var id: String {
        context.id
    }

    var executionDirectory: String {
        repositoryRoot
    }
}

struct GlobalTaskRunnerSnapshot: Equatable, Sendable {
    let catalogs: [DeveloperTerminalTaskCatalog]

    static let empty = GlobalTaskRunnerSnapshot(catalogs: [])

    var terminalCount: Int {
        catalogs.count
    }

    var totalTaskCount: Int {
        catalogs.reduce(into: 0) { $0 += $1.tasks.count }
    }
}

enum ComposeRuntimeQuickAction: String, Equatable, Sendable {
    case composeUp
    case composeDown
    case followLogs
}

enum ComposeRuntimeQuickCommandPlanner {
    static func command(for action: ComposeRuntimeQuickAction, runtime: ComposeRuntimeCatalog) -> String {
        switch action {
        case .composeUp:
            return "docker compose up -d"

        case .composeDown:
            return "docker compose down"

        case .followLogs:
            if let service = preferredLogsService(runtime: runtime) {
                return "docker compose logs -f \(service)"
            }
            return "docker compose logs -f"
        }
    }

    private static func preferredLogsService(runtime: ComposeRuntimeCatalog) -> String? {
        if let runningService = runtime.services.first(where: { $0.state == .running })?.serviceName {
            return runningService
        }

        return runtime.services.first?.serviceName
    }
}

struct GlobalTaskDiscoveryService: Sendable {
    private let fileSystem: any DeveloperWorkspaceFileSystem

    init(fileSystem: any DeveloperWorkspaceFileSystem = LocalDeveloperWorkspaceFileSystem()) {
        self.fileSystem = fileSystem
    }

    func snapshot(from layoutState: WorkspaceLayoutState) -> GlobalTaskRunnerSnapshot {
        let catalogs = terminalContexts(from: layoutState)
            .compactMap(discoverCatalog(for:))

        return GlobalTaskRunnerSnapshot(catalogs: catalogs)
    }

    private func terminalContexts(from layoutState: WorkspaceLayoutState) -> [DeveloperTerminalTaskContext] {
        layoutState.workspaceOrder
            .compactMap { layoutState.workspaces[$0] }
            .flatMap { workspace in
                workspace.columns
                    .flatMap(\.windows)
                    .flatMap(\.tabs)
                    .compactMap { tab in
                        guard
                            tab.type == .terminal,
                            let workingDirectory = tab.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                            !workingDirectory.isEmpty,
                            supportsTaskDispatch(shellCommand: tab.command)
                        else {
                            return nil
                        }

                        return DeveloperTerminalTaskContext(
                            paneID: tab.id,
                            workspaceID: workspace.id,
                            workspaceName: workspace.name,
                            terminalTitle: tab.title,
                            shellCommand: resolvedShellCommand(from: tab.command),
                            workingDirectory: standardizedPath(workingDirectory)
                        )
                    }
            }
    }

    private func discoverCatalog(for context: DeveloperTerminalTaskContext) -> DeveloperTerminalTaskCatalog? {
        guard let repositoryRoot = resolveRepositoryRoot(startingAt: context.workingDirectory) else {
            return nil
        }

        let repositoryName = resolveRepositoryName(repositoryRoot: repositoryRoot)
        let relativeDirectoryLabel = relativeDirectoryLabel(
            workingDirectory: context.workingDirectory,
            repositoryRoot: repositoryRoot
        )

        var capabilities: [DeveloperCapability] = []
        var tasks: [DeveloperTask] = []
        var composeManifestFileName: String?
        var composeServices: [String] = []

        let packageJSONPath = appending("package.json", to: repositoryRoot)
        if fileSystem.fileExists(at: packageJSONPath) {
            capabilities.append(.nodePackageScripts)
            let packageDiscovery = discoverPackageScripts(packageJSONPath: packageJSONPath, repositoryRoot: repositoryRoot)
            tasks.append(
                DeveloperTask(
                    title: "install",
                    command: packageDiscovery.packageManager.installCommand,
                    source: .packageScript,
                    detail: packageDiscovery.packageName ?? "Dependencies",
                    priority: 8
                )
            )
            tasks.append(contentsOf: packageDiscovery.tasks)
        }

        if let detectedComposeFileName = composeFileName(in: repositoryRoot) {
            capabilities.append(.dockerCompose)
            composeManifestFileName = detectedComposeFileName
            composeServices = composeServiceNames(composePath: appending(detectedComposeFileName, to: repositoryRoot))
            tasks.append(contentsOf: discoverComposeTasks(repositoryRoot: repositoryRoot, composeFileName: detectedComposeFileName))
        } else if fileSystem.fileExists(at: appending("Dockerfile", to: repositoryRoot)) {
            capabilities.append(.dockerfile)
        }

        let makefilePath = appending("Makefile", to: repositoryRoot)
        if fileSystem.fileExists(at: makefilePath) {
            capabilities.append(.makefile)
            tasks.append(contentsOf: discoverMakeTasks(makefilePath: makefilePath))
        }

        if fileSystem.fileExists(at: appending("Package.swift", to: repositoryRoot)) {
            capabilities.append(.swiftPackage)
            tasks.append(contentsOf: [
                DeveloperTask(
                    title: "swift build",
                    command: "swift build",
                    source: .swiftPackage,
                    detail: "SwiftPM build",
                    priority: 22
                ),
                DeveloperTask(
                    title: "swift test",
                    command: "swift test",
                    source: .swiftPackage,
                    detail: "SwiftPM tests",
                    priority: 16
                ),
            ])
        }

        if let xcodeEntry = resolveXcodeEntry(repositoryRoot: repositoryRoot) {
            capabilities.append(.xcodeWorkspace)
            tasks.append(
                DeveloperTask(
                    title: "Open in Xcode",
                    command: "xed .",
                    source: .xcodeWorkspace,
                    detail: xcodeEntry,
                    priority: 28
                )
            )
        }

        guard !tasks.isEmpty else {
            return nil
        }

        return DeveloperTerminalTaskCatalog(
            context: context,
            repositoryName: repositoryName,
            repositoryRoot: repositoryRoot,
            relativeDirectoryLabel: relativeDirectoryLabel,
            composeFileName: composeManifestFileName,
            composeServices: composeServices,
            capabilities: capabilities,
            tasks: tasks.sorted(by: taskOrdering)
        )
    }

    private func resolveRepositoryRoot(startingAt workingDirectory: String) -> String? {
        var current = standardizedPath(workingDirectory)
        guard fileSystem.directoryExists(at: current) else {
            return nil
        }

        while true {
            if containsProjectMarker(at: current) {
                return current
            }

            let parent = URL(fileURLWithPath: current, isDirectory: true).deletingLastPathComponent().path
            if parent == current || parent.isEmpty {
                break
            }
            current = parent
        }

        return nil
    }

    private func containsProjectMarker(at path: String) -> Bool {
        let markers = [
            "package.json",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml",
            "Dockerfile",
            "Makefile",
            "Package.swift",
            ".git",
        ]

        if markers.contains(where: { fileSystem.fileExists(at: appending($0, to: path)) || fileSystem.directoryExists(at: appending($0, to: path)) }) {
            return true
        }

        if let xcodeEntry = resolveXcodeEntry(repositoryRoot: path) {
            return !xcodeEntry.isEmpty
        }

        return false
    }

    private func resolveRepositoryName(repositoryRoot: String) -> String {
        let packageJSONPath = appending("package.json", to: repositoryRoot)
        if
            fileSystem.fileExists(at: packageJSONPath),
            let data = try? fileSystem.contents(at: packageJSONPath),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = payload["name"] as? String,
            !name.isEmpty
        {
            return name
        }

        return URL(fileURLWithPath: repositoryRoot, isDirectory: true).lastPathComponent
    }

    private func relativeDirectoryLabel(workingDirectory: String, repositoryRoot: String) -> String {
        guard workingDirectory != repositoryRoot else {
            return "repo root"
        }

        let prefix = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
        if workingDirectory.hasPrefix(prefix) {
            return String(workingDirectory.dropFirst(prefix.count))
        }

        return workingDirectory
    }

    private func discoverPackageScripts(
        packageJSONPath: String,
        repositoryRoot _: String
    ) -> (packageName: String?, packageManager: NodePackageManager, tasks: [DeveloperTask]) {
        guard
            let data = try? fileSystem.contents(at: packageJSONPath),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, .npm, [])
        }

        let packageName = payload["name"] as? String
        let scripts = payload["scripts"] as? [String: String] ?? [:]
        let packageManager = resolvePackageManager(repositoryRoot: URL(fileURLWithPath: packageJSONPath).deletingLastPathComponent().path)

        let tasks = scripts.keys.sorted(by: packageScriptOrdering).map { scriptName in
            DeveloperTask(
                title: scriptName,
                command: packageManager.runCommand(for: scriptName),
                source: .packageScript,
                detail: scripts[scriptName] ?? "",
                priority: packageScriptPriority(scriptName)
            )
        }

        return (packageName, packageManager, tasks)
    }

    private func resolvePackageManager(repositoryRoot: String) -> NodePackageManager {
        if fileSystem.fileExists(at: appending("pnpm-lock.yaml", to: repositoryRoot)) {
            return .pnpm
        }
        if fileSystem.fileExists(at: appending("bun.lockb", to: repositoryRoot)) || fileSystem.fileExists(at: appending("bun.lock", to: repositoryRoot)) {
            return .bun
        }
        if fileSystem.fileExists(at: appending("yarn.lock", to: repositoryRoot)) {
            return .yarn
        }
        return .npm
    }

    private func composeFileName(in repositoryRoot: String) -> String? {
        let candidates = ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"]
        return candidates.first { fileSystem.fileExists(at: appending($0, to: repositoryRoot)) }
    }

    private func discoverComposeTasks(repositoryRoot: String, composeFileName: String) -> [DeveloperTask] {
        let composePath = appending(composeFileName, to: repositoryRoot)
        let services = composeServiceNames(composePath: composePath)
        var tasks: [DeveloperTask] = [
            DeveloperTask(
                title: "compose up",
                command: "docker compose up -d",
                source: .dockerCompose,
                detail: composeFileName,
                priority: 10
            ),
            DeveloperTask(
                title: "compose ps",
                command: "docker compose ps",
                source: .dockerCompose,
                detail: composeFileName,
                priority: 18
            ),
            DeveloperTask(
                title: "compose down",
                command: "docker compose down",
                source: .dockerCompose,
                detail: composeFileName,
                priority: 32
            ),
        ]

        tasks.append(contentsOf: services.prefix(6).enumerated().map { index, service in
            DeveloperTask(
                title: "logs \(service)",
                command: "docker compose logs -f \(service)",
                source: .dockerCompose,
                detail: "service",
                priority: 12 + index
            )
        })

        return tasks
    }

    private func composeServiceNames(composePath: String) -> [String] {
        guard
            let data = try? fileSystem.contents(at: composePath),
            let yaml = String(data: data, encoding: .utf8),
            let decoded = try? Yams.load(yaml: yaml)
        else {
            return []
        }

        if let document = decoded as? [String: Any], let services = document["services"] as? [String: Any] {
            return services.keys.sorted()
        }

        if let document = decoded as? [AnyHashable: Any], let services = document["services"] as? [AnyHashable: Any] {
            return services.keys.compactMap { $0 as? String }.sorted()
        }

        return []
    }

    private func discoverMakeTasks(makefilePath: String) -> [DeveloperTask] {
        guard
            let data = try? fileSystem.contents(at: makefilePath),
            let content = String(data: data, encoding: .utf8)
        else {
            return []
        }

        let targets = content
            .split(separator: "\n")
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard
                    !trimmed.isEmpty,
                    !trimmed.hasPrefix("."),
                    !trimmed.hasPrefix("#"),
                    !trimmed.contains("="),
                    let colonIndex = trimmed.firstIndex(of: ":")
                else {
                    return nil
                }

                let target = String(trimmed[..<colonIndex])
                guard !target.isEmpty, !target.contains("%") else {
                    return nil
                }
                return target
            }

        return Array(Set(targets)).sorted(by: packageScriptOrdering).map { target in
            DeveloperTask(
                title: "make \(target)",
                command: "make \(target)",
                source: .makeTarget,
                detail: "Makefile target",
                priority: makeTargetPriority(target)
            )
        }
    }

    private func resolveXcodeEntry(repositoryRoot: String) -> String? {
        guard let entries = try? fileSystem.contentsOfDirectory(at: repositoryRoot) else {
            return nil
        }

        return entries.first { entry in
            let lowercased = entry.lowercased()
            return lowercased.hasSuffix(".xcodeproj") || lowercased.hasSuffix(".xcworkspace")
        }
    }

    private func taskOrdering(_ lhs: DeveloperTask, _ rhs: DeveloperTask) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }

        if lhs.source != rhs.source {
            return lhs.source.rawValue < rhs.source.rawValue
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func packageScriptOrdering(_ lhs: String, _ rhs: String) -> Bool {
        let lhsPriority = packageScriptPriority(lhs)
        let rhsPriority = packageScriptPriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private func packageScriptPriority(_ name: String) -> Int {
        switch name.lowercased() {
        case "dev":
            return 0
        case "start":
            return 1
        case "test":
            return 2
        case "lint":
            return 3
        case "typecheck":
            return 4
        case "build":
            return 5
        case "format":
            return 6
        default:
            return 30
        }
    }

    private func makeTargetPriority(_ name: String) -> Int {
        switch name.lowercased() {
        case "dev":
            return 14
        case "run":
            return 15
        case "test":
            return 17
        case "lint":
            return 19
        case "build":
            return 24
        default:
            return 34
        }
    }

    private func appending(_ component: String, to path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(component).path
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func supportsTaskDispatch(shellCommand: [String]?) -> Bool {
        let resolved = resolvedShellCommand(from: shellCommand)
        if resolved.contains("-c") || resolved.contains("-lc") {
            return false
        }

        guard let first = resolved.first else {
            return true
        }

        let executable: String
        let firstName = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        if firstName == "env" {
            executable = resolved
                .dropFirst()
                .first { part in
                    !part.hasPrefix("-") && !part.contains("=")
                } ?? first
        } else {
            executable = first
        }

        let shellName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        return ["zsh", "bash", "sh", "fish"].contains(shellName)
    }

    private func resolvedShellCommand(from command: [String]?) -> [String] {
        guard let command, !command.isEmpty else {
            return ["/bin/zsh"]
        }
        return command
    }
}

@MainActor
final class GlobalTaskRunnerViewModel: ObservableObject {
    @Published private(set) var snapshot = GlobalTaskRunnerSnapshot.empty
    @Published private(set) var runtimeSnapshot = ComposeRuntimeSnapshot.empty
    @Published private(set) var isRefreshingRuntime = false
    @Published private(set) var lastRuntimeRefreshAt: Date?

    private let discovery: GlobalTaskDiscoveryService
    private let runtimeInspector: ComposeRuntimeInspectionService
    private var refreshTask: Task<Void, Never>?
    private var runtimeRefreshTask: Task<Void, Never>?

    init(
        discovery: GlobalTaskDiscoveryService = .init(),
        runtimeInspector: ComposeRuntimeInspectionService = .init()
    ) {
        self.discovery = discovery
        self.runtimeInspector = runtimeInspector
    }

    deinit {
        refreshTask?.cancel()
        runtimeRefreshTask?.cancel()
    }

    func refresh(layoutState: WorkspaceLayoutState) {
        refreshTask?.cancel()
        let discovery = self.discovery
        let runtimeInspector = self.runtimeInspector
        isRefreshingRuntime = true
        refreshTask = Task {
            let snapshot = await Task.detached(priority: .utility) {
                discovery.snapshot(from: layoutState)
            }.value
            let runtimeSnapshot = await Task.detached(priority: .utility) {
                await runtimeInspector.inspect(catalogs: snapshot.catalogs)
            }.value

            guard !Task.isCancelled else {
                return
            }

            self.snapshot = snapshot
            self.runtimeSnapshot = runtimeSnapshot
            self.lastRuntimeRefreshAt = snapshot.catalogs.isEmpty ? nil : Date()
            self.isRefreshingRuntime = false
        }
    }

    func refreshRuntime() {
        runtimeRefreshTask?.cancel()
        let catalogs = snapshot.catalogs
        guard !catalogs.isEmpty else {
            runtimeSnapshot = .empty
            lastRuntimeRefreshAt = nil
            isRefreshingRuntime = false
            return
        }

        let runtimeInspector = self.runtimeInspector
        isRefreshingRuntime = true
        runtimeRefreshTask = Task {
            let runtimeSnapshot = await Task.detached(priority: .utility) {
                await runtimeInspector.inspect(catalogs: catalogs)
            }.value

            guard !Task.isCancelled else {
                return
            }

            self.runtimeSnapshot = runtimeSnapshot
            self.lastRuntimeRefreshAt = Date()
            self.isRefreshingRuntime = false
        }
    }
}

private enum NodePackageManager: Sendable {
    case npm
    case pnpm
    case yarn
    case bun

    var installCommand: String {
        switch self {
        case .npm:
            return "npm install"
        case .pnpm:
            return "pnpm install"
        case .yarn:
            return "yarn install"
        case .bun:
            return "bun install"
        }
    }

    func runCommand(for scriptName: String) -> String {
        switch self {
        case .npm:
            return "npm run \(scriptName)"
        case .pnpm:
            return "pnpm run \(scriptName)"
        case .yarn:
            return "yarn \(scriptName)"
        case .bun:
            return "bun run \(scriptName)"
        }
    }
}
