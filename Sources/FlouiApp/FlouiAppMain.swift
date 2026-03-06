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

    private let permissionController = PermissionOnboardingController(checker: MacPermissionChecker())
    private let workspaceStateStore = JSONWorkspaceStateStore()
    private let statusFileIngestor = StatusEventFileIngestor(fileURL: Self.defaultStatusFileURL)

    var body: some Scene {
        WindowGroup("Floui") {
            AppShellView(
                layoutState: $layoutState,
                pillStore: $pillStore,
                permissionState: $permissionState,
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
    }

    private func bootstrap() async {
        if let snapshot = try? await workspaceStateStore.load() {
            await MainActor.run {
                layoutState = snapshot.layoutState
                lastSessionMetadata = snapshot.lastSessionMetadata
            }
        } else {
            var seededLayoutState = WorkspaceLayoutState()
            WorkspaceLayoutReducer.reduce(state: &seededLayoutState, action: .loadManifest(Self.sampleManifest))
            await MainActor.run {
                layoutState = seededLayoutState
            }
        }

        let refreshed = await permissionController.refresh()
        await MainActor.run {
            permissionState = refreshed
        }
    }

    private func persist(layoutState: WorkspaceLayoutState) async {
        let snapshot = WorkspacePersistenceSnapshot(
            layoutState: layoutState,
            lastSessionMetadata: lastSessionMetadata,
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

    let permissionController: PermissionOnboardingController
    private let permissionEvaluator = PermissionHealthEvaluator()
    @StateObject private var terminalRuntime = TerminalRuntimeViewModel()
    @StateObject private var browserAutomation = BrowserAutomationController()

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
                .background(.ultraThinMaterial)
            }
            .navigationSplitViewStyle(.balanced)

            shortcutHandlers
        }
        .task(id: activeWorkspaceTaskKey) {
            guard let workspace = activeWorkspace else {
                return
            }
            applyBrowserLayout(workspace: workspace, force: false)
        }
    }

    private var workspaceSidebar: some View {
        List(selection: Binding(
            get: { layoutState.activeWorkspaceID },
            set: { newValue in
                guard let id = newValue else { return }
                WorkspaceLayoutReducer.reduce(state: &layoutState, action: .switchWorkspace(id))
            }
        )) {
            ForEach(layoutState.workspaceOrder, id: \.self) { workspaceID in
                Text(layoutState.workspaces[workspaceID]?.name ?? workspaceID)
                    .tag(Optional(workspaceID))
            }
        }
        .frame(minWidth: 240)
    }

    private var fixedPillRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Fixed Pills")
                    .font(.headline)
                    .padding(.horizontal, 8)
                Spacer(minLength: 8)
                Button(browserAutomation.isApplying ? "Applying..." : "Apply Layout") {
                    applyBrowserLayout(force: true)
                }
                .buttonStyle(.bordered)
                .disabled(browserAutomation.isApplying || activeWorkspace == nil)
            }

            let pills = activeWorkspace?.fixedPills ?? []
            ForEach(pills, id: \.id) { pill in
                FixedPillView(pill: pill, state: pillStore.pillsByPaneID[pill.id])
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 260)
        .background(Color.black.opacity(0.25))
    }

    private var workspaceCanvas: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(activeWorkspace?.columns ?? [], id: \.id) { column in
                    VStack(spacing: 12) {
                        ForEach(column.windows, id: \.id) { window in
                            MiniWindowCard(
                                workspaceID: currentWorkspaceID,
                                window: window,
                                terminalRuntime: terminalRuntime,
                                onSelectTab: { windowID, tabID in
                                    selectTab(windowID: windowID, tabID: tabID)
                                }
                            )
                        }
                    }
                    .frame(width: column.width ?? 420)
                }
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.18))
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

    private var activeWorkspaceTaskKey: String {
        guard let workspace = activeWorkspace else {
            return "no-workspace"
        }

        return "\(workspace.id)-\(workspace.hashValue)"
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
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
    }

    private func selectTab(windowID: String, tabID: String) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .selectTab(windowID: windowID, tabID: tabID))
    }

    private func cycleTab(direction: WorkspaceTabCycleDirection) {
        WorkspaceLayoutReducer.reduce(state: &layoutState, action: .cycleTab(direction: direction))
    }

    private func applyBrowserLayout(force: Bool) {
        guard let workspace = activeWorkspace else {
            return
        }

        applyBrowserLayout(workspace: workspace, force: force)
    }

    private func applyBrowserLayout(workspace: WorkspaceManifest, force: Bool) {
        browserAutomation.apply(workspace: workspace, force: force)
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

struct MiniWindowCard: View {
    let workspaceID: String
    let window: WorkspaceMiniWindowManifest
    @ObservedObject var terminalRuntime: TerminalRuntimeViewModel
    let onSelectTab: (String, String) -> Void
    @State private var terminalInput = ""

    private var activeTab: WorkspaceTabManifest? {
        if let activeTabID = window.activeTabID {
            return window.tabs.first(where: { $0.id == activeTabID }) ?? window.tabs.first
        }
        return window.tabs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(window.id)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(window.tabs, id: \.id) { tab in
                    Button {
                        onSelectTab(window.id, tab.id)
                    } label: {
                        Text(tab.title)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(tab.id == activeTab?.id ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Group {
                if let tab = activeTab {
                    switch tab.type {
                    case .terminal:
                        TerminalPaneView(
                            tab: tab,
                            workspaceID: workspaceID,
                            snapshot: terminalRuntime.snapshotsByPaneID[tab.id],
                            inputText: $terminalInput,
                            onAppear: {
                                terminalRuntime.activate(
                                    tab: tab,
                                    workspaceID: workspaceID,
                                    surfaceID: "surface-\(window.id)-\(tab.id)"
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
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

struct TerminalPaneView: View {
    let tab: WorkspaceTabManifest
    let workspaceID: String
    let snapshot: TerminalPaneRuntimeState?
    @Binding var inputText: String
    let onAppear: () -> Void
    let onSubmitInput: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot?.isRunning == true ? "Running" : "Stopped")
                    .font(.caption2.bold())
                    .foregroundStyle(snapshot?.isRunning == true ? .green : .secondary)
                Spacer(minLength: 8)
                if let exitCode = snapshot?.exitCode {
                    Text("exit \(exitCode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))

            TextField("Send input to \(tab.id)", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
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
}

struct BrowserPaneView: View {
    let tab: WorkspaceTabManifest

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.05))
            .frame(height: 180)
            .overlay(alignment: .center) {
                VStack(spacing: 6) {
                    Text("Browser Surface")
                        .font(.caption.bold())
                    Text(tab.url ?? "about:blank")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
    }
}

struct PillPaneView: View {
    let tab: WorkspaceTabManifest

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.05))
            .frame(height: 180)
            .overlay(alignment: .center) {
                Text("Pill Pane: \(tab.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }
}

@MainActor
final class TerminalRuntimeViewModel: ObservableObject {
    @Published private(set) var snapshotsByPaneID: [String: TerminalPaneRuntimeState] = [:]

    private let runtime = TerminalWorkspaceRuntime(engine: DefaultTerminalEngineFactory.make())
    private var activePaneIDs = Set<String>()
    private var pollTask: Task<Void, Never>?

    init() {
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
        let command = (tab.command?.isEmpty == false) ? (tab.command ?? ["/bin/zsh"]) : ["/bin/zsh"]
        let config = TerminalSessionConfig(
            workspaceID: workspaceID,
            paneID: tab.id,
            shellCommand: command
        )

        Task { [runtime] in
            do {
                try await runtime.activateTerminal(config: config)
                try? await runtime.attachSurface(paneID: tab.id, surfaceID: surfaceID)
            } catch {
                await MainActor.run {
                    self.snapshotsByPaneID[tab.id] = TerminalPaneRuntimeState(
                        paneID: tab.id,
                        workspaceID: workspaceID,
                        command: command,
                        isRunning: false,
                        lastMessage: "Terminal start failed: \(error.localizedDescription)",
                        outputLines: []
                    )
                }
            }
        }
    }

    func sendInput(paneID: String, input: String) {
        Task { [runtime] in
            try? await runtime.sendInput(paneID: paneID, input: input)
        }
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
}

@MainActor
final class BrowserAutomationController: ObservableObject {
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pill.title)
                    .font(.caption.bold())
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Text(state?.message ?? "idle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
    }

    private var color: Color {
        switch state?.severity {
        case .critical:
            return .red
        case .warning:
            return .orange
        case .info:
            return .green
        case nil:
            return .gray
        }
    }
}
