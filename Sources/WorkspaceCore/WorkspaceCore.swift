import FlouiCore
import Foundation
import Yams

public enum WorkspacePaneType: String, Codable, Sendable {
    case terminal
    case browser
    case pill
}

public struct WorkspaceTabManifest: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var type: WorkspacePaneType
    public var command: [String]?
    public var browser: BrowserKind?
    public var url: String?

    public init(
        id: String,
        title: String,
        type: WorkspacePaneType,
        command: [String]? = nil,
        browser: BrowserKind? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.command = command
        self.browser = browser
        self.url = url
    }
}

public struct WorkspaceMiniWindowManifest: Codable, Hashable, Sendable {
    public var id: String
    public var activeTabID: String?
    public var tabs: [WorkspaceTabManifest]

    public init(id: String, activeTabID: String? = nil, tabs: [WorkspaceTabManifest]) {
        self.id = id
        self.activeTabID = activeTabID
        self.tabs = tabs
    }
}

public struct WorkspaceColumnManifest: Codable, Hashable, Sendable {
    public var id: String
    public var width: Double?
    public var windows: [WorkspaceMiniWindowManifest]

    public init(id: String, width: Double? = nil, windows: [WorkspaceMiniWindowManifest]) {
        self.id = id
        self.width = width
        self.windows = windows
    }
}

public struct FixedPillManifest: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var source: String

    public init(id: String, title: String, source: String) {
        self.id = id
        self.title = title
        self.source = source
    }
}

public struct ShortcutBindingManifest: Codable, Hashable, Sendable {
    public var id: String
    public var command: String
    public var key: String

    public init(id: String, command: String, key: String) {
        self.id = id
        self.command = command
        self.key = key
    }
}

public struct BrowserProfileManifest: Codable, Hashable, Sendable {
    public var browser: BrowserKind
    public var profileName: String
    public var remoteDebuggingPort: Int?

    public init(browser: BrowserKind, profileName: String, remoteDebuggingPort: Int? = nil) {
        self.browser = browser
        self.profileName = profileName
        self.remoteDebuggingPort = remoteDebuggingPort
    }
}

public struct WorkspaceManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: Int
    public var columns: [WorkspaceColumnManifest]
    public var fixedPills: [FixedPillManifest]
    public var shortcuts: [ShortcutBindingManifest]
    public var browserProfiles: [BrowserProfileManifest]

    public init(
        id: String,
        name: String,
        version: Int,
        columns: [WorkspaceColumnManifest],
        fixedPills: [FixedPillManifest] = [],
        shortcuts: [ShortcutBindingManifest] = [],
        browserProfiles: [BrowserProfileManifest] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.columns = columns
        self.fixedPills = fixedPills
        self.shortcuts = shortcuts
        self.browserProfiles = browserProfiles
    }
}

public enum WorkspaceManifestError: Error, Equatable, Sendable {
    case decodeFailed(String)
    case emptyColumns
    case duplicateID(String)
    case invalidReference(String)
}

public struct WorkspaceManifestParser {
    public init() {}

    public func parse(yaml: String) throws -> WorkspaceManifest {
        do {
            let decoder = YAMLDecoder()
            let manifest = try decoder.decode(WorkspaceManifest.self, from: yaml)
            try validate(manifest)
            return manifest
        } catch let error as WorkspaceManifestError {
            throw error
        } catch {
            throw WorkspaceManifestError.decodeFailed(error.localizedDescription)
        }
    }

    public func validate(_ manifest: WorkspaceManifest) throws {
        guard !manifest.columns.isEmpty else {
            throw WorkspaceManifestError.emptyColumns
        }

        try ensureUnique(ids: manifest.columns.map(\.id), label: "column")
        try ensureUnique(ids: manifest.fixedPills.map(\.id), label: "fixed pill")
        try ensureUnique(ids: manifest.shortcuts.map(\.id), label: "shortcut")

        for column in manifest.columns {
            try ensureUnique(ids: column.windows.map(\.id), label: "window")
            for window in column.windows {
                try ensureUnique(ids: window.tabs.map(\.id), label: "tab")
                if let active = window.activeTabID,
                   !window.tabs.map(\.id).contains(active)
                {
                    throw WorkspaceManifestError.invalidReference("activeTabID \(active) missing in window \(window.id)")
                }
            }
        }
    }

