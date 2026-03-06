import FlouiCore
import Foundation
import TerminalHost
import Testing

actor RecordingSurfaceBridge: TerminalSurfaceBridge {
    var startedConfigs: [TerminalSessionConfig] = []
    var attached: [(TerminalSessionID, String)] = []
    var inputs: [(TerminalSessionID, String)] = []
    var resized: [(TerminalSessionID, Int, Int)] = []
    var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]

    func start(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        startedConfigs.append(config)
        let id = TerminalSessionID()
        let stream = AsyncStream<TerminalEvent> { continuation in
            continuation.yield(.status("started"))
            continuation.finish()
        }
        streams[id] = stream
        return id
    }

    func attach(sessionID: TerminalSessionID, surfaceID: String) async throws {
        attached.append((sessionID, surfaceID))
    }

    func input(sessionID: TerminalSessionID, text: String) async throws {
        inputs.append((sessionID, text))
    }

    func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        resized.append((sessionID, cols, rows))
    }

    func events(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in continuation.finish() }
    }
}

actor RuntimeMockTerminalEngine: TerminalEngine {
    var startedConfigs: [TerminalSessionConfig] = []
    var sentInputs: [(TerminalSessionID, String)] = []
    var resizedSessions: [(TerminalSessionID, Int, Int)] = []
    var continuations: [TerminalSessionID: AsyncStream<TerminalEvent>.Continuation] = [:]
    var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]

    func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        startedConfigs.append(config)
        let id = TerminalSessionID()
        var continuationBox: AsyncStream<TerminalEvent>.Continuation?
        let stream = AsyncStream<TerminalEvent> { continuation in
            continuationBox = continuation
        }
        streams[id] = stream
        continuations[id] = continuationBox
        return id
    }

    func attachView(sessionID _: TerminalSessionID, surfaceID _: String) async throws {}

    func sendInput(sessionID: TerminalSessionID, input: String) async throws {
        sentInputs.append((sessionID, input))
    }

    func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        resizedSessions.append((sessionID, cols, rows))
    }

    func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in continuation.finish() }
    }

    func emit(sessionID: TerminalSessionID, event: TerminalEvent) {
        continuations[sessionID]?.yield(event)
    }
}

actor FailingStartTerminalEngine: TerminalEngine {
    private(set) var startCalls = 0

    func startSession(config _: TerminalSessionConfig) async throws -> TerminalSessionID {
        startCalls += 1
        throw FlouiError.unsupported("libghostty not available")
    }

    func attachView(sessionID _: TerminalSessionID, surfaceID _: String) async throws {}
    func sendInput(sessionID _: TerminalSessionID, input _: String) async throws {}
    func resize(sessionID _: TerminalSessionID, cols _: Int, rows _: Int) async throws {}

    func subscribeEvents(sessionID _: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        AsyncStream { continuation in continuation.finish() }
    }
}

actor MockGhosttyProvider: GhosttyFunctionProviding {
    private(set) var startCalls: [(String, TerminalSessionConfig)] = []
    private(set) var attachCalls: [(String, String)] = []
    private(set) var inputCalls: [(String, String)] = []
    private(set) var resizeCalls: [(String, Int32, Int32)] = []

    var startReturnCode: Int32 = 0
    var attachReturnCode: Int32 = 0
    var inputReturnCode: Int32 = 0
    var resizeReturnCode: Int32 = 0

    func loadFunctions() async throws -> GhosttyRuntimeFunctions {
        GhosttyRuntimeFunctions(
            startSession: { [self] sessionID, config in
                await self.recordStart(sessionID: sessionID, config: config)
                return await self.startReturnCode
            },
            attachSurface: { [self] sessionID, surfaceID in
                await self.recordAttach(sessionID: sessionID, surfaceID: surfaceID)
                return await self.attachReturnCode
            },
            sendInput: { [self] sessionID, input in
                await self.recordInput(sessionID: sessionID, input: input)
                return await self.inputReturnCode
            },
            resize: { [self] sessionID, cols, rows in
                await self.recordResize(sessionID: sessionID, cols: cols, rows: rows)
                return await self.resizeReturnCode
            }
        )
    }

    private func recordStart(sessionID: String, config: TerminalSessionConfig) {
        startCalls.append((sessionID, config))
    }

    private func recordAttach(sessionID: String, surfaceID: String) {
        attachCalls.append((sessionID, surfaceID))
    }

    private func recordInput(sessionID: String, input: String) {
        inputCalls.append((sessionID, input))
    }

    private func recordResize(sessionID: String, cols: Int32, rows: Int32) {
        resizeCalls.append((sessionID, cols, rows))
    }
}

