# Floui

Floui is a macOS 15+ Apple Silicon workspace orchestrator for terminal + browser development workflows.

## Current State

This repository now contains a working iterative implementation of the architecture:

- Native Swift modular architecture (Swift 6.2, macOS 15+)
- SwiftUI app shell with:
  - workspace sidebar
  - horizontally scrollable mini-window canvas
  - fixed status-pill rail
- Decision-complete core interfaces:
  - `TerminalEngine`
  - `BrowserAdapter`
  - `DevToolsAdapter`
  - harness interfaces (`Clock`, `ProcessRunner`, `SocketTransport`, `AppleEventClient`, `CDPClient`, `TerminalSurfaceBridge`)
- Workspace manifest YAML schema + parser + validation
- Workspace layout reducer and restore planner (`autoRun` always false)
  - tab selection + next/previous tab cycling actions for keyboard shortcuts
- Status event JSON-line codec + pill state machine
  - file tailing ingestion (`StatusEventFileIngestor`) with partial-line and truncation handling
- Browser orchestration services with Apple Events adapters
  - profile-aware chromium remote debugging port propagation
  - `about:blank` fallback when no browser URL is provided
  - safer AppleScript generation for tab creation and bounds targeting by window ID
  - recovery advisor and actionable permission/browser failure guidance
  - bounded AppleScript execution via client-side timeout wrapping
  - graph-derived browser tiling from workspace columns/windows
  - auto-apply caching so identical workspace layouts do not relaunch browsers repeatedly
- Ghostty abstraction + concrete runtime bridge (`GhosttyRuntimeBridge`) via dynamic `libghostty` C symbols
- Terminal workspace runtime (`TerminalWorkspaceRuntime`) with pane lifecycle tracking for terminal tabs
  - `GhosttyFirstTerminalEngine` prefers Ghostty and falls back to external process sessions when `libghostty` is unavailable
  - external terminal sessions now support stdin forwarding, stdout/stderr ingestion, resize status updates, and exit propagation
- Permission onboarding + health reporting (`PermissionOnboardingController`, `PermissionHealthEvaluator`)
- CDP ingestion stack:
  - `ChromiumDevToolsAdapter` target cache + lifecycle stream handling
  - `URLSessionCDPClient` real websocket client for Chrome/Brave CDP
  - `DevToolsPillCoordinator` + mapper for fixed-pill updates
- Workspace persistence:
  - `JSONWorkspaceStateStore` for restoring/saving layout + last session metadata
  - app bootstrap restores persisted state before falling back to sample workspace
  - state is persisted on layout changes and non-active scene transitions
- App-shell orchestration:
  - `WorkspaceAutomationCoordinator` coordinates restore priming, terminal preparation, and browser auto-apply from the active workspace
  - restored terminal panes stay suspended until explicitly started, so persisted commands are not rerun automatically
- App-shell presentation:
  - card-based workspace sidebar with per-workspace activity summaries
  - workspace cycling/focus reducer actions and tested presentation helpers for pill/workspace telemetry
  - global task runner sidebar for repo-aware package scripts, Docker Compose flows, Make targets, SwiftPM commands, and Xcode launch actions across terminal directories
  - Docker Compose runtime inspection in the task runner sidebar, including per-service state, health, and published ports
  - live runtime sidebar for cross-workspace shell status, active commands, cwd, and branch context
- Shell-aware terminal context:
  - interactive `zsh`/`bash` launches are instrumented so panes report cwd, git branch, running command, and prompt-ready transitions back into Floui
  - shell markers are stripped from visible transcript output before scrollback is rendered
- Terminal transcript UX:
  - searchable AppKit-backed scrollback view with text selection and copy support
  - larger scrollback retention (5,000 lines per pane)
  - pane chrome for find/copy/paste plus recent-command rerun and interrupt controls
- `floui-cli` wrapper that emits structured `task.started/task.done` JSON events
- Local `xcodebuild` test scripts aligned to TDD flow
- Release hardening scaffolding:
  - deterministic `.app` bundle generation around the SwiftPM release binary
  - embedded Sparkle updater runtime for bundled releases
  - Developer ID signing / notarization / artifact packaging scripts
  - Sparkle-compatible bundle metadata + appcast generation hook

