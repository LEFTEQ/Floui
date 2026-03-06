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

- `Sources/FlouiApp/FlouiAppMain.swift`
  - App shell runtime wiring.
  - `TerminalRuntimeViewModel` now owns shell-aware quick actions (`interrupt`, `rerunRecentCommand`, generic `runCommand`) so the runtime sidebar and pane chrome reuse the same dispatch path instead of duplicating terminal-control logic in views.

- `Sources/FlouiApp/GlobalTaskRunner.swift`
  - Reusable repository-discovery and quick-run orchestration for dev workflows.
  - Includes `GlobalTaskDiscoveryService`, `GlobalTaskRunnerViewModel`, terminal-context modeling, package-script/docker/make/swift/Xcode detection, and deterministic quick-run command dispatch assumptions.

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
- Shell-aware terminal context should flow through `ShellIntegration.swift` and `TerminalIntegration.swift`; avoid parsing ad-hoc prompt text directly in views or reducers.
- Transcript rendering/search/selection should go through `TerminalTextViews.swift`; avoid rebuilding custom transcript widgets in individual panes.
- Runtime control actions should route through `TerminalRuntimeViewModel`; avoid sending raw terminal control sequences directly from SwiftUI views.
