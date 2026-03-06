@testable import FlouiApp
import Foundation
import Testing

@MainActor
private final class MockAppUpdaterDriver: AppUpdaterDriving {
    var startCallCount = 0
    var checkCallCount = 0
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var allowsAutomaticUpdates = true
    var feedURL: URL? = URL(string: "https://downloads.example.com/floui/appcast.xml")
    var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    var startError: Error?
    var checkError: Error?

    func start() throws {
        startCallCount += 1
        if let startError {
            throw startError
        }
    }

    func checkForUpdates() throws {
        checkCallCount += 1
        if let checkError {
            throw checkError
        }
    }
}

@Test("Updater environment disables update checks outside a bundled app")
func updaterEnvironmentRejectsNonBundledRuns() {
    let environment = AppUpdaterEnvironment(
        bundleURL: URL(fileURLWithPath: "/tmp/Floui"),
        feedURL: URL(string: "https://downloads.example.com/floui/appcast.xml")
    )

    #expect(environment.support == .unsupported("Updater is only available from a bundled .app release build."))
}

@Test("Updater environment requires a configured appcast feed")
func updaterEnvironmentRequiresFeed() {
    let environment = AppUpdaterEnvironment(
        bundleURL: URL(fileURLWithPath: "/Applications/Floui.app"),
        feedURL: nil
    )

    #expect(environment.support == .unsupported("Updater is disabled until SUFeedURL is configured in the app bundle."))
}

@MainActor
@Test("Updater controller starts driver and exposes current settings")
func updaterControllerStartsDriver() throws {
    let driver = MockAppUpdaterDriver()
    let controller = AppUpdaterController(
        environment: AppUpdaterEnvironment(
            bundleURL: URL(fileURLWithPath: "/Applications/Floui.app"),
            feedURL: driver.feedURL
        ),
        driverFactory: { driver }
    )

    controller.startIfNeeded()

    #expect(driver.startCallCount == 1)
    #expect(controller.state.isAvailable)
    #expect(controller.state.canCheckForUpdates)
    #expect(controller.state.feedURL == driver.feedURL)
    #expect(controller.state.automaticallyChecksForUpdates)
    #expect(controller.state.automaticallyDownloadsUpdates == false)
    #expect(controller.state.statusMessage == "Ready to check for updates.")
    #expect(controller.state.lastError == nil)
}

@MainActor
@Test("Updater controller surfaces startup failures")
func updaterControllerSurfacesStartupFailures() {
    let driver = MockAppUpdaterDriver()
    driver.startError = AppUpdaterError.startupFailed("Sparkle failed to start.")
    let controller = AppUpdaterController(
        environment: AppUpdaterEnvironment(
            bundleURL: URL(fileURLWithPath: "/Applications/Floui.app"),
            feedURL: driver.feedURL
        ),
        driverFactory: { driver }
    )

    controller.startIfNeeded()

    #expect(driver.startCallCount == 1)
    #expect(controller.state.canCheckForUpdates == false)
    #expect(controller.state.statusMessage == "Updater unavailable.")
    #expect(controller.state.lastError == "Sparkle failed to start.")
}

@MainActor
@Test("Updater controller propagates manual update checks and setting changes")
func updaterControllerChecksAndPersistsSettings() {
    let driver = MockAppUpdaterDriver()
    let controller = AppUpdaterController(
        environment: AppUpdaterEnvironment(
            bundleURL: URL(fileURLWithPath: "/Applications/Floui.app"),
            feedURL: driver.feedURL
        ),
        driverFactory: { driver }
    )

    controller.startIfNeeded()
    controller.setAutomaticallyChecksForUpdates(false)
    controller.setAutomaticallyDownloadsUpdates(true)
    controller.checkForUpdates()

    #expect(driver.automaticallyChecksForUpdates == false)
    #expect(driver.automaticallyDownloadsUpdates == true)
    #expect(driver.checkCallCount == 1)
    #expect(controller.state.statusMessage == "Checking for updates…")
    #expect(controller.state.lastError == nil)
}

