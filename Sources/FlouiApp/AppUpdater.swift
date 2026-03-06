import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

struct AppUpdaterEnvironment: Equatable {
    let bundleURL: URL
    let feedURL: URL?

    init(bundleURL: URL, feedURL: URL?) {
        self.bundleURL = bundleURL
        self.feedURL = feedURL
    }

    init(bundle: Bundle) {
        bundleURL = bundle.bundleURL

        if let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           let feedURL = URL(string: feedURLString),
           !feedURLString.isEmpty
        {
            self.feedURL = feedURL
        } else {
            feedURL = nil
        }
    }

    static var live: AppUpdaterEnvironment {
        AppUpdaterEnvironment(bundle: .main)
    }

    var support: AppUpdaterSupport {
        guard bundleURL.pathExtension == "app" else {
            return .unsupported("Updater is only available from a bundled .app release build.")
        }

        guard feedURL != nil else {
            return .unsupported("Updater is disabled until SUFeedURL is configured in the app bundle.")
        }

        return .supported
    }
}

enum AppUpdaterSupport: Equatable {
    case supported
    case unsupported(String)
}

enum AppUpdaterError: LocalizedError, Equatable {
    case startupFailed(String)
    case unavailable(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case let .startupFailed(message),
             let .unavailable(message),
             let .runtime(message):
            return message
        }
    }
}

struct AppUpdaterState: Equatable {
    var isAvailable: Bool
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var allowsAutomaticUpdates: Bool
    var feedURL: URL?
    var lastUpdateCheckDate: Date?
    var statusMessage: String
    var lastError: String?

    static func unavailable(reason: String, feedURL: URL?) -> AppUpdaterState {
        AppUpdaterState(
            isAvailable: false,
            canCheckForUpdates: false,
            automaticallyChecksForUpdates: false,
            automaticallyDownloadsUpdates: false,
            allowsAutomaticUpdates: false,
            feedURL: feedURL,
            lastUpdateCheckDate: nil,
            statusMessage: reason,
            lastError: nil
        )
    }
}

@MainActor
protocol AppUpdaterDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var feedURL: URL? { get }
    var lastUpdateCheckDate: Date? { get }

    func start() throws
    func checkForUpdates() throws
}

@MainActor
final class AppUpdaterController: ObservableObject {
    @Published private(set) var state: AppUpdaterState

    private let environment: AppUpdaterEnvironment
    private let driverFactory: () -> AppUpdaterDriving
    private var driver: AppUpdaterDriving?

    init(
        environment: AppUpdaterEnvironment = .live,
        driverFactory: @escaping () -> AppUpdaterDriving = {
            #if canImport(Sparkle)
            SparkleAppUpdaterDriver()
            #else
            UnsupportedAppUpdaterDriver(reason: "Sparkle is unavailable in this build.")
            #endif
        }
    ) {
        self.environment = environment
        self.driverFactory = driverFactory

        switch environment.support {
        case .supported:
            state = AppUpdaterState(
                isAvailable: true,
                canCheckForUpdates: false,
                automaticallyChecksForUpdates: false,
                automaticallyDownloadsUpdates: false,
                allowsAutomaticUpdates: false,
                feedURL: environment.feedURL,
                lastUpdateCheckDate: nil,
                statusMessage: "Updater is initializing.",
                lastError: nil
            )
        case let .unsupported(reason):
            state = .unavailable(reason: reason, feedURL: environment.feedURL)
        }
    }

    func startIfNeeded() {
        guard case .supported = environment.support else {
            return
        }

        if let driver {
            refreshState(from: driver, statusMessage: "Ready to check for updates.", lastError: nil)
            return
        }

        let driver = driverFactory()
        self.driver = driver

        do {
            try driver.start()
            refreshState(from: driver, statusMessage: "Ready to check for updates.", lastError: nil)
        } catch {
            let message = error.localizedDescription
            state.canCheckForUpdates = false
            state.statusMessage = "Updater unavailable."
            state.lastError = message
        }
    }