    private func ensureUnique(ids: [String], label: String) throws {
        var seen = Set<String>()
        for id in ids {
            if seen.contains(id) {
                throw WorkspaceManifestError.duplicateID("\(label):\(id)")
            }
            seen.insert(id)
        }
    }
}

public struct WorkspaceLayoutState: Codable, Equatable, Sendable {
    public var activeWorkspaceID: String?
    public var workspaceOrder: [String]
    public var workspaces: [String: WorkspaceManifest]
    public var horizontalOffset: Double
    public var pinnedPills: Set<String>
    public var activeWindowIDByWorkspace: [String: String]

    public init(
        activeWorkspaceID: String? = nil,
        workspaceOrder: [String] = [],
        workspaces: [String: WorkspaceManifest] = [:],
        horizontalOffset: Double = 0,
        pinnedPills: Set<String> = [],
        activeWindowIDByWorkspace: [String: String] = [:]
    ) {
        self.activeWorkspaceID = activeWorkspaceID
        self.workspaceOrder = workspaceOrder
        self.workspaces = workspaces
        self.horizontalOffset = horizontalOffset
        self.pinnedPills = pinnedPills
        self.activeWindowIDByWorkspace = activeWindowIDByWorkspace
    }
}

public enum WorkspaceTabCycleDirection: Equatable, Sendable {
    case next
    case previous
}

public enum WorkspaceLayoutAction: Equatable, Sendable {
    case loadManifest(WorkspaceManifest)
    case switchWorkspace(String)
    case setHorizontalOffset(Double)
    case pinPill(String)
    case unpinPill(String)
    case selectTab(windowID: String, tabID: String)
    case cycleTab(direction: WorkspaceTabCycleDirection)
}

public enum WorkspaceLayoutReducer {
    public static func reduce(state: inout WorkspaceLayoutState, action: WorkspaceLayoutAction) {
        switch action {
        case let .loadManifest(manifest):
            state.workspaces[manifest.id] = manifest
            if !state.workspaceOrder.contains(manifest.id) {
                state.workspaceOrder.append(manifest.id)
            }
            state.activeWorkspaceID = state.activeWorkspaceID ?? manifest.id
            if state.activeWindowIDByWorkspace[manifest.id] == nil {
                state.activeWindowIDByWorkspace[manifest.id] = firstWindowID(in: manifest)
            }

        case let .switchWorkspace(workspaceID):
            if let manifest = state.workspaces[workspaceID] {
                state.activeWorkspaceID = workspaceID
                state.horizontalOffset = 0
                if state.activeWindowIDByWorkspace[workspaceID] == nil {
                    state.activeWindowIDByWorkspace[workspaceID] = firstWindowID(in: manifest)
                }
            }

        case let .setHorizontalOffset(offset):
            state.horizontalOffset = max(0, offset)

        case let .pinPill(pillID):
            state.pinnedPills.insert(pillID)

        case let .unpinPill(pillID):
            state.pinnedPills.remove(pillID)

        case let .selectTab(windowID, tabID):
            guard
                let workspaceID = state.activeWorkspaceID,
                var manifest = state.workspaces[workspaceID],
                let path = locateWindow(windowID: windowID, in: manifest)
            else {
                return
            }

            var window = manifest.columns[path.columnIndex].windows[path.windowIndex]
            guard window.tabs.contains(where: { $0.id == tabID }) else {
                return
            }

            window.activeTabID = tabID
            manifest.columns[path.columnIndex].windows[path.windowIndex] = window
            state.workspaces[workspaceID] = manifest
            state.activeWindowIDByWorkspace[workspaceID] = windowID

        case let .cycleTab(direction):
            guard
                let workspaceID = state.activeWorkspaceID,
                var manifest = state.workspaces[workspaceID]
            else {
                return
            }

            let currentWindowID = state.activeWindowIDByWorkspace[workspaceID] ?? firstWindowID(in: manifest)
            guard
                let currentWindowID,
                let path = locateWindow(windowID: currentWindowID, in: manifest)
            else {
                return
            }

            var window = manifest.columns[path.columnIndex].windows[path.windowIndex]
            guard !window.tabs.isEmpty else {
                return
            }

            let currentTabID = window.activeTabID ?? window.tabs.first?.id
            let currentIndex = window.tabs.firstIndex(where: { $0.id == currentTabID }) ?? 0
            let nextIndex: Int
            switch direction {
            case .next:
                nextIndex = (currentIndex + 1) % window.tabs.count
            case .previous:
                nextIndex = (currentIndex - 1 + window.tabs.count) % window.tabs.count
            }

            window.activeTabID = window.tabs[nextIndex].id
            manifest.columns[path.columnIndex].windows[path.windowIndex] = window
            state.workspaces[workspaceID] = manifest
            state.activeWindowIDByWorkspace[workspaceID] = currentWindowID
        }
    }

