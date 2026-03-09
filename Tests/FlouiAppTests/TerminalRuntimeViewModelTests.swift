@testable import FlouiApp
import FlouiCore
import Foundation
import Testing
import WorkspaceCore

actor AppMockTerminalEngine: TerminalEngine {
    private(set) var startedConfigs: [TerminalSessionConfig] = []
    private(set) var startedSessionIDs: [TerminalSessionID] = []
    private(set) var attachedSurfaces: [(TerminalSessionID, String)] = []
    private(set) var sentInputs: [(TerminalSessionID, String)] = []
    private var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]
    private var continuations: [TerminalSessionID: AsyncStream<TerminalEvent>.Continuation] = [:]
    private var pendingEvents: [TerminalSessionID: [TerminalEvent]] = [:]

    func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        startedConfigs.append(config)
        let sessionID = TerminalSessionID()
        startedSessionIDs.append(sessionID)
        streams[sessionID] = AsyncStream { continuation in
            continuations[sessionID] = continuation
            if let bufferedEvents = pendingEvents.removeValue(forKey: sessionID) {
                for event in bufferedEvents {
                    continuation.yield(event)
                }
            }
        }
        return sessionID
    }

    func attachView(sessionID: TerminalSessionID, surfaceID: String) async throws {
        attachedSurfaces.append((sessionID, surfaceID))
    }

    func sendInput(sessionID: TerminalSessionID, input: String) async throws {
        sentInputs.append((sessionID, input))
    }
    func resize(sessionID _: TerminalSessionID, cols _: Int, rows _: Int) async throws {}

    func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in
            continuation.finish()
        }
    }

    func emit(sessionID: TerminalSessionID, event: TerminalEvent) {
        if let continuation = continuations[sessionID] {
            continuation.yield(event)
            return
        }

        pendingEvents[sessionID, default: []].append(event)
    }

    func hasSubscriber(sessionID: TerminalSessionID) -> Bool {
        continuations[sessionID] != nil
    }
}

@MainActor
@Test("Quick-run tasks start shell sessions in the configured directory and dispatch repo-scoped commands")
func quickRunTasksUseWorkingDirectoryAwareShellDispatch() async throws {
    let engine = AppMockTerminalEngine()
    let runtime = TerminalRuntimeViewModel(engine: engine)

    let context = DeveloperTerminalTaskContext(
        paneID: "term-1",
        workspaceID: "w1",
        workspaceName: "Workspace",
        terminalTitle: "Web",
        shellCommand: ["/bin/zsh"],
        workingDirectory: "/Users/o'connor/project/app"
    )

    runtime.runTask(
        "pnpm run dev",
        in: context,
        executionDirectory: "/Users/o'connor/project"
    )

    try await Task.sleep(nanoseconds: 125_000_000)

    let started = await engine.startedConfigs
    let inputs = await engine.sentInputs

    #expect(started.count == 1)
    #expect(started.first?.workingDirectory == "/Users/o'connor/project/app")
    #expect(inputs.count == 1)
    #expect(inputs.first?.1 == "cd '/Users/o'\\''connor/project' && pnpm run dev\n")
}

@MainActor
@Test("Restored terminals stay suspended until explicitly started")
func restoredTerminalsRequireExplicitStart() async throws {
    let engine = AppMockTerminalEngine()
    let runtime = TerminalRuntimeViewModel(engine: engine)
    let workspace = WorkspaceManifest(
        id: "w1",
        name: "Workspace",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "c1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "win-1",
                        activeTabID: "term-1",
                        tabs: [
                            WorkspaceTabManifest(id: "term-1", title: "Terminal", type: .terminal, command: ["/bin/zsh"]),
                        ]
                    )
                ]
            )
        ]
    )
    let tab = workspace.columns[0].windows[0].tabs[0]

    runtime.primeRestorePlans([
        WorkspaceRestorePlan(
            workspaceID: "w1",
            panes: [
                RestorePanePlan(
                    paneID: "term-1",
                    type: .terminal,
                    command: ["/usr/bin/env", "bash", "-lc", "echo restored"],
                    autoRun: false
                )
            ]
        )
    ])
    runtime.prepare(workspace: workspace)
    runtime.activate(tab: tab, workspaceID: "w1", surfaceID: "surface-1")

    try await Task.sleep(nanoseconds: 425_000_000)

    let startedBeforeManualStart = await engine.startedConfigs
    #expect(startedBeforeManualStart.isEmpty)
    #expect(runtime.requiresManualStart(paneID: "term-1"))
    #expect(runtime.snapshotsByPaneID["term-1"]?.lastMessage == "Restored. Command not auto-run.")
    #expect(runtime.snapshotsByPaneID["term-1"]?.command == ["/usr/bin/env", "bash", "-lc", "echo restored"])

    runtime.start(tab: tab, workspaceID: "w1", surfaceID: "surface-1")

    try await Task.sleep(nanoseconds: 200_000_000)

    let startedAfterManualStart = await engine.startedConfigs
    let attachedSurfaces = await engine.attachedSurfaces
    #expect(startedAfterManualStart.count == 1)
    #expect(startedAfterManualStart.first?.shellCommand == ["/usr/bin/env", "bash", "-lc", "echo restored"])
    #expect(attachedSurfaces.count == 1)
    #expect(attachedSurfaces.first?.1 == "surface-1")
    #expect(runtime.requiresManualStart(paneID: "term-1") == false)
    #expect(runtime.snapshotsByPaneID["term-1"]?.isRunning == true)
}

