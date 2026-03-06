import Foundation
import StatusPills
import TerminalHost
import WorkspaceCore

enum AppShellTone: String, Equatable, Sendable {
    case idle
    case active
    case warning
    case critical
}

struct WorkspacePresentationSummary: Equatable, Sendable {
    let workspaceID: String
    let title: String
    let columnCount: Int
    let windowCount: Int
    let tabCount: Int
    let terminalCount: Int
    let browserCount: Int
    let pillTabCount: Int
    let fixedPillCount: Int
    let runningTaskCount: Int
    let alertCount: Int
    let shortcutCount: Int
    let activeWindowID: String?
    let activeTabTitle: String?
    let tone: AppShellTone

    static func build(
        workspace: WorkspaceManifest,
        pillStore: StatusPillStore,
        activeWindowID: String?
    ) -> WorkspacePresentationSummary {
        let windows = workspace.columns.flatMap(\.windows)
        let tabs = windows.flatMap(\.tabs)
        let pills = pillStore.pillsByPaneID.values.filter { $0.workspaceID == workspace.id }

        let terminalCount = tabs.filter { $0.type == .terminal }.count
        let browserCount = tabs.filter { $0.type == .browser }.count
        let pillTabCount = tabs.filter { $0.type == .pill }.count
        let runningTaskCount = pills.filter(\.isRunning).count
        let alertCount = pills.reduce(into: 0) { $0 += $1.unreadAlerts }
        let activeTabTitle = resolveActiveTabTitle(windows: windows, activeWindowID: activeWindowID)

        let tone: AppShellTone
        if pills.contains(where: { $0.severity == .critical }) {
            tone = .critical
        } else if pills.contains(where: { $0.severity == .warning }) || alertCount > 0 {
            tone = .warning
        } else if runningTaskCount > 0 {
            tone = .active
        } else {
            tone = .idle
        }

        return WorkspacePresentationSummary(
            workspaceID: workspace.id,
            title: workspace.name,
            columnCount: workspace.columns.count,
            windowCount: windows.count,
            tabCount: tabs.count,
            terminalCount: terminalCount,
            browserCount: browserCount,
            pillTabCount: pillTabCount,
            fixedPillCount: workspace.fixedPills.count,
            runningTaskCount: runningTaskCount,
            alertCount: alertCount,
            shortcutCount: workspace.shortcuts.count,
            activeWindowID: activeWindowID,
            activeTabTitle: activeTabTitle,
            tone: tone
        )
    }

    var densityLabel: String {
        "\(columnCount) cols · \(windowCount) windows · \(tabCount) tabs"
    }

    var capabilityLabel: String {
        "\(terminalCount) terminals · \(browserCount) browsers · \(fixedPillCount) pills"
    }

    var activityLabel: String {
        if alertCount > 0 {
            return "\(alertCount) \(pluralized("alert", count: alertCount))"
        }

        if runningTaskCount > 0 {
            return "\(runningTaskCount) live \(pluralized("task", count: runningTaskCount))"
        }

        return "Ready"
    }

    private static func resolveActiveTabTitle(
        windows: [WorkspaceMiniWindowManifest],
        activeWindowID: String?
    ) -> String? {
        if let activeWindowID,
           let focusedWindow = windows.first(where: { $0.id == activeWindowID })
        {
            return activeTabTitle(in: focusedWindow)
        }

        for window in windows {
            if let title = activeTabTitle(in: window) {
                return title
            }
        }

        return nil
    }

    private static func activeTabTitle(in window: WorkspaceMiniWindowManifest) -> String? {
        if let activeTabID = window.activeTabID,
           let activeTab = window.tabs.first(where: { $0.id == activeTabID })
        {
            return activeTab.title
        }

        return window.tabs.first?.title
    }
}

struct FixedPillPresentation: Equatable, Sendable {
    let title: String
    let sourceLabel: String
    let contextLabel: String
    let message: String
    let statusLabel: String
    let activityLabel: String
    let progressValue: Double?
    let progressLabel: String?
    let unreadAlertCount: Int
    let tone: AppShellTone

    static func make(
        pill: FixedPillManifest,
        state: StatusPillState?,
        now: Date
    ) -> FixedPillPresentation {
        let sourceLabel = humanizedSource(pill.source)

        guard let state else {
            return FixedPillPresentation(
                title: pill.title,
                sourceLabel: sourceLabel,
                contextLabel: "Waiting for \(sourceLabel)",
                message: "Waiting for events",
                statusLabel: "Idle",
                activityLabel: "No activity",
                progressValue: nil,
                progressLabel: nil,
                unreadAlertCount: 0,
                tone: .idle
            )
        }

        let tone: AppShellTone
        switch state.severity {
        case .critical:
            tone = .critical
        case .warning:
            tone = .warning
        case .info:
            tone = state.isRunning ? .active : .idle
        }

        let progressLabel: String?
        if let progress = state.progress {
            progressLabel = "\(Int((progress * 100).rounded()))%"
        } else {
            progressLabel = nil
        }

        return FixedPillPresentation(
            title: pill.title,
            sourceLabel: sourceLabel,
            contextLabel: "Workspace \(state.workspaceID)",
            message: state.message.isEmpty ? "Waiting for events" : state.message,
            statusLabel: state.isRunning ? "Live" : "Idle",
            activityLabel: RelativeActivityFormatter.describe(since: state.lastEventAt, now: now),
            progressValue: state.progress,
            progressLabel: progressLabel,
            unreadAlertCount: state.unreadAlerts,
            tone: tone
        )
    }

