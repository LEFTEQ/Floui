import Darwin
import FlouiCore
import Foundation

public struct GhosttyRuntimeFunctions: Sendable {
    public var startSession: @Sendable (_ sessionID: String, _ config: TerminalSessionConfig) async -> Int32
    public var attachSurface: @Sendable (_ sessionID: String, _ surfaceID: String) async -> Int32
    public var sendInput: @Sendable (_ sessionID: String, _ input: String) async -> Int32
    public var resize: @Sendable (_ sessionID: String, _ cols: Int32, _ rows: Int32) async -> Int32

    public init(
        startSession: @escaping @Sendable (_ sessionID: String, _ config: TerminalSessionConfig) async -> Int32,
        attachSurface: @escaping @Sendable (_ sessionID: String, _ surfaceID: String) async -> Int32,
        sendInput: @escaping @Sendable (_ sessionID: String, _ input: String) async -> Int32,
        resize: @escaping @Sendable (_ sessionID: String, _ cols: Int32, _ rows: Int32) async -> Int32
    ) {
        self.startSession = startSession
        self.attachSurface = attachSurface
        self.sendInput = sendInput
        self.resize = resize
    }
}

public protocol GhosttyFunctionProviding: Sendable {
    func loadFunctions() async throws -> GhosttyRuntimeFunctions
}

public protocol DynamicLibraryLoading: Sendable {
    func open(path: String, flags: Int32) -> UnsafeMutableRawPointer?
    func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer?
    func close(handle: UnsafeMutableRawPointer)
    func lastErrorMessage() -> String?
}

public struct DarwinDynamicLibraryLoader: DynamicLibraryLoading {
    public init() {}

    public func open(path: String, flags: Int32) -> UnsafeMutableRawPointer? {
        dlopen(path, flags)
    }

    public func symbol(handle: UnsafeMutableRawPointer, name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }

    public func close(handle: UnsafeMutableRawPointer) {
        dlclose(handle)
    }

    public func lastErrorMessage() -> String? {
        guard let ptr = dlerror() else {
            return nil
        }
        return String(cString: ptr)
    }
}

public struct GhosttyLibraryConfiguration: Sendable {
    public var candidatePaths: [String]
    public var dlopenFlags: Int32

    public init(candidatePaths: [String], dlopenFlags: Int32 = RTLD_NOW | RTLD_LOCAL) {
        self.candidatePaths = candidatePaths
        self.dlopenFlags = dlopenFlags
    }

    public static var `default`: GhosttyLibraryConfiguration {
        GhosttyLibraryConfiguration(candidatePaths: [
            "/Applications/Ghostty.app/Contents/Frameworks/libghostty.dylib",
            "/opt/homebrew/lib/libghostty.dylib",
            "libghostty.dylib",
        ])
    }
}

public final class DLGhosttyFunctionProvider: GhosttyFunctionProviding, @unchecked Sendable {
    private let loader: DynamicLibraryLoading
    private let configuration: GhosttyLibraryConfiguration

    private var loadedHandle: UnsafeMutableRawPointer?
    private var loadedFunctions: GhosttyRuntimeFunctions?

    public init(
        loader: DynamicLibraryLoading = DarwinDynamicLibraryLoader(),
        configuration: GhosttyLibraryConfiguration = .default
    ) {
        self.loader = loader
        self.configuration = configuration
    }

    deinit {
        if let loadedHandle {
            loader.close(handle: loadedHandle)
        }
    }

    public func loadFunctions() async throws -> GhosttyRuntimeFunctions {
        if let loadedFunctions {
            return loadedFunctions
        }

        let handle = try openLibraryHandle()

        let start = try resolve(handle: handle, symbol: GhosttySymbol.startSession.rawValue, as: GhosttyStartSessionFn.self)
        let attach = try resolve(handle: handle, symbol: GhosttySymbol.attachSurface.rawValue, as: GhosttyAttachSurfaceFn.self)
        let input = try resolve(handle: handle, symbol: GhosttySymbol.sendInput.rawValue, as: GhosttySendInputFn.self)
        let resize = try resolve(handle: handle, symbol: GhosttySymbol.resize.rawValue, as: GhosttyResizeFn.self)

        let functions = GhosttyRuntimeFunctions(
            startSession: { sessionID, config in
                invokeStart(start, sessionID: sessionID, config: config)
            },
            attachSurface: { sessionID, surfaceID in
                sessionID.withCString { sessionPtr in
                    surfaceID.withCString { surfacePtr in
                        attach(sessionPtr, surfacePtr)
                    }
                }
            },
            sendInput: { sessionID, inputText in
                sessionID.withCString { sessionPtr in
                    inputText.withCString { inputPtr in
                        input(sessionPtr, inputPtr)
                    }
                }
            },
            resize: { sessionID, cols, rows in
                sessionID.withCString { sessionPtr in
                    resize(sessionPtr, cols, rows)
                }
            }
        )

        loadedHandle = handle
        loadedFunctions = functions
        return functions
    }

    private func openLibraryHandle() throws -> UnsafeMutableRawPointer {
        var errors: [String] = []

        for path in configuration.candidatePaths {
            if let handle = loader.open(path: path, flags: configuration.dlopenFlags) {
                return handle
            }

            if let error = loader.lastErrorMessage() {
                errors.append("\(path): \(error)")
            } else {
                errors.append("\(path): unknown dlopen error")
            }
        }

        let details = errors.joined(separator: " | ")
        throw FlouiError.unsupported("Unable to load libghostty. \(details)")
    }

