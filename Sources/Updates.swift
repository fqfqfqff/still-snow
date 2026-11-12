import AppKit
import Combine
import Sparkle

final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var checkingObservation: NSKeyValueObservation?
    @Published private(set) var canCheck = false

    var requiresInstallation: Bool {
        let bundle = Bundle.main.bundleURL
        if bundle.pathComponents.contains("AppTranslocation") { return true }
        return (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
#if UPDATE_TEST
    private var installImmediately = false
#endif

    var available: Bool { controller != nil }
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticInstallation: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard !requiresInstallation, let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URLComponents(string: feed),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
#if UPDATE_TEST
        let localTestFeed = url.scheme == "http" && url.host == "127.0.0.1"
#else
        let localTestFeed = false
#endif
        guard url.scheme == "https" || localTestFeed else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                   updaterDelegate: self, userDriverDelegate: self)
        checkingObservation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            self?.canCheck = updater.canCheckForUpdates
        }
#if UPDATE_TEST
        if localTestFeed && CommandLine.arguments.contains("--verify-update") {
            installImmediately = true
            controller?.updater.checkForUpdatesInBackground()
        }
#endif
    }

    func check() {
        guard canCheck else { return }
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

#if UPDATE_TEST
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        guard installImmediately else { return false }
        DispatchQueue.main.async(execute: install)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        guard let error else { return }
        NSLog("Update verification: %@", error.localizedDescription)
    }
#endif
}