@MainActor
@Test("Terminal runtime can interrupt the active command and rerun recent shell history")
func terminalRuntimeSupportsInterruptAndRerun() async throws {
    let engine = AppMockTerminalEngine()
    let runtime = TerminalRuntimeViewModel(engine: engine)
    let tab = WorkspaceTabManifest(
        id: "term-1",
        title: "Terminal",
        type: .terminal,
        command: ["/bin/zsh"],
        workingDirectory: "/repo"
    )

    runtime.start(tab: tab, workspaceID: "w1", surfaceID: "surface-1")
    try await Task.sleep(nanoseconds: 425_000_000)

    let started = await engine.startedConfigs
    let sessionID = try #require(await engine.startedSessionIDs.first)
    #expect(started.count == 1)

    await engine.emit(
        sessionID: sessionID,
        event: .output("__FLOUI__RUN\tpnpm run dev\nserver ready\n__FLOUI__IDLE\n")
    )

    try await Task.sleep(nanoseconds: 75_000_000)

    runtime.interrupt(paneID: "term-1")
    runtime.rerunRecentCommand(paneID: "term-1")

    try await Task.sleep(nanoseconds: 125_000_000)

    let inputs = await engine.sentInputs.map(\.1)
    #expect(inputs.contains("\u{3}"))
    #expect(inputs.contains("pnpm run dev\n"))
    #expect(runtime.snapshotsByPaneID["term-1"]?.recentCommands.first == "pnpm run dev")
}

@MainActor
@Test("Terminal runtime can clear transcript output without losing recent command history")
func terminalRuntimeClearsTranscriptOutput() async throws {
    let engine = AppMockTerminalEngine()
    let runtime = TerminalRuntimeViewModel(engine: engine)
    let tab = WorkspaceTabManifest(
        id: "term-1",
        title: "Terminal",
        type: .terminal,
        command: ["/bin/zsh"],
        workingDirectory: "/repo"
    )

    runtime.start(tab: tab, workspaceID: "w1", surfaceID: "surface-1")
    try await Task.sleep(nanoseconds: 200_000_000)

    let sessionID = try #require(await engine.startedSessionIDs.first)
    for _ in 0..<20 {
        if await engine.hasSubscriber(sessionID: sessionID) {
            break
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(await engine.hasSubscriber(sessionID: sessionID))
    await engine.emit(
        sessionID: sessionID,
        event: .output("__FLOUI__RUN\tpnpm run dev\nbooting\nready\n__FLOUI__IDLE\n")
    )

    try await Task.sleep(nanoseconds: 425_000_000)

    #expect(runtime.snapshotsByPaneID["term-1"] != nil)
    #expect(runtime.snapshotsByPaneID["term-1"]?.isRunning == true)
    #expect(runtime.snapshotsByPaneID["term-1"]?.outputLines == ["booting", "ready"])
    #expect(runtime.snapshotsByPaneID["term-1"]?.recentCommands.first == "pnpm run dev")

    runtime.clearTranscript(paneID: "term-1")

    try await Task.sleep(nanoseconds: 425_000_000)

    #expect(runtime.snapshotsByPaneID["term-1"]?.outputLines.isEmpty == true)
    #expect(runtime.snapshotsByPaneID["term-1"]?.recentCommands.first == "pnpm run dev")
    #expect(runtime.snapshotsByPaneID["term-1"]?.lastMessage == "Scrollback cleared")
}
