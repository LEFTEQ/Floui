@testable import FlouiApp
import Foundation
import StatusPills
import Testing
import WorkspaceCore

@Test("Workspace presentation summary aggregates workspace structure and pill activity")
func workspacePresentationSummaryAggregatesWorkspace() {
    let workspace = WorkspaceManifest(
        id: "shipyard",
        name: "Shipyard",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "col-1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "win-1",
                        activeTabID: "term-1",
                        tabs: [
                            WorkspaceTabManifest(id: "term-1", title: "Shell", type: .terminal),
                            WorkspaceTabManifest(id: "browser-1", title: "Docs", type: .browser, browser: .chrome),
                        ]
                    ),
                    WorkspaceMiniWindowManifest(
                        id: "win-2",
                        activeTabID: "term-2",
                        tabs: [
                            WorkspaceTabManifest(id: "term-2", title: "Worker", type: .terminal),
                        ]
                    ),
                ]
            )
        ],
        fixedPills: [
            FixedPillManifest(id: "pill-1", title: "Claude", source: "claude-code"),
            FixedPillManifest(id: "pill-2", title: "Coder", source: "coder-cli"),
        ],
        shortcuts: [
            ShortcutBindingManifest(id: "deploy", command: "workspace.deploy", key: "cmd+enter"),
        ]
    )

    var pillStore = StatusPillStore()
    pillStore.apply(
        StatusEvent(
            event: .taskStarted,
            workspaceID: "shipyard",
            paneID: "pill-1",
            taskID: "task-1",
            source: "claude-code",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            severity: .info,
            message: "Building"
        )
    )
    pillStore.apply(
        StatusEvent(
            event: .taskAlert,
            workspaceID: "shipyard",
            paneID: "pill-1",
            taskID: "task-1",
            source: "claude-code",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            severity: .critical,
            message: "Build failed"
        )
    )

    let summary = WorkspacePresentationSummary.build(
        workspace: workspace,
        pillStore: pillStore,
        activeWindowID: "win-2"
    )

    #expect(summary.columnCount == 1)
    #expect(summary.windowCount == 2)
    #expect(summary.tabCount == 3)
    #expect(summary.terminalCount == 2)
    #expect(summary.browserCount == 1)
    #expect(summary.fixedPillCount == 2)
    #expect(summary.runningTaskCount == 1)
    #expect(summary.alertCount == 1)
    #expect(summary.shortcutCount == 1)
    #expect(summary.activeTabTitle == "Worker")
    #expect(summary.tone == .critical)
    #expect(summary.activityLabel == "1 alert")
}

@Test("Fixed pill presentation formats source progress and relative activity")
func fixedPillPresentationFormatsLiveState() {
    let pill = FixedPillManifest(id: "pill-1", title: "Claude Code", source: "claude-code")
    let state = StatusPillState(
        workspaceID: "shipyard",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        lastEventAt: Date(timeIntervalSince1970: 1_700_000_000),
        isRunning: true,
        progress: 0.63,
        severity: .warning,
        message: "Waiting for review",
        unreadAlerts: 2
    )

    let presentation = FixedPillPresentation.make(
        pill: pill,
        state: state,
        now: Date(timeIntervalSince1970: 1_700_000_125)
    )

    #expect(presentation.sourceLabel == "Claude Code")
    #expect(presentation.contextLabel == "Workspace shipyard")
    #expect(presentation.message == "Waiting for review")
    #expect(presentation.statusLabel == "Live")
    #expect(presentation.activityLabel == "2m ago")
    #expect(presentation.progressLabel == "63%")
    #expect(presentation.progressValue == 0.63)
    #expect(presentation.unreadAlertCount == 2)
    #expect(presentation.tone == .warning)
}

@Test("Relative activity formatter uses compact labels")
func relativeActivityFormatterUsesCompactLabels() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(RelativeActivityFormatter.describe(since: now, now: now) == "just now")
    #expect(RelativeActivityFormatter.describe(since: now.addingTimeInterval(-12), now: now) == "12s ago")
    #expect(RelativeActivityFormatter.describe(since: now.addingTimeInterval(-120), now: now) == "2m ago")
    #expect(RelativeActivityFormatter.describe(since: now.addingTimeInterval(-7_200), now: now) == "2h ago")
}

