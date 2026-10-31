import SwiftUI
import AppKit

// Uninstall an app with its leftovers, reset an app, or clear what deleted apps
// left behind; everything goes to the Trash.
struct AppsPane: View {
    @ObservedObject var model: AppUninstaller
    @State var mode = Mode.installed
    @State private var query = ""
    @State private var confirmRemoval = false
    @State private var confirmReset = false
    @State private var confirmQuit = false
    @State private var confirmOrphans = false
    @State private var copiedCask: String?

    enum Mode: Hashable { case installed, leftovers }

    var body: some View {
        // The page fills the window: the list and the details scroll on their own.
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            PageHeader(title: L.t("un.title"), subtitle: L.t("un.subtitle"))
            Picker("", selection: $mode) {
                Text(L.t("un.mode.installed")).tag(Mode.installed)
                Text(L.t("un.mode.leftovers")).tag(Mode.leftovers)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().tint(Theme.accent)
            if model.fullDiskAccess == false {
                Callout(.warning, message: L.t("un.fdaBanner")) {
                    Button(L.t("un.openFDA")) { Privacy.openFullDiskAccessSettings() }.secondaryButton()
                }
            }
            if mode == .installed {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    appList.frame(width: 240)
                    details
                }
                .frame(maxHeight: .infinity)
            } else {
                orphanView
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.reload() }
        .onChange(of: mode) { _ in model.clearReport() }
        .alert(L.f("un.quitTitle", model.selected?.name ?? ""), isPresented: $confirmQuit) {
            Button(L.t("un.quit")) { model.quitSelected(force: false) }
            Button(L.t("un.forceQuit"), role: .destructive) { model.quitSelected(force: true) }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: { Text(L.t("un.quitBody")) }
        .alert(L.f("un.confirmTitle", model.selected?.name ?? ""), isPresented: $confirmRemoval) {
            Button(L.t("un.confirm"), role: .destructive) { model.uninstall() }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: {
            confirmation(model.chosen)
        }
        .alert(L.f("un.resetTitle", model.selected?.name ?? ""), isPresented: $confirmReset) {
            Button(L.t("un.reset"), role: .destructive) { model.uninstall(keepApp: true) }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("un.resetBody") + "\n\n") + confirmation(model.resettable)
        }
        .alert(L.f("un.orphanTitle", model.chosenOrphans.count), isPresented: $confirmOrphans) {
            Button(L.t("un.confirm"), role: .destructive) { model.removeOrphans() }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: {
            confirmation(model.chosenOrphans)
        }
    }

    private func confirmation(_ items: [Leftover]) -> Text {
        let system = items.filter(\.system).count
        return Text(system > 0 ? L.f("un.confirmBody", items.count, system) : L.f("un.confirmBodyUser", items.count))
    }

    // MARK: Installed apps

    private var filtered: [InstalledApp] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.bundleID.localizedCaseInsensitiveContains(text) }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField(L.t("un.search"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { app in
                        Button { model.select(app) } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable().frame(width: 20, height: 20)
                                Text(app.name).font(Theme.Typo.secondary).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(model.selected == app ? Theme.accent.opacity(0.16) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if filtered.isEmpty && !model.apps.isEmpty { EmptyState(icon: "magnifyingglass", text: L.t("un.noMatch")) }
        }
        .padding(Theme.Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground()
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let app = model.selected {
                HStack(spacing: Theme.Space.m) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            if let version = app.version { Text(version).font(Theme.Typo.caption).foregroundStyle(Theme.ink3) }
                            if app.isAppStore { Badge(text: L.t("un.appStore"), compact: true) }
                            if app.cask != nil { Badge(text: "Homebrew", compact: true) }
                            if model.isRunning { Badge(text: L.t("un.running"), tint: Theme.warning, compact: true) }
                        }
                        Text(app.bundleID).font(Theme.Typo.caption).foregroundStyle(Theme.ink3).textSelection(.enabled)
                    }
                }
                if let cask = app.cask { brewHint(cask) }
                if model.scanning {
                    HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Note(L.t("un.scanning")) }
                    Spacer(minLength: 0)
                } else {
                    RowDivider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            items
                            if let report = model.report { reportView(report) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    RowDivider()
                    footer
                }
            } else {
                EmptyState(icon: "app.dashed", text: L.t("un.empty"))
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    // Homebrew keeps its own record of the cask; its zap is the tidy way out.
    private func brewHint(_ cask: String) -> some View {
        let command = "brew uninstall --zap --cask \(cask)"
        return VStack(alignment: .leading, spacing: 6) {
            Note(L.t("un.brewHint"))
            HStack(spacing: 8) {
                Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink2).textSelection(.enabled)
                Spacer(minLength: 6)
                Button(copiedCask == cask ? L.t("un.copied") : L.t("un.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCask = cask
                }
                .secondaryButton()
            }
        }
        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.leftovers.count <= 1 { Note(L.t("un.nothing")) }
            ForEach(model.leftovers) { item in
                itemRow(item, size: model.sizes[item.id], disabled: item.kind == .app,
                        isOn: Binding(get: { !model.excluded.contains(item.id) }, set: { included in
                            if included { model.excluded.remove(item.id) } else { model.excluded.insert(item.id) }
                        }))
            }
        }
    }

    private func itemRow(_ item: Leftover, size: Int64?, disabled: Bool = false, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: isOn).toggleStyle(.checkbox).labelsHidden().disabled(disabled)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(L.t("un.kind.\(item.kind.rawValue)")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                    if item.system { Badge(text: L.t("un.admin"), tint: Theme.ink3, compact: true) }
                    if item.byName { Badge(text: L.t("un.byName"), tint: Theme.ink3, compact: true).help(L.t("un.byNameHelp")) }
                    if item.fromCask { Badge(text: "Homebrew", tint: Theme.ink3, compact: true).help(L.t("un.fromCaskHelp")) }
                    if item.protected && model.fullDiskAccess == false { Badge(text: L.t("un.fdaBadge"), tint: Theme.warning, compact: true) }
                }
                Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                    .help(item.url.path)
            }
            Spacer(minLength: 6)
            Text(size.map(Self.bytes) ?? "—").font(Theme.telemetry(11)).foregroundStyle(Theme.ink2)
        }
    }

    private var footer: some View {
        let chosen = model.chosen
        let total = chosen.compactMap { model.sizes[$0.id] }.reduce(0, +)
        return HStack {
            Text(L.f("un.total", chosen.count, Self.bytes(total))).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            Button(L.t("un.resetButton")) {
                if model.isRunning { confirmQuit = true } else { confirmReset = true }
            }
            .secondaryButton()
            .disabled(model.working || model.resettable.isEmpty)
            .help(L.t("un.resetHelp"))
            Button(L.t("un.remove")) {
                if model.isRunning { confirmQuit = true } else { confirmRemoval = true }
            }
            .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.small)
            .disabled(model.working || chosen.isEmpty)
        }
    }

    // MARK: Leftovers of deleted apps

    private var orphanView: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Note(L.t("un.orphanIntro"))
                Spacer(minLength: Theme.Space.m)
                if model.orphanScanning { ProgressView().controlSize(.small) }
                Button(model.orphansScanned ? L.t("un.rescan") : L.t("un.scan")) { model.scanOrphans() }
                    .secondaryButton()
                    .disabled(model.orphanScanning || model.working)
            }
            if model.orphansScanned && !model.orphanScanning {
                if model.orphans.isEmpty {
                    EmptyState(icon: "checkmark.circle", text: L.t("un.orphanNone"))
                } else {
                    RowDivider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.orphans) { group in orphanGroup(group) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    RowDivider()
                    orphanFooter
                }
            } else if !model.orphanScanning {
                EmptyState(icon: "sparkle.magnifyingglass", text: L.t("un.orphanHint"))
            } else {
                Spacer(minLength: 0)
            }
            if let report = model.report { reportView(report) }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground()
    }

    private func orphanGroup(_ group: OrphanGroup) -> some View {
        let ids = Set(group.items.map(\.id))
        let total = group.items.compactMap { model.orphanSizes[$0.id] }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { ids.isSubset(of: model.orphanSelection) }, set: { on in
                    if on { model.orphanSelection.formUnion(ids) } else { model.orphanSelection.subtract(ids) }
                }))
                .toggleStyle(.checkbox).labelsHidden()
                Text(group.bundleID).font(Theme.Typo.secondary.weight(.semibold)).foregroundStyle(Theme.ink).textSelection(.enabled)
                Spacer(minLength: 6)
                Text(Self.bytes(total)).font(Theme.telemetry(11)).foregroundStyle(Theme.ink2)
            }
            ForEach(group.items) { item in
                itemRow(item, size: model.orphanSizes[item.id],
                        isOn: Binding(get: { model.orphanSelection.contains(item.id) }, set: { on in
                            if on { model.orphanSelection.insert(item.id) } else { model.orphanSelection.remove(item.id) }
                        }))
                .padding(.leading, 22)
            }
        }
    }

    private var orphanFooter: some View {
        let chosen = model.chosenOrphans
        let total = chosen.compactMap { model.orphanSizes[$0.id] }.reduce(0, +)
        return HStack {
            Text(L.f("un.total", chosen.count, Self.bytes(total))).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            Button(L.t("un.remove")) { confirmOrphans = true }
                .buttonStyle(.borderedProminent).tint(Theme.danger).controlSize(.small)
                .disabled(model.working || chosen.isEmpty)
        }
    }

    // MARK: Shared

    private func reportView(_ report: UninstallReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.line)
            Label(L.f("un.done", report.moved.count), systemImage: "checkmark.circle.fill")
                .font(Theme.Typo.secondary.weight(.medium)).foregroundStyle(Theme.ink)
            if !report.skipped.isEmpty {
                Callout(.warning, message: L.f("un.partial", report.skipped.count))
                ForEach(report.skipped, id: \.path) { skip in
                    Note("\((skip.path as NSString).abbreviatingWithTildeInPath) — \(skip.reason)")
                }
            }
            if let log = report.logURL {
                Button(L.t("un.showLog")) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowsNonnumericFormatting = false
        return formatter
    }()
    private static func bytes(_ value: Int64) -> String { byteFormatter.string(fromByteCount: value) }
}
