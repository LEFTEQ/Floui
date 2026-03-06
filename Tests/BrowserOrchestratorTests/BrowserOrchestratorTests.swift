import BrowserOrchestrator
import FlouiCore
import Foundation
import Testing
import WorkspaceCore

actor RecordingBrowserAdapter: BrowserAdapter {
    let kind: BrowserKind

    var launches: [BrowserLaunchRequest] = []
    var boundsUpdates: [(BrowserWindowID, FlouiRect)] = []
    var openDevToolsCalls: [BrowserTabID] = []

    init(kind: BrowserKind) {
        self.kind = kind
    }

    func launch(_ request: BrowserLaunchRequest) async throws {
        launches.append(request)
    }

    func listWindows() async throws -> [BrowserWindow] {
        [BrowserWindow(id: BrowserWindowID("window-1"), title: "Main", bounds: FlouiRect(x: 0, y: 0, width: 800, height: 600))]
    }

    func setWindowBounds(windowID: BrowserWindowID, bounds: FlouiRect) async throws {
        boundsUpdates.append((windowID, bounds))
    }

    func listTabs(windowID _: BrowserWindowID) async throws -> [BrowserTab] {
        [BrowserTab(id: BrowserTabID("tab-1"), title: "Tab", url: "https://example.com", index: 0)]
    }

    func focusTab(tabID _: BrowserTabID) async throws {}

    func openDevTools(tabID: BrowserTabID) async throws {
        openDevToolsCalls.append(tabID)
    }
}

actor RecordingAppleEventClient: AppleEventClient {
    private var queuedResponses: [String] = []
    private(set) var scripts: [String] = []

    func enqueue(response: String) {
        queuedResponses.append(response)
    }

    func runScript(_ script: String) async throws -> String {
        scripts.append(script)
        if queuedResponses.isEmpty {
            return ""
        }
        return queuedResponses.removeFirst()
    }
}

actor FailingBrowserAdapter: BrowserAdapter {
    let kind: BrowserKind
    let failure: Error

    init(kind: BrowserKind, failure: Error) {
        self.kind = kind
        self.failure = failure
    }

    func launch(_: BrowserLaunchRequest) async throws {
        throw failure
    }

    func listWindows() async throws -> [BrowserWindow] { [] }
    func setWindowBounds(windowID _: BrowserWindowID, bounds _: FlouiRect) async throws {}
    func listTabs(windowID _: BrowserWindowID) async throws -> [BrowserTab] { [] }
    func focusTab(tabID _: BrowserTabID) async throws {}
    func openDevTools(tabID _: BrowserTabID) async throws {}
}

actor RecordingCDPClient: CDPClient {
    var connectedHost: String?
    var connectedPort: Int?
    var sentMethods: [String] = []
    var streamContinuation: AsyncStream<[String: String]>.Continuation?

    func connect(host: String, port: Int) async throws {
        connectedHost = host
        connectedPort = port
    }

    func send(method: String, params _: [String: String]) async throws {
        sentMethods.append(method)
    }

    func events() async -> AsyncStream<[String: String]> {
        AsyncStream { continuation in
            streamContinuation = continuation
        }
    }

    func close() async {
        streamContinuation?.finish()
    }

    func push(event: [String: String]) {
        streamContinuation?.yield(event)
    }

    func finishEvents() {
        streamContinuation?.finish()
    }
}

actor DevToolsEventRecorder {
    private var events: [DevToolsEvent] = []

    func append(_ event: DevToolsEvent) {
        events.append(event)
    }

    func snapshot() -> [DevToolsEvent] {
        events
    }
}

@Test("Browser layout builder extracts browser windows from manifest")
func browserLayoutBuilderFromManifest() {
    let manifest = WorkspaceManifest(
        id: "w1",
        name: "Workspace",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "col-1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "win-1",
                        tabs: [
                            WorkspaceTabManifest(id: "browser-1", title: "Chrome", type: .browser, browser: .chrome, url: "https://a.dev"),
                            WorkspaceTabManifest(id: "term-1", title: "Term", type: .terminal),
                        ]
                    )
                ]
            )
        ],
        browserProfiles: [
            BrowserProfileManifest(browser: .chrome, profileName: "floui-dev", remoteDebuggingPort: 9222)
        ]
    )

    let layout = BrowserLayoutBuilder.fromManifest(manifest, defaultBounds: FlouiRect(x: 10, y: 10, width: 1200, height: 900))

    #expect(layout.workspaceID == "w1")
    #expect(layout.plans.count == 1)
    #expect(layout.plans[0].browser == .chrome)
    #expect(layout.plans[0].profileName == "floui-dev")
    #expect(layout.plans[0].remoteDebuggingPort == 9222)
}

