import BrowserOrchestrator
import FlouiCore
import Foundation
import Permissions
import StatusPills
import TerminalHost
import Testing
import WorkspaceCore

actor HybridBrowserAdapter: BrowserAdapter {
    let kind: BrowserKind
    var launches: [BrowserLaunchRequest] = []

    init(kind: BrowserKind) {
        self.kind = kind
    }

    func launch(_ request: BrowserLaunchRequest) async throws { launches.append(request) }
    func listWindows() async throws -> [BrowserWindow] {
        [BrowserWindow(id: BrowserWindowID("w"), title: "mock", bounds: FlouiRect(x: 0, y: 0, width: 1, height: 1))]
    }

    func setWindowBounds(windowID _: BrowserWindowID, bounds _: FlouiRect) async throws {}
    func listTabs(windowID _: BrowserWindowID) async throws -> [BrowserTab] {
        [BrowserTab(id: BrowserTabID("t"), title: "tab", url: "https://example.com", index: 0)]
    }

    func focusTab(tabID _: BrowserTabID) async throws {}
    func openDevTools(tabID _: BrowserTabID) async throws {}
}

@Test("Hybrid flow: parse -> restore -> browser orchestration -> status pills")
func hybridEndToEndFlow() async throws {
    let yaml = """
    id: default
    name: Default
    version: 1
    columns:
      - id: c1
        windows:
          - id: w1
            activeTabID: browser-1
            tabs:
              - id: browser-1
                title: Chrome
                type: browser
                browser: chrome
                url: https://example.com
              - id: term-1
                title: Terminal
                type: terminal
                command: ["/bin/zsh"]
    fixedPills:
      - id: pill-1
        title: Claude
        source: claude-code
    shortcuts: []
    browserProfiles:
      - browser: chrome
        profileName: floui-dev
        remoteDebuggingPort: 9222
    """

    let parser = WorkspaceManifestParser()
    let manifest = try parser.parse(yaml: yaml)

    let restore = WorkspaceRestorePlanner().makePlan(manifest: manifest, metadata: LastSessionMetadata())
    #expect(restore.panes.allSatisfy { !$0.autoRun })

    let adapter = HybridBrowserAdapter(kind: .chrome)
    let orchestrator = BrowserWorkspaceOrchestrator(adapters: [.chrome: adapter])
    let layout = BrowserLayoutBuilder.fromManifest(manifest, defaultBounds: FlouiRect(x: 0, y: 0, width: 1200, height: 900))

    try await orchestrator.apply(layout: layout)
    let launches = await adapter.launches
    #expect(launches.count == 1)

    var store = StatusPillStore()
    store.apply(StatusEvent(
        event: .taskStarted,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: Date(),
        message: "running"
    ))

    #expect(store.pillsByPaneID["pill-1"]?.isRunning == true)
}

actor HybridDevToolsAdapter: DevToolsAdapter {
    private var continuations: [String: AsyncStream<DevToolsEvent>.Continuation] = [:]

    func connect(instance _: BrowserKind, port _: Int) async throws {}

    func listTargets() async throws -> [DevToolsTarget] {
        []
    }

    func subscribeTargetEvents(targetID: String) async -> AsyncStream<DevToolsEvent> {
        AsyncStream { continuation in
            continuations[targetID] = continuation
        }
    }

    func close() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func emit(targetID: String, event: DevToolsEvent) {
        continuations[targetID]?.yield(event)
    }

    func finish(targetID: String) {
        continuations[targetID]?.finish()
    }
}

actor HybridPermissionChecker: PermissionChecking {
    func check(kind: PermissionKind) async -> PermissionSnapshot {
        PermissionSnapshot(kind: kind, status: .granted, detail: "ok", checkedAt: Date())
    }

    func request(kind: PermissionKind) async -> PermissionSnapshot {
        PermissionSnapshot(kind: kind, status: .granted, detail: "ok", checkedAt: Date())
    }

    func checkAll() async -> PermissionHealth {
        PermissionHealth(snapshots: PermissionKind.requiredForWorkspaceControl.map { kind in
            PermissionSnapshot(kind: kind, status: .granted, detail: "ok", checkedAt: Date())
        })
    }

    func requestAll() async -> PermissionHealth {
        await checkAll()
    }
}

actor HybridRecordingCDPClient: CDPClient {
    var connectedHost: String?
    var connectedPort: Int?
    var sentMethods: [String] = []
    var continuation: AsyncStream<[String: String]>.Continuation?

    func connect(host: String, port: Int) async throws {
        connectedHost = host
        connectedPort = port
    }

    func send(method: String, params _: [String: String]) async throws {
        sentMethods.append(method)
    }

    func events() async -> AsyncStream<[String: String]> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func close() async {
        continuation?.finish()
    }

    func push(event: [String: String]) {
        continuation?.yield(event)
    }

    func finish() {
        continuation?.finish()
    }
}

@Test("Hybrid flow: permissions health + CDP target updates drive fixed pills")
func hybridPermissionsAndCDPFlow() async throws {
    let permissionController = PermissionOnboardingController(checker: HybridPermissionChecker())
    let permissionState = await permissionController.refresh()
    #expect(permissionState.isComplete)

    let adapter = HybridDevToolsAdapter()
    let coordinator = DevToolsPillCoordinator(adapter: adapter)
    let binding = DevToolsPillBinding(
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "cdp:tab-1",
        targetID: "tab-1",
        source: "chrome-devtools"
    )

    await coordinator.bind(binding: binding)
    await adapter.emit(targetID: "tab-1", event: .connected)
    await adapter.emit(targetID: "tab-1", event: .targetUpdated(DevToolsTarget(id: "tab-1", title: "Devtools", url: "https://example.com")))
    await adapter.emit(targetID: "tab-1", event: .disconnected)
    await adapter.finish(targetID: "tab-1")

    try? await Task.sleep(nanoseconds: 30_000_000)

    let store = await coordinator.storeSnapshot()
    #expect(store.pillsByPaneID["pill-1"]?.severity == .warning)
    #expect(store.pillsByPaneID["pill-1"]?.unreadAlerts == 1)
}

@Test("Hybrid flow: Chromium adapter event ingestion updates pill coordinator state")
func hybridChromiumAdapterToPillFlow() async throws {
    let cdpClient = HybridRecordingCDPClient()
    let adapter = ChromiumDevToolsAdapter(client: cdpClient)
    let coordinator = DevToolsPillCoordinator(adapter: adapter)

    try await adapter.connect(instance: .chrome, port: 9222)

    let binding = DevToolsPillBinding(
        workspaceID: "default",
        paneID: "pill-cdp",
        taskID: "cdp:target-42",
        targetID: "target-42",
        source: "chrome-devtools"
    )

    await coordinator.bind(binding: binding)

    await cdpClient.push(event: [
        "method": "Target.targetCreated",
        "targetId": "target-42",
        "title": "Build",
        "url": "https://localhost:3000",
    ])
    await cdpClient.push(event: [
        "method": "Target.targetDestroyed",
        "targetId": "target-42",
    ])
    await cdpClient.finish()

    try? await Task.sleep(nanoseconds: 40_000_000)

    let store = await coordinator.storeSnapshot()
    #expect(store.pillsByPaneID["pill-cdp"]?.unreadAlerts == 1)
    #expect(store.pillsByPaneID["pill-cdp"]?.severity == .warning)
}
