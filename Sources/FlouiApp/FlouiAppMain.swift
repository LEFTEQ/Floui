import BrowserOrchestrator
import FlouiCore
import Permissions
import StatusPills
import SwiftUI
import TerminalHost
import WorkspaceCore

@main
struct FlouiAppMain: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var layoutState = WorkspaceLayoutState()
    @State private var pillStore = StatusPillStore()
    @State private var permissionState = PermissionOnboardingState()
    @State private var lastSessionMetadata = LastSessionMetadata()
    @State private var didBootstrapState = false
    @State private var didStartStatusIngestion = false
    @State private var didRestorePersistedSession = false
    @State private var didStartUpdater = false
    @StateObject private var updaterController = AppUpdaterController()

    private let permissionController = PermissionOnboardingController(checker: MacPermissionChecker())
    private let workspaceStateStore = JSONWorkspaceStateStore()
    private let statusFileIngestor = StatusEventFileIngestor(fileURL: Self.defaultStatusFileURL)

    var body: some Scene {
        WindowGroup("Floui") {
            AppShellView(
                layoutState: $layoutState,
                pillStore: $pillStore,
                permissionState: $permissionState,
                lastSessionMetadata: lastSessionMetadata,
                didRestorePersistedSession: didRestorePersistedSession,
                permissionController: permissionController
            )
            .frame(minWidth: 1320, minHeight: 780)
            .task {
                guard !didBootstrapState else {
                    return
                }

                didBootstrapState = true
                await bootstrap()
            }
            .task {
                guard !didStartStatusIngestion else {
                    return
                }

                didStartStatusIngestion = true
                await runStatusIngestionLoop()
            }
            .task {
                guard !didStartUpdater else {
                    return
                }

                didStartUpdater = true
                await MainActor.run {
                    updaterController.startIfNeeded()
                }
            }
            .onChange(of: layoutState) { _, updated in
                guard didBootstrapState else {
                    return
                }

                Task {
                    await persist(layoutState: updated)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard didBootstrapState else {
                    return
                }

                guard phase != .active else {
                    return
                }

                Task {
                    await persist(layoutState: layoutState)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates()
                }
                .disabled(!updaterController.state.canCheckForUpdates)
            }
        }
        Settings {
            UpdaterSettingsView(updaterController: updaterController)
        }
    }

    private func bootstrap() async {
        if let snapshot = try? await workspaceStateStore.load() {
            await MainActor.run {
                layoutState = snapshot.layoutState
                lastSessionMetadata = snapshot.lastSessionMetadata
                didRestorePersistedSession = true
            }
        } else {
            var seededLayoutState = WorkspaceLayoutState()
            WorkspaceLayoutReducer.reduce(state: &seededLayoutState, action: .loadManifest(Self.sampleManifest))
            await MainActor.run {
                layoutState = seededLayoutState
                lastSessionMetadata = LastSessionMetadata.capture(from: seededLayoutState)
                didRestorePersistedSession = false
            }
        }

        let refreshed = await permissionController.refresh()
        await MainActor.run {
            permissionState = refreshed
        }
    }

    private func persist(layoutState: WorkspaceLayoutState) async {
        let metadata = LastSessionMetadata.capture(from: layoutState)
        await MainActor.run {
            lastSessionMetadata = metadata
        }

        let snapshot = WorkspacePersistenceSnapshot(
            layoutState: layoutState,
            lastSessionMetadata: metadata,
            savedAt: Date()
        )
        try? await workspaceStateStore.save(snapshot)
    }

    private func runStatusIngestionLoop() async {
        while !Task.isCancelled {
            if let snapshot = try? await statusFileIngestor.poll() {
                await MainActor.run {
                    pillStore = snapshot
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private static var sampleManifest: WorkspaceManifest {
        WorkspaceManifest(
            id: "default",
            name: "Default",
            version: 1,
            columns: [
                WorkspaceColumnManifest(
                    id: "col-1",
                    width: 420,
                    windows: [
                        WorkspaceMiniWindowManifest(
                            id: "win-1",
                            activeTabID: "term-1",
                            tabs: [
                                WorkspaceTabManifest(id: "term-1", title: "Terminal", type: .terminal, command: ["/bin/zsh"]),
                                WorkspaceTabManifest(id: "chrome-1", title: "Chrome Dev", type: .browser, browser: .chrome, url: "https://github.com"),
                            ]
                        )
                    ]
                ),
                WorkspaceColumnManifest(
                    id: "col-2",
                    width: 420,
                    windows: [
                        WorkspaceMiniWindowManifest(
                            id: "win-2",
                            activeTabID: "safari-1",
                            tabs: [
                                WorkspaceTabManifest(id: "safari-1", title: "Safari", type: .browser, browser: .safari, url: "https://developer.apple.com"),
                            ]
                        )
                    ]
                ),
            ],
            fixedPills: [
                FixedPillManifest(id: "pill-claude", title: "Claude Code", source: "claude-code"),
                FixedPillManifest(id: "pill-coder", title: "Coder CLI", source: "coder-cli"),
            ]
        )
    }

    private static var defaultStatusFileURL: URL {
        if let configuredPath = ProcessInfo.processInfo.environment["FLOUI_STATUS_FILE"],
           !configuredPath.isEmpty
        {
            return URL(fileURLWithPath: configuredPath)
        }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Floui", isDirectory: true)
            .appendingPathComponent("status-events.jsonl")
    }
}

struct AppShellView: View {
    @Binding var layoutState: WorkspaceLayoutState
    @Binding var pillStore: StatusPillStore
    @Binding var permissionState: PermissionOnboardingState

    let lastSessionMetadata: LastSessionMetadata
    let didRestorePersistedSession: Bool
    let permissionController: PermissionOnboardingController
    private let permissionEvaluator = PermissionHealthEvaluator()
    @StateObject private var terminalRuntime: TerminalRuntimeViewModel
    @StateObject private var browserAutomation: BrowserAutomationController
    @StateObject private var automationCoordinator: WorkspaceAutomationCoordinator

    init(
        layoutState: Binding<WorkspaceLayoutState>,
        pillStore: Binding<StatusPillStore>,
        permissionState: Binding<PermissionOnboardingState>,
        lastSessionMetadata: LastSessionMetadata,
        didRestorePersistedSession: Bool,
        permissionController: PermissionOnboardingController
    ) {
        _layoutState = layoutState
        _pillStore = pillStore
        _permissionState = permissionState
        self.lastSessionMetadata = lastSessionMetadata
        self.didRestorePersistedSession = didRestorePersistedSession
        self.permissionController = permissionController

        let terminalRuntime = TerminalRuntimeViewModel()
        let browserAutomation = BrowserAutomationController()
        _terminalRuntime = StateObject(wrappedValue: terminalRuntime)
        _browserAutomation = StateObject(wrappedValue: browserAutomation)
        _automationCoordinator = StateObject(
            wrappedValue: WorkspaceAutomationCoordinator(
                terminalRuntime: terminalRuntime,
                browserAutomation: browserAutomation
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !permissionState.isComplete {
                PermissionBannerView(
                    permissionState: permissionState,
                    healthReport: permissionEvaluator.evaluate(permissionState.health),
                    onCheck: {
                        Task {
                            let refreshed = await permissionController.refresh()
                            await MainActor.run {
                                permissionState = refreshed
                            }
                        }
                    },
                    onRequest: {
                        Task {
                            let requested = await permissionController.requestAll()
                            await MainActor.run {
                                permissionState = requested
                            }
                        }
                    }
                )
                .padding(10)
                .background(Color.orange.opacity(0.16))
            }

            if let browserRecoveryIssue = browserAutomation.recoveryIssue {
                BrowserRecoveryBannerView(
                    issue: browserRecoveryIssue,
                    isRetrying: browserAutomation.isApplying,
                    onRetry: { applyBrowserLayout(force: true) },
                    onDismiss: { browserAutomation.recoveryIssue = nil }
                )
                .padding(10)
                .background(Color.red.opacity(0.14))
            }

            NavigationSplitView {
                workspaceSidebar
            } detail: {
                HStack(spacing: 0) {
                    fixedPillRail
                    workspaceCanvas
                }
                .background(shellBackground)
            }
            .navigationSplitViewStyle(.balanced)

            shortcutHandlers
        }
        .background(shellBackground.ignoresSafeArea())
        .task(id: automationTaskKey) {
            automationCoordinator.sync(
                layoutState: layoutState,
                lastSessionMetadata: lastSessionMetadata,
                permissionState: permissionState,
                restoredSession: didRestorePersistedSession,
                forceBrowserApply: false
            )
        }
    }

    private var workspaceSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspaces")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Horizontal canvases with live terminals, browsers, and pills.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                ForEach(layoutState.workspaceOrder, id: \.self) { workspaceID in
                    if let workspace = layoutState.workspaces[workspaceID] {
                        let summary = WorkspacePresentationSummary.build(
                            workspace: workspace,
                            pillStore: pillStore,
                            activeWindowID: layoutState.activeWindowIDByWorkspace[workspaceID]
                        )

                        Button {
                            switchWorkspace(workspaceID)
                        } label: {
                            WorkspaceSidebarCardView(
                                summary: summary,
                                isSelected: workspaceID == layoutState.activeWorkspaceID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(minWidth: 290)
        .background(sidebarBackground)
    }

    private var fixedPillRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixed Pills")
                        .font(.headline)
                    Text(activeWorkspaceSummary?.activityLabel ?? "No live workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(browserAutomation.isApplying ? "Applying..." : "Apply Layout") {
                    applyBrowserLayout(force: true)
                }
                .buttonStyle(.bordered)
                .disabled(browserAutomation.isApplying || activeWorkspace == nil)
            }

            if let summary = activeWorkspaceSummary {
                HStack(spacing: 8) {
                    ShellStatBadge(value: summary.fixedPillCount, label: "pills", tone: .idle)
                    ShellStatBadge(value: summary.runningTaskCount, label: "live", tone: .active)
                    ShellStatBadge(value: summary.alertCount, label: "alerts", tone: summary.tone)
                }
            }

            let pills = activeWorkspace?.fixedPills ?? []
            if pills.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 88)
                    .overlay {
                        Text("No fixed pills configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            } else {
                ForEach(pills, id: \.id) { pill in
                    FixedPillView(pill: pill, state: pillStore.pillsByPaneID[pill.id])
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 310)
        .background(pillRailBackground)
    }

    private var workspaceCanvas: some View {
        VStack(spacing: 0) {
            if let _ = activeWorkspace, let summary = activeWorkspaceSummary {
                WorkspaceCanvasHeaderView(
                    summary: summary,
                    restoredSession: didRestorePersistedSession,
                    isApplyingLayout: browserAutomation.isApplying,
                    onApplyLayout: { applyBrowserLayout(force: true) }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            ScrollView(.horizontal) {
                if let activeWorkspace {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(activeWorkspace.columns.enumerated()), id: \.element.id) { index, column in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Column \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(column.windows.count) windows")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                ForEach(column.windows, id: \.id) { window in
                                    MiniWindowCard(
                                        workspaceID: currentWorkspaceID,
                                        window: window,
                                        isFocused: layoutState.activeWindowIDByWorkspace[currentWorkspaceID] == window.id,
                                        terminalRuntime: terminalRuntime,
                                        onFocusWindow: {
                                            focusWindow(window.id)
                                        },
                                        onSelectTab: { windowID, tabID in
                                            selectTab(windowID: windowID, tabID: tabID)
                                        }
                                    )
                                }
                            }
                            .frame(width: column.width ?? 420)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                } else {
                    EmptyWorkspaceCanvasView()
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(canvasBackground)
    }

    private var activeWorkspace: WorkspaceManifest? {
        guard let id = layoutState.activeWorkspaceID else {
            return nil
        }
        return layoutState.workspaces[id]
    }

    private var currentWorkspaceID: String {
        layoutState.activeWorkspaceID ?? "default"
    }

    private var activeWorkspaceSummary: WorkspacePresentationSummary? {
        guard let workspace = activeWorkspace else {
            return nil
        }

        return WorkspacePresentationSummary.build(
            workspace: workspace,
            pillStore: pillStore,
            activeWindowID: layoutState.activeWindowIDByWorkspace[workspace.id]
        )
    }

    private var automationTaskKey: String {
        let workspaceKey: String
        if let workspace = activeWorkspace {
            workspaceKey = "\(workspace.id)-\(workspace.hashValue)"
        } else {
            workspaceKey = "no-workspace"
        }

        let permissionKey = permissionState.health.snapshots
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map { "\($0.kind.rawValue):\($0.status.rawValue)" }
            .joined(separator: ",")

        return "\(workspaceKey)|\(permissionKey)|restored:\(didRestorePersistedSession)"
    }

    private var shortcutHandlers: some View {
        VStack(spacing: 0) {
            Button("Next Tab") {
                cycleTab(direction: .next)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Tab") {
                cycleTab(direction: .previous)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Next Workspace") {
                cycleWorkspace(direction: .next)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button("Previous Workspace") {
                cycleWorkspace(direction: .previous)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Apply Browser Layout") {
                applyBrowserLayout(force: true)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
    }

    private func switchWorkspace(_ workspaceID: String) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .switchWorkspace(workspaceID))
    }

    private func focusWindow(_ windowID: String) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .focusWindow(windowID))
    }

    private func selectTab(windowID: String, tabID: String) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .selectTab(windowID: windowID, tabID: tabID))
    }

    private func cycleTab(direction: WorkspaceTabCycleDirection) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .cycleTab(direction: direction))
    }

    private func cycleWorkspace(direction: WorkspaceCycleDirection) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .cycleWorkspace(direction: direction))
    }

    private func applyBrowserLayout(force: Bool) {
        automationCoordinator.sync(
            layoutState: layoutState,
            lastSessionMetadata: lastSessionMetadata,
            permissionState: permissionState,
            restoredSession: didRestorePersistedSession,
            forceBrowserApply: force
        )
    }

    private var shellBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.08, blue: 0.11),
                Color(red: 0.11, green: 0.12, blue: 0.16),
                Color(red: 0.06, green: 0.07, blue: 0.10),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var sidebarBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.10, blue: 0.14),
                Color(red: 0.06, green: 0.07, blue: 0.10),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var pillRailBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.09, blue: 0.10),
                Color(red: 0.09, green: 0.08, blue: 0.12),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var canvasBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.10, blue: 0.14),
                    Color(red: 0.05, green: 0.06, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 32)
                .fill(Color(red: 0.95, green: 0.50, blue: 0.28).opacity(0.06))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: 320, y: -180)

            RoundedRectangle(cornerRadius: 40)
                .fill(Color(red: 0.25, green: 0.72, blue: 0.78).opacity(0.05))
                .frame(width: 480, height: 320)
                .blur(radius: 70)
                .offset(x: -260, y: 160)
        }
    }
}

