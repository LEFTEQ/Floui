import Foundation
import Permissions
import Testing

actor MockPermissionChecker: PermissionChecking {
    private var _checkHealth = PermissionHealth.empty
    private var _requestHealth = PermissionHealth.empty

    func setCheckHealth(_ health: PermissionHealth) {
        _checkHealth = health
    }

    func setRequestHealth(_ health: PermissionHealth) {
        _requestHealth = health
    }

    func check(kind: PermissionKind) async -> PermissionSnapshot {
        _checkHealth.snapshot(for: kind) ?? PermissionSnapshot(
            kind: kind,
            status: .notDetermined,
            detail: "mock",
            checkedAt: Date()
        )
    }

    func request(kind: PermissionKind) async -> PermissionSnapshot {
        _requestHealth.snapshot(for: kind) ?? PermissionSnapshot(
            kind: kind,
            status: .notDetermined,
            detail: "mock",
            checkedAt: Date()
        )
    }

    func checkAll() async -> PermissionHealth {
        _checkHealth
    }

    func requestAll() async -> PermissionHealth {
        _requestHealth
    }
}

@Test("PermissionHealth tracks required grant completion")
func permissionHealthCompletion() {
    let now = Date(timeIntervalSince1970: 1)
    let granted = PermissionHealth(snapshots: PermissionKind.requiredForWorkspaceControl.map {
        PermissionSnapshot(kind: $0, status: .granted, detail: "ok", checkedAt: now)
    })

    let mixed = PermissionHealth(snapshots: [
        PermissionSnapshot(kind: .accessibility, status: .granted, detail: "ok", checkedAt: now),
        PermissionSnapshot(kind: .notifications, status: .denied, detail: "no", checkedAt: now),
        PermissionSnapshot(kind: .automationSafari, status: .granted, detail: "ok", checkedAt: now),
        PermissionSnapshot(kind: .automationChrome, status: .granted, detail: "ok", checkedAt: now),
        PermissionSnapshot(kind: .automationBrave, status: .granted, detail: "ok", checkedAt: now),
    ])

    #expect(granted.allRequiredGranted)
    #expect(mixed.allRequiredGranted == false)
}

@Test("Onboarding controller refresh and requestAll update state")
func onboardingControllerFlow() async {
    let checker = MockPermissionChecker()

    await checker.setCheckHealth(PermissionHealth(snapshots: [
        PermissionSnapshot(kind: .accessibility, status: .notDetermined, detail: "pending", checkedAt: Date()),
        PermissionSnapshot(kind: .notifications, status: .notDetermined, detail: "pending", checkedAt: Date()),
        PermissionSnapshot(kind: .automationSafari, status: .notDetermined, detail: "pending", checkedAt: Date()),
        PermissionSnapshot(kind: .automationChrome, status: .notDetermined, detail: "pending", checkedAt: Date()),
        PermissionSnapshot(kind: .automationBrave, status: .notDetermined, detail: "pending", checkedAt: Date()),
    ]))

    await checker.setRequestHealth(PermissionHealth(snapshots: PermissionKind.requiredForWorkspaceControl.map {
        PermissionSnapshot(kind: $0, status: .granted, detail: "ok", checkedAt: Date())
    }))

    let controller = PermissionOnboardingController(checker: checker)

    let refreshed = await controller.refresh()
    #expect(refreshed.isComplete == false)

    let requested = await controller.requestAll()
    #expect(requested.isComplete)
}

@Test("PermissionHealthEvaluator reports denied and missing requirements")
func permissionHealthEvaluatorReporting() {
    let now = Date(timeIntervalSince1970: 10)
    let health = PermissionHealth(snapshots: [
        PermissionSnapshot(kind: .accessibility, status: .denied, detail: "denied", checkedAt: now),
        PermissionSnapshot(kind: .notifications, status: .notDetermined, detail: "pending", checkedAt: now),
        PermissionSnapshot(kind: .automationSafari, status: .granted, detail: "ok", checkedAt: now),
        PermissionSnapshot(kind: .automationChrome, status: .granted, detail: "ok", checkedAt: now),
        PermissionSnapshot(kind: .automationBrave, status: .notDetermined, detail: "pending", checkedAt: now),
    ])

    let report = PermissionHealthEvaluator().evaluate(health)
    #expect(report.isHealthy == false)
    #expect(report.deniedRequired.count == 1)
    #expect(report.missingRequired.count == 2)
}

@Test("MacPermissionChecker reports unavailable notifications outside app runtime")
func macPermissionCheckerNotificationFallback() async {
    let checker = MacPermissionChecker(notificationRuntimeAvailable: { false })
    let snapshot = await checker.check(kind: .notifications)

    #expect(snapshot.status == .unavailable)
    #expect(snapshot.detail == "Notification status unavailable")
}
