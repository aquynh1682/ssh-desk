import SSHDeskCore
import SwiftUI

/// Màn "Monitor" (ADR-019): lưới thẻ tài nguyên cho các server của thư mục. Quyết định (ngưỡng, định dạng)
/// nằm ở SSHDeskCore. Vòng làm mới chỉ chạy khi màn này hiện.
struct MonitorView: View {
    @Bindable var model: AppModel

    private var m: MonitorModel { model.monitor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.folder == nil {
                ContentUnavailableView(
                    "Chọn một thư mục", systemImage: "gauge.with.dots.needle.67percent",
                    description: Text("Chọn một thư mục ở mục PROJECTS để theo dõi tài nguyên các server.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                Divider().overlay(Theme.divider)
                if m.hosts.isEmpty {
                    ContentUnavailableView(
                        "Thư mục chưa có máy chủ SSH", systemImage: "server.rack",
                        description: Text("Thêm máy chủ Linux vào thư mục này để theo dõi.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)],
                            alignment: .leading, spacing: 14
                        ) {
                            ForEach(m.hosts) { host in
                                MonitorCard(
                                    host: host, state: m.states[host.id], running: m.isRunning,
                                    thresholds: model.settings.monitorThresholds,
                                    retry: { m.retry(host.id) })
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .onAppear { m.enter() }
        .onDisappear { m.leave() }
        .sheet(
            item: Binding(get: { m.prodConfirm }, set: { m.prodConfirm = $0 })
        ) { request in
            ProdConfirmSheet(request: request, confirm: { m.confirmProd() }, cancel: { m.prodConfirm = nil })
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Monitor").font(.system(size: 26, weight: .bold))
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                    Text(m.folder ?? "").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    Text("·").foregroundStyle(Theme.textTertiary)
                    Text(m.isRunning ? "Đang theo dõi" : "Đã dừng")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Picker(
                "Chu kỳ",
                selection: Binding(get: { m.intervalSeconds }, set: { m.setInterval($0) })
            ) {
                ForEach(MonitorModel.intervals, id: \.self) { Text("\($0) giây").tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            .help("Khoảng thời gian giữa hai lần đọc")
            if m.isRunning {
                Button {
                    m.stop()
                } label: {
                    Label("Dừng", systemImage: "pause.fill")
                }
                .buttonStyle(OutlineButtonStyle())
            } else {
                Button {
                    m.requestStart()
                } label: {
                    Label("Tiếp tục", systemImage: "play.fill")
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(m.hosts.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }
}

// MARK: - Màu theo ngưỡng

private func color(for level: MonitorLevel) -> Color {
    switch level {
    case .danger: return Theme.red
    case .warning: return Theme.amber
    case .normal: return Theme.green
    case .unknown: return Theme.textTertiary
    }
}

/// Thẻ một server.
struct MonitorCard: View {
    let host: HostProfile
    let state: MonitorHostState?
    let running: Bool
    var thresholds: MonitorThresholds = .default
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            switch state?.status {
            case .none:
                note(running ? "Đang chờ…" : "Chưa theo dõi")
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Đang kết nối…").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
                metrics
            case .unsupported:
                note("Không hỗ trợ (cần Linux có /proc)")
            case .failed(let reason):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                    Text(reason.isEmpty ? "Lỗi" : reason).font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 4)
                    Button("Thử lại", action: retry).buttonStyle(.link).font(.system(size: 12.5))
                }
                metrics.opacity(0.5)
            case .ok:
                metrics
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var statusColor: Color {
        switch state?.status {
        case .ok: return Theme.green
        case .failed: return Theme.red
        case .connecting: return Theme.amber
        default: return Theme.textTertiary
        }
    }

    private var statusLabel: String {
        switch state?.status {
        case .ok: return "Hoạt động"
        case .failed: return "Lỗi"
        case .connecting: return "Đang kết nối"
        case .unsupported: return "Không hỗ trợ"
        case .none: return "Chưa theo dõi"
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9).accessibilityLabel(statusLabel)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(HostPresentation.addressText(host))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(HostPresentation.badgeCode(for: host.environment))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(host.environment == .prod ? Theme.amber : Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.rowSelected, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private var metrics: some View {
        if let snap = state?.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                meter(
                    "CPU", MonitorFormat.percent(snap.cpuPercent), snap.cpuPercent, snap.cpuLevel(using: thresholds),
                    history: state?.cpuHistory.values ?? [])
                Text("Load " + MonitorFormat.load(snap.load, cores: snap.cores))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                if let mem = snap.memory {
                    meter(
                        "RAM",
                        "\(MonitorFormat.size(kb: mem.usedKB)) / \(MonitorFormat.size(kb: mem.totalKB))",
                        snap.memoryPercent, snap.memoryLevel(using: thresholds),
                        history: state?.memoryHistory.values ?? [])
                    if mem.swapTotalKB > 0 {
                        meter(
                            "Swap",
                            "\(MonitorFormat.size(kb: mem.swapUsedKB)) / \(MonitorFormat.size(kb: mem.swapTotalKB))",
                            snap.swapPercent, snap.swapLevel(using: thresholds), history: [])
                    }
                }
                ForEach(snap.disks, id: \.mount) { d in
                    meter(
                        d.mount, "\(MonitorFormat.size(kb: d.usedKB)) / \(MonitorFormat.size(kb: d.totalKB))",
                        d.percent, .level(forPercent: d.percent, thresholds: thresholds), history: [], showPercent: true
                    )
                }
                HStack {
                    Text("Uptime " + MonitorFormat.uptime(seconds: snap.uptimeSeconds))
                    Spacer()
                    Text("cập nhật " + Self.timeFormatter.string(from: snap.takenAt))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func meter(
        _ label: String, _ value: String, _ percent: Double?, _ level: MonitorLevel,
        history: [Double], showPercent: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(color(for: level))
                if showPercent {
                    Text(MonitorFormat.percent(percent)).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(color(for: level))
                }
            }
            HStack(spacing: 8) {
                UsageBar(fraction: (percent ?? 0) / 100, tint: color(for: level))
                if history.count > 1 {
                    Sparkline(values: history).stroke(color(for: level), lineWidth: 1.2)
                        .frame(width: 80, height: 18)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thanh phần trăm.
private struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.rowSelected)
                RoundedRectangle(cornerRadius: 3).fill(tint)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

/// Đường sparkline 0–100%.
private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let y = rect.maxY - rect.height * CGFloat(min(100, max(0, v)) / 100)
            let pt = CGPoint(x: rect.minX + step * CGFloat(i), y: y)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}
