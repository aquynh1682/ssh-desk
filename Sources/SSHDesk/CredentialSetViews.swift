import AppKit
import SSHDeskCore
import SwiftUI

/// Danh sách "Bộ đăng nhập" trong Cài đặt → Bảo mật (ADR-030).
struct CredentialSetsSection: View {
    @Bindable var model: AppModel
    @Local private var editing: EditTarget?
    @Local private var deleting: CredentialSet?
    @Local private var usersOf: CredentialSet?

    enum EditTarget: Identifiable {
        case new
        case edit(CredentialSet)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let s): return s.id.uuidString
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bộ đăng nhập").font(.system(size: 13.5))
                    Text(
                        "Dùng chung password / key / passphrase / agent cho nhiều máy. Mật khẩu riêng của máy vẫn ưu tiên hơn bộ."
                    )
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Thêm bộ…") { editing = .new }
            }
            if model.credentialSets.isEmpty {
                Text("Chưa có bộ đăng nhập nào.").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(model.credentialSets) { set in row(set) }
        }
        .sheet(item: $editing) { target in
            CredentialSetEditor(model: model, target: target)
        }
        .sheet(item: $usersOf) { set in
            CredentialSetUsersSheet(model: model, set: set)
        }
        .confirmationDialog(
            "Xoá bộ “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá bộ", role: .destructive) {
                if let d = deleting { Task { await model.deleteCredentialSet(d.id) } }
                deleting = nil
            }
            Button("Huỷ", role: .cancel) { deleting = nil }
        } message: {
            let n = deleting.map { model.credentialSetUsage[$0.id] ?? 0 } ?? 0
            Text(
                "\(n) máy đang dùng bộ này sẽ không còn dùng nó (máy được giữ nguyên). Password/passphrase của bộ bị xoá khỏi Keychain."
            )
        }
    }

    private func row(_ set: CredentialSet) -> some View {
        let hasPw = model.setHasPassword(set.id)
        let count = model.credentialSetUsage[set.id] ?? 0
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name).font(.system(size: 13, weight: .semibold))
                Text("\(set.kindLabel(hasPassword: hasPw)) · \(count) máy")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let file = set.identityFile,
                    !FileManager.default.fileExists(
                        atPath: CredentialResolution.expandTilde(file, home: NSHomeDirectory()))
                {
                    Text("Không thấy file key \(file)").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            Spacer()
            Button("Máy dùng") { usersOf = set }.disabled(count == 0)
            Button("Sửa…") { editing = .edit(set) }
            Button("Xoá…", role: .destructive) { deleting = set }
        }
        .padding(.vertical, 4)
    }
}

/// Tạo / sửa bộ. Password và passphrase là SecureField; để trống khi sửa = giữ nguyên.
struct CredentialSetEditor: View {
    @Bindable var model: AppModel
    let target: CredentialSetsSection.EditTarget
    @Environment(\.dismiss) private var dismiss

    @Local private var loaded = false
    @Local private var original: CredentialSet?
    @Local private var name = ""
    @Local private var user = ""
    @Local private var note = ""
    @Local private var identityFile = ""
    @Local private var preset: IdentityAgentPreset?
    @Local private var customAgent = ""
    @Local private var password = ""
    @Local private var passphrase = ""
    @Local private var saving = false
    @Local private var confirmKeyLoss = false

    private var isNew: Bool { original == nil }

    private var agentValue: String? {
        switch preset {
        case nil: return nil
        case .custom?: return customAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        case let p?: return p.path
        }
    }

    private var draftSet: CredentialSet {
        var s = original ?? CredentialSet(name: "")
        s.name = name
        s.user = user
        s.note = note
        s.identityFile = identityFile
        s.identityAgent = agentValue
        return s
    }

