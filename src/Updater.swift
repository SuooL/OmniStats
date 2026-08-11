import SwiftUI
import AppKit

// Repository coordinates — the single source of truth for links & updates.
enum Repo {
    static let owner = "SuooL"
    static let name  = "OmniStats"
    static var url: String { "https://github.com/\(owner)/\(name)" }
    static var releasesURL: String { url + "/releases" }
    static var apiLatest: String { "https://api.github.com/repos/\(owner)/\(name)/releases/latest" }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let name: String?
    let body: String?
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let assets: [Asset]
}

// Checks GitHub Releases for a newer version and can self-replace the running
// .app ("hot update"): download the release zip, unpack, swap the bundle, relaunch.
//
// Auto flow (Prowl-like, opt-in via config): a periodic background check finds an
// update → downloads the zip silently → shows one confirm dialog ("Install &
// Relaunch?") → hot-swaps and relaunches on confirm. Never restarts unprompted.
final class Updater: ObservableObject {
    @Published var checking = false
    @Published var downloading = false
    @Published var status = ""
    @Published var updateAvailable = false
    @Published var readyToInstall = false        // downloaded, awaiting install
    @Published var latestVersion: String?

    private var releaseURL = Repo.releasesURL
    private var zipURL: String?
    private var releaseNotes = ""
    private var pendingZipPath: String?
    private var autoDownload = true
    private var timer: Timer?
    var demoMode = false                          // --demo-update: show the dialog without swapping

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // Start background update checks: once now (throttled) and every 6h after.
    func startAutoChecks(enabled: Bool, autoDownload: Bool) {
        self.autoDownload = autoDownload
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        if now - last > 3600 {                    // at most hourly across relaunches
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
            check(silent: true)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            self?.check(silent: true)
        }
    }

    func check(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if !silent { status = L.t("u.checking") }
        var req = URLRequest(url: URL(string: Repo.apiLatest)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                self.checking = false
                guard let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.status = silent ? "" : L.t("u.noRelease"); return
                }
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = latest
                self.releaseURL = rel.html_url
                self.releaseNotes = rel.body ?? ""
                self.zipURL = rel.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url
                if self.isNewer(latest, than: self.currentVersion) {
                    self.updateAvailable = true
                    self.status = L.f("u.newVersion", latest)
                    // Background detection + opt-in → download quietly, then prompt.
                    if silent && self.autoDownload && !self.readyToInstall && !self.downloading {
                        self.startDownload()
                    }
                } else {
                    self.updateAvailable = false
                    self.status = silent ? "" : L.f("u.upToDate", self.currentVersion)
                }
            }
        }.resume()
    }

    // Manual "download & install" button.
    func downloadAndInstall() {
        if readyToInstall { promptInstall() } else { startDownload() }
    }
    // Settings "install & relaunch" button (already downloaded → explicit, no extra prompt).
    func installNow() { if let z = pendingZipPath { applyUpdate(zipPath: z) } }

    private func startDownload() {
        guard !downloading, !readyToInstall else { return }
        guard let z = zipURL, let url = URL(string: z) else { openReleasePage(); return }
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath) else {
            status = L.t("u.notWritable"); openReleasePage(); return
        }
        downloading = true
        status = L.t("u.downloading")
        URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            guard let tmp else {
                DispatchQueue.main.async { self.downloading = false; self.status = L.t("u.downloadFailed") }
                return
            }
            // ditto needs a .zip suffix
            let zipPath = NSTemporaryDirectory() + "OmniStats-update.zip"
            try? FileManager.default.removeItem(atPath: zipPath)
            let moved = (try? FileManager.default.moveItem(atPath: tmp.path, toPath: zipPath)) != nil
            DispatchQueue.main.async {
                self.downloading = false
                guard moved else { self.status = L.t("u.downloadFailed"); return }
                self.pendingZipPath = zipPath
                self.readyToInstall = true
                self.status = L.f("u.downloaded", self.latestVersion ?? "")
                self.promptInstall()
            }
        }.resume()
    }

    // The single confirmation before a hot-swap + relaunch.
    func promptInstall() {
        guard pendingZipPath != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L.f("u.readyTitle", latestVersion ?? currentVersion)
        var info = L.t("u.readyBody")
        let notes = releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(500)) }
        alert.informativeText = info
        alert.addButton(withTitle: L.t("u.installNow"))       // default
        alert.addButton(withTitle: L.t("u.later"))
        alert.addButton(withTitle: L.t("a.viewReleaseNotes"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: if let z = pendingZipPath { applyUpdate(zipPath: z) }
        case .alertThirdButtonReturn: openReleasePage()       // stays downloaded; install later from Settings
        default: break                                        // "Later": keep it ready
        }
    }

    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func openReleasePage() { if let u = URL(string: releaseURL) { NSWorkspace.shared.open(u) } }
    func openRepo()        { if let u = URL(string: Repo.url) { NSWorkspace.shared.open(u) } }

    // For screenshots/testing the update dialog without touching the bundle.
    func demoPrompt() {
        demoMode = true
        latestVersion = "9.9.9"
        releaseNotes = "• Menu-bar network & top-process readouts\n• Auto hot-update\n• New app icon"
        pendingZipPath = NSTemporaryDirectory() + "OmniStats-demo.zip"
        readyToInstall = true
        updateAvailable = true
        promptInstall()
    }

    // Best-effort in-place update. Falls back to opening the release page.
    private func applyUpdate(zipPath: String) {
        if demoMode { status = "(demo) install & relaunch"; return }
        let bundle = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let work = NSTemporaryDirectory() + "OmniStats-update-x"
        let script = """
        set -e
        rm -rf "\(work)"; mkdir -p "\(work)"
        /usr/bin/ditto -x -k "\(zipPath)" "\(work)"
        NEW=$(/usr/bin/find "\(work)" -maxdepth 2 -name "*.app" -print -quit)
        [ -n "$NEW" ] || exit 1
        for i in $(seq 1 60); do /bin/kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        /bin/rm -rf "\(bundle)"
        /usr/bin/ditto "$NEW" "\(bundle)"
        /usr/bin/xattr -dr com.apple.quarantine "\(bundle)" 2>/dev/null || true
        /usr/bin/open "\(bundle)"
        """
        let sh = NSTemporaryDirectory() + "OmniStats-update.sh"
        try? script.write(toFile: sh, atomically: true, encoding: .utf8)
        status = L.t("u.installing")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh]
        do { try p.run() } catch { status = L.t("u.installFailed"); openReleasePage(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}
