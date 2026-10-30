import SwiftUI
import AppKit

// Uninstall an app with its leftovers; everything goes to the Trash.
struct AppsPane: View {
    @ObservedObject var model: AppUninstaller
    @State private var query = ""
    @State private var confirmRemoval = false
    @State private var confirmQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.t("un.title")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.ink)
                Text(L.t("un.subtitle")).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            if model.fullDiskAccess == false { accessBanner }
            HStack(alignment: .top, spacing: 16) {
                appList.frame(width: 240)
                details.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { model.reload() }
        .alert(L.f("un.quitTitle", model.selected?.name ?? ""), isPresented: $confirmQuit) {
            Button(L.t("un.quit")) { model.quitSelected(force: false) }
            Button(L.t("un.forceQuit"), role: .destructive) { model.quitSelected(force: true) }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: { Text(L.t("un.quitBody")) }
        .alert(L.f("un.confirmTitle", model.selected?.name ?? ""), isPresented: $confirmRemoval) {
            Button(L.t("un.confirm"), role: .destructive) { model.uninstall() }
            Button(L.t("un.cancel"), role: .cancel) {}
        } message: {
            let chosen = model.chosen
            let system = chosen.filter(\.system).count
            Text(system > 0 ? L.f("un.confirmBody", chosen.count, system) : L.f("un.confirmBodyUser", chosen.count))
        }
    }

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text(L.t("un.fdaBanner")).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L.t("un.openFDA")) { Privacy.openFullDiskAccessSettings() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private var filtered: [InstalledApp] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.bundleID.localizedCaseInsensitiveContains(text) }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L.t("un.search"), text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { app in
                        Button { model.select(app) } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable().frame(width: 20, height: 20)
                                Text(app.name).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6)
                            .background(model.selected == app ? Theme.accent.opacity(0.16) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 440)
        }
        .padding(10)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let app = model.selected {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                            if let version = app.version { Text(version).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
                            if app.isAppStore { badge(L.t("un.appStore"), Theme.accent) }
                            if model.isRunning { badge(L.t("un.running"), .orange) }
                        }
                        Text(app.bundleID).font(.system(size: 11)).foregroundStyle(Theme.ink3).textSelection(.enabled)
                    }
                }
                if model.scanning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); note(L.t("un.scanning")) }
                } else {
                    items
                    footer
                }
                if let report = model.report { reportView(report) }
            } else {
                note(L.t("un.empty"))
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.leftovers.count <= 1 { note(L.t("un.nothing")) }
            ForEach(model.leftovers) { item in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { !model.excluded.contains(item.id) }, set: { included in
                        if included { model.excluded.remove(item.id) } else { model.excluded.insert(item.id) }
                    }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(item.kind == .app)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(L.t("un.kind.\(item.kind.rawValue)")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                            if item.system { badge(L.t("un.admin"), Theme.ink3) }
                            if item.byName { badge(L.t("un.byName"), Theme.ink3).help(L.t("un.byNameHelp")) }
                            if item.protected && model.fullDiskAccess == false { badge(L.t("un.fdaBadge"), .orange) }
                        }
                        Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                            .help(item.url.path)
                    }
                    Spacer(minLength: 6)
                    Text(model.sizes[item.id].map(Self.bytes) ?? "—").font(Theme.telemetry(11)).foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private var footer: some View {
        let chosen = model.chosen
        let total = chosen.compactMap { model.sizes[$0.id] }.reduce(0, +)
        return HStack {
            Text(L.f("un.total", chosen.count, Self.bytes(total))).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            Spacer()
            if model.working { ProgressView().controlSize(.small) }
            Button(L.t("un.remove")) {
                if model.isRunning { confirmQuit = true } else { confirmRemoval = true }
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            .disabled(model.working || chosen.isEmpty)
        }
    }

    private func reportView(_ report: UninstallReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.line)
            Text(L.f("un.done", report.moved.count)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            if !report.skipped.isEmpty {
                Text(L.f("un.partial", report.skipped.count)).font(.system(size: 11)).foregroundStyle(.orange)
                ForEach(report.skipped, id: \.path) { skip in
                    Text("\((skip.path as NSString).abbreviatingWithTildeInPath) — \(skip.reason)")
                        .font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let log = report.logURL {
                Button(L.t("un.showLog")) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
    }

    private static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }
}
