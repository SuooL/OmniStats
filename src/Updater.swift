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
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let assets: [Asset]
}

// Checks GitHub Releases for a newer version and can self-replace the running
// .app ("hot update"): download the release zip, unpack, swap the bundle, relaunch.
final class Updater: ObservableObject {
    @Published var checking = false
    @Published var status = ""
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    private var releaseURL = Repo.releasesURL
    private var zipURL: String?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    func checkAutomatically(_ enabled: Bool) {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        guard now - last > 86_400 else { return }   // at most once per day
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if !silent { status = "正在检查更新…" }
        var req = URLRequest(url: URL(string: Repo.apiLatest)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async {
                self.checking = false
                guard let data, let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    self.status = silent ? "" : "暂无发布或检查失败"; return
                }
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = latest
                self.releaseURL = rel.html_url
                self.zipURL = rel.assets.first { $0.name.hasSuffix(".zip") }?.browser_download_url
                if self.isNewer(latest, than: self.currentVersion) {
                    self.updateAvailable = true
                    self.status = "发现新版本 \(latest)"
                } else {
                    self.updateAvailable = false
                    self.status = silent ? "" : "已是最新版本 (\(self.currentVersion))"
                }
            }
        }.resume()
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

    // Best-effort in-place update. Falls back to opening the release page.
    func installUpdate() {
        guard let z = zipURL, let url = URL(string: z),
              FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath) else {
            openReleasePage(); return
        }
        status = "正在下载更新…"
        URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            guard let tmp else { DispatchQueue.main.async { self.status = "下载失败"; self.openReleasePage() }; return }
            // ditto needs a .zip suffix
            let zipPath = NSTemporaryDirectory() + "OmniStats-update.zip"
            try? FileManager.default.removeItem(atPath: zipPath)
            try? FileManager.default.moveItem(atPath: tmp.path, toPath: zipPath)
            self.applyUpdate(zipPath: zipPath)
        }.resume()
    }

    private func applyUpdate(zipPath: String) {
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
        status = "正在安装,应用即将重启…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [sh]
        do { try p.run() } catch { status = "安装失败"; openReleasePage(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }
}