@Test("Browser layout builder falls back to default chromium debugging port")
func browserLayoutBuilderDefaultRemotePort() {
    let manifest = WorkspaceManifest(
        id: "w1",
        name: "Workspace",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "col-1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "win-1",
                        tabs: [
                            WorkspaceTabManifest(id: "browser-1", title: "Brave", type: .browser, browser: .brave, url: "https://a.dev"),
                        ]
                    )
                ]
            )
        ]
    )

    let layout = BrowserLayoutBuilder.fromManifest(manifest, defaultBounds: FlouiRect(x: 10, y: 10, width: 1200, height: 900))
    #expect(layout.plans.count == 1)
    #expect(layout.plans[0].remoteDebuggingPort == 9222)
}

@Test("Orchestrator launches and tiles browser windows")
func orchestratorAppliesPlan() async throws {
    let chrome = RecordingBrowserAdapter(kind: .chrome)
    let safari = RecordingBrowserAdapter(kind: .safari)

    let orchestrator = BrowserWorkspaceOrchestrator(adapters: [.chrome: chrome, .safari: safari])
    let layout = BrowserWorkspaceLayout(
        workspaceID: "w1",
        plans: [
            BrowserWindowPlan(
                browser: .chrome,
                profileName: "floui-dev",
                urls: ["https://example.com"],
                bounds: FlouiRect(x: 0, y: 0, width: 1200, height: 900),
                openDevToolsForFirstTab: true,
                remoteDebuggingPort: 9444
            )
        ]
    )

    try await orchestrator.apply(layout: layout)

    let launches = await chrome.launches
    let boundsUpdates = await chrome.boundsUpdates
    let devToolsCalls = await chrome.openDevToolsCalls

    #expect(launches.count == 1)
    #expect(launches.first?.remoteDebuggingPort == 9444)
    #expect(boundsUpdates.count == 1)
    #expect(devToolsCalls.count == 1)
}

@Test("Orchestrator uses about:blank fallback when no URLs provided")
func orchestratorUsesAboutBlankFallback() async throws {
    let chrome = RecordingBrowserAdapter(kind: .chrome)
    let orchestrator = BrowserWorkspaceOrchestrator(adapters: [.chrome: chrome])
    let layout = BrowserWorkspaceLayout(
        workspaceID: "w1",
        plans: [
            BrowserWindowPlan(
                browser: .chrome,
                profileName: "floui-dev",
                urls: [],
                bounds: FlouiRect(x: 0, y: 0, width: 1200, height: 900),
                openDevToolsForFirstTab: false,
                remoteDebuggingPort: 9222
            )
        ]
    )

    try await orchestrator.apply(layout: layout)
    let launches = await chrome.launches
    #expect(launches.count == 1)
    #expect(launches.first?.urls == ["about:blank"])
}

@Test("Apple event adapter launch does not duplicate first URL")
func appleEventAdapterLaunchScriptAvoidsDuplicateFirstURL() async throws {
    let client = RecordingAppleEventClient()
    let adapter = AppleEventBrowserAdapter(kind: .chrome, appleEvents: client)

    try await adapter.launch(BrowserLaunchRequest(
        profileName: "floui-dev",
        urls: ["https://first.example", "https://second.example"],
        enableRemoteDebugging: true,
        remoteDebuggingPort: 9222
    ))

    let scripts = await client.scripts
    #expect(scripts.count == 1)
    #expect(scripts[0].contains("set URL of active tab of front window to \"https://first.example\""))
    #expect(scripts[0].contains("{\"https://second.example\"}"))
    #expect(scripts[0].contains("{\"https://first.example\", \"https://second.example\"}") == false)
}

@Test("Apple event adapter parses newline responses and targets bounds by window ID")
func appleEventAdapterWindowAndTabParsing() async throws {
    let client = RecordingAppleEventClient()
    let adapter = AppleEventBrowserAdapter(kind: .chrome, appleEvents: client)

    await client.enqueue(response: "w1::Main, Window\nw2::Docs")
    let windows = try await adapter.listWindows()
    #expect(windows.count == 2)
    #expect(windows.first?.title == "Main, Window")
    #expect(windows.last?.id == BrowserWindowID("w2"))

    await client.enqueue(response: "t1::Tab, One::https://one.example\nt2::Tab Two::https://two.example")
    let tabs = try await adapter.listTabs(windowID: BrowserWindowID("w2"))
    #expect(tabs.count == 2)
    #expect(tabs.first?.title == "Tab, One")
    #expect(tabs.first?.url == "https://one.example")

    try await adapter.setWindowBounds(
        windowID: BrowserWindowID("w2"),
        bounds: FlouiRect(x: 10, y: 20, width: 1000, height: 700)
    )

    let scripts = await client.scripts
    #expect(scripts.count == 3)
    #expect(scripts[2].contains("id as string"))
    #expect(scripts[2].contains("\"w2\""))
}

