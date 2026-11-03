import Sparkle

/// In-app updates (Sparkle 2): reads `appcast.xml` of the latest GitHub release, checks its EdDSA signature and the
/// Developer ID signature of the new build, then replaces the app. Feed and public key are in Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`). Debug builds never update, so a development build is not replaced by a release.
@MainActor
enum Updater {
    #if DEBUG
    private static let controller: SPUStandardUpdaterController? = nil
    #else
    private static let controller: SPUStandardUpdaterController? =
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    static var isAvailable: Bool { controller != nil }

    /// Starts the scheduled background checks.
    static func start() { _ = controller }

    static func checkForUpdates() { controller?.checkForUpdates(nil) }
}
