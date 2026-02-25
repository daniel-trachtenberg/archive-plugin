import Foundation
import Sparkle

@MainActor
final class SparkleUpdateController: NSObject {
    static let shared = SparkleUpdateController()

    private let updaterController: SPUStandardUpdaterController

    private override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
