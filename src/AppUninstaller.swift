import AppKit

struct InstalledApp: Identifiable, Equatable, Hashable {
    let url: URL
    let bundleID: String
    let name: String
    let version: String?
    let isAppStore: Bool
    var cask: String? = nil      // Homebrew cask token, when Homebrew installed it
    var zap: [String] = []       // that cask's curated cleanup paths
    var id: String { url.path }
}

struct Leftover: Identifiable, Equatable {
    enum Kind: String {
        case app, support, caches, preferences, container, groupContainer, launchAgent, launchDaemon
        case helper, logs, savedState, webData, receipt, scripts, other
    }
    let url: URL
    let kind: Kind
    let system: Bool      // outside the home folder: removed with administrator rights
    let protected: Bool   // another app's container: macOS requires Full Disk Access
    var byName = false    // matched the app's name rather than its identifier
    var fromCask = false  // listed by the app's Homebrew cask
    var id: String { url.path }
}

enum AppCatalog {
    // Top level plus one folder deep (e.g. /Applications/Utilities or a vendor
    // folder). Apple's own apps and OmniStats itself are never offered.
    static func installedApps(in roots: [URL], excluding ownBundleID: String?) -> [InstalledApp] {
        let fileManager = FileManager.default
        var found: [InstalledApp] = []
        var seen = Set<String>()
        func consider(_ url: URL) {
            guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !id.lowercased().hasPrefix("com.apple."), id != ownBundleID, seen.insert(url.path).inserted else { return }
            let info = bundle.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            found.append(InstalledApp(url: url, bundleID: id, name: name,
                                      version: info["CFBundleShortVersionString"] as? String,
                                      isAppStore: fileManager.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)))
        }
        for root in roots {
            for item in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                if item.pathExtension == "app" { consider(item); continue }
                guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                for child in (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] { consider(child) }
            }
        }
        let casks = homebrewCasks(in: caskrooms)
        for index in found.indices {
            if let cask = casks[found[index].url.standardizedFileURL.path] { found[index].cask = cask.token; found[index].zap = cask.zap }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var caskrooms = [URL(fileURLWithPath: "/opt/homebrew/Caskroom"), URL(fileURLWithPath: "/usr/local/Caskroom")]

    // Caskroom/<token>/<version>/<App>.app is a symlink to the installed app; the
    // install receipt carries Homebrew's curated "zap" cleanup list.
    static func homebrewCasks(in caskrooms: [URL]) -> [String: (token: String, zap: [String])] {
        let fileManager = FileManager.default
        var result: [String: (token: String, zap: [String])] = [:]
        for room in caskrooms {
            for cask in (try? fileManager.contentsOfDirectory(at: room, includingPropertiesForKeys: nil)) ?? [] {
                let receipt = cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
                var zap: [String] = []
                if let data = try? Data(contentsOf: receipt),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let artifacts = json["uninstall_artifacts"] as? [[String: Any]] {
                    for artifact in artifacts {
                        for stanza in (artifact["zap"] as? [[String: Any]]) ?? [] {
                            for key in ["trash", "delete"] {
                                if let paths = stanza[key] as? [String] { zap += paths }
                                else if let path = stanza[key] as? String { zap.append(path) }
                            }
                        }
                    }
                }
                for version in (try? fileManager.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil)) ?? []
                where !version.lastPathComponent.hasPrefix(".") {
                    for link in (try? fileManager.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
                    where link.pathExtension == "app" {
                        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { continue }
                        let resolved = URL(fileURLWithPath: target, relativeTo: version).standardizedFileURL.path
                        result[resolved] = (cask.lastPathComponent, zap)
                    }
                }
            }
        }
        return result
    }
}

// Finds an app's files by its bundle identifier first. Names only count when
// they are distinctive, so folders shared by a vendor's apps stay untouched.
struct LeftoverScanner {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var root = URL(fileURLWithPath: "/")

