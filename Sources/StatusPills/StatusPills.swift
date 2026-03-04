import FlouiCore
import Foundation

public enum StatusEventType: String, Codable, CaseIterable, Sendable {
    case taskStarted = "task.started"
    case taskProgress = "task.progress"
    case taskAlert = "task.alert"
    case taskDone = "task.done"
    case taskHeartbeat = "task.heartbeat"
}

public enum PillSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case critical
}

public struct StatusEvent: Codable, Equatable, Sendable {
    public var event: StatusEventType
    public var workspaceID: String
    public var paneID: String
    public var taskID: String
    public var source: String
    public var timestamp: Date
    public var severity: PillSeverity?
    public var message: String?
    public var progress: Double?
    public var metadata: [String: String]?

    public init(
        event: StatusEventType,
        workspaceID: String,
        paneID: String,
        taskID: String,
        source: String,
        timestamp: Date,
        severity: PillSeverity? = nil,
        message: String? = nil,
        progress: Double? = nil,
        metadata: [String: String]? = nil
    ) {
        self.event = event
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.taskID = taskID
        self.source = source
        self.timestamp = timestamp
        self.severity = severity
        self.message = message
        self.progress = progress
        self.metadata = metadata
    }
}

public enum StatusEventParsingError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidJSON(String)
}

public struct StatusEventCodec {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    public func decode(line: String) throws -> StatusEvent {
        guard let data = line.data(using: .utf8) else {
            throw StatusEventParsingError.invalidEncoding
        }

        do {
            return try decoder.decode(StatusEvent.self, from: data)
        } catch {
            throw StatusEventParsingError.invalidJSON(error.localizedDescription)
        }
    }

    public func encode(_ event: StatusEvent) throws -> String {
        let data = try encoder.encode(event)
        guard let line = String(data: data, encoding: .utf8) else {
            throw StatusEventParsingError.invalidEncoding
        }
        return line
    }
}

public struct StatusPillState: Equatable, Sendable {
    public var workspaceID: String
    public var paneID: String
    public var taskID: String
    public var source: String
    public var lastEventAt: Date
    public var lastHeartbeatAt: Date?
    public var isRunning: Bool
    public var progress: Double?
    public var severity: PillSeverity
    public var message: String
    public var unreadAlerts: Int

    public init(
        workspaceID: String,
        paneID: String,
        taskID: String,
        source: String,
        lastEventAt: Date,
        lastHeartbeatAt: Date? = nil,
        isRunning: Bool,
        progress: Double? = nil,
        severity: PillSeverity,
        message: String,
        unreadAlerts: Int = 0
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.taskID = taskID
        self.source = source
        self.lastEventAt = lastEventAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.isRunning = isRunning
        self.progress = progress
        self.severity = severity
        self.message = message
        self.unreadAlerts = unreadAlerts
    }
}

public enum StatusPillReducer {
    public static func reduce(state: inout StatusPillState?, event: StatusEvent) {
        if state == nil {
            state = StatusPillState(
                workspaceID: event.workspaceID,
                paneID: event.paneID,
                taskID: event.taskID,
                source: event.source,
                lastEventAt: event.timestamp,
                isRunning: event.event != .taskDone,
                severity: event.severity ?? .info,
                message: event.message ?? "",
                unreadAlerts: event.event == .taskAlert ? 1 : 0
            )
        }

        guard var current = state else {
            return
        }

        current.lastEventAt = event.timestamp
        current.taskID = event.taskID
        current.source = event.source

        if let progress = event.progress {
            current.progress = min(max(progress, 0), 1)
        }

        if let message = event.message {
            current.message = message
        }

        if let severity = event.severity {
            current.severity = severity
        }

        switch event.event {
        case .taskStarted:
            current.isRunning = true
            current.severity = current.severity == .critical ? .warning : .info

        case .taskProgress:
            current.isRunning = true

        case .taskAlert:
            current.isRunning = true
            current.unreadAlerts += 1
            if current.severity == .info {
                current.severity = .warning
            }

        case .taskDone:
            current.isRunning = false
            current.progress = 1
            if current.severity != .critical {
                current.severity = .info
            }

        case .taskHeartbeat:
            current.lastHeartbeatAt = event.timestamp
            current.isRunning = true
        }

        state = current
    }

