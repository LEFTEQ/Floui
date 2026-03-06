import Permissions
import SwiftUI
import WorkspaceCore

@MainActor
protocol TerminalWorkspaceCoordinating: AnyObject {
    func primeRestorePlans(_ plans: [WorkspaceRestorePlan])
    func prepare(workspace: WorkspaceManifest)
}

@MainActor
protocol BrowserWorkspaceCoordinating: AnyObject {
    func apply(workspace: WorkspaceManifest, force: Bool)
}

@MainActor
final class WorkspaceAutomationCoordinator: ObservableObject {
    private let terminalRuntime: TerminalWorkspaceCoordinating
    private let browserAutomation: BrowserWorkspaceCoordinating
    private let restorePlanner: WorkspaceRestorePlanner

    private var didPrimeRestorePlans = false

    init(
        terminalRuntime: TerminalWorkspaceCoordinating,
        browserAutomation: BrowserWorkspaceCoordinating,
        restorePlanner: WorkspaceRestorePlanner = .init()
    ) {
        self.terminalRuntime = terminalRuntime
        self.browserAutomation = browserAutomation
        self.restorePlanner = restorePlanner
    }

    func sync(
        layoutState: WorkspaceLayoutState,
        lastSessionMetadata: LastSessionMetadata,
        permissionState: PermissionOnboardingState,
        restoredSession: Bool,
        forceBrowserApply: Bool = false
    ) {
        if restoredSession, !didPrimeRestorePlans {
            let plans = layoutState.workspaceOrder.compactMap { workspaceID -> WorkspaceRestorePlan? in
                guard let manifest = layoutState.workspaces[workspaceID] else {
                    return nil
                }
                return restorePlanner.makePlan(manifest: manifest, metadata: lastSessionMetadata)
            }
            terminalRuntime.primeRestorePlans(plans)
            didPrimeRestorePlans = true
        }

        guard
            let workspaceID = layoutState.activeWorkspaceID,
            let workspace = layoutState.workspaces[workspaceID]
        else {
            return
        }

        terminalRuntime.prepare(workspace: workspace)

        if forceBrowserApply || shouldAutoApplyBrowsers(for: workspace, with: permissionState) {
            browserAutomation.apply(workspace: workspace, force: forceBrowserApply)
        }
    }

    private func shouldAutoApplyBrowsers(
        for workspace: WorkspaceManifest,
        with permissionState: PermissionOnboardingState
    ) -> Bool {
        let automationKinds = Set(
            workspace.columns
                .flatMap(\.windows)
                .flatMap(\.tabs)
                .compactMap { tab -> PermissionKind? in
                    guard tab.type == .browser, let browser = tab.browser else {
                        return nil
                    }

                    switch browser {
                    case .safari:
                        return .automationSafari
                    case .chrome:
                        return .automationChrome
                    case .brave:
                        return .automationBrave
                    }
                }
        )

        return automationKinds.allSatisfy { kind in
            guard let snapshot = permissionState.health.snapshot(for: kind) else {
                return true
            }

            switch snapshot.status {
            case .denied, .unavailable:
                return false
            case .granted, .notDetermined:
                return true
            }
        }
    }
}
