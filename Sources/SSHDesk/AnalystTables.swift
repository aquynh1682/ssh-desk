import SSHDeskCore
import SwiftUI

extension AnalystEdgeStyle {
    var color: Color {
        switch self {
        case .passed: return Theme.green
        case .failed: return Theme.red
        case .notTested: return Theme.textTertiary
        case .observed: return Theme.blue
        }
    }
}

extension AnalystCheckLine.Tone {
    var color: Color {
        switch self {
        case .good: return Theme.green
        case .bad: return Theme.red
        case .neutral: return Theme.textSecondary
        }
    }
}

/// Khung thẻ có tiêu đề dùng chung trong màn Analyst.
struct AnalystCard<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            content()
        }
        .cardStyle()
    }
}

/// Dải thông báo khi đang xem lần chạy cũ (chỉ đọc).
struct AnalystHistoryBanner: View {
    let analyst: AnalystModel

    var body: some View {
        if analyst.viewingHistory, let run = analyst.current {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Đang xem lần chạy lúc \(AnalystDateText.string(run.startedAt)) (chỉ đọc)")
                Spacer()
                Button("Về kết quả mới nhất") { analyst.backToLatest() }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct AnalystEmptyView: View {
    let state: AnalystEmptyState

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: symbol)
        } description: {
            Text(state.message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch state {
        case .noHosts: return "server.rack"
        case .notRunYet: return "play.circle"
        case .noEdges: return "point.3.connected.trianglepath.dotted"
        case .hasData: return ""
        }
    }
}

// MARK: - Bảng kết quả

struct AnalystResultsTable: View {
    let analyst: AnalystModel
    let run: StoredAnalystRun
    var maxHeight: CGFloat?

    var body: some View {
        let rows = AnalystPresentation.rows(run, timeout: analyst.probeTimeout)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                cell("Nguồn", flex: true).frame(maxWidth: .infinity, alignment: .leading)
                cell("Đích", flex: true).frame(maxWidth: .infinity, alignment: .leading)
                cell("Port", flex: false).frame(width: 90, alignment: .leading)
                cell("Kết quả", flex: false).frame(width: 150, alignment: .leading)
                cell("Thời gian", flex: false).frame(width: 80, alignment: .leading)
                // Đặt cả chiều cao: Color.clear tự do sẽ giãn dọc và đẩy header xa tiêu đề.
                Color.clear.frame(width: 30, height: 1)
            }
            .padding(.horizontal, 14).frame(height: 30)
            Divider().overlay(Theme.divider)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let selected = analyst.isSelected(row.flow)
                        HStack(spacing: 8) {
                            Text(row.source).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.destination).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.port).font(.system(size: 12.5, design: .monospaced))
                                .frame(width: 90, alignment: .leading)
                            HStack(spacing: 6) {
                                Image(systemName: icon(row.style)).foregroundStyle(row.style.color)
                                Text(row.resultText).foregroundStyle(row.style.color)
                            }
                            .frame(width: 150, alignment: .leading)
                            Text(row.timeText).monospacedDigit()
                                .frame(width: 80, alignment: .leading)
                            Menu {
                                Button("Xem chi tiết") {
                                    analyst.selection = .flow(row.flow)
                                    analyst.tab = .map
                                }
                                Button("Thử lại kết nối") { analyst.retest(row.flow) }
                                    .disabled(analyst.isRunning || analyst.viewingHistory)
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 30, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 14).frame(height: AnalystPanelLayout.rowHeight)
                        .background(
                            row.isFailure
                                ? Theme.red.opacity(0.12)
                                : (selected ? Theme.rowSelected : .clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { analyst.selection = .flow(row.flow) }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private func cell(_ text: String, flex: Bool) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }

    private func icon(_ s: AnalystEdgeStyle) -> String {
        switch s {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "minus.circle"
        }
    }
}

struct AnalystExportMenu: View {
    let analyst: AnalystModel

    var body: some View {
        Menu {
            Button("Markdown (.md)…") { analyst.export(.markdown) }
            Button("CSV (.csv)…") { analyst.export(.csv) }
        } label: {
            Label("Xuất báo cáo", systemImage: "square.and.arrow.up").font(.system(size: 12.5))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(analyst.current == nil)
    }
}

struct AnalystResultsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        let a = model.analyst
        VStack(spacing: 10) {
            AnalystHistoryBanner(analyst: a)
            if let run = a.current, !run.topology.flows.isEmpty {
                AnalystCard(
                    title: "Kết quả kiểm tra", subtitle: AnalystPresentation.summary(run.results)
                ) {
                    AnalystExportMenu(analyst: a)
                } content: {
                    AnalystResultsTable(analyst: a, run: run)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                AnalystEmptyView(state: a.emptyState == .hasData ? .noEdges : a.emptyState)
            }
        }
        .padding(16)
    }
}

// MARK: - Servers

struct AnalystServersTab: View {
    @Bindable var model: AppModel

    var body: some View {
        let a = model.analyst
        let hosts = a.hosts
        let windowsHosts = a.windowsHosts
        VStack(spacing: 10) {
            AnalystHistoryBanner(analyst: a)
            if hosts.isEmpty && windowsHosts.isEmpty {
                AnalystEmptyView(state: .noHosts)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if let run = a.current, !run.warnings.isEmpty { warnings(run) }
                        AnalystCard(title: "Máy chủ trong thư mục", subtitle: nil) {
                            if a.current == nil {
                                Text("Chưa quét").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                        } content: {
                            table(a, hosts)
                        }
                        if !windowsHosts.isEmpty {
                            AnalystCard(title: "Máy Windows", subtitle: nil) {
                            } content: {
                                VStack(spacing: 0) {
                                    ForEach(windowsHosts) { h in
                                        HStack(spacing: 8) {
                                            Image(systemName: "desktopcomputer")
                                                .foregroundStyle(Theme.textTertiary)
                                            Text(h.displayName).lineLimit(1)
                                            Text(HostPresentation.addressText(h))
                                                .font(.system(size: 12.5, design: .monospaced))
                                                .foregroundStyle(Theme.textSecondary)
                                            Spacer()
                                            Text("Máy Windows — không áp dụng")
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        .font(.system(size: 13))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func warnings(_ run: StoredAnalystRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Cảnh báo lần chạy gần nhất", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
            ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, w in
                Text("• " + w.text).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func table(_ a: AnalystModel, _ hosts: [HostProfile]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                head("Tên").frame(width: 140, alignment: .leading)
                head("IP").frame(width: 130, alignment: .leading)
                head("Môi trường").frame(width: 90, alignment: .leading)
                head("Thu thập").frame(width: 130, alignment: .leading)
                head("Cổng LISTEN (tiến trình)").frame(maxWidth: .infinity, alignment: .leading)
                head("Ra ngoài project").frame(width: 120, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            Divider().overlay(Theme.divider)
            ForEach(hosts) { h in
                let node = a.current?.topology.node(h.id)
                let issues = a.current.map { AnalystPresentation.issues(for: h.id, in: $0.warnings) } ?? []
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(a.isLive(h.id) ? Theme.green : Theme.textTertiary)
                                .frame(width: 8, height: 8)
                            Text(h.displayName).lineLimit(1)
                        }
                        .frame(width: 140, alignment: .leading)
                        Text(node?.addresses.first?.address ?? HostPresentation.addressText(h))
                            .font(.system(size: 12.5, design: .monospaced)).lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        EnvironmentBadge(environment: h.environment)
                            .frame(width: 90, alignment: .leading)
                        Text(AnalystPresentation.collectionStatus(node, warnings: a.current?.warnings ?? []))
                            .foregroundStyle(
                                node == nil
                                    ? Theme.textSecondary : (node?.collected == true ? Theme.green : Theme.amber)
                            )
                            .frame(width: 130, alignment: .leading)
                        Text(node.map(AnalystPresentation.listenSummary) ?? "—")
                            .font(.system(size: 12.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(node.map(AnalystPresentation.externalText) ?? "—")
                            .frame(width: 120, alignment: .leading)
                    }
                    ForEach(issues, id: \.self) { text in
                        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    a.selection = .node(h.id)
                    a.tab = .map
                }
                Divider().overlay(Theme.divider)
            }
        }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Lịch sử

struct AnalystHistoryTab: View {
    @Bindable var model: AppModel

    var body: some View {
        let a = model.analyst
        ScrollView {
            if a.history.isEmpty {
                ContentUnavailableView(
                    "Chưa có lần chạy nào", systemImage: "clock",
                    description: Text(
                        "Mỗi lần “Chạy kiểm tra” xong sẽ được lưu lại ở đây (giữ \(model.settings.analystRetention) lần gần nhất)."
                    )
                )
                .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(a.history) { s in
                        let selected = a.current?.id == s.id
                        HStack(spacing: 12) {
                            Image(systemName: s.failed > 0 ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(s.failed > 0 ? Theme.red : Theme.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AnalystDateText.string(s.startedAt)).font(.system(size: 13.5, weight: .medium))
                                Text(
                                    AnalystPresentation.summary(
                                        passed: s.passed, failed: s.failed,
                                        untestable: s.flowCount - s.passed - s.failed)
                                        + " · \(s.serverCount) server"
                                        + (s.status == .partial ? " · có cảnh báo" : "")
                                )
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if selected {
                                Text("Đang xem").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                            Button("Xem") { a.view(s) }.buttonStyle(OutlineButtonStyle())
                            Button {
                                a.pendingDelete = s
                            } label: {
                                Image(systemName: "trash").foregroundStyle(Theme.textSecondary)
                                    .frame(width: 26, height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Xoá lần chạy").disabled(a.isRunning)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(selected ? Theme.rowSelected : .clear)
                        Divider().overlay(Theme.divider)
                    }
                }
                .cardStyle().padding(16)
            }
        }
    }
}