    private var validationError: String? {
        do { _ = try draftSet.validated() } catch { return AppModel.setMessage(error) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "Bộ đăng nhập mới" : "Sửa bộ đăng nhập") {
                    TextField("Tên", text: $name)
                    TextField("User gợi ý (tuỳ chọn)", text: $user)
                    TextField("Ghi chú", text: $note, axis: .vertical).lineLimit(1...3)
                }
                Section("Mật khẩu") {
                    SecureField(
                        "Mật khẩu", text: $password,
                        prompt: Text(
                            original.map { model.setHasPassword($0.id) } == true
                                ? "Để trống = giữ mật khẩu hiện tại" : "Tuỳ chọn"))
                    if let o = original, model.setHasPassword(o.id) {
                        Button("Xoá mật khẩu của bộ", role: .destructive) {
                            Task { await model.clearSetSecret(o.id, passphrase: false) }
                        }
                    }
                }
                Section("Key") {
                    HStack {
                        TextField("File key (đường dẫn)", text: $identityFile)
                        Button("Chọn…") { chooseKey() }
                        let withPrivate = model.keys.keys.filter(\.hasPrivateKey)
                        if !withPrivate.isEmpty {
                            Menu("Key đã quét") {
                                ForEach(withPrivate) { k in
                                    Button(k.name) { identityFile = k.privateKeyPath ?? "" }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if !identityFile.isEmpty,
                        !FileManager.default.fileExists(
                            atPath: CredentialResolution.expandTilde(identityFile, home: NSHomeDirectory()))
                    {
                        Text("Không thấy file key này").font(.caption).foregroundStyle(Theme.amber)
                    }
                    SecureField(
                        "Passphrase của key", text: $passphrase,
                        prompt: Text(
                            original.map { model.setHasPassphrase($0.id) } == true
                                ? "Để trống = giữ passphrase hiện tại" : "Tuỳ chọn"))
                    if let o = original, model.setHasPassphrase(o.id) {
                        Button("Xoá passphrase", role: .destructive) {
                            Task { await model.clearSetSecret(o.id, passphrase: true) }
                        }
                    }
                    Text(
                        "Chỉ lưu đường dẫn, app không đọc nội dung key. Passphrase chỉ tự điền khi mở bằng Warp (ssh hỏi đúng key này). Truyền file, tunnel, Analyst, Monitor luôn hỏi bạn."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent") {
                    Picker("Agent", selection: $preset) {
                        Text("Theo mặc định (Cài đặt)").tag(IdentityAgentPreset?.none)
                        ForEach(IdentityAgentPreset.allCases, id: \.self) {
                            Text($0.title).tag(IdentityAgentPreset?.some($0))
                        }
                    }
                    if preset == .custom {
                        TextField("Đường dẫn socket", text: $customAgent, prompt: Text("~/.../agent.sock"))
                    }
                }
                if let e = validationError, !name.isEmpty || !identityFile.isEmpty {
                    Text(e).foregroundStyle(Theme.red).font(.caption)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") {
                    if keyLossCount > 0 { confirmKeyLoss = true } else { Task { await save() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || validationError != nil)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
        .confirmationDialog(
            "Bỏ key của bộ?", isPresented: $confirmKeyLoss, titleVisibility: .visible
        ) {
            Button("Vẫn lưu", role: .destructive) { Task { await save() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("\(keyLossCount) máy dùng xác thực File khoá đang lấy key từ bộ này sẽ không còn key.")
        }
    }

    /// Số máy `.keyFile` đang lấy key từ bộ sẽ mất key nếu lưu như hiện tại.
    private var keyLossCount: Int {
        guard let o = original else { return 0 }
        return CredentialSet.hostsLosingKey(hosts: model.hosts, before: o, after: draftSet.normalizedForCompare).count
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard case .edit(let s) = target else { return }
        original = s
        name = s.name
        user = s.user ?? ""
        note = s.note
        identityFile = s.identityFile ?? ""
        if let agent = s.identityAgent {
            let p = IdentityAgentPreset.matching(agent)
            preset = p
            if p == .custom { customAgent = agent }
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Chọn"
        if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let pw = password.isEmpty ? nil : password
        let pp = passphrase.isEmpty ? nil : passphrase
        password = ""
        passphrase = ""
        if await model.saveCredentialSet(draftSet, isNew: isNew, password: pw, passphrase: pp) { dismiss() }
    }
}

/// Máy đang dùng một bộ.
struct CredentialSetUsersSheet: View {
    @Bindable var model: AppModel
    let set: CredentialSet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Máy dùng bộ “\(set.name)”").font(.headline)
            let users = model.hosts.filter { $0.credentialSetID == set.id }
            List(users) { h in
                HStack {
                    Text(h.displayName)
                    Spacer()
                    if !(h.credentialReference ?? "").isEmpty {
                        Text("có mật khẩu riêng (ưu tiên)").font(.caption).foregroundStyle(.secondary)
                    }
                    if h.autofillHold {
                        Text("đang hold").font(.caption).foregroundStyle(Theme.amber)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 440, height: 300)
    }
}

/// "Gán bộ đăng nhập…" cho cả thư mục: xem trước số máy và máy có mật khẩu riêng.
struct AssignSetSheet: View {
    @Bindable var model: AppModel
    let target: AssignSetTarget
    @Environment(\.dismiss) private var dismiss
    @Local private var chosen: UUID?

    var body: some View {
        let hosts = model.assignableHosts(inFolder: target.folder)
        let own = hosts.filter { !($0.credentialReference ?? "").isEmpty }
        let current = hosts.filter { $0.credentialSetID != nil }
        VStack(alignment: .leading, spacing: 12) {
            Text("Gán bộ đăng nhập cho thư mục “\(target.folder)”").font(.headline)
            Picker("Bộ đăng nhập", selection: $chosen) {
                Text("Gỡ bộ khỏi các máy").tag(UUID?.none)
                ForEach(model.credentialSets) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(hosts.count) máy sẽ bị ảnh hưởng (máy alias có sẵn trong ~/.ssh/config được bỏ qua).")
                if !own.isEmpty {
                    Text("\(own.count) máy có mật khẩu riêng — mật khẩu riêng vẫn ưu tiên hơn bộ.")
                        .foregroundStyle(Theme.amber)
                }
                if chosen != nil, !current.isEmpty {
                    Text("\(current.count) máy đang dùng bộ khác sẽ chuyển sang bộ này.")
                }
                if chosen == nil {
                    Text("\(current.count) máy đang dùng bộ sẽ được gỡ.")
                }
                Text(
                    "Gán thủ công không tạm tắt tự điền. Cần chọn từng máy riêng lẻ? Bảng máy chủ chưa hỗ trợ chọn nhiều — dùng thư mục."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Áp dụng") {
                    Task {
                        await model.assignCredentialSet(chosen, to: hosts.map(\.id))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hosts.isEmpty || (chosen == nil && current.isEmpty))
            }
        }
        .padding(18).frame(width: 460)
    }
}
