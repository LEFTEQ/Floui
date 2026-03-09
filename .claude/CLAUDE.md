# Floui Project Memory

## Shared Modules

- `Sources/FlouiCore/FlouiCore.swift`
  - Shared contracts and primitives used across the app.
  - Includes: `TerminalEngine`, `BrowserAdapter`, `DevToolsAdapter`, harness boundaries.

- `Sources/WorkspaceCore/WorkspaceCore.swift`
  - Canonical workspace model and YAML schema parser.
  - Includes layout reducer, restore planner, and JSON persistence store (`JSONWorkspaceStateStore`) for layout + session metadata snapshots.

- `Sources/StatusPills/StatusPills.swift`
  - Shared status event schema and reducer for fixed pill state.
  - Includes `DevToolsStatusEventMapper` and `DevToolsPillCoordinator` for CDP-to-pill ingestion.
  - Includes `StatusEventFileTailer` + `StatusEventFileIngestor` for JSONL status ingestion from wrapper output files.

- `Sources/TerminalHost/TerminalHost.swift`
  - Terminal engine adapters and session manager.
  - Includes `TerminalWorkspaceRuntime` and `TerminalPaneRuntimeState` for pane lifecycle, event consumption, terminal input forwarding, and resize propagation.
  - Includes `GhosttyFirstTerminalEngine` and `DefaultTerminalEngineFactory` for Ghostty-first runtime selection with external-process fallback.

- `Sources/TerminalHost/TerminalIntegration.swift`
  - Reusable shell-marker parser for live terminal context.
  - Includes `TerminalIntegrationParser` and `TerminalIntegrationEvent` for extracting cwd, git branch, active command, and prompt-ready state from shell integration output while keeping transcript output clean.

- `Sources/TerminalHost/GhosttyRuntimeBridge.swift`
  - Concrete Ghostty runtime integration.
  - Dynamic `libghostty` loader (`dlopen`/`dlsym`) + typed symbol bridge + `GhosttyRuntimeBridge`.

- `Sources/FlouiApp/AppShellPresentation.swift`
  - Reusable presentation helpers for the SwiftUI shell.
  - Includes `WorkspacePresentationSummary`, `FixedPillPresentation`, and `RelativeActivityFormatter` so sidebar/header/pill views share deterministic formatting logic instead of duplicating it in view bodies.
  - Includes `TerminalRuntimePanelPresentation` and `TerminalRuntimeActivityKind` for the live-runtime sidebar cards, task classification, docker/manual command detection, status counts, and terminal ordering logic.

- `Sources/FlouiApp/ShellIntegration.swift`
  - Shared shell bootstrapper for interactive terminal sessions.
  - Prepares app-support integration files and rewrites supported interactive `zsh`/`bash` launches so panes report cwd, branch, and active command context back to Floui.

- `Sources/FlouiApp/TerminalTextViews.swift`
  - Shared AppKit-backed transcript surface.
  - Includes `SelectableTerminalTranscriptView` for searchable, selectable, copy-friendly scrollback inside SwiftUI terminal panes.
  - Includes `HistoryAwareTerminalInputField` + `TerminalCommandTextField` for command-history aware terminal input (`up/down`) with native AppKit command handling.

- `Sources/FlouiApp/TerminalInteraction.swift`
  - Shared terminal interaction logic and control hooks.
  - Includes `TerminalTranscriptSearchNavigator` for deterministic transcript search matching/selection cycling and `TerminalCommandHistoryState` for input draft/history traversal semantics.
  - Includes `TerminalTranscriptController` for transcript copy/select/scroll/focus actions without embedding AppKit references in view reducers.

- `Sources/FlouiApp/FlouiAppMain.swift`
  - App shell runtime wiring.
  - `TerminalRuntimeViewModel` now owns shell-aware quick actions (`interrupt`, `rerunRecentCommand`, generic `runCommand`) so the runtime sidebar and pane chrome reuse the same dispatch path instead of duplicating terminal-control logic in views.

- `Sources/FlouiApp/GlobalTaskRunner.swift`
  - Reusable repository-discovery and quick-run orchestration for dev workflows.
  - Includes `GlobalTaskDiscoveryService`, `GlobalTaskRunnerViewModel`, terminal-context modeling, package-script/docker/make/swift/Xcode detection, Docker Compose manifest/service discovery, and deterministic quick-run command dispatch assumptions.

- `Sources/FlouiApp/RuntimeInspector.swift`
  - Reusable runtime inspection layer for external developer tooling state.
  - Includes `ComposeRuntimeInspectionService`, `ComposeRuntimeSnapshot`, and Docker Compose service-state parsing from `docker compose ps --format json` output so the task runner sidebar can show live runtime status without embedding process logic in SwiftUI views.

- `Sources/BrowserOrchestrator/BrowserOrchestrator.swift`
  - Browser layout planning/orchestration and concrete integration adapters.
  - Includes `ChromiumDevToolsAdapter` target lifecycle cache and `URLSessionCDPClient`.
  - Includes `CocoaAppleEventClient`, `BrowserOrchestrationError`, and `BrowserRecoveryAdvisor` for actionable browser recovery UX.
  - Includes `BrowserCanvasLayoutContext`, graph-derived `BrowserLayoutBuilder`, and `BrowserAutoApplyCoordinator` for deterministic browser tiling and cached auto-apply behavior.

- `Sources/Permissions/Permissions.swift`
  - Permission onboarding state machine, checker, and health evaluator/reporting.

## Testing Entry Points

- `scripts/test-core`
- `scripts/test-integration`
- `scripts/test-e2e-hybrid`
- `scripts/test-e2e-real`

## Integration Notes

- Ghostty integration stays behind `TerminalSurfaceBridge`; keep domain logic decoupled from symbol-level runtime details.
- Browser automation logic should remain in adapters; keep workspace reducers pure and deterministic.
- CDP event ingestion should map through `DevToolsStatusEventMapper` before touching pill store state.
- UI chrome should derive counts, tone, and relative-time labels from `AppShellPresentation.swift`; avoid re-implementing workspace/pill formatting inside views.
- Repo/task discovery should go through `GlobalTaskRunner.swift`; avoid ad-hoc filesystem parsing in SwiftUI views.
- External runtime inspection such as Docker Compose state should go through `RuntimeInspector.swift`; avoid shelling out from SwiftUI views or mixing command parsing into presentation code.
- Shell-aware terminal context should flow through `ShellIntegration.swift` and `TerminalIntegration.swift`; avoid parsing ad-hoc prompt text directly in views or reducers.
- Transcript rendering/search/selection should go through `TerminalTextViews.swift`; avoid rebuilding custom transcript widgets in individual panes.
- Terminal search matching/selection and command history traversal should go through `TerminalInteraction.swift`; avoid duplicating search-index and history-cursor logic in SwiftUI view bodies.
- Runtime control actions should route through `TerminalRuntimeViewModel`; avoid sending raw terminal control sequences directly from SwiftUI views.