actor FailingGhosttyProvider: GhosttyFunctionProviding {
    func loadFunctions() async throws -> GhosttyRuntimeFunctions {
        throw FlouiError.unsupported("libghostty not available")
    }
}

@Test("GhosttyTerminalEngine delegates to surface bridge")
func ghosttyEngineDelegation() async throws {
    let bridge = RecordingSurfaceBridge()
    let engine = GhosttyTerminalEngine(bridge: bridge)

    let sessionID = try await engine.startSession(config: TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "p1",
        shellCommand: ["/bin/zsh"]
    ))

    try await engine.attachView(sessionID: sessionID, surfaceID: "surface-1")
    try await engine.sendInput(sessionID: sessionID, input: "ls\n")
    try await engine.resize(sessionID: sessionID, cols: 120, rows: 30)

    let attached = await bridge.attached
    let inputs = await bridge.inputs
    let resized = await bridge.resized

    #expect(attached.count == 1)
    #expect(inputs.first?.1 == "ls\n")
    #expect(resized.first?.1 == 120)
}

@Test("TerminalSessionManager throws for unknown pane")
func sessionManagerUnknownPane() async {
    let bridge = RecordingSurfaceBridge()
    let manager = TerminalSessionManager(engine: GhosttyTerminalEngine(bridge: bridge))

    await #expect(throws: FlouiError.notFound("no active terminal session for pane p-missing")) {
        try await manager.attachView(paneID: "p-missing", surfaceID: "surface")
    }
}

@Test("ExternalTerminalEngine supports interactive input, output and exit propagation")
func externalEngineInteractiveFlow() async throws {
    let runtime = TerminalWorkspaceRuntime(engine: ExternalTerminalEngine())
    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "p1",
        shellCommand: ["/bin/sh", "-lc", "read line; echo ECHO:$line"]
    )

    try await runtime.activateTerminal(config: config)
    try await runtime.resize(paneID: "p1", cols: 120, rows: 32)
    try await runtime.sendInput(paneID: "p1", input: "hello\n")

    var snapshot: TerminalPaneRuntimeState?
    for _ in 0 ..< 40 {
        snapshot = await runtime.snapshot(for: "p1")
        if snapshot?.exitCode != nil {
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    #expect(snapshot?.outputLines.contains(where: { $0.contains("ECHO:hello") }) == true)
    #expect(snapshot?.exitCode == 0)
    #expect(snapshot?.isRunning == false)
}

@Test("GhosttyRuntimeBridge calls loaded runtime functions")
func ghosttyRuntimeBridgeDelegatesToRuntimeFunctions() async throws {
    let provider = MockGhosttyProvider()
    let bridge = GhosttyRuntimeBridge(provider: provider)

    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "pane-1",
        shellCommand: ["/bin/zsh"]
    )

    let sessionID = try await bridge.start(config: config)
    try await bridge.attach(sessionID: sessionID, surfaceID: "surface-1")
    try await bridge.input(sessionID: sessionID, text: "ls\n")
    try await bridge.resize(sessionID: sessionID, cols: 100, rows: 30)

    let startCalls = await provider.startCalls
    let attachCalls = await provider.attachCalls
    let inputCalls = await provider.inputCalls
    let resizeCalls = await provider.resizeCalls

    #expect(startCalls.count == 1)
    #expect(startCalls.first?.1 == config)
    #expect(attachCalls.first?.1 == "surface-1")
    #expect(inputCalls.first?.1 == "ls\n")
    #expect(resizeCalls.first?.1 == 100)
    #expect(resizeCalls.first?.2 == 30)

    var events: [TerminalEvent] = []
    for await event in await bridge.events(sessionID: sessionID) {
        events.append(event)
        if events.count >= 4 {
            break
        }
    }

    #expect(events.contains { if case .status("ghostty-session-started") = $0 { return true } else { return false } })
}

@Test("GhosttyRuntimeBridge surfaces provider loading errors")
func ghosttyRuntimeBridgePropagatesProviderFailure() async {
    let bridge = GhosttyRuntimeBridge(provider: FailingGhosttyProvider())

    await #expect(throws: FlouiError.unsupported("libghostty not available")) {
        _ = try await bridge.start(config: TerminalSessionConfig(
            workspaceID: "w1",
            paneID: "pane-1",
            shellCommand: ["/bin/zsh"]
        ))
    }
}

