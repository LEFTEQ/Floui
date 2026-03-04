import Foundation

public struct FlouiRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum FlouiError: Error, Equatable, Sendable {
    case unsupported(String)
    case notFound(String)
    case invalidInput(String)
    case operationFailed(String)
}

public struct TerminalSessionID: Hashable, Codable, Sendable {
    public var rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TerminalSessionConfig: Codable, Hashable, Sendable {
    public var workspaceID: String
    public var paneID: String
    public var shellCommand: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        workspaceID: String,
        paneID: String,
        shellCommand: [String],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.shellCommand = shellCommand
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public enum TerminalEvent: Equatable, Sendable {
    case output(String)
    case processExited(Int32)
    case status(String)
}

public protocol TerminalEngine: Sendable {
    func startSession(config: TerminalSessionConfig) async throws -> TerminalSessionID
    func attachView(sessionID: TerminalSessionID, surfaceID: String) async throws
    func sendInput(sessionID: TerminalSessionID, input: String) async throws
    func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws
    func subscribeEvents(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent>
}

public enum BrowserKind: String, Codable, CaseIterable, Sendable {
    case safari
    case chrome
    case brave
}

public struct BrowserWindowID: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct BrowserTabID: Codable, Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct BrowserLaunchRequest: Codable, Hashable, Sendable {
    public var profileName: String
    public var urls: [String]
    public var enableRemoteDebugging: Bool
    public var remoteDebuggingPort: Int?

    public init(
        profileName: String,
        urls: [String],
        enableRemoteDebugging: Bool = false,
        remoteDebuggingPort: Int? = nil
    ) {
        self.profileName = profileName
        self.urls = urls
        self.enableRemoteDebugging = enableRemoteDebugging
        self.remoteDebuggingPort = remoteDebuggingPort
    }
}

public struct BrowserWindow: Codable, Hashable, Sendable {
    public var id: BrowserWindowID
    public var title: String
    public var bounds: FlouiRect

    public init(id: BrowserWindowID, title: String, bounds: FlouiRect) {
        self.id = id
        self.title = title
        self.bounds = bounds
    }
}

public struct BrowserTab: Codable, Hashable, Sendable {
    public var id: BrowserTabID
    public var title: String
    public var url: String
    public var index: Int

    public init(id: BrowserTabID, title: String, url: String, index: Int) {
        self.id = id
        self.title = title
        self.url = url
        self.index = index
    }
}

public protocol BrowserAdapter: Sendable {
    var kind: BrowserKind { get }
    func launch(_ request: BrowserLaunchRequest) async throws
    func listWindows() async throws -> [BrowserWindow]
    func setWindowBounds(windowID: BrowserWindowID, bounds: FlouiRect) async throws
    func listTabs(windowID: BrowserWindowID) async throws -> [BrowserTab]
    func focusTab(tabID: BrowserTabID) async throws
    func openDevTools(tabID: BrowserTabID) async throws
}

public struct DevToolsTarget: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }
}

public enum DevToolsEvent: Equatable, Sendable {
    case connected
    case targetUpdated(DevToolsTarget)
    case disconnected
}

public protocol DevToolsAdapter: Sendable {
    func connect(instance: BrowserKind, port: Int) async throws
    func listTargets() async throws -> [DevToolsTarget]
    func subscribeTargetEvents(targetID: String) async -> AsyncStream<DevToolsEvent>
    func close() async
}

public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(for duration: TimeInterval) async throws
}

public protocol ProcessRunner: Sendable {
    @discardableResult
    func run(_ launchPath: String, _ arguments: [String], environment: [String: String]) async throws -> Int32
}

public protocol SocketTransport: Sendable {
    func send(line: String) async throws
    func receiveLines() async -> AsyncStream<String>
}

public protocol AppleEventClient: Sendable {
    @discardableResult
    func runScript(_ script: String) async throws -> String
}

public protocol CDPClient: Sendable {
    func connect(host: String, port: Int) async throws
    func send(method: String, params: [String: String]) async throws
    func events() async -> AsyncStream<[String: String]>
    func close() async
}

public protocol TerminalSurfaceBridge: Sendable {
    func start(config: TerminalSessionConfig) async throws -> TerminalSessionID
    func attach(sessionID: TerminalSessionID, surfaceID: String) async throws
    func input(sessionID: TerminalSessionID, text: String) async throws
    func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws
    func events(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent>
}

public struct SystemClock: Clock {
    public init() {}

    public var now: Date {
        Date()
    }

    public func sleep(for duration: TimeInterval) async throws {
        let nanos = UInt64(max(0, duration) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

public struct FoundationProcessRunner: ProcessRunner {
    public init() {}

    @discardableResult
    public func run(_ launchPath: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            process.environment = merged
        }

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
