@testable import FlouiApp
import Foundation
import FlouiCore
import Permissions
import Testing
import WorkspaceCore

@MainActor
private final class MockTerminalWorkspaceCoordinator: TerminalWorkspaceCoordinating {
    private(set) var primedPlans: [[WorkspaceRestorePlan]] = []
    private(set) var preparedWorkspaceIDs: [String] = []

    func primeRestorePlans(_ plans: [WorkspaceRestorePlan]) {
        primedPlans.append(plans)
    }

    func prepare(workspace: WorkspaceManifest) {
        preparedWorkspaceIDs.append(workspace.id)
    }
}

@MainActor
private final class MockBrowserWorkspaceCoordinator: BrowserWorkspaceCoordinating {
    private(set) var applied: [(workspaceID: String, force: Bool)] = []

    func apply(workspace: WorkspaceManifest, force: Bool) {
        applied.append((workspace.id, force))
    }
}

@MainActor
@Test("Workspace coordinator primes restore plans once and prepares the active workspace")
func workspaceCoordinatorPrimesRestorePlansOnce() {
    let terminal = MockTerminalWorkspaceCoordinator()
    let browser = MockBrowserWorkspaceCoordinator()
    let coordinator = WorkspaceAutomationCoordinator(
        terminalRuntime: terminal,
        browserAutomation: browser
    )
    let workspace = makeWorkspaceManifest(id: "default")
    var layoutState = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &layoutState, action: .loadManifest(workspace))

    coordinator.sync(
        layoutState: layoutState,
        lastSessionMetadata: LastSessionMetadata(paneCommands: ["term-1": ["/usr/bin/env", "echo", "restore"]]),
        permissionState: permissionState(automationStatus: .granted),
        restoredSession: true
    )
    coordinator.sync(
        layoutState: layoutState,
        lastSessionMetadata: LastSessionMetadata(paneCommands: ["term-1": ["/usr/bin/env", "echo", "restore"]]),
        permissionState: permissionState(automationStatus: .granted),
        restoredSession: true
    )

    #expect(terminal.primedPlans.count == 1)
    #expect(terminal.primedPlans.first?.first?.workspaceID == "default")
    #expect(terminal.primedPlans.first?.first?.panes.first(where: { $0.paneID == "term-1" })?.command == ["/usr/bin/env", "echo", "restore"])
    #expect(terminal.preparedWorkspaceIDs == ["default", "default"])
    #expect(browser.applied.count == 2)
    #expect(browser.applied.allSatisfy { $0.workspaceID == "default" && $0.force == false })
}

@MainActor
@Test("Workspace coordinator suppresses automatic browser apply when automation is denied")
func workspaceCoordinatorSuppressesDeniedBrowserAutomation() {
    let terminal = MockTerminalWorkspaceCoordinator()
    let browser = MockBrowserWorkspaceCoordinator()
    let coordinator = WorkspaceAutomationCoordinator(
        terminalRuntime: terminal,
        browserAutomation: browser
    )
    let workspace = makeWorkspaceManifest(id: "default")
    var layoutState = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &layoutState, action: .loadManifest(workspace))

    coordinator.sync(
        layoutState: layoutState,
        lastSessionMetadata: LastSessionMetadata(),
        permissionState: permissionState(automationStatus: .denied),
        restoredSession: false
    )

    #expect(terminal.preparedWorkspaceIDs == ["default"])
    #expect(browser.applied.isEmpty)
}

@MainActor
@Test("Workspace coordinator ignores denied automation for browsers not present in the workspace")
func workspaceCoordinatorScopesPermissionChecksToUsedBrowsers() {
    let terminal = MockTerminalWorkspaceCoordinator()
    let browser = MockBrowserWorkspaceCoordinator()
    let coordinator = WorkspaceAutomationCoordinator(
        terminalRuntime: terminal,
        browserAutomation: browser
    )
    let workspace = makeWorkspaceManifest(id: "default", browser: .chrome)
    var layoutState = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &layoutState, action: .loadManifest(workspace))

    coordinator.sync(
        layoutState: layoutState,
        lastSessionMetadata: LastSessionMetadata(),
        permissionState: permissionState(statuses: [
            .automationSafari: .denied,
            .automationChrome: .granted,
            .automationBrave: .denied,
        ]),
        restoredSession: false
    )

    #expect(browser.applied.count == 1)
    #expect(browser.applied.first?.workspaceID == "default")
    #expect(browser.applied.first?.force == false)
}

@MainActor
@Test("Workspace coordinator force apply bypasses automatic browser permission gating")
func workspaceCoordinatorForceAppliesBrowserLayout() {
    let terminal = MockTerminalWorkspaceCoordinator()
    let browser = MockBrowserWorkspaceCoordinator()
    let coordinator = WorkspaceAutomationCoordinator(
        terminalRuntime: terminal,
        browserAutomation: browser
    )
    let workspace = makeWorkspaceManifest(id: "default")
    var layoutState = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &layoutState, action: .loadManifest(workspace))

    coordinator.sync(
        layoutState: layoutState,
        lastSessionMetadata: LastSessionMetadata(),
        permissionState: permissionState(automationStatus: .denied),
        restoredSession: false,
        forceBrowserApply: true
    )

    #expect(browser.applied.count == 1)
    #expect(browser.applied.first?.workspaceID == "default")
    #expect(browser.applied.first?.force == true)
}

private func makeWorkspaceManifest(id: String, browser: BrowserKind = .chrome) -> WorkspaceManifest {
    WorkspaceManifest(
        id: id,
        name: "Workspace \(id)",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "col-1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "win-1",
                        activeTabID: "term-1",
                        tabs: [
                            WorkspaceTabManifest(id: "term-1", title: "Terminal", type: .terminal, command: ["/bin/zsh"]),
                            WorkspaceTabManifest(id: "browser-1", title: "Browser", type: .browser, browser: browser, url: "https://example.com"),
                        ]
                    )
                ]
            )
        ]
    )
}

private func permissionState(automationStatus: PermissionStatus) -> PermissionOnboardingState {
    permissionState(statuses: [
        .automationSafari: automationStatus,
        .automationChrome: automationStatus,
        .automationBrave: automationStatus,
    ])
}

private func permissionState(statuses: [PermissionKind: PermissionStatus]) -> PermissionOnboardingState {
    PermissionOnboardingState(
        health: PermissionHealth(snapshots: [
            PermissionSnapshot(kind: .automationSafari, status: statuses[.automationSafari] ?? .notDetermined, detail: "", checkedAt: Date()),
            PermissionSnapshot(kind: .automationChrome, status: statuses[.automationChrome] ?? .notDetermined, detail: "", checkedAt: Date()),
            PermissionSnapshot(kind: .automationBrave, status: statuses[.automationBrave] ?? .notDetermined, detail: "", checkedAt: Date()),
        ])
    )
}
