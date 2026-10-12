import Foundation
import Sparkle

/// Automatic updates through Sparkle (the standard open-source Mac updater, MIT licence).
/// Updates are only checked once a feed address (SUFeedURL) and signing key (SUPublicEDKey) are set in
/// Info.plist; until then the button explains that updates aren't set up yet.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = (!feed.isEmpty && !key.isEmpty)
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
