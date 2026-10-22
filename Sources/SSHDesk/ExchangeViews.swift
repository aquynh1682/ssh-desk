import AppKit
import SSHDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// File xuất/nhập đã đọc, đang xem trước (ADR-020).
struct ExchangePreview: Identifiable {
    let id = UUID()
    let fileName: String
    let file: ExchangeFile
}

enum ExportScope {
    case all
    case folder(String)
}

extension AppModel {
    /// Xuất qua NSSavePanel. Kèm bastion mà các máy cần. Không bao giờ ghi mật khẩu.
    func exportHosts(_ scope: ExportScope) {
        let selected: [HostProfile]
        let folderNames: [String]
        let suggested: String
        switch scope {
        case .all:
            selected = hosts
            folderNames = folders
            suggested = "ssh-desk-hosts"
        case .folder(let name):
            selected = hosts.filter { $0.project == name }
            folderNames = [name]
            suggested = "ssh-desk-" + name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        guard !selected.isEmpty else {
            alert = AppAlert(title: "Không có gì để xuất", message: "Danh sách máy chủ đang rỗng.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Xuất danh sách máy chủ"
        panel.message = "File chứa thông tin kết nối và cấu hình, KHÔNG chứa mật khẩu."
        panel.nameFieldStringValue = suggested + "." + HostExchange.fileExtension
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let set = HostExchange.exportSet(selected: selected, all: hosts)
        let forwards = forwards
        let store = credentials
        Task {
            do {
                let data = try await Task.detached {
                    let reauth = Set(
                        set.filter { h in h.credentialReference.map { store.exists(ref: $0) } ?? false }
                            .map(\.id))
                    return try HostExchange.export(
                        hosts: set, forwards: forwards, folders: folderNames, needsReauth: reauth)
                }.value
                try HostExchange.write(data, to: url)
                showToast("Đã xuất \(set.count) máy chủ → \(url.lastPathComponent)")
            } catch { show(error, title: "Không xuất được") }
        }
    }

    /// Chọn file rồi mở sheet xem trước.
    func beginImportFile() {
        let panel = NSOpenPanel()
        panel.title = "Nhập danh sách máy chủ"
        panel.message = "Chọn file .sshdesk.json đã xuất từ SSH Desk."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let file = try await Task.detached { try HostExchange.read(from: url) }.value
                exchangePreview = ExchangePreview(fileName: url.lastPathComponent, file: file)
            } catch { show(error, title: "Không đọc được file") }
        }
    }

    func confirmExchangeImport(_ plan: HostExchange.Plan) async -> Bool {
        guard let service else { return false }
        do {
            try await service.applyImport(plan)
            await reload()
            showToast("Đã nhập \(plan.importCount) máy chủ")
            return true
        } catch {
            show(error, title: "Không nhập được (chưa ghi gì)")
            await reload()
            return false
        }
    }
}

/// Sheet xem trước khi nhập: máy mới / trùng / lỗi, cảnh báo, chọn cách xử lý máy trùng.
struct HostImportPreviewSheet: View {
    @Bindable var model: AppModel
    let preview: ExchangePreview
    @Environment(\.dismiss) private var dismiss

    @Local private var duplicates = DuplicateHandling.skip
    @Local private var plan: HostExchange.Plan?
    @Local private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nhập máy chủ").font(.title2.bold())
            Text("\(preview.fileName) · \(preview.file.hostCount) máy chủ")
                .font(.callout).foregroundStyle(.secondary)
            if let plan {
                summary(plan)
                Picker("Máy trùng (cùng loại, host, port, user)", selection: $duplicates) {
                    Text("Bỏ qua").tag(DuplicateHandling.skip)
                    Text("Nhập thành bản sao").tag(DuplicateHandling.copy)
                }
                .pickerStyle(.segmented)
                list(plan)
                ForEach(Array(plan.fileWarnings.enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(
                "Mật khẩu không nằm trong file: máy dùng mật khẩu cần nhập lại sau khi nhập. Không đụng tới ~/.ssh/config."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Nhập \(plan?.importCount ?? 0) máy") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled((plan?.importCount ?? 0) == 0 || importing)
            }
        }
        .padding(18)
        .frame(width: 680, height: 580)
        .onAppear { recompute() }
        .onChange(of: duplicates) { recompute() }
    }

    private func recompute() {
        plan = HostExchange.plan(
            file: preview.file, existingHosts: model.hosts, existingFolders: model.folders,
            existingForwards: model.forwards, duplicates: duplicates)
    }

    private func summary(_ plan: HostExchange.Plan) -> some View {
        HStack(spacing: 16) {
            Label("\(plan.newCount) mới", systemImage: "plus.circle.fill").foregroundStyle(Theme.green)
            Label("\(plan.duplicateCount) trùng", systemImage: "doc.on.doc.fill")
                .foregroundStyle(Theme.amber)
            Label("\(plan.invalidCount) lỗi", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.red)
            if !plan.forwards.isEmpty {
                Label("\(plan.forwards.count) port forward", systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
    }

    private func list(_ plan: HostExchange.Plan) -> some View {
        List {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(e)).foregroundStyle(color(e))
                        Text(e.displayName).font(.body.weight(.medium)).lineLimit(1)
                        Text(label(e)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !e.subtitle.isEmpty {
                        Text(e.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if case .invalid(let reason) = e.outcome {
                        Text(reason).font(.caption).foregroundStyle(Theme.red)
                    }
                    ForEach(Array(e.warnings.enumerated()), id: \.offset) { _, w in
                        Text("⚠︎ \(w)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func icon(_ e: HostExchange.Entry) -> String {
        switch e.outcome {
        case .new: return "plus.circle.fill"
        case .duplicate: return e.willImport ? "doc.on.doc.fill" : "minus.circle.fill"
        case .invalid: return "xmark.octagon.fill"
        }
    }

    private func color(_ e: HostExchange.Entry) -> Color {
        switch e.outcome {
        case .new: return Theme.green
        case .duplicate: return Theme.amber
        case .invalid: return Theme.red
        }
    }

    private func label(_ e: HostExchange.Entry) -> String {
        switch e.outcome {
        case .new: return "mới"
        case .duplicate: return e.willImport ? "trùng — nhập thành bản sao" : "trùng — bỏ qua"
        case .invalid: return "lỗi — bỏ qua"
        }
    }

    private func run() async {
        // Lập lại kế hoạch ngay trước khi ghi (dữ liệu có thể đã đổi từ lúc mở sheet).
        let fresh = HostExchange.plan(
            file: preview.file, existingHosts: model.hosts, existingFolders: model.folders,
            existingForwards: model.forwards, duplicates: duplicates)
        importing = true
        let ok = await model.confirmExchangeImport(fresh)
        importing = false
        if ok { dismiss() }
    }
}
