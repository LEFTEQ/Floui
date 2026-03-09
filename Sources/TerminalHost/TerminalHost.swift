import FlouiCore
import Foundation
import StatusPills

public final class GhosttyTerminalEngine: TerminalEngine,  Sendable {
    private let bridge: TerminalSurfaceBridge

    public init(bridge: TerminalSurfaceBridge) {
        self.bridge = bridge
    }

    public func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        try await bridge.start(config: config)
    }

    public func attachView(sessionID: TerminalSessionID, surfaceID: String) async throws {
        try await bridge.attach(sessionID: sessionID, surfaceID: surfaceID)
    }

    public func sendInput(sessionID: TerminalSessionID, input: String) async throws {
        try await bridge.input(sessionID: sessionID, text: input)
    }

    public func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        try await bridge.resize(sessionID: sessionID, cols: cols, rows: rows)
    }

    public func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        await bridge.events(sessionID: sessionID)
    }
}

public actor ExternalTerminalEngine: TerminalEngine {
    private struct SessionRecord {
        var config: TerminalSessionConfig
        var process: Process
        var stdin: FileHandle
        var stdout: FileHandle
        var stderr: FileHandle
    }

    private var sessions: [TerminalSessionID: SessionRecord] = [:]
    private var continuations: [TerminalSessionID: AsyncStream<TerminalEvent>.Continuation] = [:]
    private var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]

    public init() {}

    public func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        guard let executable = config.shellCommand.first else {
            throw FlouiError.invalidInput("shellCommand must include executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(config.shellCommand.dropFirst())

        if let workingDirectory = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            environment[key] = value
        }
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let sessionID = TerminalSessionID()

        var continuationBox: AsyncStream<TerminalEvent>.Continuation?
        let stream = AsyncStream<TerminalEvent> { continuation in
            continuationBox = continuation
        }

        guard let continuationBox else {
            throw FlouiError.operationFailed("failed to create stream continuation")
        }

        sessions[sessionID] = SessionRecord(
            config: config,
            process: process,
            stdin: inputPipe.fileHandleForWriting,
            stdout: outputPipe.fileHandleForReading,
            stderr: errorPipe.fileHandleForReading
        )
        continuations[sessionID] = continuationBox
        streams[sessionID] = stream

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Self.yieldOutput(data, to: continuationBox)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Self.yieldOutput(data, to: continuationBox)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            let remainingStdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingStdout.isEmpty {
                Self.yieldOutput(remainingStdout, to: continuationBox)
            }

            let remainingStderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingStderr.isEmpty {
                Self.yieldOutput(remainingStderr, to: continuationBox)
            }

            continuationBox.yield(.processExited(terminatedProcess.terminationStatus))
            Task { await self?.cleanupSession(sessionID: sessionID, finishStream: true) }
        }

        do {
            try process.run()
            emit(.status("external-session-started"), for: sessionID)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            cleanupSession(sessionID: sessionID, finishStream: true)
            throw FlouiError.operationFailed("failed to start external process: \(error.localizedDescription)")
        }

        return sessionID
    }

    public func attachView(sessionID: TerminalSessionID, surfaceID _: String) async throws {
        guard sessions[sessionID] != nil else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }
    }

    public func sendInput(sessionID: TerminalSessionID, input: String) async throws {
        guard let session = sessions[sessionID] else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        do {
            try session.stdin.write(contentsOf: Data(input.utf8))
        } catch {
            throw FlouiError.operationFailed("failed to write terminal input: \(error.localizedDescription)")
        }
    }

    public func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        guard sessions[sessionID] != nil else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        emit(.status("external-resize \(cols)x\(rows)"), for: sessionID)
    }

    public func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in
            continuation.yield(.status("session-not-found"))
            continuation.finish()
        }
    }

    private static func yieldOutput(_ data: Data, to continuation: AsyncStream<TerminalEvent>.Continuation) {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            continuation.yield(.output(text))
            return
        }

        let decoded = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        if !decoded.isEmpty {
            continuation.yield(.status("external-output-bytes: \(decoded)"))
        }
    }

    private func cleanupSession(sessionID: TerminalSessionID, finishStream: Bool) {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return
        }

        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil
        session.process.terminationHandler = nil

        try? session.stdin.close()
        try? session.stdout.close()
        try? session.stderr.close()

        if finishStream {
            continuations[sessionID]?.finish()
        }

        continuations.removeValue(forKey: sessionID)
        streams.removeValue(forKey: sessionID)
    }

    private func emit(_ event: TerminalEvent, for sessionID: TerminalSessionID) {
        guard let continuation = continuations[sessionID] else {
            return
        }

        continuation.yield(event)

        if case .processExited = event {
            cleanupSession(sessionID: sessionID, finishStream: true)
        }
    }
}

