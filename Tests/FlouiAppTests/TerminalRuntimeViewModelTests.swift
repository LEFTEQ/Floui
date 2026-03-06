@testable import FlouiApp
import FlouiCore
import Foundation
import Testing
import WorkspaceCore

actor AppMockTerminalEngine: TerminalEngine {
    private(set) var startedConfigs: [TerminalSessionConfig] = []
    private(set) var attachedSurfaces: [(TerminalSessionID, String)] = []
    private var streams: [TerminalSessionID: AsyncStream<TerminalEvent>] = [:]

    func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        startedConfigs.append(config)
        let sessionID = TerminalSessionID()
        streams[sessionID] = AsyncStream { continuation in
            continuation.finish()
        }
        return sessionID
    }

    func attachView(sessionID: TerminalSessionID, surfaceID: String) async throws {
        attachedSurfaces.append((sessionID, surfaceID))
    }

    func sendInput(sessionID _: TerminalSessionID, input _: String) async throws {}
    func resize(sessionID _: TerminalSessionID, cols _: Int, rows _: Int) async throws {}

    func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        streams[sessionID] ?? AsyncStream { continuation in
            continuation.finish()
        }
    }
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

    try await Task.sleep(nanoseconds: 75_000_000)

    let startedBeforeManualStart = await engine.startedConfigs
    #expect(startedBeforeManualStart.isEmpty)
    #expect(runtime.requiresManualStart(paneID: "term-1"))
    #expect(runtime.snapshotsByPaneID["term-1"]?.lastMessage == "Restored. Command not auto-run.")
    #expect(runtime.snapshotsByPaneID["term-1"]?.command == ["/usr/bin/env", "bash", "-lc", "echo restored"])

    runtime.start(tab: tab, workspaceID: "w1", surfaceID: "surface-1")

    try await Task.sleep(nanoseconds: 75_000_000)

    let startedAfterManualStart = await engine.startedConfigs
    let attachedSurfaces = await engine.attachedSurfaces
    #expect(startedAfterManualStart.count == 1)
    #expect(startedAfterManualStart.first?.shellCommand == ["/usr/bin/env", "bash", "-lc", "echo restored"])
    #expect(attachedSurfaces.count == 1)
    #expect(attachedSurfaces.first?.1 == "surface-1")
    #expect(runtime.requiresManualStart(paneID: "term-1") == false)
    #expect(runtime.snapshotsByPaneID["term-1"]?.isRunning == true)
}