struct PermissionBannerView: View {
    let permissionState: PermissionOnboardingState
    let healthReport: PermissionHealthReport
    let onCheck: () -> Void
    let onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission onboarding required for window control and alerts")
                .font(.subheadline.bold())
            Text(healthReport.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(permissionState.health.snapshots, id: \.kind.rawValue) { snapshot in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: snapshot.status))
                        .frame(width: 8, height: 8)
                    Text(snapshot.kind.displayName)
                        .font(.caption)
                    Spacer(minLength: 8)
                    Text(snapshot.status.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Re-check", action: onCheck)
                    .buttonStyle(.bordered)
                Button("Request Required", action: onRequest)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func color(for status: PermissionStatus) -> Color {
        switch status {
        case .granted:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        case .unavailable:
            return .gray
        }
    }
}

struct BrowserRecoveryBannerView: View {
    let issue: BrowserRecoveryIssue
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(issue.title)
                    .font(.subheadline.bold())
                Spacer(minLength: 8)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            }

            Text(issue.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(issue.steps, id: \.self) { step in
                Text("• \(step)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(isRetrying ? "Retrying..." : "Retry Browser Layout") {
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
            }
        }
    }
}

struct WorkspaceSidebarCardView: View {
    let summary: WorkspacePresentationSummary
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.headline)
                    Text(summary.densityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 8) {
                ShellStatBadge(value: summary.terminalCount, label: "term", tone: .active)
                ShellStatBadge(value: summary.browserCount, label: "web", tone: .idle)
                ShellStatBadge(value: summary.alertCount, label: "alerts", tone: summary.tone)
            }

            HStack {
                Text(summary.activityLabel)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 8)
                if let activeTabTitle = summary.activeTabTitle {
                    Text(activeTabTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isSelected ? accentColor.opacity(0.16) : Color.white.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? accentColor.opacity(0.85) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.4 : 1)
        }
    }

    private var accentColor: Color {
        switch summary.tone {
        case .idle:
            return Color(red: 0.55, green: 0.59, blue: 0.67)
        case .active:
            return Color(red: 0.24, green: 0.73, blue: 0.78)
        case .warning:
            return Color(red: 0.95, green: 0.63, blue: 0.24)
        case .critical:
            return Color(red: 0.96, green: 0.37, blue: 0.33)
        }
    }
}

