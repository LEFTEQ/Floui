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

- `Sources/TerminalHost/GhosttyRuntimeBridge.swift`
  - Concrete Ghostty runtime integration.
  - Dynamic `libghostty` loader (`dlopen`/`dlsym`) + typed symbol bridge + `GhosttyRuntimeBridge`.

- `Sources/BrowserOrchestrator/BrowserOrchestrator.swift`
  - Browser layout planning/orchestration and concrete integration adapters.
  - Includes `ChromiumDevToolsAdapter` target lifecycle cache and `URLSessionCDPClient`.

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
