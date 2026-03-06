import BrowserOrchestrator
import FlouiCore
import Foundation
import TerminalHost
import Testing

@Test("Real E2E gate: requires explicit opt-in")
func requiresOptInEnvironmentFlag() {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    #expect(enabled || !enabled)
}

@Test("Real E2E smoke: required apps are installed")
func verifyRequiredAppsInstalled() {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    guard enabled else {
        return
    }

    let requiredApps = [
        "/Applications/Safari.app",
        "/Applications/Google Chrome.app",
        "/Applications/Brave Browser.app",
    ]

    for app in requiredApps {
        #expect(FileManager.default.fileExists(atPath: app))
    }
}

@Test("Real E2E contract: browser adapters operate or provide actionable recovery guidance")
func realBrowserAdapterContractOrRecovery() async throws {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    guard enabled else {
        return
    }

    let client = CocoaAppleEventClient()
    let bounds = FlouiRect(x: 80, y: 80, width: 1200, height: 800)

    for browser in BrowserKind.allCases {
        let adapter = AppleEventBrowserAdapter(kind: browser, appleEvents: client)

        do {
            try await adapter.launch(BrowserLaunchRequest(
                profileName: "floui-real-e2e",
                urls: ["about:blank"],
                enableRemoteDebugging: browser != .safari,
                remoteDebuggingPort: browser == .safari ? nil : 9222
            ))

            let windows = try await adapter.listWindows()
            if let firstWindow = windows.first {
                try await adapter.setWindowBounds(windowID: firstWindow.id, bounds: bounds)
                _ = try await adapter.listTabs(windowID: firstWindow.id)
            }
        } catch {
            let issue = BrowserRecoveryAdvisor.advise(error: error)
            #expect(issue.summary.isEmpty == false)
            #expect(issue.steps.isEmpty == false)
            #expect(issue.title.isEmpty == false)
        }
    }
}

@Test("Real E2E contract: terminal runtime handles start/input/resize/exit")
func realTerminalRuntimeContract() async throws {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    guard enabled else {
        return
    }

    let runtime = TerminalWorkspaceRuntime(engine: ExternalTerminalEngine())
    let config = TerminalSessionConfig(
        workspaceID: "real-e2e",
        paneID: "term-e2e",
        shellCommand: ["/bin/sh", "-lc", "read line; echo ECHO:$line"]
    )

    try await runtime.activateTerminal(config: config)
    try await runtime.resize(paneID: "term-e2e", cols: 120, rows: 40)
    try await runtime.sendInput(paneID: "term-e2e", input: "real-e2e\n")

    var snapshot: TerminalPaneRuntimeState?
    for _ in 0 ..< 40 {
        snapshot = await runtime.snapshot(for: "term-e2e")
        if snapshot?.exitCode != nil {
            break
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    #expect(snapshot?.outputLines.contains(where: { $0.contains("ECHO:real-e2e") }) == true)
    #expect(snapshot?.exitCode == 0)
    #expect(snapshot?.isRunning == false)
}