    public static func checkHeartbeatTimeout(state: inout StatusPillState, now: Date, timeout: TimeInterval) {
        guard state.isRunning else {
            return
        }

        guard let lastHeartbeatAt = state.lastHeartbeatAt else {
            return
        }

        if now.timeIntervalSince(lastHeartbeatAt) > timeout {
            state.severity = .warning
            state.message = "Heartbeat timeout"
            state.unreadAlerts += 1
        }
    }
}

public struct StatusPillStore: Sendable {
    public private(set) var pillsByPaneID: [String: StatusPillState]

    public init(pillsByPaneID: [String: StatusPillState] = [:]) {
        self.pillsByPaneID = pillsByPaneID
    }

    public mutating func apply(_ event: StatusEvent) {
        var current = pillsByPaneID[event.paneID]
        StatusPillReducer.reduce(state: &current, event: event)
        if let current {
            pillsByPaneID[event.paneID] = current
        }
    }
}

public struct DevToolsPillBinding: Equatable, Sendable {
    public var workspaceID: String
    public var paneID: String
    public var taskID: String
    public var targetID: String
    public var source: String

    public init(workspaceID: String, paneID: String, taskID: String, targetID: String, source: String) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.taskID = taskID
        self.targetID = targetID
        self.source = source
    }

    fileprivate var key: String {
        "\(workspaceID)::\(paneID)::\(targetID)"
    }
}

public struct DevToolsStatusEventMapper {
    public init() {}

    public func map(event: DevToolsEvent, binding: DevToolsPillBinding, now: Date) -> StatusEvent {
        switch event {
        case .connected:
            return StatusEvent(
                event: .taskStarted,
                workspaceID: binding.workspaceID,
                paneID: binding.paneID,
                taskID: binding.taskID,
                source: binding.source,
                timestamp: now,
                severity: .info,
                message: "DevTools connected",
                metadata: ["targetID": binding.targetID]
            )

        case let .targetUpdated(target):
            let message = target.title.isEmpty ? "Target updated" : "Target: \(target.title)"
            return StatusEvent(
                event: .taskProgress,
                workspaceID: binding.workspaceID,
                paneID: binding.paneID,
                taskID: binding.taskID,
                source: binding.source,
                timestamp: now,
                severity: .info,
                message: message,
                progress: nil,
                metadata: ["targetID": target.id, "url": target.url]
            )

        case .disconnected:
            return StatusEvent(
                event: .taskAlert,
                workspaceID: binding.workspaceID,
                paneID: binding.paneID,
                taskID: binding.taskID,
                source: binding.source,
                timestamp: now,
                severity: .warning,
                message: "DevTools disconnected",
                metadata: ["targetID": binding.targetID]
            )
        }
    }
}

public actor DevToolsPillCoordinator {
    private let adapter: DevToolsAdapter
    private let clock: Clock
    private let mapper: DevToolsStatusEventMapper
    private var store = StatusPillStore()
    private var watchers: [String: Task<Void, Never>] = [:]

    public init(adapter: DevToolsAdapter, clock: Clock = SystemClock(), mapper: DevToolsStatusEventMapper = .init()) {
        self.adapter = adapter
        self.clock = clock
        self.mapper = mapper
    }

    public func bind(binding: DevToolsPillBinding) async {
        if watchers[binding.key] != nil {
            return
        }

        let stream = await adapter.subscribeTargetEvents(targetID: binding.targetID)
        let key = binding.key
        watchers[key] = Task {
            for await event in stream {
                await self.consume(event: event, binding: binding)
            }
            await self.unbind(key: key)
        }
    }

    public func unbind(binding: DevToolsPillBinding) {
        unbind(key: binding.key)
    }

    public func storeSnapshot() -> StatusPillStore {
        store
    }

    public func stopAll() async {
        for (_, task) in watchers {
            task.cancel()
        }
        watchers.removeAll()
        await adapter.close()
    }

    private func consume(event: DevToolsEvent, binding: DevToolsPillBinding) {
        let mapped = mapper.map(event: event, binding: binding, now: clock.now)
        store.apply(mapped)
    }

    private func unbind(key: String) {
        watchers[key]?.cancel()
        watchers.removeValue(forKey: key)
    }
}
