# Floui

Floui is a macOS 15+ Apple Silicon workspace orchestrator for terminal + browser development workflows.

## Current State

This repository now contains the **Phase 1 foundation** of the plan:

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
- Status event JSON-line codec + pill state machine
  - file tailing ingestion (`StatusEventFileIngestor`) with partial-line and truncation handling
- Browser orchestration services with Apple Events adapters
  - profile-aware chromium remote debugging port propagation
  - `about:blank` fallback when no browser URL is provided
  - safer AppleScript generation for tab creation and bounds targeting by window ID
- Ghostty abstraction + concrete runtime bridge (`GhosttyRuntimeBridge`) via dynamic `libghostty` C symbols
- Permission onboarding + health reporting (`PermissionOnboardingController`, `PermissionHealthEvaluator`)
- CDP ingestion stack:
  - `ChromiumDevToolsAdapter` target cache + lifecycle stream handling
  - `URLSessionCDPClient` real websocket client for Chrome/Brave CDP
  - `DevToolsPillCoordinator` + mapper for fixed-pill updates
- Workspace persistence:
  - `JSONWorkspaceStateStore` for restoring/saving layout + last session metadata
  - app bootstrap restores persisted state before falling back to sample workspace
  - state is persisted on layout changes and non-active scene transitions
- `floui-cli` wrapper that emits structured `task.started/task.done` JSON events
- Local `xcodebuild` test scripts aligned to TDD flow

## Project Layout

- `Sources/FlouiCore`: shared interfaces and common domain types.
- `Sources/WorkspaceCore`: workspace schema, parser, reducer, restore planning.
- `Sources/StatusPills`: status event schema + reducer/state machine.
- `Sources/TerminalHost`: terminal engines, session manager, status emitter.
- `Sources/BrowserOrchestrator`: browser layout/orchestration + adapters.
- `Sources/FlouiApp`: SwiftUI macOS shell.
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
```

`test-e2e-real` requires explicit opt-in:

```bash
FLOUI_REAL_E2E=1 ./scripts/test-e2e-real
```

## Notes on External Integrations

- Ghostty uses a concrete runtime adapter that loads `libghostty` dynamically and calls a pinned symbol contract (`ghostty_floui_*`).
- Safari support is launch/tile/script oriented.
- Chrome/Brave support CDP target lifecycle ingestion via `URLSessionCDPClient` + `ChromiumDevToolsAdapter`.
- Direct notarized distribution and in-app update wiring are planned in hardening/release phase.
