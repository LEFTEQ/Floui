import FlouiCore
import Foundation
import WorkspaceCore

public enum BrowserAutomationError: Error, Equatable, Sendable {
    case appleScriptFailure(code: Int, message: String)
}

public struct BrowserOrchestrationError: Error, Equatable, Sendable {
    public var browser: BrowserKind
    public var operation: String
    public var code: Int?
    public var message: String

    public init(browser: BrowserKind, operation: String, code: Int?, message: String) {
        self.browser = browser
        self.operation = operation
        self.code = code
        self.message = message
    }
}

public struct BrowserRecoveryIssue: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var steps: [String]
    public var isPermissionIssue: Bool

    public init(title: String, summary: String, steps: [String], isPermissionIssue: Bool) {
        self.title = title
        self.summary = summary
        self.steps = steps
        self.isPermissionIssue = isPermissionIssue
    }
}

public enum BrowserRecoveryAdvisor {
    public static func advise(error: Error) -> BrowserRecoveryIssue {
        if let orchestrationError = error as? BrowserOrchestrationError {
            if orchestrationError.code == -1743 {
                return BrowserRecoveryIssue(
                    title: "\(orchestrationError.browser.rawValue.capitalized) automation permission required",
                    summary: "macOS denied Apple Events access while running \(orchestrationError.operation).",
                    steps: [
                        "Open System Settings > Privacy & Security > Automation.",
                        "Enable control access for Floui to \(orchestrationError.browser.rawValue.capitalized).",
                        "Retry the browser orchestration action.",
                    ],
                    isPermissionIssue: true
                )
            }

            if orchestrationError.code == -600 {
                return BrowserRecoveryIssue(
                    title: "\(orchestrationError.browser.rawValue.capitalized) is not available",
                    summary: "The target browser process is not running or did not respond to Apple Events.",
                    steps: [
                        "Start \(orchestrationError.browser.rawValue.capitalized) manually once.",
                        "Verify the app is installed in /Applications.",
                        "Retry browser orchestration.",
                    ],
                    isPermissionIssue: false
                )
            }

            return BrowserRecoveryIssue(
                title: "Browser orchestration failed",
                summary: orchestrationError.message,
                steps: [
                    "Confirm browser permissions in System Settings > Privacy & Security > Automation.",
                    "Check browser installation and try relaunching the browser.",
                    "Retry the operation from Floui.",
                ],
                isPermissionIssue: false
            )
        }

        if let flouiError = error as? FlouiError {
            return BrowserRecoveryIssue(
                title: "Browser orchestration failed",
                summary: String(describing: flouiError),
                steps: [
                    "Verify browser adapters are configured for Safari, Chrome, and Brave.",
                    "Retry after relaunching Floui.",
                ],
                isPermissionIssue: false
            )
        }

        return BrowserRecoveryIssue(
            title: "Browser orchestration failed",
            summary: error.localizedDescription,
            steps: [
                "Retry the operation.",
                "If it repeats, check browser automation permissions in System Settings.",
            ],
            isPermissionIssue: false
        )
    }
}

public struct BrowserWindowPlan: Equatable, Sendable {
    public var browser: BrowserKind
    public var profileName: String
    public var urls: [String]
    public var bounds: FlouiRect
    public var openDevToolsForFirstTab: Bool
    public var remoteDebuggingPort: Int?

    public init(
        browser: BrowserKind,
        profileName: String,
        urls: [String],
        bounds: FlouiRect,
        openDevToolsForFirstTab: Bool,
        remoteDebuggingPort: Int?
    ) {
        self.browser = browser
        self.profileName = profileName
        self.urls = urls
        self.bounds = bounds
        self.openDevToolsForFirstTab = openDevToolsForFirstTab
        self.remoteDebuggingPort = remoteDebuggingPort
    }
}

public struct BrowserWorkspaceLayout: Equatable, Sendable {
    public var workspaceID: String
    public var plans: [BrowserWindowPlan]

    public init(workspaceID: String, plans: [BrowserWindowPlan]) {
        self.workspaceID = workspaceID
        self.plans = plans
    }
}