    // Vendor folders shared by several apps, and words too generic to identify one.
    static let sharedFolders: Set<String> = [
        "google", "microsoft", "adobe", "apple", "jetbrains", "mozilla", "steam", "epic", "oracle", "java",
        "python", "crashreporter", "icloud", "addressbook", "cloudkit", "knowledge", "syncservices", "fonts",
        "uninstaller", "installer", "updater", "launcher", "helper", "agent", "service", "setup", "support",
        "data", "cache", "logs", "code", "desktop", "client", "studio", "music", "notes", "mail", "photos",
        "player", "browser", "editor", "viewer", "manager", "monitor", "tools", "utility", "utilities",
    ]
    // Well-known apps whose data folder has a generic name.
    static let knownFolders: [String: [String]] = [
        "com.microsoft.vscode": ["Code"], "com.microsoft.vscodeinsiders": ["Code - Insiders"],
    ]

    // The identifier itself or a component of it: "com.x.app.helper", "com.x.app_stats.sqlite3".
    static func matchesBundleID(_ name: String, _ bundleID: String) -> Bool {
        let name = name.lowercased(), id = bundleID.lowercased()
        return name == id || name.hasPrefix(id + ".") || name.hasPrefix(id + "_")
    }
    static func matchesGroup(_ name: String, _ bundleID: String) -> Bool {
        let name = name.lowercased(), id = bundleID.lowercased()
        return name == "group." + id || name.hasSuffix("." + id) || name.contains("." + id + ".")
    }
    static func matchesName(_ name: String, _ appName: String, bundleID: String = "") -> Bool {
        let folder = name.lowercased()
        if knownFolders[bundleID.lowercased()]?.contains(where: { $0.lowercased() == folder }) == true { return true }
        let app = appName.lowercased()
        return app.count >= 4 && !sharedFolders.contains(app) && folder == app
    }

    func scan(_ app: InstalledApp) -> [Leftover] {
        var items: [Leftover] = []
        var paths = Set<String>()
        func add(_ url: URL, _ kind: Leftover.Kind, system: Bool, protected: Bool = false, byName: Bool = false, fromCask: Bool = false) {
            guard paths.insert(url.standardizedFileURL.path).inserted else { return }
            items.append(Leftover(url: url, kind: kind, system: system, protected: protected, byName: byName, fromCask: fromCask))
        }
        let owner = (try? FileManager.default.attributesOfItem(atPath: app.url.path)[.ownerAccountID] as? NSNumber)?.intValue
        add(app.url, .app, system: owner == 0)

        let user = home.appendingPathComponent("Library"), library = root.appendingPathComponent("Library")
        func look(_ directory: URL, _ kind: Leftover.Kind, system: Bool, byName: Bool = false, protected: Bool = false,
                  match: ((String) -> Bool)? = nil) {
            for url in Self.contents(directory) {
                let name = url.lastPathComponent
                let stem = (name as NSString).deletingPathExtension
                if match?(name) ?? (Self.matchesBundleID(name, app.bundleID) || Self.matchesBundleID(stem, app.bundleID)) {
                    add(url, kind, system: system, protected: protected)
                } else if match == nil, byName, Self.matchesName(name, app.name, bundleID: app.bundleID) {
                    add(url, kind, system: system, protected: protected, byName: true)
                }
            }
        }
        for (base, system) in [(user, false), (library, true)] {
            look(base.appendingPathComponent("Application Support"), .support, system: system, byName: true)
            look(base.appendingPathComponent("Caches"), .caches, system: system, byName: !system)
            look(base.appendingPathComponent("Preferences"), .preferences, system: system)
            look(base.appendingPathComponent("Logs"), .logs, system: system, byName: true)
        }
        look(user.appendingPathComponent("Preferences/ByHost"), .preferences, system: false)
        look(user.appendingPathComponent("HTTPStorages"), .webData, system: false)
        look(user.appendingPathComponent("WebKit"), .webData, system: false)
        look(user.appendingPathComponent("Cookies"), .webData, system: false)
        look(user.appendingPathComponent("Saved Application State"), .savedState, system: false)
        look(user.appendingPathComponent("Application Scripts"), .scripts, system: false)
        look(user.appendingPathComponent("Containers"), .container, system: false, protected: true)
        look(user.appendingPathComponent("Group Containers"), .groupContainer, system: false, protected: true,
             match: { Self.matchesGroup($0, app.bundleID) })
        look(root.appendingPathComponent("private/var/db/receipts"), .receipt, system: true)

        // launchd jobs: by name, or by content pointing at this app (also finds
        // the privileged helper a daemon runs).
        var helperPaths: [String] = []
        for (directory, kind, system) in [(user.appendingPathComponent("LaunchAgents"), Leftover.Kind.launchAgent, false),
                                          (library.appendingPathComponent("LaunchAgents"), .launchAgent, true),
                                          (library.appendingPathComponent("LaunchDaemons"), .launchDaemon, true)] {
            for url in Self.contents(directory) where url.pathExtension == "plist" {
                let job = Self.launchJob(url)
                let associated = job.associated.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
                let insideApp = job.program.map { $0.hasPrefix(app.url.path + "/") } ?? false
                if Self.matchesBundleID(url.deletingPathExtension().lastPathComponent, app.bundleID) || associated || insideApp {
                    add(url, kind, system: system)
                    if let program = job.program { helperPaths.append(program) }
                }
            }
        }
        let helpers = library.appendingPathComponent("PrivilegedHelperTools")
        for url in Self.contents(helpers)
        where Self.matchesBundleID(url.lastPathComponent, app.bundleID) || helperPaths.contains(url.path)
            || helperPaths.contains(Self.systemPath(url, root: root)) {
            add(url, .helper, system: true)
        }
        for path in app.zap {
            for url in expandZap(path) {
                guard let item = zapItem(url) else { continue }
                add(item.url, item.kind, system: item.system, protected: item.protected, fromCask: true)
            }
        }
        return items
    }