public actor GhosttyFirstTerminalEngine: TerminalEngine {
    private enum EngineSelection {
        case primary
        case fallback
    }

    private let primary: TerminalEngine
    private let fallback: TerminalEngine
    private var sessionEngines: [TerminalSessionID: EngineSelection] = [:]
    private var forceFallback = false

    public init(
        primary: TerminalEngine = GhosttyTerminalEngine(bridge: GhosttyRuntimeBridge()),
        fallback: TerminalEngine = ExternalTerminalEngine()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        if forceFallback {
            let id = try await fallback.startSession(config: config)
            sessionEngines[id] = .fallback
            return id
        }

        do {
            let id = try await primary.startSession(config: config)
            sessionEngines[id] = .primary
            return id
        } catch {
            guard shouldFallback(from: error) else {
                throw error
            }

            forceFallback = true
            let id = try await fallback.startSession(config: config)
            sessionEngines[id] = .fallback
            return id
        }
    }

    public func attachView(sessionID: TerminalSessionID, surfaceID: String) async throws {
        try await engine(for: sessionID).attachView(sessionID: sessionID, surfaceID: surfaceID)
    }

    public func sendInput(sessionID: TerminalSessionID, input: String) async throws {
        try await engine(for: sessionID).sendInput(sessionID: sessionID, input: input)
    }

    public func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        try await engine(for: sessionID).resize(sessionID: sessionID, cols: cols, rows: rows)
    }

    public func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        do {
            let selectedEngine = try engine(for: sessionID)
            return await selectedEngine.subscribeEvents(sessionID: sessionID)
        } catch {
            return AsyncStream { continuation in
                continuation.yield(.status("session-not-found"))
                continuation.finish()
            }
        }
    }

    private func engine(for sessionID: TerminalSessionID) throws -> TerminalEngine {
        guard let selection = sessionEngines[sessionID] else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        switch selection {
        case .primary:
            return primary
        case .fallback:
            return fallback
        }
    }

    private func shouldFallback(from error: Error) -> Bool {
        guard let flouiError = error as? FlouiError else {
            return false
        }

        switch flouiError {
        case .unsupported:
            return true
        case let .operationFailed(message):
            let lowercased = message.lowercased()
            return lowercased.contains("libghostty") || lowercased.contains("ghostty")
        default:
            return false
        }
    }
}

public enum DefaultTerminalEngineFactory {
    public static func make() -> TerminalEngine {
        GhosttyFirstTerminalEngine()
    }
}

public actor TerminalSessionManager {
    private let engine: TerminalEngine
    private var activeSessions: [String: TerminalSessionID] = [:]

    public init(engine: TerminalEngine) {
        self.engine = engine
    }

    public func start(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        let id = try await engine.startSession(config: config)
        activeSessions[config.paneID] = id
        return id
    }

    public func sessionID(for paneID: String) -> TerminalSessionID? {
        activeSessions[paneID]
    }

    public func clearSession(for paneID: String) {
        activeSessions.removeValue(forKey: paneID)
    }

    public func attachView(paneID: String, surfaceID: String) async throws {
        guard let sessionID = activeSessions[paneID] else {
            throw FlouiError.notFound("no active terminal session for pane \(paneID)")
        }

        try await engine.attachView(sessionID: sessionID, surfaceID: surfaceID)
    }
}

public struct TerminalPaneRuntimeState: Equatable, Sendable {
    public var paneID: String
    public var workspaceID: String
    public var command: [String]
    public var workingDirectory: String?
    public var currentDirectory: String?
    public var gitBranch: String?
    public var activeCommand: String?
    public var recentCommands: [String]
    public var isRunning: Bool
    public var lastMessage: String
    public var outputLines: [String]
    public var exitCode: Int32?

    public init(
        paneID: String,
        workspaceID: String,
        command: [String],
        workingDirectory: String? = nil,
        currentDirectory: String? = nil,
        gitBranch: String? = nil,
        activeCommand: String? = nil,
        recentCommands: [String] = [],
        isRunning: Bool,
        lastMessage: String,
        outputLines: [String] = [],
        exitCode: Int32? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.command = command
        self.workingDirectory = workingDirectory
        self.currentDirectory = currentDirectory ?? workingDirectory
        self.gitBranch = gitBranch
        self.activeCommand = activeCommand
        self.recentCommands = recentCommands
        self.isRunning = isRunning
        self.lastMessage = lastMessage
        self.outputLines = outputLines
        self.exitCode = exitCode
    }
}