public enum BrowserLayoutBuilder {
    public static func fromManifest(_ manifest: WorkspaceManifest, defaultBounds: FlouiRect) -> BrowserWorkspaceLayout {
        let profiles = Dictionary(uniqueKeysWithValues: manifest.browserProfiles.map { ($0.browser, $0) })

        let plans: [BrowserWindowPlan] = manifest.columns.flatMap { column in
            column.windows.compactMap { window in
                let browserTabs = window.tabs.filter { $0.type == .browser }
                guard !browserTabs.isEmpty else {
                    return nil
                }

                let browser = browserTabs.first?.browser ?? .safari
                let profile = profiles[browser]?.profileName ?? "Default"
                let remoteDebuggingPort = browser == .safari ? nil : (profiles[browser]?.remoteDebuggingPort ?? 9222)

                let urls = browserTabs.compactMap(\.url)
                let openDevTools = browser != .safari

                return BrowserWindowPlan(
                    browser: browser,
                    profileName: profile,
                    urls: urls,
                    bounds: defaultBounds,
                    openDevToolsForFirstTab: openDevTools,
                    remoteDebuggingPort: remoteDebuggingPort
                )
            }
        }

        return BrowserWorkspaceLayout(workspaceID: manifest.id, plans: plans)
    }
}

public actor BrowserWorkspaceOrchestrator {
    private var adapters: [BrowserKind: BrowserAdapter]

    public init(adapters: [BrowserKind: BrowserAdapter]) {
        self.adapters = adapters
    }

    public func apply(layout: BrowserWorkspaceLayout) async throws {
        for plan in layout.plans {
            guard let adapter = adapters[plan.browser] else {
                throw FlouiError.notFound("missing browser adapter for \(plan.browser.rawValue)")
            }

            let urls = plan.urls.isEmpty ? ["about:blank"] : plan.urls
            let remoteDebuggingPort = plan.browser == .safari ? nil : (plan.remoteDebuggingPort ?? 9222)
            let launchRequest = BrowserLaunchRequest(
                profileName: plan.profileName,
                urls: urls,
                enableRemoteDebugging: plan.browser != .safari,
                remoteDebuggingPort: remoteDebuggingPort
            )
            do {
                try await adapter.launch(launchRequest)
            } catch {
                throw wrap(error: error, browser: plan.browser, operation: "launch")
            }

            let windows: [BrowserWindow]
            do {
                windows = try await adapter.listWindows()
            } catch {
                throw wrap(error: error, browser: plan.browser, operation: "listWindows")
            }

            if let firstWindow = windows.first {
                do {
                    try await adapter.setWindowBounds(windowID: firstWindow.id, bounds: plan.bounds)
                } catch {
                    throw wrap(error: error, browser: plan.browser, operation: "setWindowBounds")
                }

                let tabs: [BrowserTab]
                do {
                    tabs = try await adapter.listTabs(windowID: firstWindow.id)
                } catch {
                    throw wrap(error: error, browser: plan.browser, operation: "listTabs")
                }

                if let firstTab = tabs.first, plan.openDevToolsForFirstTab {
                    do {
                        try await adapter.openDevTools(tabID: firstTab.id)
                    } catch {
                        throw wrap(error: error, browser: plan.browser, operation: "openDevTools")
                    }
                }
            }
        }
    }

    private func wrap(error: Error, browser: BrowserKind, operation: String) -> BrowserOrchestrationError {
        if let automation = error as? BrowserAutomationError {
            switch automation {
            case let .appleScriptFailure(code, message):
                return BrowserOrchestrationError(browser: browser, operation: operation, code: code, message: message)
            }
        }

        return BrowserOrchestrationError(
            browser: browser,
            operation: operation,
            code: nil,
            message: error.localizedDescription
        )
    }
}

public struct AppleEventBrowserAdapter: BrowserAdapter {
    public let kind: BrowserKind
    private let appleEvents: AppleEventClient

    public init(kind: BrowserKind, appleEvents: AppleEventClient) {
        self.kind = kind
        self.appleEvents = appleEvents
    }

    public func launch(_ request: BrowserLaunchRequest) async throws {
        let appName = appNameForKind(kind)
        let firstURL = request.urls.first ?? "about:blank"
        let additionalURLs = Array(request.urls.dropFirst())
            .map(escapeAppleScriptString)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        let openAdditionalTabs = additionalURLs.isEmpty ? "" : """
            repeat with nextUrl in {\(additionalURLs)}
                make new tab at end of tabs of front window with properties {URL:nextUrl}
            end repeat
        """

        let script = """
        tell application "\(appName)"
            activate
            if count of windows is 0 then
                make new window
            end if
            set URL of active tab of front window to "\(escapeAppleScriptString(firstURL))"
        \(openAdditionalTabs)
        end tell
        """
        _ = try await appleEvents.runScript(script)
    }