struct WorkspaceCanvasHeaderView: View {
    let summary: WorkspacePresentationSummary
    let restoredSession: Bool
    let isApplyingLayout: Bool
    let onApplyLayout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(summary.capabilityLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Button(isApplyingLayout ? "Applying Layout..." : "Apply Layout") {
                        onApplyLayout()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplyingLayout)

                    if restoredSession {
                        Text("Restored session")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 8) {
                ShellStatBadge(value: summary.columnCount, label: "cols", tone: .idle)
                ShellStatBadge(value: summary.windowCount, label: "windows", tone: .idle)
                ShellStatBadge(value: summary.runningTaskCount, label: "live", tone: .active)
                ShellStatBadge(value: summary.alertCount, label: "alerts", tone: summary.tone)
                ShellStatBadge(value: summary.shortcutCount, label: "custom keys", tone: .idle)
            }

            HStack(spacing: 8) {
                ShellShortcutBadge(text: "Cmd+Shift+[ ] tabs")
                ShellShortcutBadge(text: "Opt+Cmd+← → workspaces")
                ShellShortcutBadge(text: "Opt+Cmd+L layout")
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct ShellStatBadge: View {
    let value: Int
    let label: String
    let tone: AppShellTone

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.caption.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var tint: Color {
        switch tone {
        case .idle:
            return Color.white
        case .active:
            return Color.cyan
        case .warning:
            return Color.orange
        case .critical:
            return Color.red
        }
    }
}

struct ShellShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
    }
}

struct EmptyWorkspaceCanvasView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No workspace selected")
                .font(.title3.bold())
            Text("Load or create a workspace manifest to start arranging terminals, browsers, and fixed pills.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.04))
        )
    }
}