    // "~" and simple globs from a Homebrew zap stanza, existing paths only.
    func expandZap(_ path: String) -> [URL] {
        var expanded = path
        if expanded.hasPrefix("~/") { expanded = home.path + expanded.dropFirst(1) }
        else if expanded.hasPrefix("/") { expanded = (root.path == "/" ? "" : root.path) + expanded }
        else { return [] }
        let url = URL(fileURLWithPath: expanded)
        guard url.lastPathComponent.contains(where: { "*?[".contains($0) }) else {
            return FileManager.default.fileExists(atPath: url.path) ? [url] : []
        }
        let pattern = url.lastPathComponent
        return Self.contents(url.deletingLastPathComponent()).filter { fnmatch(pattern, $0.lastPathComponent, 0) == 0 }
    }

    // A zap path is only taken when it is an app's own item: never a home or
    // Library root, and outside home only where omnistats-cleaner may move it.
    func zapItem(_ url: URL) -> Leftover? {
        let path = url.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        let folderKinds: [String: Leftover.Kind] = [
            "Application Support": .support, "Caches": .caches, "Preferences": .preferences, "Logs": .logs,
            "LaunchAgents": .launchAgent, "LaunchDaemons": .launchDaemon, "PrivilegedHelperTools": .helper,
            "Saved Application State": .savedState, "Containers": .container, "Group Containers": .groupContainer,
            "HTTPStorages": .webData, "WebKit": .webData, "Cookies": .webData, "Application Scripts": .scripts,
        ]
        if path.hasPrefix(homePath + "/") {
            let parts = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
            let protectedTop: Set<String> = ["Library", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures",
                                             "Public", "Applications", ".Trash", ".ssh", ".config", ".local", ".cache", ".gnupg"]
            guard let first = parts.first, !(parts.count == 1 && protectedTop.contains(first)) else { return nil }
            if first == "Library" && parts.count < 3 { return nil }
            let kind = parts.count >= 3 && first == "Library" ? folderKinds[parts[1]] ?? .other : .other
            return Leftover(url: url, kind: kind, system: false, protected: kind == .container || kind == .groupContainer)
        }
        let systemPath = Self.systemPath(url, root: root)
        let parent = (systemPath as NSString).deletingLastPathComponent
        let allowed = ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
                       "/Library/Application Support", "/Library/Caches", "/Library/Logs", "/Library/Preferences"]
        guard allowed.contains(parent) else { return nil }
        return Leftover(url: url, kind: folderKinds[(parent as NSString).lastPathComponent] ?? .other, system: true, protected: false)
    }

    static func contents(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
    // A plist's associated apps and program path, read without loading the job.
    static func launchJob(_ url: URL) -> (associated: [String], program: String?) {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return ([], nil) }
        let associated = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        return (associated, program)
    }
    // The path as the real system sees it (tests scan a scratch root).
    static func systemPath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard rootPath != "/", path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count))
    }

    static func size(of url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return nil }
        var total: Int64 = 0
        for case let child as URL in walker {
            total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

struct OrphanGroup: Identifiable, Equatable {
    let bundleID: String
    let items: [Leftover]
    var id: String { bundleID }
}

// Leftovers of apps that are gone. Only reverse-DNS names count, an app any
// vendor sibling of is still installed is left alone (shared updaters and
// helpers), and a launchd job counts only when its program no longer exists.
enum OrphanScanner {
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "co", "cc", "me", "de", "jp", "cn", "ai", "dev", "pro", "md", "now", "tv", "us",
        "uk", "fr", "ru", "ch", "nl", "se", "info", "biz", "eu", "in", "it", "es", "be", "at", "au", "ca", "ly", "so", "sh",
        "im", "is", "xyz", "fm", "gg", "to", "ws", "hk", "tw", "kr", "edu", "one", "tech", "studio", "dk", "no", "fi", "pl",
    ]
    static let hostingPrefixes: Set<String> = ["io.github", "com.github", "io.gitlab", "com.gitee"]
    // Data that SDKs and system or developer tools keep under their own names
    // on behalf of apps that may well still be installed.
    static let notApps = [
        "com.apple.", "com.amplitude.", "com.segment.", "com.crashlytics", "com.hackemist.", "io.sentry", "com.google.firebase",
        "com.mixpanel", "com.bugsnag", "com.microsoft.appcenter", "com.facebook.sdk", "org.sparkle-project.", "org.cups.",
        "org.swift.", "org.freedesktop.", "org.python.", "org.llvm.", "com.google.keystone",
    ]

    // "com.x.app", "com.x.app.plist", "com.x.app_stats.sqlite3", "com.x.app.savedState" -> "com.x.app".
    static func identifier(in name: String) -> String? {
        let base = String(name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var parts = base.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let extensions: Set<String> = ["plist", "savedstate", "binarycookies", "sqlite", "sqlite3", "db", "log"]
        while let last = parts.last, extensions.contains(last.lowercased()) { parts.removeLast() }
        guard parts.count >= 3, topLevelDomains.contains(parts[0].lowercased()),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        return parts.joined(separator: ".")
    }
    static func vendor(_ id: String) -> String {
        let parts = id.lowercased().split(separator: ".").map(String.init)
        let depth = hostingPrefixes.contains(parts.prefix(2).joined(separator: ".")) ? 3 : 2
        return parts.prefix(depth).joined(separator: ".")
    }
    static func belongsToInstalled(_ id: String, installed: [String], vendors: Set<String>) -> Bool {
        let lower = id.lowercased()
        if notApps.contains(where: { lower.hasPrefix($0) }) || lower.hasSuffix("-cli") || lower.hasSuffix(".cli") { return true }
        if installed.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }
        return vendors.contains(vendor(lower))
    }

    static func scan(home: URL, root: URL, installedIDs: [String], isRegistered: (String) -> Bool) -> [OrphanGroup] {
        let installed = installedIDs.map { $0.lowercased() }
        let vendors = Set(installed.map(vendor))
        let user = home.appendingPathComponent("Library"), library = root.appendingPathComponent("Library")
        var found: [String: [Leftover]] = [:]
        var registered: [String: Bool] = [:]
        func orphaned(_ id: String) -> Bool {
            if belongsToInstalled(id, installed: installed, vendors: vendors) { return false }
            if let cached = registered[id] { return !cached }
            let known = isRegistered(id); registered[id] = known
            return !known
        }
        let folders: [(URL, Leftover.Kind, Bool, Bool)] = [
            (user.appendingPathComponent("Application Support"), .support, false, false),
            (user.appendingPathComponent("Caches"), .caches, false, false),
            (user.appendingPathComponent("Preferences"), .preferences, false, false),
            (user.appendingPathComponent("HTTPStorages"), .webData, false, false),
            (user.appendingPathComponent("WebKit"), .webData, false, false),
            (user.appendingPathComponent("Cookies"), .webData, false, false),
            (user.appendingPathComponent("Saved Application State"), .savedState, false, false),
            (user.appendingPathComponent("Logs"), .logs, false, false),
            (user.appendingPathComponent("Application Scripts"), .scripts, false, false),
            (user.appendingPathComponent("Containers"), .container, false, true),
            (library.appendingPathComponent("Application Support"), .support, true, false),
            (library.appendingPathComponent("Caches"), .caches, true, false),
        ]
        for (folder, kind, system, protected) in folders {
            for url in LeftoverScanner.contents(folder) {
                guard let id = identifier(in: url.lastPathComponent), orphaned(id) else { continue }
                found[id, default: []].append(Leftover(url: url, kind: kind, system: system, protected: protected))
            }
        }
        var programs = Set<String>()
        for (folder, kind, system) in [(user.appendingPathComponent("LaunchAgents"), Leftover.Kind.launchAgent, false),
                                       (library.appendingPathComponent("LaunchAgents"), .launchAgent, true),
                                       (library.appendingPathComponent("LaunchDaemons"), .launchDaemon, true)] {
            for url in LeftoverScanner.contents(folder) where url.pathExtension == "plist" {
                let job = LeftoverScanner.launchJob(url)
                if let program = job.program { programs.insert(program) }
                guard let program = job.program, let id = identifier(in: url.lastPathComponent),
                      !id.lowercased().hasPrefix("com.apple."),
                      !FileManager.default.fileExists(atPath: (root.path == "/" ? "" : root.path) + program),
                      !installed.contains(where: { id.lowercased() == $0 || id.lowercased().hasPrefix($0 + ".") }) else { continue }
                found[id, default: []].append(Leftover(url: url, kind: kind, system: system, protected: false))
            }
        }
        for url in LeftoverScanner.contents(library.appendingPathComponent("PrivilegedHelperTools")) {
            guard let id = identifier(in: url.lastPathComponent), orphaned(id),
                  !programs.contains(LeftoverScanner.systemPath(url, root: root)) else { continue }
            found[id, default: []].append(Leftover(url: url, kind: .helper, system: true, protected: false))
        }
        // "com.x.app.helper" joins "com.x.app" when both are present.
        let ids = found.keys.sorted { $0.count < $1.count }
        var groups: [String: [Leftover]] = [:]
        for id in ids {
            let owner = groups.keys.first { id.lowercased().hasPrefix($0.lowercased() + ".") } ?? id
            groups[owner, default: []] += found[id] ?? []
        }
        return groups.map { OrphanGroup(bundleID: $0.key, items: $0.value.sorted { $0.url.path < $1.url.path }) }
            .sorted { $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending }
    }

    // LaunchServices knows an app with this identifier somewhere (not in the Trash).
    static func isRegistered(_ id: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path) && !url.path.contains("/.Trash/")
    }
}

