import SwiftUI

struct ResourceView: View {
    @ObservedObject var sampler: ResourceSampler
    @ObservedObject var store: ConfigStore
    var body: some View {
        VStack(spacing: 9) {
            metric("cpu", "CPU", sampler.snapshot.cpuPercent.map { String(format: "%.0f%%", $0) },
                   sampler.snapshot.cpuPercent.map { $0 / 100 }, Theme.accent, L.t("resource.cpuHelp"),
                   loading: sampler.snapshot.cpuWarmingUp)
            metric("memorychip", L.t("resource.memory"), sampler.snapshot.memory?.label(binary: true),
                   sampler.snapshot.memory?.fraction, Theme.series(0), L.t("resource.memoryHelp"))
            metric("cpu", "GPU", sampler.snapshot.gpuPercent.map { String(format: "%.0f%%", $0) },
                   sampler.snapshot.gpuPercent.map { $0 / 100 }, Theme.series(2), L.t("resource.gpuHelp"))
            metric("internaldrive", L.t("resource.disk"), sampler.snapshot.disk?.label(binary: false),
                   sampler.snapshot.disk?.fraction, Theme.series(1), L.t("resource.diskHelp"))
        }
        .padding(10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
    private func metric(_ icon: String, _ title: String, _ value: String?, _ fraction: Double?,
                        _ color: Color, _ help: String, loading: Bool = false) -> some View {
        let ready = sampler.hasSample && !loading
        let displayed = ready ? value : nil
        return VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 4)
                Text(displayed ?? L.t(ready ? "resource.unavailable" : "resource.loading"))
                    .font(Theme.telemetry(10)).foregroundStyle(displayed == nil ? Theme.ink3 : Theme.ink)
            }
            GeometryReader { geometry in
                Capsule().fill(Theme.line)
                if ready, let fraction {
                    Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }.frame(height: 3)
        }
        .help(help)
        .accessibilityElement(children: .combine)
    }
}
