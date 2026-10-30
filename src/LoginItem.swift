import Foundation
import ServiceManagement

// Launch at login through SMAppService (macOS 13+). The system owns this state —
// the user can also change it in System Settings › General › Login Items — so the
// toggle always shows the live status instead of a stored preference.
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    init() { refresh() }

    // Registered, whether or not the user still has to approve it.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    // A login item registered from a translocated or temporary copy (the DMG,
    // Downloads, a build folder) breaks once that copy goes away.
    var canRegister: Bool { Self.isInstalled(bundlePath: Bundle.main.bundlePath) }

    static func isInstalled(bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") { return false }
        let userApplications = (home as NSString).appendingPathComponent("Applications") + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications)
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if status != current { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