    private static func firstWindowID(in manifest: WorkspaceManifest) -> String? {
        manifest.columns.first?.windows.first?.id
    }

    private static func locateWindow(windowID: String, in manifest: WorkspaceManifest) -> (columnIndex: Int, windowIndex: Int)? {
        for (columnIndex, column) in manifest.columns.enumerated() {
            if let windowIndex = column.windows.firstIndex(where: { $0.id == windowID }) {
                return (columnIndex, windowIndex)
            }
        }
        return nil
    }
}

public struct LastSessionMetadata: Codable, Equatable, Sendable {
    public var paneCommands: [String: [String]]

    public init(paneCommands: [String: [String]] = [:]) {
        self.paneCommands = paneCommands
    }
}

public struct RestorePanePlan: Equatable, Sendable {
    public var paneID: String
    public var type: WorkspacePaneType
    public var command: [String]?
    public var autoRun: Bool

    public init(paneID: String, type: WorkspacePaneType, command: [String]?, autoRun: Bool) {
        self.paneID = paneID
        self.type = type
        self.command = command
        self.autoRun = autoRun
    }
}

public struct WorkspaceRestorePlan: Equatable, Sendable {
    public var workspaceID: String
    public var panes: [RestorePanePlan]

    public init(workspaceID: String, panes: [RestorePanePlan]) {
        self.workspaceID = workspaceID
        self.panes = panes
    }
}

public struct WorkspaceRestorePlanner {
    public init() {}

    public func makePlan(manifest: WorkspaceManifest, metadata: LastSessionMetadata) -> WorkspaceRestorePlan {
        let panes = manifest.columns
            .flatMap(\.windows)
            .flatMap(\.tabs)
            .map { tab in
                let command = metadata.paneCommands[tab.id] ?? tab.command
                return RestorePanePlan(
                    paneID: tab.id,
                    type: tab.type,
                    command: command,
                    autoRun: false
                )
            }

        return WorkspaceRestorePlan(workspaceID: manifest.id, panes: panes)
    }
}

public struct WorkspacePersistenceSnapshot: Codable, Equatable, Sendable {
    public var layoutState: WorkspaceLayoutState
    public var lastSessionMetadata: LastSessionMetadata
    public var savedAt: Date

    public init(layoutState: WorkspaceLayoutState, lastSessionMetadata: LastSessionMetadata, savedAt: Date) {
        self.layoutState = layoutState
        self.lastSessionMetadata = lastSessionMetadata
        self.savedAt = savedAt
    }
}

public enum WorkspaceStateStoreError: Error, Equatable, Sendable {
    case encodeFailed
    case decodeFailed
    case ioFailed
}

public protocol WorkspaceStateStoring: Sendable {
    func load() async throws -> WorkspacePersistenceSnapshot?
    func save(_ snapshot: WorkspacePersistenceSnapshot) async throws
}

public actor JSONWorkspaceStateStore: WorkspaceStateStoring {
    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = JSONWorkspaceStateStore.defaultFileURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> WorkspacePersistenceSnapshot? {
        if !fileManager.fileExists(atPath: fileURL.path) {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw WorkspaceStateStoreError.ioFailed
        }

        do {
            return try decoder.decode(WorkspacePersistenceSnapshot.self, from: data)
        } catch {
            throw WorkspaceStateStoreError.decodeFailed
        }
    }

    public func save(_ snapshot: WorkspacePersistenceSnapshot) async throws {
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw WorkspaceStateStoreError.encodeFailed
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw WorkspaceStateStoreError.ioFailed
        }
    }

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Floui", isDirectory: true)
            .appendingPathComponent("workspace-state.json")
    }
}
