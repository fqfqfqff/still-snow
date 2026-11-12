import AppKit
import Sparkle

final class AppUpdates: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
#if UPDATE_TEST
    private var installImmediately = false
#endif

    var available: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticInstallation: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
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
                                                   updaterDelegate: self, userDriverDelegate: nil)
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