    public func listWindows() async throws -> [BrowserWindow] {
        let script = """
        tell application "\(appNameForKind(kind))"
            set output to {}
            repeat with w in windows
                set end of output to (id of w as string) & "::" & (name of w as string)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return output as string
        end tell
        """

        let response = try await appleEvents.runScript(script)
        if response.isEmpty {
            return []
        }

        let entries = response
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return entries.enumerated().map { index, entry in
            let parts = entry.split(separator: "::", maxSplits: 1, omittingEmptySubsequences: false)
            let id = parts.first.map(String.init) ?? "window-\(index)"
            let title = parts.count > 1 ? String(parts[1]) : "Browser Window"
            return BrowserWindow(
                id: BrowserWindowID(id),
                title: title,
                bounds: FlouiRect(x: 0, y: 0, width: 1400, height: 900)
            )
        }
    }

    public func setWindowBounds(windowID: BrowserWindowID, bounds: FlouiRect) async throws {
        let script = """
        tell application "\(appNameForKind(kind))"
            set targetWindow to first window whose (id as string) is "\(escapeAppleScriptString(windowID.rawValue))"
            set bounds of targetWindow to {\(Int(bounds.x)), \(Int(bounds.y)), \(Int(bounds.x + bounds.width)), \(Int(bounds.y + bounds.height))}
        end tell
        """
        _ = try await appleEvents.runScript(script)
    }

    public func listTabs(windowID _: BrowserWindowID) async throws -> [BrowserTab] {
        let script = """
        tell application "\(appNameForKind(kind))"
            set output to {}
            repeat with t in tabs of front window
                set end of output to (id of t as string) & "::" & (title of t as string) & "::" & (URL of t as string)
            end repeat
            set AppleScript's text item delimiters to linefeed
            return output as string
        end tell
        """

        let response = try await appleEvents.runScript(script)
        if response.isEmpty {
            return []
        }

        return response
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, entry in
                let parts = entry.split(separator: "::", maxSplits: 2, omittingEmptySubsequences: false)
            let id = parts.indices.contains(0) ? String(parts[0]) : "tab-\(index)"
            let title = parts.indices.contains(1) ? String(parts[1]) : "Tab \(index + 1)"
            let url = parts.indices.contains(2) ? String(parts[2]) : "about:blank"
            return BrowserTab(id: BrowserTabID(id), title: title, url: url, index: index)
            }
    }

    public func focusTab(tabID: BrowserTabID) async throws {
        let script = """
        tell application "\(appNameForKind(kind))"
            repeat with t in tabs of front window
                if (id of t as string) is equal to "\(tabID.rawValue)" then
                    set current tab of front window to t
                    exit repeat
                end if
            end repeat
        end tell
        """
        _ = try await appleEvents.runScript(script)
    }

    public func openDevTools(tabID: BrowserTabID) async throws {
        guard kind != .safari else {
            return
        }

        let script = """
        tell application "System Events"
            tell process "\(appNameForKind(kind))"
                keystroke "i" using {command down, option down}
            end tell
        end tell
        """
        _ = try await appleEvents.runScript(script)
        _ = tabID
    }

    private func appNameForKind(_ kind: BrowserKind) -> String {
        switch kind {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave Browser"
        }
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct CocoaAppleEventClient: AppleEventClient {
    public init() {}

    public func runScript(_ script: String) async throws -> String {
        var errorInfo: NSDictionary?
        guard let engine = NSAppleScript(source: script) else {
            throw BrowserAutomationError.appleScriptFailure(code: -1, message: "Unable to create NSAppleScript engine")
        }

        let value = engine.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                ?? "AppleScript execution failed"
            throw BrowserAutomationError.appleScriptFailure(code: code, message: message)
        }

        return value.stringValue ?? ""
    }
}

