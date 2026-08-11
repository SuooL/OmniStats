import SwiftUI
import AppKit
import Sparkle

// Repository coordinates — the single source of truth for links.
enum Repo {
    static let owner = "SuooL"
    static let name  = "OmniStats"
    static var url: String { "https://github.com/\(owner)/\(name)" }
    static var releasesURL: String { url + "/releases" }
}

// Thin SwiftUI-friendly wrapper over Sparkle's SPUUpdater.
//
// Sparkle owns the whole update cycle — scheduled checks (configured via the
// SU* keys in Info.plist), download, EdDSA verification, and the install/relaunch
// UI. This wrapper exposes only what the Settings pane binds to. Updates are
// served from a static appcast (a release asset), so the check never touches the
// rate-limited GitHub REST API.
final class Updater: NSObject, ObservableObject {
    // Published so the "Check for Updates…" button enables/disables in step with
    // Sparkle (it's busy while a check/download is already in flight).
    @Published private(set) var canCheckForUpdates = false

    private let updater: SPUUpdater
    private var kvo: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        super.init()
        canCheckForUpdates = updater.canCheckForUpdates
        kvo = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            DispatchQueue.main.async { self?.canCheckForUpdates = u.canCheckForUpdates }
        }
    }

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // Sparkle persists these in its own defaults; mirror them for the toggles.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates()  { updater.checkForUpdates() }
    func openRepo()         { if let u = URL(string: Repo.url) { NSWorkspace.shared.open(u) } }
    func openReleasePage()  { if let u = URL(string: Repo.releasesURL) { NSWorkspace.shared.open(u) } }
}