@Test("TerminalWorkspaceRuntime starts once and tracks terminal events")
func terminalWorkspaceRuntimeLifecycle() async throws {
    let engine = RuntimeMockTerminalEngine()
    let runtime = TerminalWorkspaceRuntime(engine: engine)

    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "term-1",
        shellCommand: ["/bin/zsh"]
    )

    try await runtime.activateTerminal(config: config)
    try await runtime.activateTerminal(config: config)

    let started = await engine.startedConfigs
    #expect(started.count == 1)

    guard let sessionID = await runtime.sessionID(for: "term-1") else {
        Issue.record("missing session id")
        return
    }

    await engine.emit(sessionID: sessionID, event: .status("booted"))
    await engine.emit(sessionID: sessionID, event: .processExited(0))
    try? await Task.sleep(nanoseconds: 30_000_000)

    let snapshot = await runtime.snapshot(for: "term-1")
    #expect(snapshot?.isRunning == false)
    #expect(snapshot?.lastMessage == "Exited (0)")
    #expect(snapshot?.exitCode == 0)
}

@Test("TerminalWorkspaceRuntime can restart a pane after process exit")
func terminalWorkspaceRuntimeRestartAfterExit() async throws {
    let engine = RuntimeMockTerminalEngine()
    let runtime = TerminalWorkspaceRuntime(engine: engine)
    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "term-1",
        shellCommand: ["/bin/zsh"]
    )

    try await runtime.activateTerminal(config: config)

    guard let firstSessionID = await runtime.sessionID(for: "term-1") else {
        Issue.record("missing initial session id")
        return
    }

    await engine.emit(sessionID: firstSessionID, event: .processExited(0))
    try? await Task.sleep(nanoseconds: 30_000_000)

    try await runtime.activateTerminal(config: config)

    let started = await engine.startedConfigs
    let secondSessionID = await runtime.sessionID(for: "term-1")

    #expect(started.count == 2)
    #expect(secondSessionID != nil)
    #expect(secondSessionID != firstSessionID)
}

@Test("TerminalWorkspaceRuntime forwards input and errors for missing panes")
func terminalWorkspaceRuntimeInputForwarding() async throws {
    let engine = RuntimeMockTerminalEngine()
    let runtime = TerminalWorkspaceRuntime(engine: engine)

    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "term-1",
        shellCommand: ["/bin/zsh"]
    )

    try await runtime.activateTerminal(config: config)
    try await runtime.sendInput(paneID: "term-1", input: "echo hello\n")
    let sent = await engine.sentInputs
    #expect(sent.count == 1)
    #expect(sent.first?.1 == "echo hello\n")

    do {
        try await runtime.sendInput(paneID: "missing", input: "x")
        Issue.record("Expected missing pane to throw")
    } catch let error as FlouiError {
        #expect(error == FlouiError.notFound("no active terminal session for pane missing"))
    }
}

@Test("TerminalWorkspaceRuntime forwards resize and errors for missing panes")
func terminalWorkspaceRuntimeResizeForwarding() async throws {
    let engine = RuntimeMockTerminalEngine()
    let runtime = TerminalWorkspaceRuntime(engine: engine)

    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "term-1",
        shellCommand: ["/bin/zsh"]
    )

    try await runtime.activateTerminal(config: config)
    try await runtime.resize(paneID: "term-1", cols: 140, rows: 42)
    let resized = await engine.resizedSessions
    #expect(resized.count == 1)
    #expect(resized.first?.1 == 140)
    #expect(resized.first?.2 == 42)

    do {
        try await runtime.resize(paneID: "missing", cols: 80, rows: 24)
        Issue.record("Expected missing pane to throw")
    } catch let error as FlouiError {
        #expect(error == FlouiError.notFound("no active terminal session for pane missing"))
    }
}

@Test("GhosttyFirstTerminalEngine falls back to external engine when ghostty is unavailable")
func ghosttyFirstEngineFallback() async throws {
    let primary = FailingStartTerminalEngine()
    let fallback = RuntimeMockTerminalEngine()
    let engine = GhosttyFirstTerminalEngine(primary: primary, fallback: fallback)
    let config = TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "term-1",
        shellCommand: ["/bin/zsh"]
    )

    let sessionID = try await engine.startSession(config: config)
    try await engine.attachView(sessionID: sessionID, surfaceID: "surface-1")
    try await engine.sendInput(sessionID: sessionID, input: "echo hi\n")
    try await engine.resize(sessionID: sessionID, cols: 90, rows: 20)

    let primaryStartCalls = await primary.startCalls
    let fallbackStarts = await fallback.startedConfigs
    let fallbackInputs = await fallback.sentInputs
    let fallbackResizes = await fallback.resizedSessions
    #expect(primaryStartCalls == 1)
    #expect(fallbackStarts.count == 1)
    #expect(fallbackInputs.first?.1 == "echo hi\n")
    #expect(fallbackResizes.first?.1 == 90)
    #expect(fallbackResizes.first?.2 == 20)
}