public actor ChromiumDevToolsAdapter: DevToolsAdapter {
    private struct TargetSubscriber {
        var targetID: String
        var continuation: AsyncStream<DevToolsEvent>.Continuation
    }

    private let client: CDPClient
    private var isConnected = false
    private var eventPumpTask: Task<Void, Never>?
    private var targetsByID: [String: DevToolsTarget] = [:]
    private var subscribers: [UUID: TargetSubscriber] = [:]

    public init(client: CDPClient) {
        self.client = client
    }

    public func connect(instance _: BrowserKind, port: Int) async throws {
        if isConnected {
            await close()
        }

        try await client.connect(host: "127.0.0.1", port: port)
        isConnected = true
        try await client.send(method: "Target.setDiscoverTargets", params: ["discover": "true"])
        startEventPump()
    }

    public func listTargets() async throws -> [DevToolsTarget] {
        guard isConnected else {
            throw FlouiError.invalidInput("CDP not connected")
        }

        try await client.send(method: "Target.getTargets", params: [:])
        return targetsByID.values.sorted(by: { $0.id < $1.id })
    }

    public func subscribeTargetEvents(targetID: String) async -> AsyncStream<DevToolsEvent> {
        var continuationBox: AsyncStream<DevToolsEvent>.Continuation?
        let stream = AsyncStream<DevToolsEvent> { continuation in
            continuationBox = continuation
        }

        guard let continuationBox else {
            return AsyncStream { continuation in
                continuation.yield(.disconnected)
                continuation.finish()
            }
        }

        let token = UUID()
        continuationBox.onTermination = { _ in
            Task {
                await self.removeSubscriber(token: token)
            }
        }

        subscribers[token] = TargetSubscriber(targetID: targetID, continuation: continuationBox)
        continuationBox.yield(.connected)
        if let currentTarget = targetsByID[targetID] {
            continuationBox.yield(.targetUpdated(currentTarget))
        }

        return stream
    }

    public func close() async {
        eventPumpTask?.cancel()
        eventPumpTask = nil

        finishSubscribers()
        await client.close()
        targetsByID.removeAll()
        isConnected = false
    }

    private func startEventPump() {
        eventPumpTask?.cancel()
        eventPumpTask = Task {
            let rawEvents = await client.events()
            for await event in rawEvents {
                self.consume(rawEvent: event)
            }
            self.finishSubscribers()
        }
    }

    private func consume(rawEvent: [String: String]) {
        guard let targetID = rawEvent["targetId"] else {
            return
        }

        let method = rawEvent["method"] ?? "Target.targetInfoChanged"

        switch method {
        case "Target.targetDestroyed":
            targetsByID.removeValue(forKey: targetID)
            disconnectSubscribers(for: targetID)

        case "Target.targetCreated", "Target.targetInfoChanged":
            let target = DevToolsTarget(
                id: targetID,
                title: rawEvent["title"] ?? "",
                url: rawEvent["url"] ?? ""
            )
            targetsByID[targetID] = target
            notifySubscribers(about: target)

        default:
            let target = DevToolsTarget(
                id: targetID,
                title: rawEvent["title"] ?? "",
                url: rawEvent["url"] ?? ""
            )
            targetsByID[targetID] = target
            notifySubscribers(about: target)
        }
    }

    private func notifySubscribers(about target: DevToolsTarget) {
        for (_, subscriber) in subscribers where subscriber.targetID == target.id {
            subscriber.continuation.yield(.targetUpdated(target))
        }
    }

    private func disconnectSubscribers(for targetID: String) {
        let matchingTokens = subscribers.compactMap { token, subscriber in
            subscriber.targetID == targetID ? token : nil
        }

        for token in matchingTokens {
            if let continuation = subscribers[token]?.continuation {
                continuation.yield(.disconnected)
                continuation.finish()
            }
            subscribers.removeValue(forKey: token)
        }
    }

    private func finishSubscribers() {
        for (_, subscriber) in subscribers {
            subscriber.continuation.yield(.disconnected)
            subscriber.continuation.finish()
        }
        subscribers.removeAll()
    }

    private func removeSubscriber(token: UUID) {
        subscribers.removeValue(forKey: token)
    }
}

public struct NoopDevToolsAdapter: DevToolsAdapter {
    public init() {}

    public func connect(instance _: BrowserKind, port _: Int) async throws {}

    public func listTargets() async throws -> [DevToolsTarget] {
        []
    }

    public func subscribeTargetEvents(targetID _: String) async -> AsyncStream<DevToolsEvent> {
        AsyncStream { continuation in
            continuation.yield(.connected)
            continuation.yield(.disconnected)
            continuation.finish()
        }
    }

    public func close() async {}
}