    func checkForUpdates() {
        guard let driver else {
            if case let .unsupported(reason) = environment.support {
                state.lastError = reason
            }
            return
        }

        do {
            try driver.checkForUpdates()
            refreshState(from: driver, statusMessage: "Checking for updates…", lastError: nil)
        } catch {
            state.lastError = error.localizedDescription
            state.statusMessage = "Updater unavailable."
            state.canCheckForUpdates = false
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let driver else {
            return
        }

        driver.automaticallyChecksForUpdates = enabled
        refreshState(from: driver, statusMessage: state.statusMessage, lastError: nil)
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let driver, driver.allowsAutomaticUpdates else {
            return
        }

        driver.automaticallyDownloadsUpdates = enabled
        refreshState(from: driver, statusMessage: state.statusMessage, lastError: nil)
    }

    private func refreshState(from driver: AppUpdaterDriving, statusMessage: String, lastError: String?) {
        state = AppUpdaterState(
            isAvailable: true,
            canCheckForUpdates: driver.canCheckForUpdates,
            automaticallyChecksForUpdates: driver.automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: driver.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: driver.allowsAutomaticUpdates,
            feedURL: driver.feedURL ?? environment.feedURL,
            lastUpdateCheckDate: driver.lastUpdateCheckDate,
            statusMessage: statusMessage,
            lastError: lastError
        )
    }
}

@MainActor
private final class UnsupportedAppUpdaterDriver: AppUpdaterDriving {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    var canCheckForUpdates: Bool { false }
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set {}
    }
    var automaticallyDownloadsUpdates: Bool {
        get { false }
        set {}
    }
    var allowsAutomaticUpdates: Bool { false }
    var feedURL: URL? { nil }
    var lastUpdateCheckDate: Date? { nil }

    func start() throws {
        throw AppUpdaterError.unavailable(reason)
    }

    func checkForUpdates() throws {
        throw AppUpdaterError.unavailable(reason)
    }
}

#if canImport(Sparkle)
@MainActor
private final class SparkleAppUpdaterDriver: NSObject, AppUpdaterDriving {
    private let controller: SPUStandardUpdaterController
    private var started = false

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    var canCheckForUpdates: Bool {
        started && controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var allowsAutomaticUpdates: Bool {
        controller.updater.allowsAutomaticUpdates
    }

    var feedURL: URL? {
        controller.updater.feedURL
    }

    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    func start() throws {
        guard !started else {
            return
        }

        do {
            try controller.updater.start()
        } catch {
            throw AppUpdaterError.startupFailed(error.localizedDescription)
        }

        _ = controller.updater.clearFeedURLFromUserDefaults()
        started = true
    }

    func checkForUpdates() throws {
        if !started {
            try start()
        }

        guard controller.updater.canCheckForUpdates else {
            throw AppUpdaterError.unavailable("An update session is already in progress.")
        }

        controller.checkForUpdates(nil)
    }
}
#endif

struct UpdaterSettingsView: View {
    @ObservedObject var updaterController: AppUpdaterController

    var body: some View {
        Form {
            Section("Status") {
                Text(updaterController.state.statusMessage)
                    .font(.body.weight(.medium))

                if let error = updaterController.state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let feedURL = updaterController.state.feedURL {
                    LabeledContent("Feed") {
                        Text(feedURL.absoluteString)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }

                LabeledContent("Last Check") {
                    Text(lastCheckDescription)
                        .font(.caption)
                }
            }

            Section("Preferences") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updaterController.state.automaticallyChecksForUpdates },
                        set: { updaterController.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .disabled(!updaterController.state.isAvailable)

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { updaterController.state.automaticallyDownloadsUpdates },
                        set: { updaterController.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!updaterController.state.isAvailable || !updaterController.state.allowsAutomaticUpdates)

                Button("Check for Updates Now") {
                    updaterController.checkForUpdates()
                }
                .disabled(!updaterController.state.canCheckForUpdates)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 240)
    }

    private var lastCheckDescription: String {
        guard let date = updaterController.state.lastUpdateCheckDate else {
            return "Never"
        }

        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