struct UninstallReport: Equatable {
    var moved: [String] = []
    var destinations: [String: String] = [:]   // where each moved item is now, when known
    var skipped: [Skip] = []
    var logURL: URL?
    struct Skip: Equatable { let path: String; let reason: String }

    // omnistats-cleaner prints "moved\t<path>\t<dest>" / "skipped\t<path>\t<reason>".
    mutating func absorbCleanerOutput(_ output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            if fields[0] == "moved" { moved.append(fields[1]); destinations[fields[1]] = fields[2] }
            else if fields[0] == "skipped" { skipped.append(Skip(path: fields[1], reason: fields[2])) }
        }
    }
}

enum Privacy {
    // macOS has no API for this: try a folder that only Full Disk Access opens.
    static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool? {
        for folder in ["Library/Safari", "Library/Mail", "Library/Messages"] {
            let url = home.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
        return nil
    }
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// Lists apps, finds leftovers, and moves everything to the Trash: the app first
// (stopping there if macOS refuses), then the user's files, then system files
// through one administrator prompt for omnistats-cleaner.
final class AppUninstaller: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var selected: InstalledApp?
    @Published private(set) var leftovers: [Leftover] = []
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var excluded = Set<String>()
    @Published private(set) var scanning = false
    @Published private(set) var working = false
    @Published private(set) var report: UninstallReport?
    @Published private(set) var fullDiskAccess: Bool?
    @Published private(set) var orphans: [OrphanGroup] = []
    @Published private(set) var orphanSizes: [String: Int64] = [:]
    @Published private(set) var orphanScanning = false
    @Published private(set) var orphansScanned = false
    @Published var orphanSelection = Set<String>()     // nothing is ticked until the user reviews it
    private let queue = DispatchQueue(label: "com.omnistats.uninstaller", qos: .userInitiated)
    private var generation = 0

    func reload() {
        fullDiskAccess = Privacy.hasFullDiskAccess()
        let roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let own = Bundle.main.bundleIdentifier
        queue.async { [weak self] in
            let found = AppCatalog.installedApps(in: roots, excluding: own)
            DispatchQueue.main.async { self?.apps = found }
        }
    }

    func select(_ app: InstalledApp?) {
        generation += 1
        selected = app; leftovers = []; sizes = [:]; excluded = []; report = nil
        guard let app else { return }
        scanning = true
        let current = generation
        queue.async { [weak self] in
            let items = LeftoverScanner().scan(app)
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.leftovers = items; self.scanning = false
                // Containers stay unticked without Full Disk Access: macOS would refuse them.
                if self.fullDiskAccess == false { self.excluded = Set(items.filter(\.protected).map(\.id)) }
            }
            for item in items {
                let size = LeftoverScanner.size(of: item.url)
                DispatchQueue.main.async {
                    guard let self, self.generation == current, let size else { return }
                    self.sizes[item.id] = size
                }
            }
        }
    }

