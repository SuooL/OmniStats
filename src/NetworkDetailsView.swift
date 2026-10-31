import SwiftUI

struct NetworkDetailsView: View {
    @ObservedObject var net: NetSampler
    @ObservedObject var netProc: NetProcSampler
    @ObservedObject var store: ConfigStore
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("m.network")).font(Theme.Typo.heading).foregroundStyle(Theme.ink)
                    Text(L.t("network.lastHour")).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                if !net.iface.isEmpty {
                    Text(net.iface).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L.t("network.hideDetails"))
                .accessibilityLabel(L.t("network.hideDetails"))
            }

            DualSparkline(up: net.txHistory.samples, down: net.rxHistory.samples,
                          windowSeconds: 3600, now: sampleTime(), kind: store.config.netChartKind)
            Rectangle().fill(Theme.line).frame(height: 1)
            processList
        }
        .padding(14).frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(PanelSurface(fill: Theme.surface, line: Theme.line))
        .environment(\.colorScheme, store.config.appearance.colorScheme)
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("m.netProcHeader")).font(Theme.Typo.caption).foregroundStyle(Theme.ink2)
                .frame(height: 14)
            processRows
        }
        // Keep the detail window stable while waiting, idle or showing 1–5 apps.
        // Header (14), header gap (5), five rows (80), four row gaps (20).
        .frame(height: 119, alignment: .topLeading)
    }

    @ViewBuilder private var processRows: some View {
        if netProc.state == .warmingUp {
            Text(L.t("network.warmingUp")).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
        } else if netProc.state == .unavailable {
            Label(L.t("network.unavailable"), systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.caption).foregroundStyle(Theme.warning)
        } else if netProc.top.isEmpty {
            Text(L.t("m.netIdle")).font(Theme.Typo.caption).foregroundStyle(Theme.ink3)
        } else {
            ForEach(netProc.top) { process in processRow(process) }
        }
    }

    private func processRow(_ process: NetProcUsage) -> some View {
        HStack(spacing: 6) {
            Text(process.name).font(Theme.Typo.caption).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            rate("arrow.up", process.txBps)
            rate("arrow.down", process.rxBps)
        }
        .frame(height: 16)
    }

    private func rate(_ icon: String, _ value: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.speed(value))
            Text(humanRate(value)).font(Theme.telemetry(10)).foregroundStyle(Theme.speed(value))
        }.frame(width: 74, alignment: .trailing)
    }
}
