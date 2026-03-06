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

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { await self?.emitOutput(data, for: sessionID) }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            Task { await self?.emitOutput(data, for: sessionID) }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { await self?.handleProcessTermination(sessionID: sessionID, status: terminatedProcess.terminationStatus) }
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

    private func emitOutput(_ data: Data, for sessionID: TerminalSessionID) {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            emit(.output(text), for: sessionID)
            return
        }

        let decoded = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        if !decoded.isEmpty {
            emit(.status("external-output-bytes: \(decoded)"), for: sessionID)
        }
    }

    private func handleProcessTermination(sessionID: TerminalSessionID, status: Int32) {
        guard let session = sessions[sessionID] else {
            return
        }

        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil

        let remainingStdout = session.stdout.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            emitOutput(remainingStdout, for: sessionID)
        }

        let remainingStderr = session.stderr.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            emitOutput(remainingStderr, for: sessionID)
        }

        emit(.processExited(status), for: sessionID)
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
    public var isRunning: Bool
    public var lastMessage: String
    public var outputLines: [String]
    public var exitCode: Int32?

    public init(
        paneID: String,
        workspaceID: String,
        command: [String],
        isRunning: Bool,
        lastMessage: String,
        outputLines: [String] = [],
        exitCode: Int32? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.command = command
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
            isRunning: true,
            lastMessage: "Session started"
        )
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
            appendOutput(text, to: &state.outputLines)
            if let last = state.outputLines.last {
                state.lastMessage = last
            }

        case let .status(message):
            state.lastMessage = message

        case let .processExited(code):
            state.isRunning = false
            state.exitCode = code
            state.lastMessage = "Exited (\(code))"
            await manager.clearSession(for: paneID)
        }

        statesByPaneID[paneID] = state
    }

    private func appendOutput(_ text: String, to lines: inout [String]) {
        let normalized = text
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        lines.append(contentsOf: normalized)
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
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
