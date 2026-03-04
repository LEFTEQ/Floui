import ApplicationServices
import FlouiCore
import Foundation
import UserNotifications

public enum PermissionKind: String, CaseIterable, Codable, Sendable {
    case accessibility
    case notifications
    case automationSafari
    case automationChrome
    case automationBrave

    public static var requiredForWorkspaceControl: [PermissionKind] {
        [.accessibility, .notifications, .automationSafari, .automationChrome, .automationBrave]
    }

    public var displayName: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .notifications:
            return "Notifications"
        case .automationSafari:
            return "Safari Automation"
        case .automationChrome:
            return "Chrome Automation"
        case .automationBrave:
            return "Brave Automation"
        }
    }
}

public enum PermissionStatus: String, Codable, Sendable {
    case granted
    case denied
    case notDetermined
    case unavailable
}

public struct PermissionSnapshot: Codable, Equatable, Sendable {
    public var kind: PermissionKind
    public var status: PermissionStatus
    public var detail: String
    public var checkedAt: Date

    public init(kind: PermissionKind, status: PermissionStatus, detail: String, checkedAt: Date) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.checkedAt = checkedAt
    }
}

public struct PermissionHealth: Codable, Equatable, Sendable {
    public var snapshots: [PermissionSnapshot]

    public init(snapshots: [PermissionSnapshot]) {
        self.snapshots = snapshots
    }

    public static var empty: PermissionHealth {
        PermissionHealth(snapshots: [])
    }

    public var allRequiredGranted: Bool {
        let map = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.kind, $0.status) })
        return PermissionKind.requiredForWorkspaceControl.allSatisfy { map[$0] == .granted }
    }

    public func snapshot(for kind: PermissionKind) -> PermissionSnapshot? {
        snapshots.first { $0.kind == kind }
    }
}

public struct PermissionHealthReport: Equatable, Sendable {
    public var missingRequired: [PermissionSnapshot]
    public var deniedRequired: [PermissionSnapshot]

    public init(missingRequired: [PermissionSnapshot], deniedRequired: [PermissionSnapshot]) {
        self.missingRequired = missingRequired
        self.deniedRequired = deniedRequired
    }

    public var isHealthy: Bool {
        missingRequired.isEmpty && deniedRequired.isEmpty
    }

    public var summary: String {
        if isHealthy {
            return "All required permissions granted"
        }

        if !deniedRequired.isEmpty {
            return "Some permissions are denied and need manual approval in System Settings"
        }

        return "Some permissions still need onboarding approval"
    }
}

public struct PermissionHealthEvaluator {
    public init() {}

    public func evaluate(_ health: PermissionHealth) -> PermissionHealthReport {
        let required = PermissionKind.requiredForWorkspaceControl.compactMap { health.snapshot(for: $0) }
        let denied = required.filter { $0.status == .denied }
        let missing = required.filter { $0.status != .granted && $0.status != .denied }
        return PermissionHealthReport(missingRequired: missing, deniedRequired: denied)
    }
}

public protocol PermissionChecking: Sendable {
    func check(kind: PermissionKind) async -> PermissionSnapshot
    func request(kind: PermissionKind) async -> PermissionSnapshot
    func checkAll() async -> PermissionHealth
    func requestAll() async -> PermissionHealth
}