    private static func humanizedSource(_ raw: String) -> String {
        raw
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

enum RelativeActivityFormatter {
    static func describe(since date: Date?, now: Date) -> String {
        guard let date else {
            return "No activity"
        }

        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<5:
            return "just now"
        case 5..<60:
            return "\(seconds)s ago"
        case 60..<(60 * 60):
            return "\(seconds / 60)m ago"
        case (60 * 60)..<(60 * 60 * 24):
            return "\(seconds / 3600)h ago"
        default:
            return "\(seconds / 86400)d ago"
        }
    }
}

private func pluralized(_ noun: String, count: Int) -> String {
    count == 1 ? noun : "\(noun)s"
}

struct TerminalRuntimeEntryPresentation: Equatable, Sendable, Identifiable {
    let id: String
    let paneID: String
    let workspaceID: String
    let workspaceName: String
    let terminalTitle: String
    let shellLabel: String
    let directoryLabel: String
    let branchLabel: String?
    let activityLabel: String
    let isRunning: Bool
    let isActiveWorkspace: Bool
    let tone: AppShellTone
}

struct TerminalRuntimePanelPresentation: Equatable, Sendable {
    let entries: [TerminalRuntimeEntryPresentation]
    let liveCount: Int
    let readyCount: Int
    let stoppedCount: Int

    static func build(
        layoutState: WorkspaceLayoutState,
        snapshotsByPaneID: [String: TerminalPaneRuntimeState]
    ) -> TerminalRuntimePanelPresentation {
        let entries = layoutState.workspaceOrder
            .compactMap { layoutState.workspaces[$0] }
            .flatMap { workspace in
                workspace.columns
                    .flatMap(\.windows)
                    .flatMap(\.tabs)
                    .compactMap { tab -> TerminalRuntimeEntryPresentation? in
                        guard tab.type == .terminal else {
                            return nil
                        }

                        let snapshot = snapshotsByPaneID[tab.id]
                        let currentDirectory = snapshot?.currentDirectory ?? snapshot?.workingDirectory ?? tab.workingDirectory
                        let activityLabel: String
                        let tone: AppShellTone

                        if let activeCommand = snapshot?.activeCommand, !activeCommand.isEmpty {
                            activityLabel = activeCommand
                            tone = .active
                        } else if snapshot?.isRunning == true {
                            activityLabel = "Shell ready"
                            tone = .idle
                        } else if let lastMessage = snapshot?.lastMessage, !lastMessage.isEmpty {
                            activityLabel = lastMessage
                            tone = .warning
                        } else {
                            activityLabel = "Not started"
                            tone = .idle
                        }

                        let shellLabel = (snapshot?.command ?? tab.command ?? ["/bin/zsh"])
                            .joined(separator: " ")

                        return TerminalRuntimeEntryPresentation(
                            id: tab.id,
                            paneID: tab.id,
                            workspaceID: workspace.id,
                            workspaceName: workspace.name,
                            terminalTitle: tab.title,
                            shellLabel: shellLabel,
                            directoryLabel: compactPathLabel(currentDirectory),
                            branchLabel: snapshot?.gitBranch,
                            activityLabel: activityLabel,
                            isRunning: snapshot?.isRunning ?? false,
                            isActiveWorkspace: workspace.id == layoutState.activeWorkspaceID,
                            tone: tone
                        )
                    }
            }
            .sorted(by: entryOrdering)

        let liveCount = entries.filter { $0.isRunning && $0.tone == .active }.count
        let readyCount = entries.filter { $0.isRunning && $0.tone != .active }.count
        let stoppedCount = entries.count - liveCount - readyCount

        return TerminalRuntimePanelPresentation(
            entries: entries,
            liveCount: liveCount,
            readyCount: readyCount,
            stoppedCount: stoppedCount
        )
    }

    private static func entryOrdering(_ lhs: TerminalRuntimeEntryPresentation, _ rhs: TerminalRuntimeEntryPresentation) -> Bool {
        if lhs.isActiveWorkspace != rhs.isActiveWorkspace {
            return lhs.isActiveWorkspace && !rhs.isActiveWorkspace
        }

        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning && !rhs.isRunning
        }

        if lhs.tone != rhs.tone {
            return toneRank(lhs.tone) < toneRank(rhs.tone)
        }

        if lhs.workspaceName != rhs.workspaceName {
            return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
        }

        return lhs.terminalTitle.localizedCaseInsensitiveCompare(rhs.terminalTitle) == .orderedAscending
    }

    private static func toneRank(_ tone: AppShellTone) -> Int {
        switch tone {
        case .active:
            return 0
        case .warning:
            return 1
        case .critical:
            return 2
        case .idle:
            return 3
        }
    }

    private static func compactPathLabel(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "No directory"
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        let last = url.lastPathComponent
        if last.isEmpty {
            return path
        }

        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" {
            return last
        }

        return "\(parent)/\(last)"
    }
}