public actor URLSessionCDPClient: CDPClient {
    private var host: String?
    private var port: Int?
    private var messageID = 0
    private var socketTask: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<[String: String]>.Continuation?
    private var eventStream: AsyncStream<[String: String]>?

    public init() {}

    public func connect(host: String, port: Int) async throws {
        self.host = host
        self.port = port

        let websocketURL = try await fetchWebSocketURL(host: host, port: port)
        let task = URLSession.shared.webSocketTask(with: websocketURL)
        task.resume()
        socketTask = task

        startReceiverLoop()
    }

    public func send(method: String, params: [String: String]) async throws {
        guard let socketTask else {
            throw FlouiError.invalidInput("CDP client not connected")
        }

        messageID += 1
        let payload: [String: Any] = [
            "id": messageID,
            "method": method,
            "params": normalizedParams(params),
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FlouiError.operationFailed("Failed to encode CDP request")
        }

        try await socketTask.send(.string(text))
    }

    public func events() async -> AsyncStream<[String: String]> {
        if let eventStream {
            return eventStream
        }

        var continuationBox: AsyncStream<[String: String]>.Continuation?
        let stream = AsyncStream<[String: String]> { continuation in
            continuationBox = continuation
        }

        eventStream = stream
        eventContinuation = continuationBox
        return stream
    }

    public func close() async {
        receiverTask?.cancel()
        receiverTask = nil

        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil

        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
    }

    private func startReceiverLoop() {
        receiverTask?.cancel()
        receiverTask = Task {
            while !Task.isCancelled {
                guard let socketTask else {
                    break
                }

                do {
                    let message = try await socketTask.receive()
                    let payloads = parseIncoming(message: message)
                    for payload in payloads {
                        eventContinuation?.yield(payload)
                    }
                } catch {
                    break
                }
            }

            eventContinuation?.finish()
        }
    }

    private func fetchWebSocketURL(host: String, port: Int) async throws -> URL {
        guard let url = URL(string: "http://\(host):\(port)/json/version") else {
            throw FlouiError.invalidInput("Invalid CDP endpoint URL")
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = json["webSocketDebuggerUrl"] as? String,
            let websocketURL = URL(string: value)
        else {
            throw FlouiError.operationFailed("Unable to resolve webSocketDebuggerUrl from CDP")
        }

        return websocketURL
    }

    private func parseIncoming(message: URLSessionWebSocketTask.Message) -> [[String: String]] {
        let data: Data
        switch message {
        case let .string(text):
            guard let encoded = text.data(using: .utf8) else {
                return []
            }
            data = encoded
        case let .data(binary):
            data = binary
        @unknown default:
            return []
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var payloads: [[String: String]] = []

        if let method = object["method"] as? String,
           let params = object["params"] as? [String: Any]
        {
            payloads.append(contentsOf: extractTargetPayloads(method: method, params: params))
        }

        if let result = object["result"] as? [String: Any],
           let targetInfos = result["targetInfos"] as? [[String: Any]]
        {
            for info in targetInfos {
                guard let targetID = info["targetId"] as? String else {
                    continue
                }

                payloads.append([
                    "method": "Target.targetInfoChanged",
                    "targetId": targetID,
                    "title": info["title"] as? String ?? "",
                    "url": info["url"] as? String ?? "",
                ])
            }
        }

        return payloads
    }

    private func extractTargetPayloads(method: String, params: [String: Any]) -> [[String: String]] {
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            if let info = params["targetInfo"] as? [String: Any],
               let targetID = info["targetId"] as? String
            {
                return [[
                    "method": method,
                    "targetId": targetID,
                    "title": info["title"] as? String ?? "",
                    "url": info["url"] as? String ?? "",
                ]]
            }

            if let targetID = params["targetId"] as? String {
                return [[
                    "method": method,
                    "targetId": targetID,
                    "title": params["title"] as? String ?? "",
                    "url": params["url"] as? String ?? "",
                ]]
            }

            return []

        case "Target.targetDestroyed":
            if let targetID = params["targetId"] as? String {
                return [[
                    "method": method,
                    "targetId": targetID,
                ]]
            }
            return []

        default:
            return []
        }
    }

    private func normalizedParams(_ params: [String: String]) -> [String: Any] {
        var normalized: [String: Any] = [:]
        for (key, value) in params {
            if value == "true" {
                normalized[key] = true
            } else if value == "false" {
                normalized[key] = false
            } else if let intValue = Int(value) {
                normalized[key] = intValue
            } else if let doubleValue = Double(value) {
                normalized[key] = doubleValue
            } else {
                normalized[key] = value
            }
        }
        return normalized
    }
}