    private func resolve<T>(handle: UnsafeMutableRawPointer, symbol: String, as _: T.Type) throws -> T {
        guard let rawSymbol = loader.symbol(handle: handle, name: symbol) else {
            throw FlouiError.unsupported("Missing libghostty symbol: \(symbol)")
        }

        return unsafeBitCast(rawSymbol, to: T.self)
    }
}

public actor GhosttyRuntimeBridge: TerminalSurfaceBridge {
    private struct SessionRecord {
        var stream: AsyncStream<TerminalEvent>
        var continuation: AsyncStream<TerminalEvent>.Continuation
    }

    private let provider: GhosttyFunctionProviding
    private var runtimeFunctions: GhosttyRuntimeFunctions?
    private var sessions: [TerminalSessionID: SessionRecord] = [:]

    public init(provider: GhosttyFunctionProviding = DLGhosttyFunctionProvider()) {
        self.provider = provider
    }

    public func start(config: TerminalSessionConfig) async throws -> TerminalSessionID {
        let runtime = try await loadedRuntime()
        let sessionID = TerminalSessionID()
        let nativeID = sessionID.rawValue.uuidString.lowercased()

        let status = await runtime.startSession(nativeID, config)
        try validate(status: status, operation: "startSession")

        var continuationBox: AsyncStream<TerminalEvent>.Continuation?
        let stream = AsyncStream<TerminalEvent> { continuation in
            continuationBox = continuation
        }

        guard let continuationBox else {
            throw FlouiError.operationFailed("failed to create terminal event stream")
        }

        continuationBox.yield(.status("ghostty-session-started"))

        sessions[sessionID] = SessionRecord(stream: stream, continuation: continuationBox)
        return sessionID
    }

    public func attach(sessionID: TerminalSessionID, surfaceID: String) async throws {
        guard let session = sessions[sessionID] else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        let runtime = try await loadedRuntime()
        let status = await runtime.attachSurface(sessionID.rawValue.uuidString.lowercased(), surfaceID)
        try validate(status: status, operation: "attachSurface")
        session.continuation.yield(.status("ghostty-surface-attached"))
    }

    public func input(sessionID: TerminalSessionID, text: String) async throws {
        guard let session = sessions[sessionID] else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        let runtime = try await loadedRuntime()
        let status = await runtime.sendInput(sessionID.rawValue.uuidString.lowercased(), text)
        try validate(status: status, operation: "sendInput")
        session.continuation.yield(.status("ghostty-input-forwarded"))
    }

    public func resize(sessionID: TerminalSessionID, cols: Int, rows: Int) async throws {
        guard let session = sessions[sessionID] else {
            throw FlouiError.notFound("session \(sessionID.rawValue)")
        }

        let runtime = try await loadedRuntime()
        let status = await runtime.resize(sessionID.rawValue.uuidString.lowercased(), Int32(cols), Int32(rows))
        try validate(status: status, operation: "resize")
        session.continuation.yield(.status("ghostty-resized"))
    }

    public func events(sessionID: TerminalSessionID) async -> AsyncStream<TerminalEvent> {
        sessions[sessionID]?.stream ?? AsyncStream { continuation in
            continuation.yield(.status("session-not-found"))
            continuation.finish()
        }
    }

    private func loadedRuntime() async throws -> GhosttyRuntimeFunctions {
        if let runtimeFunctions {
            return runtimeFunctions
        }

        let loaded = try await provider.loadFunctions()
        runtimeFunctions = loaded
        return loaded
    }

    private func validate(status: Int32, operation: String) throws {
        guard status == 0 else {
            throw FlouiError.operationFailed("libghostty \(operation) failed with status \(status)")
        }
    }
}

private enum GhosttySymbol: String {
    case startSession = "ghostty_floui_start_session"
    case attachSurface = "ghostty_floui_attach_surface"
    case sendInput = "ghostty_floui_send_input"
    case resize = "ghostty_floui_resize"
}

private typealias GhosttyStartSessionFn = @convention(c) (
    UnsafePointer<CChar>,
    UnsafePointer<CChar>,
    UnsafePointer<CChar>,
    UnsafePointer<CChar>,
    UnsafePointer<CChar>
) -> Int32

private typealias GhosttyAttachSurfaceFn = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
private typealias GhosttySendInputFn = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
private typealias GhosttyResizeFn = @convention(c) (UnsafePointer<CChar>, Int32, Int32) -> Int32

private func invokeStart(
    _ start: GhosttyStartSessionFn,
    sessionID: String,
    config: TerminalSessionConfig
) -> Int32 {
    let command = escapedCommand(config.shellCommand)
    let cwd = config.workingDirectory ?? ""

    return sessionID.withCString { sessionPtr in
        config.workspaceID.withCString { workspacePtr in
            config.paneID.withCString { panePtr in
                command.withCString { commandPtr in
                    cwd.withCString { cwdPtr in
                        start(sessionPtr, workspacePtr, panePtr, commandPtr, cwdPtr)
                    }
                }
            }
        }
    }
}

private func escapedCommand(_ parts: [String]) -> String {
    parts.map { part in
        if part.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\"" }) {
            return "\"\(part.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return part
    }
    .joined(separator: " ")
}
