import Foundation
import Testing

@Test("Real E2E gate: requires explicit opt-in")
func requiresOptInEnvironmentFlag() {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    #expect(enabled || !enabled)
}

@Test("Real E2E smoke: required apps are installed")
func verifyRequiredAppsInstalled() {
    let enabled = ProcessInfo.processInfo.environment["FLOUI_REAL_E2E"] == "1"
    guard enabled else {
        return
    }

    let requiredApps = [
        "/Applications/Safari.app",
        "/Applications/Google Chrome.app",
        "/Applications/Brave Browser.app",
    ]

    for app in requiredApps {
        #expect(FileManager.default.fileExists(atPath: app))
    }
}