@Test("Orchestrator wraps adapter AppleScript failures with browser context")
func orchestratorWrapsAutomationFailures() async {
    let failing = FailingBrowserAdapter(
        kind: .chrome,
        failure: BrowserAutomationError.appleScriptFailure(code: -1743, message: "Not authorized to send Apple events")
    )
    let orchestrator = BrowserWorkspaceOrchestrator(adapters: [.chrome: failing])
    let layout = BrowserWorkspaceLayout(
        workspaceID: "w1",
        plans: [
            BrowserWindowPlan(
                browser: .chrome,
                profileName: "floui-dev",
                urls: ["https://example.com"],
                bounds: FlouiRect(x: 0, y: 0, width: 1200, height: 900),
                openDevToolsForFirstTab: true,
                remoteDebuggingPort: 9222
            )
        ]
    )

    await #expect(throws: BrowserOrchestrationError(
        browser: .chrome,
        operation: "launch",
        code: -1743,
        message: "Not authorized to send Apple events"
    )) {
        try await orchestrator.apply(layout: layout)
    }
}

@Test("Recovery advisor maps automation denial to actionable permissions steps")
func recoveryAdvisorPermissionMapping() {
    let issue = BrowserRecoveryAdvisor.advise(
        error: BrowserOrchestrationError(
            browser: .brave,
            operation: "launch",
            code: -1743,
            message: "Not authorized to send Apple events"
        )
    )

    #expect(issue.isPermissionIssue)
    #expect(issue.summary.contains("denied Apple Events access"))
    #expect(issue.steps.contains(where: { $0.contains("System Settings") }))
}

@Test("Recovery advisor maps Apple Event timeout to actionable retry steps")
func recoveryAdvisorTimeoutMapping() {
    let issue = BrowserRecoveryAdvisor.advise(
        error: BrowserOrchestrationError(
            browser: .chrome,
            operation: "listWindows",
            code: -1712,
            message: "Apple event timed out"
        )
    )

    #expect(issue.isPermissionIssue == false)
    #expect(issue.summary.contains("did not complete"))
    #expect(issue.steps.contains(where: { $0.contains("responsive") }))
}

@Test("ChromiumDevToolsAdapter sends bootstrap commands")
func chromiumAdapterBootstrap() async throws {
    let client = RecordingCDPClient()
    let adapter = ChromiumDevToolsAdapter(client: client)

    try await adapter.connect(instance: .chrome, port: 9222)
    _ = try await adapter.listTargets()

    let methods = await client.sentMethods
    #expect(methods.contains("Target.setDiscoverTargets"))
    #expect(methods.contains("Target.getTargets"))
}

@Test("ChromiumDevToolsAdapter ingests target lifecycle updates from CDP stream")
func chromiumAdapterIngestsTargetLifecycle() async throws {
    let client = RecordingCDPClient()
    let adapter = ChromiumDevToolsAdapter(client: client)

    try await adapter.connect(instance: .chrome, port: 9222)
    let stream = await adapter.subscribeTargetEvents(targetID: "target-1")

    let recorder = DevToolsEventRecorder()
    let collector = Task {
        for await event in stream {
            await recorder.append(event)
            if case .disconnected = event {
                break
            }
        }
    }

    await client.push(event: [
        "method": "Target.targetCreated",
        "targetId": "target-1",
        "title": "Dev Session",
        "url": "https://example.dev",
    ])

    try? await Task.sleep(nanoseconds: 20_000_000)

    let targetsAfterCreate = try await adapter.listTargets()
    #expect(targetsAfterCreate.contains(where: { $0.id == "target-1" }))

    await client.push(event: [
        "method": "Target.targetDestroyed",
        "targetId": "target-1",
    ])
    await client.finishEvents()

    _ = await collector.result
    let received = await recorder.snapshot()
    let targetsAfterDestroy = try await adapter.listTargets()

    #expect(targetsAfterDestroy.isEmpty)
    #expect(received.contains {
        if case let .targetUpdated(target) = $0 { return target.id == "target-1" } else { return false }
    })
    #expect(received.contains {
        if case .disconnected = $0 { return true } else { return false }
    })
}
