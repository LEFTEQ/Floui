import Foundation
import FlouiCore
import StatusPills
import Testing

@Test("StatusEventCodec encodes and decodes JSON lines")
func codecRoundTrip() throws {
    let codec = StatusEventCodec()
    let event = StatusEvent(
        event: .taskProgress,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        severity: .info,
        message: "running",
        progress: 0.35,
        metadata: ["step": "compile"]
    )

    let line = try codec.encode(event)
    let decoded = try codec.decode(line: line)

    #expect(decoded == event)
}

@Test("Status reducer handles start alert done lifecycle")
func reducerLifecycle() {
    var state: StatusPillState?
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    StatusPillReducer.reduce(state: &state, event: StatusEvent(
        event: .taskStarted,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: baseDate,
        message: "started"
    ))

    StatusPillReducer.reduce(state: &state, event: StatusEvent(
        event: .taskAlert,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: baseDate.addingTimeInterval(2),
        severity: .warning,
        message: "needs attention"
    ))

    StatusPillReducer.reduce(state: &state, event: StatusEvent(
        event: .taskDone,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: baseDate.addingTimeInterval(5),
        message: "done"
    ))

    #expect(state != nil)
    #expect(state?.isRunning == false)
    #expect(state?.unreadAlerts == 1)
    #expect(state?.progress == 1)
}

@Test("Heartbeat timeout escalates severity")
func heartbeatTimeoutEscalates() {
    var state = StatusPillState(
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "coder-cli",
        lastEventAt: Date(timeIntervalSince1970: 100),
        lastHeartbeatAt: Date(timeIntervalSince1970: 100),
        isRunning: true,
        severity: .info,
        message: "healthy"
    )

    StatusPillReducer.checkHeartbeatTimeout(
        state: &state,
        now: Date(timeIntervalSince1970: 170),
        timeout: 30
    )

    #expect(state.severity == .warning)
    #expect(state.message == "Heartbeat timeout")
    #expect(state.unreadAlerts == 1)
}

@Test("StatusPillStore aggregates by pane")
func pillStoreAggregatesByPane() {
    var store = StatusPillStore()
    store.apply(StatusEvent(
        event: .taskStarted,
        workspaceID: "default",
        paneID: "pill-1",
        taskID: "task-1",
        source: "claude-code",
        timestamp: Date(),
        message: "hello"
    ))

    #expect(store.pillsByPaneID.count == 1)
    #expect(store.pillsByPaneID["pill-1"]?.message == "hello")
}

actor StubDevToolsAdapter: DevToolsAdapter {
    private var continuations: [String: AsyncStream<DevToolsEvent>.Continuation] = [:]

    func connect(instance _: BrowserKind, port _: Int) async throws {}

    func listTargets() async throws -> [DevToolsTarget] {
        []
    }

    func subscribeTargetEvents(targetID: String) async -> AsyncStream<DevToolsEvent> {
        AsyncStream { continuation in
            continuations[targetID] = continuation
        }
    }

    func close() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func emit(targetID: String, event: DevToolsEvent) {
        continuations[targetID]?.yield(event)
    }

    func finish(targetID: String) {
        continuations[targetID]?.finish()
    }
}

@Test("DevTools event mapper converts adapter events to status events")
func devToolsMapperConvertsEvents() {
    let mapper = DevToolsStatusEventMapper()
    let binding = DevToolsPillBinding(
        workspaceID: "default",
        paneID: "pill-devtools",
        taskID: "cdp:target-1",
        targetID: "target-1",
        source: "chrome-devtools"
    )
    let now = Date(timeIntervalSince1970: 1_700_000_200)

    let connected = mapper.map(event: .connected, binding: binding, now: now)
    let updated = mapper.map(
        event: .targetUpdated(DevToolsTarget(id: "target-1", title: "App", url: "https://app.dev")),
        binding: binding,
        now: now.addingTimeInterval(1)
    )
    let disconnected = mapper.map(event: .disconnected, binding: binding, now: now.addingTimeInterval(2))

    #expect(connected.event == .taskStarted)
    #expect(updated.event == .taskProgress)
    #expect(disconnected.event == .taskAlert)
    #expect(disconnected.severity == .warning)
}

@Test("DevTools pill coordinator ingests stream and updates fixed-pill state")
func devToolsCoordinatorUpdatesStore() async throws {
    let adapter = StubDevToolsAdapter()
    let coordinator = DevToolsPillCoordinator(adapter: adapter)

    let binding = DevToolsPillBinding(
        workspaceID: "default",
        paneID: "pill-devtools",
        taskID: "cdp:target-1",
        targetID: "target-1",
        source: "chrome-devtools"
    )

    await coordinator.bind(binding: binding)

    await adapter.emit(targetID: "target-1", event: .connected)
    await adapter.emit(
        targetID: "target-1",
        event: .targetUpdated(DevToolsTarget(id: "target-1", title: "Dev", url: "https://dev.local"))
    )
    await adapter.emit(targetID: "target-1", event: .disconnected)
    await adapter.finish(targetID: "target-1")

    try? await Task.sleep(nanoseconds: 30_000_000)

    let store = await coordinator.storeSnapshot()
    let pill = store.pillsByPaneID["pill-devtools"]

    #expect(pill != nil)
    #expect(pill?.unreadAlerts == 1)
    #expect(pill?.severity == .warning)
}