struct MiniWindowCard: View {
    let workspaceID: String
    let window: WorkspaceMiniWindowManifest
    let isFocused: Bool
    @ObservedObject var terminalRuntime: TerminalRuntimeViewModel
    let onFocusWindow: () -> Void
    let onSelectTab: (String, String) -> Void
    @State private var terminalInput = ""

    private var activeTab: WorkspaceTabManifest? {
        if let activeTabID = window.activeTabID {
            return window.tabs.first(where: { $0.id == activeTabID }) ?? window.tabs.first
        }
        return window.tabs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(window.id)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activeTab?.title ?? "Empty window")
                        .font(.headline)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(isFocused ? "Focused" : "Background")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isFocused ? Color.orange.opacity(0.24) : Color.white.opacity(0.08))
                        .clipShape(Capsule())
                    Text("\(window.tabs.count) tabs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(window.tabs, id: \.id) { tab in
                    Button {
                        onSelectTab(window.id, tab.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: symbol(for: tab.type))
                                .font(.caption2)
                            Text(tab.title)
                                .font(.caption)
                        }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                tab.id == activeTab?.id
                                    ? Color.cyan.opacity(0.28)
                                    : Color.white.opacity(0.08)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Group {
                if let tab = activeTab {
                    let surfaceID = "surface-\(window.id)-\(tab.id)"
                    switch tab.type {
                    case .terminal:
                        TerminalPaneView(
                            tab: tab,
                            workspaceID: workspaceID,
                            snapshot: terminalRuntime.snapshotsByPaneID[tab.id],
                            requiresManualStart: terminalRuntime.requiresManualStart(paneID: tab.id),
                            isStarting: terminalRuntime.startingPaneIDs.contains(tab.id),
                            inputText: $terminalInput,
                            onAppear: {
                                terminalRuntime.activate(
                                    tab: tab,
                                    workspaceID: workspaceID,
                                    surfaceID: surfaceID
                                )
                            },
                            onStart: {
                                terminalRuntime.start(
                                    tab: tab,
                                    workspaceID: workspaceID,
                                    surfaceID: surfaceID
                                )
                            },
                            onSubmitInput: { value in
                                terminalRuntime.sendInput(paneID: tab.id, input: value + "\n")
                            }
                        )

                    case .browser:
                        BrowserPaneView(tab: tab)

                    case .pill:
                        PillPaneView(tab: tab)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 180)
                        .overlay(alignment: .center) {
                            Text("Empty Window")
                                .foregroundStyle(.secondary)
                        }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isFocused ? Color.white.opacity(0.09) : Color.white.opacity(0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isFocused ? Color.orange.opacity(0.55) : Color.white.opacity(0.08),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 10)
        .onTapGesture(perform: onFocusWindow)
    }

    private func symbol(for type: WorkspacePaneType) -> String {
        switch type {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .pill:
            return "capsule"
        }
    }
}

struct TerminalPaneView: View {
    let tab: WorkspaceTabManifest
    let workspaceID: String
    let snapshot: TerminalPaneRuntimeState?
    let requiresManualStart: Bool
    let isStarting: Bool
    @Binding var inputText: String
    let onAppear: () -> Void
    let onStart: () -> Void
    let onSubmitInput: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot?.isRunning == true ? "Running" : "Stopped")
                    .font(.caption2.bold())
                    .foregroundStyle(snapshot?.isRunning == true ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((snapshot?.isRunning == true ? Color.green : Color.white).opacity(0.12))
                    .clipShape(Capsule())
                Spacer(minLength: 8)
                if let exitCode = snapshot?.exitCode {
                    Text("exit \(exitCode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if snapshot?.isRunning != true {
                    Button(startButtonTitle) {
                        onStart()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isStarting)
                }
            }

            if let command = snapshot?.command ?? tab.command, !command.isEmpty {
                Text(command.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot?.outputLines.suffix(120) ?? [], id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let lastMessage = snapshot?.lastMessage,
                       !lastMessage.isEmpty
                    {
                        Text(lastMessage)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.42)))

            TextField(inputPlaceholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .disabled(snapshot?.isRunning != true)
                .onSubmit {
                    let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        return
                    }
                    onSubmitInput(trimmed)
                    inputText = ""
                }
        }
        .onAppear(perform: onAppear)
    }

    private var startButtonTitle: String {
        if isStarting {
            return "Starting..."
        }

        if requiresManualStart {
            return "Start"
        }

        return snapshot == nil ? "Start" : "Restart"
    }

    private var inputPlaceholder: String {
        if snapshot?.isRunning == true {
            return "Send input to \(tab.id)"
        }

        if requiresManualStart {
            return "Restored terminal. Start manually to resume."
        }

        return "Start terminal to send input"
    }
}

