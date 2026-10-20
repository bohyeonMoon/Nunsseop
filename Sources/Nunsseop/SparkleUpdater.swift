import AppKit
import Sparkle

/// Sparkle, for a copy that replaces itself (`UpdateMethod.sparkle`). `UpdateChecker` still finds new versions through GitHub;
/// "Install Update" hands over to Sparkle's window, which shows what's new, downloads the update, checks its EdDSA and Apple
/// signatures, installs it and restarts Nunsseop.
@MainActor
final class SparkleUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()

    /// Sparkle couldn't offer the version GitHub reports, or failed on the way; Settings offers the DMG instead.
    @Published private(set) var failed = false

    /// Made on start: Sparkle keeps a weak reference to its delegate, which this shared object outlives.
    private var controller: SPUStandardUpdaterController?

    /// Started at launch so an update Sparkle already downloaded is installed when Nunsseop quits. Info.plist turns its
    /// own scheduled checks off.
    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func install() {
        start()
        failed = false
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if Self.offersDownload(after: error.map { ($0 as NSError).code }) { failed = true }
    }

    /// Any error but the user turning down the authorization prompt, including "no update found" while GitHub has one.
    nonisolated static func offersDownload(after errorCode: Int?) -> Bool {
        guard let errorCode else { return false }
        return errorCode != Int(SUError.installationCanceledError.rawValue)
    }
}
