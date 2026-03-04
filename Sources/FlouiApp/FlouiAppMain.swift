import FlouiCore
import Permissions
import StatusPills
import SwiftUI
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
            Text("Fixed Pills")
                .font(.headline)
                .padding(.horizontal, 8)

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
                            MiniWindowCard(window: window)
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

struct MiniWindowCard: View {
    let window: WorkspaceMiniWindowManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(window.id)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(window.tabs, id: \.id) { tab in
                    Text(tab.title)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tab.id == window.activeTabID ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .frame(height: 180)
                .overlay(alignment: .center) {
                    Text("\(window.tabs.first?.type.rawValue.capitalized ?? "Pane") Surface")
                        .foregroundStyle(.secondary)
                }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
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