struct BrowserPaneView: View {
    let tab: WorkspaceTabManifest

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.05))
            .frame(height: 180)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text((tab.browser?.rawValue.capitalized ?? "Browser"))
                            .font(.headline)
                        Spacer()
                        Text("Dev surface")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(tab.url ?? "about:blank")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Label("Workspace-tiled", systemImage: "square.split.2x1")
                        if tab.browser == .chrome || tab.browser == .brave {
                            Label("CDP-aware", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding(14)
            }
    }
}

struct PillPaneView: View {
    let tab: WorkspaceTabManifest

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.05))
            .frame(height: 180)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tab.title)
                        .font(.headline)
                    Text("Reserved for docked status surfaces and pinned wrappers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Always visible outside the scroll canvas", systemImage: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
    }
}

@MainActor
final class TerminalRuntimeViewModel: ObservableObject, TerminalWorkspaceCoordinating {
    private struct PreparedTerminalConfig: Sendable {
        var workspaceID: String
        var command: [String]
    }

    @Published private(set) var snapshotsByPaneID: [String: TerminalPaneRuntimeState] = [:]
    @Published private(set) var startingPaneIDs = Set<String>()

    private let runtime: TerminalWorkspaceRuntime
    private var activePaneIDs = Set<String>()
    private var preparedConfigsByPaneID: [String: PreparedTerminalConfig] = [:]
    private var surfaceIDsByPaneID: [String: String] = [:]
    private var suspendedPaneIDs = Set<String>()
    private var pollTask: Task<Void, Never>?