public actor TerminalWorkspaceRuntime {
    private let engine: TerminalEngine
    private let manager: TerminalSessionManager
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var statesByPaneID: [String: TerminalPaneRuntimeState] = [:]
    private var integrationParsersByPaneID: [String: TerminalIntegrationParser] = [:]

    public init(engine: TerminalEngine) {
        self.engine = engine
        manager = TerminalSessionManager(engine: engine)
    }

    public func activateTerminal(config: TerminalSessionConfig) async throws {
        if await manager.sessionID(for: config.paneID) != nil {
            return
        }

        let sessionID = try await manager.start(config: config)
        statesByPaneID[config.paneID] = TerminalPaneRuntimeState(
            paneID: config.paneID,
            workspaceID: config.workspaceID,
            command: config.shellCommand,
            workingDirectory: config.workingDirectory,
            currentDirectory: config.workingDirectory,
            isRunning: true,
            lastMessage: "Session started"
        )
        integrationParsersByPaneID[config.paneID] = TerminalIntegrationParser()
        startEventPump(paneID: config.paneID, sessionID: sessionID)
    }

    public func attachSurface(paneID: String, surfaceID: String) async throws {
        try await manager.attachView(paneID: paneID, surfaceID: surfaceID)
    }

    public func sendInput(paneID: String, input: String) async throws {
        guard let sessionID = await manager.sessionID(for: paneID) else {
            throw FlouiError.notFound("no active terminal session for pane \(paneID)")
        }

        try await engine.sendInput(sessionID: sessionID, input: input)
    }

    public func resize(paneID: String, cols: Int, rows: Int) async throws {
        guard let sessionID = await manager.sessionID(for: paneID) else {
            throw FlouiError.notFound("no active terminal session for pane \(paneID)")
        }

        try await engine.resize(sessionID: sessionID, cols: cols, rows: rows)
    }

    public func sessionID(for paneID: String) async -> TerminalSessionID? {
        await manager.sessionID(for: paneID)
    }

    public func snapshot(for paneID: String) -> TerminalPaneRuntimeState? {
        statesByPaneID[paneID]
    }

    public func clearOutput(paneID: String) {
        guard var state = statesByPaneID[paneID] else {
            return
        }

        state.outputLines = []
        state.lastMessage = "Scrollback cleared"
        statesByPaneID[paneID] = state
    }

    private func startEventPump(paneID: String, sessionID: TerminalSessionID) {
        eventTasks[paneID]?.cancel()
        eventTasks[paneID] = Task {
            let stream = await self.engine.subscribeEvents(sessionID: sessionID)
            for await event in stream {
                await self.consume(event: event, paneID: paneID)
            }
        }
    }

    private func consume(event: TerminalEvent, paneID: String) async {
        guard var state = statesByPaneID[paneID] else {
            return
        }

        switch event {
        case let .output(text):
            var parser = integrationParsersByPaneID[paneID] ?? TerminalIntegrationParser()
            let parsed = parser.consume(text)
            integrationParsersByPaneID[paneID] = parser

            applyIntegrationEvents(parsed.events, to: &state)
            appendOutput(parsed.visibleLines, to: &state.outputLines)
            if let last = parsed.visibleLines.last ?? state.outputLines.last {
                state.lastMessage = last
            }

        case let .status(message):
            state.lastMessage = message

        case let .processExited(code):
            if var parser = integrationParsersByPaneID.removeValue(forKey: paneID) {
                let trailing = parser.finish()
                applyIntegrationEvents(trailing.events, to: &state)
                appendOutput(trailing.visibleLines, to: &state.outputLines)
            }
            state.isRunning = false
            state.exitCode = code
            state.activeCommand = nil
            state.lastMessage = "Exited (\(code))"
            await manager.clearSession(for: paneID)
        }

        statesByPaneID[paneID] = state
    }

    private func appendOutput(_ newLines: [String], to lines: inout [String]) {
        let normalized = newLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        lines.append(contentsOf: normalized)
        if lines.count > 5_000 {
            lines.removeFirst(lines.count - 5_000)
        }
    }

    private func applyIntegrationEvents(_ events: [TerminalIntegrationEvent], to state: inout TerminalPaneRuntimeState) {
        for event in events {
            switch event {
            case let .currentDirectory(path):
                state.currentDirectory = path

            case let .gitBranch(branch):
                state.gitBranch = branch

            case let .commandStarted(command):
                state.activeCommand = command
                if state.recentCommands.first != command {
                    state.recentCommands.insert(command, at: 0)
                    if state.recentCommands.count > 20 {
                        state.recentCommands.removeLast(state.recentCommands.count - 20)
                    }
                }

            case .promptReady:
                state.activeCommand = nil
            }
        }
    }
}

public struct StatusEventEmitter {
    private let transport: SocketTransport
    private let codec: StatusEventCodec

    public init(transport: SocketTransport, codec: StatusEventCodec = .init()) {
        self.transport = transport
        self.codec = codec
    }

    public func emit(_ event: StatusEvent) async throws {
        let line = try codec.encode(event)
        try await transport.send(line: line)
    }
}