    func clearReport() { report = nil }
    var chosen: [Leftover] { leftovers.filter { !excluded.contains($0.id) } }
    // A reset clears the app's data but keeps what installs and runs it.
    static let keptOnReset: Set<Leftover.Kind> = [.app, .receipt, .launchAgent, .launchDaemon, .helper]
    var resettable: [Leftover] { chosen.filter { !Self.keptOnReset.contains($0.kind) } }
    var chosenOrphans: [Leftover] { orphans.flatMap(\.items).filter { orphanSelection.contains($0.id) } }
    var isRunning: Bool {
        guard let selected else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID).isEmpty
    }
    func quitSelected(force: Bool) {
        guard let selected else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: selected.bundleID) {
            _ = force ? app.forceTerminate() : app.terminate()
        }
    }

    func scanOrphans() {
        guard !orphanScanning else { return }
        orphanScanning = true; orphanSelection = []; report = nil
        let installed = apps.map(\.bundleID)
        queue.async { [weak self] in
            let groups = OrphanScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser, root: URL(fileURLWithPath: "/"),
                                            installedIDs: installed, isRegistered: OrphanScanner.isRegistered)
            DispatchQueue.main.async {
                guard let self else { return }
                self.orphans = groups; self.orphanScanning = false; self.orphansScanned = true; self.orphanSizes = [:]
            }
            for item in groups.flatMap(\.items) {
                let size = LeftoverScanner.size(of: item.url)
                DispatchQueue.main.async { if let size { self?.orphanSizes[item.id] = size } }
            }
        }
    }

    func removeOrphans() {
        guard !working else { return }
        let items = chosenOrphans
        guard !items.isEmpty else { return }
        working = true
        queue.async { [weak self] in
            let report = Self.remove(name: "Leftovers", identifier: "deleted-apps", appBundle: nil, items: items, action: "leftovers")
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false; self.report = report
                self.scanOrphans(); self.report = report
            }
        }
    }

    // "Reset": the app's data goes, the app stays.
    func uninstall(keepApp: Bool = false) {
        guard let app = selected, !working else { return }
        let items = keepApp ? resettable : chosen
        guard !items.isEmpty else { return }
        working = true
        queue.async { [weak self] in
            let report = keepApp
                ? Self.remove(name: app.name, identifier: app.bundleID, appBundle: nil, items: items, action: "reset")
                : Self.remove(app: app, items: items)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false; self.report = report
                self.reload()
                if report.skipped.isEmpty && !keepApp { self.selected = nil; self.leftovers = [] }
                else { self.select(app); self.report = report }
            }
        }
    }

    // The bundled tool; tests and harnesses point it at a build.
    static var cleanerURL = Bundle.main.url(forResource: "omnistats-cleaner", withExtension: nil)

    static func remove(app: InstalledApp, items: [Leftover]) -> UninstallReport {
        remove(name: app.name, identifier: app.bundleID, appBundle: items.first { $0.kind == .app }?.url,
               items: items, action: "uninstall")
    }

    static func remove(name: String, identifier: String, appBundle: URL?, items: [Leftover], action: String) -> UninstallReport {
        var report = UninstallReport()
        if let bundle = appBundle {
            if let reason = recycleApp(bundle) {
                report.skipped.append(.init(path: bundle.path, reason: reason))
                report.logURL = writeLog(name: name, identifier: identifier, action: action, report: report)
                return report   // nothing else is touched while the app itself stays
            }
            report.moved.append(bundle.path)
        }
        for item in items where !item.system && item.kind != .app {
            if item.kind == .launchAgent { run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.url.path]) }
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashed)
                report.moved.append(item.url.path)
                if let trashed { report.destinations[item.url.path] = trashed.path }
            } catch {
                report.skipped.append(.init(path: item.url.path,
                    reason: item.protected ? L.t("un.needsFDA") : error.localizedDescription))
            }
        }
        let system = items.filter { $0.system && $0.kind != .app }
        if !system.isEmpty { removeSystemItems(system, folder: trashFolderName(name), into: &report) }
        report.logURL = writeLog(name: name, identifier: identifier, action: action, report: report)
        return report
    }

    // NSWorkspace first; Finder is the path macOS reliably allows for other apps'
    // bundles (App Management), at the cost of an Automation prompt.
    private static func recycleApp(_ url: URL) -> String? {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle([url]) { _, error in failure = error; done.signal() }
        }
        done.wait()
        guard failure != nil, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to delete (POSIX file \"\(path)\" as alias)")?.executeAndReturnError(&error)
        return FileManager.default.fileExists(atPath: url.path) ? L.t("un.appBlocked") : nil
    }

    private static func removeSystemItems(_ items: [Leftover], folder: String, into report: inout UninstallReport) {
        guard let tool = cleanerURL else {
            items.forEach { report.skipped.append(.init(path: $0.url.path, reason: L.t("un.toolMissing"))) }
            return
        }
        let manifest = FileManager.default.temporaryDirectory.appendingPathComponent("omnistats-cleaner-\(UUID().uuidString).txt")
        try? items.map(\.url.path).joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: manifest) }
        let command = [tool.path, manifest.path, String(getuid()), folder].map(HelperInstaller.shellQuote).joined(separator: " ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        // The cleaner exits 1 when it refused something; its output still lists every path.
        let result = NSAppleScript(source: "do shell script \"\(escaped); true\" with administrator privileges")?
            .executeAndReturnError(&error)
        if let output = result?.stringValue {
            report.absorbCleanerOutput(output)
        } else {
            items.forEach { report.skipped.append(.init(path: $0.url.path, reason: L.t("un.adminCancelled"))) }
        }
    }

    static func trashFolderName(for app: InstalledApp, date: Date = Date()) -> String { trashFolderName(app.name, date: date) }
    static func trashFolderName(_ appName: String, date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = appName.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "." }
            .unicodeScalars.filter(\.isASCII).map(String.init).joined()
        return String("OmniStats Removed \(formatter.string(from: date)) \(name)".prefix(110))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func writeLog(name: String, identifier: String, action: String, report: UninstallReport) -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OmniStats")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(action)-\(identifier)-\(Int(Date().timeIntervalSince1970)).json")
        let entry: [String: Any] = [
            "action": action, "app": name, "bundleID": identifier,
            "date": ISO8601DateFormatter().string(from: Date()),
            "moved": report.moved.map { ["path": $0, "now": report.destinations[$0] ?? ""] },
            "skipped": report.skipped.map { ["path": $0.path, "reason": $0.reason] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
