import AppKit
import SSHDeskCore
import SwiftUI

enum TransferSheetTarget: Identifiable {
    case download(HostProfile)
    case upload(HostProfile)
    var id: String {
        switch self {
        case .download(let h): return "d-" + h.id.uuidString
        case .upload(let h): return "u-" + h.id.uuidString
        }
    }
}

/// Khối "máy đích" dùng chung: tên, target, nhãn PROD.
private struct TargetHeader: View {
    let host: HostProfile
    let direction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.displayName).font(.headline)
                EnvironmentBadge(environment: host.environment)
            }
            Text("\(direction) · \(TransferTarget.describe(host))")
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            if host.environment == .prod {
                Text("Đây là máy PRODUCTION — kiểm tra kỹ đường dẫn trước khi bắt đầu.")
                    .font(.callout).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            (host.environment == .prod ? Color.red.opacity(0.1) : Color.secondary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 8))
    }
}

private func remoteQuickPicks(_ host: HostProfile) -> [(String, String)] {
    var out: [(String, String)] = []
    if !host.defaultRemoteDirectory.isEmpty {
        out.append(("Mặc định", host.defaultRemoteDirectory))
    }
    out += host.remoteBookmarks.map { ($0.name, $0.path) }
    return out
}

@MainActor private func chooseLocal(files: Bool, directories: Bool, prompt: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = files
    panel.canChooseDirectories = directories
    panel.canCreateDirectories = directories && !files
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct DownloadSheet: View {
    @Bindable var model: AppModel
    let host: HostProfile
    @Local private var form = DownloadForm()
    @Local private var ready = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tải về").font(.title2.bold())
            TargetHeader(host: host, direction: "Tải từ server về máy này")
            Form {
                HStack {
                    TextField("Đường dẫn remote", text: $form.remotePath)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    let picks = remoteQuickPicks(host)
                    if !picks.isEmpty {
                        Menu("Chọn nhanh") {
                            ForEach(Array(picks.enumerated()), id: \.offset) { _, p in
                                Button("\(p.0): \(p.1)") { form.remotePath = p.1 }
                            }
                        }
                        .fixedSize()
                    }
                }
                Picker("Loại", selection: $form.kind) {
                    Text("File").tag(TransferItemKind.file)
                    Text("Thư mục").tag(TransferItemKind.directory)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(form.localDirectory.isEmpty ? "Chưa chọn" : form.localDirectory)
                        .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Chọn thư mục lưu…") {
                        if let p = chooseLocal(files: false, directories: true, prompt: "Chọn") {
                            form.localDirectory = p
                        }
                    }
                }
                TextField("Tên lưu (để trống = giữ tên remote)", text: $form.localName)
                    .textFieldStyle(.roundedBorder)
            }
            if let result = form.resultPath {
                LabeledContent("Đích cuối") {
                    Text(result).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            if form.hasConflict { conflictSection }
            ForEach(Array(form.issues.enumerated()), id: \.offset) { _, i in
                Text(i.message).font(.callout).foregroundStyle(.red)
            }
            summary
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bắt đầu") {
                    Task {
                        if await model.startDownload(form, host: host) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!form.canStart)
            }
        }
        .padding(20)
        .frame(width: 560)
        .passwordPromptSheet(model: model, presenter: .transferSheet)
        .onAppear {
            guard !ready else { return }
            ready = true
            form.localDirectory =
                host.defaultLocalDirectory.isEmpty
                ? model.settings.resolvedLocalDirectory() : host.defaultLocalDirectory
            if !host.defaultRemoteDirectory.isEmpty { form.remotePath = host.defaultRemoteDirectory }
        }
    }

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Đích đã tồn tại trên máy này", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Picker(
                "Xử lý",
                selection: Binding(
                    get: { form.conflictChoice },
                    set: {
                        form.conflictChoice = $0
                        if $0 == .rename, form.renameTo.isEmpty {
                            form.renameTo = form.suggestedRename ?? ""
                        }
                    })
            ) {
                Text("Chưa chọn").tag(ConflictChoice?.none)
                Text("Ghi đè").tag(ConflictChoice?.some(.overwrite))
                Text("Đổi tên").tag(ConflictChoice?.some(.rename))
                Text("Bỏ qua").tag(ConflictChoice?.some(.skip))
            }
            .pickerStyle(.radioGroup)
            if form.conflictChoice == .rename {
                TextField("Tên mới", text: $form.renameTo).textFieldStyle(.roundedBorder)
            }
        }
    }

    private var summary: some View {
        GroupBox("Tóm tắt") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Máy: \(host.displayName) (\(TransferTarget.describe(host)))")
                Text("Chiều: server → máy này")
                Text("Nguồn: \(form.remotePath.isEmpty ? "—" : form.remotePath)")
                Text("Đích: \(form.resultPath ?? "—")")
            }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}

struct UploadSheet: View {
    @Bindable var model: AppModel
    let host: HostProfile
    @Local private var form = UploadForm()
    @Local private var ready = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tải lên").font(.title2.bold())
            TargetHeader(host: host, direction: "Tải từ máy này lên server")
            Form {
                HStack {
                    Text(form.localPath.isEmpty ? "Chưa chọn file/thư mục" : form.localPath)
                        .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Chọn file/thư mục…") {
                        if let p = chooseLocal(files: true, directories: true, prompt: "Chọn") {
                            form.localPath = p
                            form.remoteName = ""
                            form.refreshLocal()
                        }
                    }
                }
                HStack {
                    TextField("Thư mục remote đích", text: $form.remoteDirectory)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    let picks = remoteQuickPicks(host)
                    if !picks.isEmpty {
                        Menu("Chọn nhanh") {
                            ForEach(Array(picks.enumerated()), id: \.offset) { _, p in
                                Button("\(p.0): \(p.1)") { form.remoteDirectory = p.1 }
                            }
                        }
                        .fixedSize()
                    }
                }
                TextField("Tên đích (để trống = giữ tên local)", text: $form.remoteName)
                    .textFieldStyle(.roundedBorder)
            }
            if let final = form.finalRemotePath {
                LabeledContent("Đường dẫn cuối") {
                    Text(final).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            ForEach(Array(form.warnings.enumerated()), id: \.offset) { _, w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            ForEach(Array(form.issues.enumerated()), id: \.offset) { _, i in
                // Chưa chọn nguồn thì chưa cần báo lỗi đỏ ngay khi mở sheet.
                if !(i == .localSourceMissing && form.localPath.isEmpty) {
                    Text(i.message).font(.callout).foregroundStyle(.red)
                }
            }
            GroupBox("Tóm tắt") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Máy: \(host.displayName) (\(TransferTarget.describe(host)))")
                    Text("Chiều: máy này → server")
                    Text("Nguồn: \(form.localPath.isEmpty ? "—" : form.localPath)")
                    Text("Đích: \(form.finalRemotePath ?? "—")")
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bắt đầu") {
                    Task {
                        if await model.startUpload(form, host: host) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!form.canStart)
            }
        }
        .padding(20)
        .frame(width: 560)
        .passwordPromptSheet(model: model, presenter: .transferSheet)
        .onAppear {
            guard !ready else { return }
            ready = true
            form.remoteDirectory = host.defaultRemoteDirectory
        }
    }
}
