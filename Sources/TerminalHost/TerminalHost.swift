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
    }

    private let runner: ProcessRunner
    private var sessions: [TerminalSessionID: SessionRecord] = [:]
    private var continuations: [TerminalSessionID: AsyncStream<TerminalEvent>.Continuation] = [:]
    private var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]

    public init(runner: ProcessRunner = FoundationProcessRunner()) {
        self.runner = runner
    }

    public func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        guard let executable = config.shellCommand.first else {
            throw FlouiError.invalidInput("shellCommand must include executable")
        }

        let sessionID = TerminalSessionID()

        var continuationBox: AsyncStream<TerminalEvent>.Continuation?
        let stream = AsyncStream<TerminalEvent> { continuation in
            continuationBox = continuation
        }

        guard let continuationBox else {
            throw FlouiError.operationFailed("failed to create stream continuation")
        }

        sessions[sessionID] = SessionRecord(config: config)
        continuations[sessionID] = continuationBox
        streams[sessionID] = stream

        let arguments = Array(config.shellCommand.dropFirst())

        Task {
            do {
                let status = try await self.runner.run(executable, arguments, environment: config.environment)
                self.emit(.processExited(status), for: sessionID)
            } catch {
                self.emit(.status("external-runner-error: \(error.localizedDescription)"), for: sessionID)
                self.emit(.processExited(1), for: sessionID)
            }
        }

        return sessionID
    }

    public func attachView(sessionID: TerminalSessionID, surfaceID _: String) async throws {
        guard sessions[sessionID] != nil else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }
    }

    public func sendInput(sessionID: TerminalSessionID, input _: String) async throws {
        guard sessions[sessionID] != nil else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        emit(.status("input-ignored-external-engine"), for: sessionID)
    }

    public func resize(sessionID: TerminalSessionID, cols _: Int, rows _: Int) async throws {
        guard sessions[sessionID] != nil else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }
    }

    public func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in
            continuation.yield(.status("session-not-found"))
            continuation.finish()
        }
    }

    private func emit(_ event: TerminalEvent, for sessionID: TerminalSessionID) {
        guard let continuation = continuations[sessionID] else {
            return
        }

        continuation.yield(event)

        if case .processExited = event {
            continuation.finish()
            continuations.removeValue(forKey: sessionID)
            streams.removeValue(forKey: sessionID)
            sessions.removeValue(forKey: sessionID)
        }
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
                self.consume(event: event, paneID: paneID)
            }
        }
    }

    private func consume(event: TerminalEvent, paneID: String) {
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
