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

actor ImmediateProcessRunner: ProcessRunner {
    let status: Int32

    init(status: Int32) {
        self.status = status
    }

    func run(_: String, _: [String], environment _: [String: String]) async throws -> Int32 {
        status
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

@Test("ExternalTerminalEngine emits exit event")
func externalEngineExitEvent() async throws {
    let runner = ImmediateProcessRunner(status: 0)
    let engine = ExternalTerminalEngine(runner: runner)

    let sessionID = try await engine.startSession(config: TerminalSessionConfig(
        workspaceID: "w1",
        paneID: "p1",
        shellCommand: ["/usr/bin/env", "echo", "hello"]
    ))

    var received: [TerminalEvent] = []
    for await event in await engine.subscribeEvents(sessionID: sessionID) {
        received.append(event)
    }

    #expect(received.contains { if case let .processExited(code) = $0 { return code == 0 } else { return false } })
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