## Interaction Notes

- Tab shortcuts: `Cmd+Shift+]` for next tab, `Cmd+Shift+[` for previous tab.
- Workspace shortcuts: `Opt+Cmd+Right` for next workspace, `Opt+Cmd+Left` for previous workspace, `Opt+Cmd+L` to re-apply browser layout.
- Terminal tabs are now live runtime panes backed by `TerminalWorkspaceRuntime` (session state + input forwarding).
- Terminal startup now prefers Ghostty automatically and falls back to external shell execution when Ghostty is unavailable.
- Interactive `zsh`/`bash` panes now report live cwd, branch, and active-command state into the shell UI and runtime sidebar.
- Restored terminal panes show prior command metadata but require an explicit Start action before launching again.
- Browser orchestration can be triggered from the fixed-pill rail using `Apply Layout`; failures surface recovery steps in-app.
- Browser layouts also auto-apply on workspace activation, scope permission checks to the browsers actually used in the workspace, and focus the active browser tab when a matching URL is present.
- The shell now highlights the focused mini-window, exposes workspace activity summaries, and keeps pill telemetry visible with progress and alert counts.
- Terminal tabs can declare a `workingDirectory`; the sidebar task runner uses that context to discover scripts/containers and dispatch quick-run commands back into the matching shell.
- The task runner also inspects `docker compose ps --format json` for detected repos so service health and running/stopped state stay visible beside discovered compose actions.
- The live runtime rail now classifies matched repo tasks versus docker/manual commands and exposes stop/rerun actions per pane.
- Terminal panes expose searchable selectable scrollback, copy/paste helpers, recent command chips, and interrupt/rerun actions, but this is still not a full Warp/VS Code-class terminal emulator yet.

## Project Layout

- `Sources/FlouiCore`: shared interfaces and common domain types.
- `Sources/WorkspaceCore`: workspace schema, parser, reducer, restore planning.
- `Sources/StatusPills`: status event schema + reducer/state machine.
- `Sources/TerminalHost`: terminal engines, session manager, status emitter.
- `Sources/BrowserOrchestrator`: browser layout/orchestration + adapters.
- `Sources/FlouiApp`: SwiftUI macOS shell.
- `Sources/FlouiApp/RuntimeInspector.swift`: shared runtime inspection services for external dev tooling state such as Docker Compose.
- `Sources/floui-cli`: wrapper command for structured task events.
- `Tests/*`: core, integration, hybrid E2E, and real E2E test suites.
- `scripts/*`: local xcodebuild gates.

## Build

```bash
swift build
```

## Run App

```bash
swift run FlouiApp
```

To enable live pill updates from wrapper events, point both app and wrappers to the same JSONL file:

```bash
export FLOUI_STATUS_FILE="$HOME/Library/Application Support/Floui/status-events.jsonl"
swift run FlouiApp
```

`swift run FlouiApp` intentionally keeps the updater disabled because Sparkle only runs correctly from a bundled `.app` with release metadata.

## Run CLI Wrapper

```bash
swift run floui-cli run claude-code --workspace default --pane pill-claude -- /usr/bin/env echo hello
```

## TDD Test Commands

```bash
./scripts/test-core
./scripts/test-integration
./scripts/test-e2e-hybrid
./scripts/test-e2e-real
./scripts/test-release-tooling
```

`test-e2e-real` requires explicit opt-in:

```bash
FLOUI_REAL_E2E=1 ./scripts/test-e2e-real
```

## Notes on External Integrations

- Ghostty uses a concrete runtime adapter that loads `libghostty` dynamically and calls a pinned symbol contract (`ghostty_floui_*`).
- Safari support is launch/tile/script oriented.
- Chrome/Brave support CDP target lifecycle ingestion via `URLSessionCDPClient` + `ChromiumDevToolsAdapter`.
- Direct notarized distribution is now scaffolded via the release scripts documented in [docs/release.md](/Users/lukaspribik/Documents/Work/Floui/docs/release.md).
- Bundled releases expose a real Sparkle-backed update flow via `Check for Updates…` and the app settings window.
