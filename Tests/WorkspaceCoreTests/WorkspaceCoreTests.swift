import Foundation
import FlouiCore
import Testing
import WorkspaceCore

@Test("Workspace manifest parser decodes valid YAML")
func parseValidManifest() throws {
    let yaml = """
    id: default
    name: Default
    version: 1
    columns:
      - id: col-1
        width: 420
        windows:
          - id: win-1
            activeTabID: term-1
            tabs:
              - id: term-1
                title: Terminal
                type: terminal
                command: ["/bin/zsh"]
              - id: browser-1
                title: Dev
                type: browser
                browser: chrome
                url: https://example.com
    fixedPills:
      - id: pill-1
        title: Claude
        source: claude-code
    shortcuts:
      - id: next-tab
        command: tab.next
        key: cmd+shift+]
    browserProfiles:
      - browser: chrome
        profileName: floui-dev
        remoteDebuggingPort: 9222
    """

    let parser = WorkspaceManifestParser()
    let manifest = try parser.parse(yaml: yaml)

    #expect(manifest.id == "default")
    #expect(manifest.columns.count == 1)
    #expect(manifest.fixedPills.count == 1)
}

@Test("Workspace manifest parser rejects missing active tab references")
func rejectInvalidActiveTab() throws {
    let yaml = """
    id: default
    name: Default
    version: 1
    columns:
      - id: col-1
        windows:
          - id: win-1
            activeTabID: missing-tab
            tabs:
              - id: term-1
                title: Terminal
                type: terminal
                command: ["/bin/zsh"]
    fixedPills: []
    shortcuts: []
    browserProfiles: []
    """

    let parser = WorkspaceManifestParser()

    #expect(throws: WorkspaceManifestError.invalidReference("activeTabID missing-tab missing in window win-1")) {
        try parser.parse(yaml: yaml)
    }
}

@Test("Layout reducer loads and switches workspace")
func layoutReducerLoadAndSwitch() {
    let primary = WorkspaceManifest(
        id: "w1",
        name: "First",
        version: 1,
        columns: [WorkspaceColumnManifest(id: "c1", windows: [WorkspaceMiniWindowManifest(id: "m1", tabs: [WorkspaceTabManifest(id: "t1", title: "A", type: .terminal)])])]
    )
    let secondary = WorkspaceManifest(
        id: "w2",
        name: "Second",
        version: 1,
        columns: [WorkspaceColumnManifest(id: "c2", windows: [WorkspaceMiniWindowManifest(id: "m2", tabs: [WorkspaceTabManifest(id: "t2", title: "B", type: .terminal)])])]
    )

    var state = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &state, action: .loadManifest(primary))
    WorkspaceLayoutReducer.reduce(state: &state, action: .loadManifest(secondary))
    WorkspaceLayoutReducer.reduce(state: &state, action: .setHorizontalOffset(200))
    WorkspaceLayoutReducer.reduce(state: &state, action: .switchWorkspace("w2"))

    #expect(state.activeWorkspaceID == "w2")
    #expect(state.horizontalOffset == 0)
    #expect(state.workspaceOrder == ["w1", "w2"])
}

@Test("Restore planner never auto-runs commands")
func restorePlannerNeverAutoRuns() {
    let manifest = WorkspaceManifest(
        id: "w1",
        name: "First",
        version: 1,
        columns: [
            WorkspaceColumnManifest(
                id: "c1",
                windows: [
                    WorkspaceMiniWindowManifest(
                        id: "m1",
                        tabs: [
                            WorkspaceTabManifest(id: "term-1", title: "A", type: .terminal, command: ["/bin/zsh"]),
                            WorkspaceTabManifest(id: "browser-1", title: "B", type: .browser, browser: .chrome, url: "https://example.com"),
                        ]
                    )
                ]
            )
        ]
    )

    let metadata = LastSessionMetadata(paneCommands: ["term-1": ["/usr/bin/env", "echo", "hello"]])

    let planner = WorkspaceRestorePlanner()
    let plan = planner.makePlan(manifest: manifest, metadata: metadata)

    #expect(plan.workspaceID == "w1")
    #expect(plan.panes.count == 2)
    #expect(plan.panes.allSatisfy { $0.autoRun == false })
    #expect(plan.panes.first(where: { $0.paneID == "term-1" })?.command == ["/usr/bin/env", "echo", "hello"])
}

@Test("Workspace state store round-trips layout and metadata")
func workspaceStateStoreRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("workspace-state.json")
    let store = JSONWorkspaceStateStore(fileURL: fileURL)

    let manifest = WorkspaceManifest(
        id: "w1",
        name: "Saved",
        version: 1,
        columns: [WorkspaceColumnManifest(id: "c1", windows: [WorkspaceMiniWindowManifest(id: "m1", tabs: [WorkspaceTabManifest(id: "t1", title: "Terminal", type: .terminal)])])]
    )
    var layout = WorkspaceLayoutState()
    WorkspaceLayoutReducer.reduce(state: &layout, action: .loadManifest(manifest))
    WorkspaceLayoutReducer.reduce(state: &layout, action: .setHorizontalOffset(320))
    WorkspaceLayoutReducer.reduce(state: &layout, action: .pinPill("pill-1"))

    let metadata = LastSessionMetadata(paneCommands: ["t1": ["/bin/zsh"]])
    let savedAt = Date(timeIntervalSince1970: 1_700_001_000)
    let snapshot = WorkspacePersistenceSnapshot(
        layoutState: layout,
        lastSessionMetadata: metadata,
        savedAt: savedAt
    )

    try await store.save(snapshot)
    let loaded = try await store.load()

    #expect(loaded == snapshot)
}

@Test("Workspace state store returns nil for missing file")
func workspaceStateStoreMissingFile() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("workspace-state.json")
    let store = JSONWorkspaceStateStore(fileURL: fileURL)

    let loaded = try await store.load()
    #expect(loaded == nil)
}

@Test("Workspace state store throws decode error for malformed JSON")
func workspaceStateStoreMalformedData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("workspace-state.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "{\"invalid\":true}".write(to: fileURL, atomically: true, encoding: .utf8)

    let store = JSONWorkspaceStateStore(fileURL: fileURL)

    await #expect(throws: WorkspaceStateStoreError.decodeFailed) {
        _ = try await store.load()
    }
}
