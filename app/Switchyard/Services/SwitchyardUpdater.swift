import Foundation
import Sparkle

struct AppUpdateConfiguration: Equatable {
    let isEnabled: Bool
    let feedURL: URL?
    let publicKey: String?

    init(infoDictionary: [String: Any]) {
        isEnabled = infoDictionary["SwitchyardUpdatesEnabled"] as? Bool ?? false
        feedURL = (infoDictionary["SUFeedURL"] as? String).flatMap(URL.init(string:))
        publicKey = infoDictionary["SUPublicEDKey"] as? String
    }

    var isUsable: Bool {
        guard isEnabled,
              feedURL?.scheme?.lowercased() == "https",
              feedURL?.host != nil,
              let publicKey,
              Data(base64Encoded: publicKey)?.count == 32 else {
            return false
        }
        return true
    }
}

@MainActor
final class SwitchyardUpdater: NSObject, ObservableObject {
    @Published private(set) var availableVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var isPresentingUpdate = false
    @Published private(set) var errorMessage: String?

    private let configuration: AppUpdateConfiguration
    private let probeInterval: TimeInterval
    private var lastProbeDate: Date?
    private var shouldInstallImmediately = false
    private var probeTimer: Timer?
    private var updaterController: SPUStandardUpdaterController?

    init(
        bundle: Bundle = .main,
        probeInterval: TimeInterval = 15 * 60
    ) {
        configuration = AppUpdateConfiguration(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
        self.probeInterval = probeInterval
        super.init()
    }

    var isUpdateAvailable: Bool {
        availableVersion != nil
    }

    func start() {
        guard configuration.isUsable, updaterController == nil else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        checkForUpdatesIfNeeded(force: true)

        let timer = Timer(
            timeInterval: probeInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForUpdatesIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    func checkForUpdatesIfNeeded(
        force: Bool = false,
        now: Date = Date()
    ) {
        guard let updater = updaterController?.updater,
              !isChecking,
              !isPresentingUpdate,
              !updater.sessionInProgress else {
            return
        }
        if !force,
           let lastProbeDate,
           now.timeIntervalSince(lastProbeDate) < probeInterval {
            return
        }

        lastProbeDate = now
        isChecking = true
        updater.checkForUpdateInformation()
    }

    func downloadAndInstall() {
        guard isUpdateAvailable,
              let updater = updaterController?.updater,
              updater.canCheckForUpdates,
              !updater.sessionInProgress else {
            return
        }

        errorMessage = nil
        isPresentingUpdate = true
        shouldInstallImmediately = true
        updater.automaticallyDownloadsUpdates = true
        updater.checkForUpdatesInBackground()
    }

    func dismissError() {
        errorMessage = nil
    }
}

extension SwitchyardUpdater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        didFindValidUpdate item: SUAppcastItem
    ) {
        availableVersion = item.displayVersionString
        isChecking = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        isChecking = false
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if shouldInstallImmediately, let error {
            errorMessage = error.localizedDescription
        }
        isChecking = false
        isPresentingUpdate = false
        shouldInstallImmediately = false
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard shouldInstallImmediately else { return false }
        immediateInstallHandler()
        return true
    }
}