    init(engine: TerminalEngine = DefaultTerminalEngineFactory.make()) {
        runtime = TerminalWorkspaceRuntime(engine: engine)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    deinit {
        pollTask?.cancel()
    }

    func activate(tab: WorkspaceTabManifest, workspaceID: String, surfaceID: String) {
        guard tab.type == .terminal else {
            return
        }

        activePaneIDs.insert(tab.id)
        preparedConfigsByPaneID[tab.id] = PreparedTerminalConfig(
            workspaceID: workspaceID,
            command: resolvedCommand(for: tab.id, fallback: tab.command)
        )
        surfaceIDsByPaneID[tab.id] = surfaceID

        Task { [weak self] in
            await self?.activatePaneIfNeeded(paneID: tab.id)
        }
    }

    func start(tab: WorkspaceTabManifest, workspaceID: String, surfaceID: String) {
        guard tab.type == .terminal else {
            return
        }

        activePaneIDs.insert(tab.id)
        preparedConfigsByPaneID[tab.id] = PreparedTerminalConfig(
            workspaceID: workspaceID,
            command: resolvedCommand(for: tab.id, fallback: tab.command)
        )
        surfaceIDsByPaneID[tab.id] = surfaceID
        suspendedPaneIDs.remove(tab.id)

        Task { [weak self] in
            await self?.ensureSessionStarted(for: tab.id)
        }
    }

    func sendInput(paneID: String, input: String) {
        Task { [runtime] in
            try? await runtime.sendInput(paneID: paneID, input: input)
        }
    }

    func primeRestorePlans(_ plans: [WorkspaceRestorePlan]) {
        for plan in plans {
            for pane in plan.panes where pane.type == .terminal {
                let command = resolvedCommand(for: pane.paneID, fallback: pane.command)
                preparedConfigsByPaneID[pane.paneID] = PreparedTerminalConfig(
                    workspaceID: plan.workspaceID,
                    command: command
                )

                guard pane.autoRun == false else {
                    continue
                }

                suspendedPaneIDs.insert(pane.paneID)
                snapshotsByPaneID[pane.paneID] = TerminalPaneRuntimeState(
                    paneID: pane.paneID,
                    workspaceID: plan.workspaceID,
                    command: command,
                    isRunning: false,
                    lastMessage: "Restored. Command not auto-run.",
                    outputLines: []
                )
            }
        }
    }

    func prepare(workspace: WorkspaceManifest) {
        for tab in workspace.columns.flatMap(\.windows).flatMap(\.tabs) where tab.type == .terminal {
            preparedConfigsByPaneID[tab.id] = PreparedTerminalConfig(
                workspaceID: workspace.id,
                command: resolvedCommand(for: tab.id, fallback: tab.command)
            )
        }
    }

    func requiresManualStart(paneID: String) -> Bool {
        suspendedPaneIDs.contains(paneID)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let paneIDs = activePaneIDs
            for paneID in paneIDs {
                if let snapshot = await runtime.snapshot(for: paneID) {
                    snapshotsByPaneID[paneID] = snapshot
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func activatePaneIfNeeded(paneID: String) async {
        if startingPaneIDs.contains(paneID) {
            return
        }

        if suspendedPaneIDs.contains(paneID) {
            return
        }

        if let sessionID = await runtime.sessionID(for: paneID) {
            await attachSurfaceIfNeeded(paneID: paneID, sessionID: sessionID)
            return
        }

        if snapshotsByPaneID[paneID] != nil {
            return
        }

        await ensureSessionStarted(for: paneID)
    }

    private func ensureSessionStarted(for paneID: String) async {
        if startingPaneIDs.contains(paneID) {
            return
        }

        guard let prepared = preparedConfigsByPaneID[paneID] else {
            return
        }

        if let sessionID = await runtime.sessionID(for: paneID) {
            await attachSurfaceIfNeeded(paneID: paneID, sessionID: sessionID)
            return
        }

        startingPaneIDs.insert(paneID)
        defer { startingPaneIDs.remove(paneID) }

        let config = TerminalSessionConfig(
            workspaceID: prepared.workspaceID,
            paneID: paneID,
            shellCommand: prepared.command
        )

        do {
            try await runtime.activateTerminal(config: config)
            if let snapshot = await runtime.snapshot(for: paneID) {
                snapshotsByPaneID[paneID] = snapshot
            }
            if let sessionID = await runtime.sessionID(for: paneID) {
                await attachSurfaceIfNeeded(paneID: paneID, sessionID: sessionID)
            }
        } catch {
            snapshotsByPaneID[paneID] = TerminalPaneRuntimeState(
                paneID: paneID,
                workspaceID: prepared.workspaceID,
                command: prepared.command,
                isRunning: false,
                lastMessage: "Terminal start failed: \(error.localizedDescription)",
                outputLines: []
            )
        }
    }

    private func attachSurfaceIfNeeded(paneID: String, sessionID _: TerminalSessionID) async {
        guard let surfaceID = surfaceIDsByPaneID[paneID] else {
            return
        }

        try? await runtime.attachSurface(paneID: paneID, surfaceID: surfaceID)
    }

    private func resolvedCommand(for paneID: String, fallback: [String]?) -> [String] {
        if let prepared = preparedConfigsByPaneID[paneID] {
            return prepared.command
        }

        if let fallback, !fallback.isEmpty {
            return fallback
        }

        return ["/bin/zsh"]
    }
}

@MainActor
final class BrowserAutomationController: ObservableObject, BrowserWorkspaceCoordinating {
    @Published var recoveryIssue: BrowserRecoveryIssue?
    @Published private(set) var isApplying = false

    private let coordinator: BrowserAutoApplyCoordinator
    private let canvas = BrowserCanvasLayoutContext(bounds: FlouiRect(x: 80, y: 70, width: 1280, height: 860))
    private var applyTask: Task<Void, Never>?

    init() {
        let appleEvents = CocoaAppleEventClient()
        let adapters: [BrowserKind: BrowserAdapter] = [
            .safari: AppleEventBrowserAdapter(kind: .safari, appleEvents: appleEvents),
            .chrome: AppleEventBrowserAdapter(kind: .chrome, appleEvents: appleEvents),
            .brave: AppleEventBrowserAdapter(kind: .brave, appleEvents: appleEvents),
        ]
        let orchestrator = BrowserWorkspaceOrchestrator(adapters: adapters)
        coordinator = BrowserAutoApplyCoordinator(orchestrator: orchestrator)
    }

    deinit {
        applyTask?.cancel()
    }

    func apply(workspace: WorkspaceManifest, force: Bool) {
        applyTask?.cancel()
        let layout = BrowserLayoutBuilder.fromManifest(workspace, canvas: canvas)
        guard !layout.plans.isEmpty else {
            recoveryIssue = nil
            isApplying = false
            return
        }

        recoveryIssue = nil
        isApplying = true

        applyTask = Task { [coordinator] in
            do {
                if force {
                    try await coordinator.forceApply(layout: layout)
                } else {
                    _ = try await coordinator.applyIfNeeded(layout: layout)
                }

                await MainActor.run {
                    self.isApplying = false
                    self.recoveryIssue = nil
                }
            } catch {
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isApplying = false
                    }
                    return
                }

                let issue = BrowserRecoveryAdvisor.advise(error: error)
                await MainActor.run {
                    self.isApplying = false
                    self.recoveryIssue = issue
                }
            }
        }
    }
}

struct FixedPillView: View {
    let pill: FixedPillManifest
    let state: StatusPillState?

    var body: some View {
        let presentation = FixedPillPresentation.make(pill: pill, state: state, now: Date())

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.caption.bold())
                    Text(presentation.sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(presentation.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(presentation.message)
                .font(.caption)
                .lineLimit(2)

            if let progressValue = presentation.progressValue {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressValue)
                        .tint(color)
                    if let progressLabel = presentation.progressLabel {
                        Text(progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text(presentation.contextLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if presentation.unreadAlertCount > 0 {
                    Text("\(presentation.unreadAlertCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.18))
                        .clipShape(Capsule())
                }
                Text(presentation.activityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.28), lineWidth: 1)
        }
    }

    private var color: Color {
        switch state?.severity {
        case .critical:
            return .red
        case .warning:
            return .orange
        case .info:
            return state?.isRunning == true ? .cyan : .gray
        case nil:
            return .gray
        }
    }
}