public actor MacPermissionChecker: PermissionChecking {
    private let clock: Clock
    private let notificationRuntimeAvailable: @Sendable () -> Bool

    public init(
        clock: Clock = SystemClock(),
        notificationRuntimeAvailable: (@Sendable () -> Bool)? = nil
    ) {
        self.clock = clock
        self.notificationRuntimeAvailable = notificationRuntimeAvailable ?? Self.defaultNotificationRuntimeAvailable
    }

    public func check(kind: PermissionKind) async -> PermissionSnapshot {
        let now = clock.now

        switch kind {
        case .accessibility:
            let trusted = AXIsProcessTrusted()
            return PermissionSnapshot(
                kind: .accessibility,
                status: trusted ? .granted : .notDetermined,
                detail: trusted ? "Trusted by macOS" : "Grant in System Settings > Privacy & Security > Accessibility",
                checkedAt: now
            )

        case .notifications:
            let status = await notificationStatus()
            let detail: String
            switch status {
            case .granted:
                detail = "Notifications enabled"
            case .denied:
                detail = "Enable in System Settings > Notifications"
            case .notDetermined:
                detail = "Permission not requested yet"
            case .unavailable:
                detail = "Notification status unavailable"
            }

            return PermissionSnapshot(
                kind: .notifications,
                status: status,
                detail: detail,
                checkedAt: now
            )

        case .automationSafari:
            return automationSnapshot(kind: .automationSafari, appName: "Safari", checkedAt: now)
        case .automationChrome:
            return automationSnapshot(kind: .automationChrome, appName: "Google Chrome", checkedAt: now)
        case .automationBrave:
            return automationSnapshot(kind: .automationBrave, appName: "Brave Browser", checkedAt: now)
        }
    }

    public func request(kind: PermissionKind) async -> PermissionSnapshot {
        switch kind {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return await check(kind: .accessibility)

        case .notifications:
            _ = await requestNotifications()
            return await check(kind: .notifications)

        case .automationSafari:
            _ = runAutomationProbe(appName: "Safari")
            return await check(kind: .automationSafari)

        case .automationChrome:
            _ = runAutomationProbe(appName: "Google Chrome")
            return await check(kind: .automationChrome)

        case .automationBrave:
            _ = runAutomationProbe(appName: "Brave Browser")
            return await check(kind: .automationBrave)
        }
    }

    public func checkAll() async -> PermissionHealth {
        var snapshots: [PermissionSnapshot] = []
        for kind in PermissionKind.requiredForWorkspaceControl {
            snapshots.append(await check(kind: kind))
        }
        return PermissionHealth(snapshots: snapshots)
    }

    public func requestAll() async -> PermissionHealth {
        var snapshots: [PermissionSnapshot] = []
        for kind in PermissionKind.requiredForWorkspaceControl {
            snapshots.append(await request(kind: kind))
        }
        return PermissionHealth(snapshots: snapshots)
    }

    private func notificationStatus() async -> PermissionStatus {
        guard notificationRuntimeAvailable() else {
            return .unavailable
        }

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    continuation.resume(returning: .granted)
                case .denied:
                    continuation.resume(returning: .denied)
                case .notDetermined:
                    continuation.resume(returning: .notDetermined)
                @unknown default:
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    private func requestNotifications() async -> Bool {
        guard notificationRuntimeAvailable() else {
            return false
        }

        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func defaultNotificationRuntimeAvailable() -> Bool {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension.lowercased() == "app" {
            return true
        }

        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        return packageType == "APPL"
    }

    private func automationSnapshot(kind: PermissionKind, appName: String, checkedAt: Date) -> PermissionSnapshot {
        let probe = runAutomationProbe(appName: appName)

        let status: PermissionStatus
        let detail: String

        if probe.success {
            status = .granted
            detail = "Automation access available"
        } else if probe.errorCode == -1743 {
            status = .denied
            detail = "Automation denied. Enable in System Settings > Privacy & Security > Automation"
        } else {
            status = .notDetermined
            detail = "Automation not granted yet"
        }

        return PermissionSnapshot(kind: kind, status: status, detail: detail, checkedAt: checkedAt)
    }

    private func runAutomationProbe(appName: String) -> (success: Bool, errorCode: Int?) {
        let script = "tell application \"\(appName)\" to id"
        var error: NSDictionary?
        let engine = NSAppleScript(source: script)
        _ = engine?.executeAndReturnError(&error)

        if error == nil {
            return (true, nil)
        }

        let code = error?[NSAppleScript.errorNumber] as? Int
        return (false, code)
    }
}

public struct PermissionOnboardingState: Equatable, Sendable {
    public var health: PermissionHealth
    public var isRunning: Bool
    public var lastError: String?

    public init(health: PermissionHealth = .empty, isRunning: Bool = false, lastError: String? = nil) {
        self.health = health
        self.isRunning = isRunning
        self.lastError = lastError
    }

    public var isComplete: Bool {
        health.allRequiredGranted
    }
}

public actor PermissionOnboardingController {
    private let checker: PermissionChecking
    private(set) var state: PermissionOnboardingState

    public init(checker: PermissionChecking, initialState: PermissionOnboardingState = .init()) {
        self.checker = checker
        state = initialState
    }

    public func refresh() async -> PermissionOnboardingState {
        state.isRunning = true
        state.lastError = nil
        state.health = await checker.checkAll()
        state.isRunning = false
        return state
    }

    public func requestAll() async -> PermissionOnboardingState {
        state.isRunning = true
        state.lastError = nil
        state.health = await checker.requestAll()
        state.isRunning = false
        return state
    }
}
