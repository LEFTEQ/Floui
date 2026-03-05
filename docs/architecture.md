# Floui Architecture (Foundation)

## Platform

- macOS 15+
- Apple Silicon only (arm64)
- Swift 6.2
- SwiftUI shell with AppKit-compatible extension points

## Core Contracts

### Terminal

`TerminalEngine`
- `startSession(config)`
- `attachView(sessionID, surfaceID)`
- `sendInput(sessionID, input)`
- `resize(sessionID, cols, rows)`
- `subscribeEvents(sessionID)`

`GhosttyTerminalEngine` is implemented as adapter-over-bridge.
`GhosttyRuntimeBridge` provides a concrete `libghostty` runtime integration through a dynamic symbol contract.

### Browser

`BrowserAdapter`
- `launch`
- `listWindows`
- `setWindowBounds`
- `listTabs`
- `focusTab`
- `openDevTools`

`BrowserWorkspaceOrchestrator` applies workspace browser plans through adapters.
`BrowserRecoveryAdvisor` maps orchestration failures into actionable recovery steps for UI.

### DevTools

`DevToolsAdapter`
- `connect`
- `listTargets`
- `subscribeTargetEvents`
- `close`

`ChromiumDevToolsAdapter` handles CDP bootstrap commands, target cache maintenance, and target lifecycle stream fan-out.
`URLSessionCDPClient` provides a real websocket-backed CDP client for Chrome/Brave.

### Permissions

- `PermissionOnboardingController` drives onboarding checks/requests.
- `PermissionHealthEvaluator` derives deterministic startup health reports for UI + gate logic.

## Workspace Model

- Source of truth: YAML manifests (`WorkspaceManifest`)
- Reducer-managed in-memory state (`WorkspaceLayoutState`)
- Restore strategy: metadata + layout restore, no automatic command rerun

## Status Pills

- Ingest JSON lines (`StatusEventCodec`)
- Lifecycle reducer (`StatusPillReducer`)
- Heartbeat timeout handling and alert escalation
- DevTools target lifecycle mapping via `DevToolsStatusEventMapper` + `DevToolsPillCoordinator`

## Terminal Runtime

- `TerminalWorkspaceRuntime` tracks per-pane terminal session lifecycle.
- Terminal panes can be activated lazily from UI tabs, receive event snapshots, and accept input forwarding.

## TDD Process

- Core modules are expected to be test-first.
- Integration layers require contract tests.
- Real-stack tests are opt-in with `FLOUI_REAL_E2E=1`.

## Test Gates

- `scripts/test-core`
- `scripts/test-integration`
- `scripts/test-e2e-hybrid`
- `scripts/test-e2e-real`
