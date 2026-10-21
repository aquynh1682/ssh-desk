import SSHDeskCore
import SwiftUI

/// Màn "Project Analyst" (ADR-016): header, tab, nội dung. Mọi quyết định trình bày nằm ở `AnalystPresentation`.
struct AnalystView: View {
    @Bindable var model: AppModel
    @Local private var showAdd = false

    private var a: AnalystModel { model.analyst }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if a.folder == nil {
                ContentUnavailableView(
                    "Chọn một thư mục", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Chọn một thư mục ở mục PROJECTS để quét kết nối giữa các server.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                tabBar
                Divider().overlay(Theme.divider)
                if a.isRunning { runningStrip }
                content
            }
        }
        .onAppear { a.enter() }
        .sheet(
            item: Binding(get: { a.prodConfirm }, set: { a.prodConfirm = $0 })
        ) { request in
            ProdConfirmSheet(request: request, confirm: { a.confirmProd() }, cancel: { a.prodConfirm = nil })
        }
        .confirmationDialog(
            "Xoá lần chạy này?",
            isPresented: Binding(
                get: { a.pendingDelete != nil }, set: { if !$0 { a.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá", role: .destructive) { a.confirmDelete() }
            Button("Huỷ", role: .cancel) { a.pendingDelete = nil }
        } message: {
            Text("Chỉ xoá bản ghi lịch sử trong SSH Desk, không đụng tới các máy chủ.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Analyst").font(.system(size: 26, weight: .bold))
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.blue)
                        Text(a.folder ?? "").font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Label("Thêm máy chủ", systemImage: "plus")
                }
                .buttonStyle(OutlineButtonStyle())
                .popover(isPresented: $showAdd, arrowEdge: .bottom) {
                    AddHostsPopover(model: model) { showAdd = false }
                }
                if a.isRunning {
                    Button {
                        a.cancelRun()
                    } label: {
                        Label("Huỷ", systemImage: "xmark")
                    }
                    .buttonStyle(OutlineButtonStyle())
                } else {
                    Button {
                        a.requestRun()
                    } label: {
                        Label("Chạy kiểm tra", systemImage: "play.fill")
                    }
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(a.hosts.isEmpty)
                    .help(
                        "Thu thập kết nối đang mở trên từng server rồi thử từng kết nối từ server nguồn")
                }
            }
            statusLine
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            Circle().fill(a.readyCount > 0 ? Theme.green : Theme.textTertiary).frame(width: 9, height: 9)
            Text(AnalystPresentation.readyText(a.readyCount))
            Text("·").foregroundStyle(Theme.textTertiary)
            Text(AnalystPresentation.sourceNote)
            Image(systemName: "info.circle").foregroundStyle(Theme.textSecondary)
                .help(
                    "Mỗi phép thử TCP chạy trên server nguồn qua SSH (timeout 3 giây). Chỉ dùng lệnh chỉ-xem, không sudo. Phiên SSH của màn Truyền file được dùng lại nếu đang mở."
                )
            if let run = a.current, !run.warnings.isEmpty {
                Button {
                    a.tab = .servers
                } label: {
                    Label("\(run.warnings.count) cảnh báo", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
    }

    private var runningStrip: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(
                a.retesting != nil
                    ? "Đang thử lại kết nối…"
                    : (a.progress.map(AnalystPresentation.progressText) ?? "Đang chuẩn bị…")
            )
            .font(.system(size: 12.5))
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Theme.rowSelected)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(.servers, "Servers (\(a.hosts.count))", "server.rack")
            tabButton(.map, "Bản đồ mạng", "point.3.connected.trianglepath.dotted")
            tabButton(.results, "Kết quả kiểm tra", "list.bullet")
            tabButton(.history, "Lịch sử", "clock")
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private func tabButton(_ tab: AnalystTab, _ title: String, _ symbol: String) -> some View {
        let selected = a.tab == tab
        return Button {
            a.tab = tab
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.cardStroke : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch a.tab {
        case .servers: AnalystServersTab(model: model)
        case .map: AnalystMapTab(model: model)
        case .results: AnalystResultsTab(model: model)
        case .history: AnalystHistoryTab(model: model)
        }
    }
}

/// Hộp xác nhận ProdGuard: liệt kê server và lệnh chính xác.
struct ProdConfirmSheet: View {
    let request: AnalystProdConfirm
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Thư mục có server PROD", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
            Text("Sẽ chạy các lệnh chỉ-xem dưới đây trên server (không sudo, không sửa gì).")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            ScrollView {
                Text(request.message)
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 260)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
            HStack {
                Spacer()
                Button("Huỷ", action: cancel).keyboardShortcut(.cancelAction)
                Button("Chạy trên \(request.prodNames.count) server PROD…", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 520)
    }
}

/// Popover "Thêm máy chủ": chọn host đưa vào thư mục (host thuộc đúng một thư mục nên sẽ được chuyển).
struct AddHostsPopover: View {
    @Bindable var model: AppModel
    let done: () -> Void
    @Local private var query = ""

    var body: some View {
        let folder = model.analyst.folder ?? ""
        let candidates = model.hosts.filter { $0.project != folder }
        let groups = HostPicker.groups(candidates, query: query)
        VStack(alignment: .leading, spacing: 8) {
            Text("Thêm máy chủ vào “\(folder)”").font(.system(size: 13, weight: .semibold))
            TextField("Tìm máy chủ…", text: $query).textFieldStyle(.roundedBorder)
            Text("Máy được chuyển từ thư mục hiện tại sang thư mục này.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            if groups.isEmpty {
                Text(candidates.isEmpty ? "Không còn máy chủ nào để thêm." : "Không khớp.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.environment) { g in
                            Text(HostPresentation.title(for: g.environment).uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary).padding(.top, 6)
                            ForEach(g.hosts) { h in
                                Button {
                                    model.analyst.add([h.id])
                                    done()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(h.displayName).font(.system(size: 13))
                                            Text(
                                                HostPresentation.addressText(h)
                                                    + (h.project.isEmpty ? "" : " · \(h.project)")
                                            )
                                            .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle").foregroundStyle(Theme.textSecondary)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14).frame(width: 320)
    }
}

enum AnalystDateText {
    static func string(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f.string(from: date)
    }
}
