import AppKit
import SSHDeskCore
import SwiftUI

struct HostFormView: View {
    @Bindable var model: AppModel
    let target: FormTarget
    @Environment(\.dismiss) private var dismiss

    @Local private var draft = HostDraft()
    @Local private var base: HostProfile?
    @Local private var loaded = false
    @Local private var showAdvanced = false
    @Local private var saving = false
    @Local private var storePassword = false
    @Local private var passwordInput = ""
    @Local private var hasSavedPassword = false

    private var isNew: Bool { base == nil }
    private var isImported: Bool { base?.connectionMode == .existingSSHConfigAlias }
    private var errors: [HostDraft.Field: String] { draft.errors(basedOn: base) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isImported, let b = base {
                    Section {
                        Label(
                            "Cấu hình kết nối lấy từ alias \(b.sshConfigAlias ?? "?") trong \(b.sshConfigPath ?? "?"). Ở đây chỉ sửa thông tin quản lý.",
                            systemImage: "link"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                Section("Thông tin chính") {
                    field("Tên", .displayName) {
                        TextField("Tên", text: $draft.displayName, prompt: Text("Web production"))
                    }
                    if !isImported {
                        LabeledContent("Kiểu kết nối") {
                            Text("Tự cấu hình (app sinh khối Host)").foregroundStyle(.secondary)
                        }
                        field("Host", .hostName) {
                            TextField("Host", text: $draft.hostName, prompt: Text("server.example.com"))
                        }
                        field("User", .user) {
                            TextField("User", text: $draft.user, prompt: Text("deploy"))
                        }
                        field("Port", .port) { TextField("Port", text: $draft.portText) }
                        Picker("Xác thực", selection: $draft.authMethod) {
                            Text("ssh-agent / mặc định").tag(HostAuthMethod.agent)
                            Text("File khoá riêng").tag(HostAuthMethod.keyFile)
                            Text("Nhập khi kết nối").tag(HostAuthMethod.interactive)
                        }
                        if draft.authMethod == .keyFile {
                            field("File khoá", .identityFile) {
                                HStack {
                                    TextField("Đường dẫn", text: $draft.identityFile)
                                    Button("Chọn…") { chooseKey() }
                                }
                            }
                        }
                        if draft.authMethod == .interactive {
                            Text("Mật khẩu/passphrase/OTP được nhập trong Warp; app không lưu.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                passwordSection
                Section {
                    DisclosureGroup("Nâng cao", isExpanded: $showAdvanced) {
                        if !isImported {
                            field("Bastion", .jumpHost) {
                                Picker("Bastion", selection: $draft.jumpHostID) {
                                    Text("Không dùng").tag(UUID?.none)
                                    ForEach(model.hosts.filter { $0.id != base?.id }) { h in
                                        Text(h.displayName).tag(UUID?.some(h.id))
                                    }
                                }
                            }
                        }
                        TextField("Dự án", text: $draft.project)
                        Picker("Môi trường", selection: $draft.environment) {
                            ForEach(HostEnvironment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        TextField("Tags (cách nhau bằng dấu phẩy)", text: $draft.tagsText)
                        TextField("Ghi chú", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                        bookmarks
                    }
                }
                if let g = errors[.general] ?? errors[.alias] {
                    Text(g).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!errors.isEmpty || saving)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: load)
    }

    private var passwordSection: some View {
        Section("Mật khẩu") {
            if hasSavedPassword {
                HStack {
                    Label("Đã lưu mật khẩu", systemImage: "checkmark.shield")
                    Spacer()
                    Button("Xoá mật khẩu đã lưu") { Task { await clearSavedPassword() } }
                }
            }
            Toggle("Lưu trong Keychain", isOn: $storePassword)
            if storePassword {
                SecureField(
                    "Mật khẩu", text: $passwordInput,
                    prompt: Text(hasSavedPassword ? "Để trống = giữ mật khẩu hiện tại" : "Mật khẩu SSH"))
                Text("Mật khẩu chỉ nằm trong Keychain. Ưu tiên dùng SSH key nếu máy chủ hỗ trợ.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func clearSavedPassword() async {
        guard let b = base, let updated = await model.clearPassword(hostID: b.id) else { return }
        base = updated
        hasSavedPassword = false
        passwordInput = ""
    }

    private var bookmarks: some View {
        VStack(alignment: .leading) {
            Text("Bookmark thư mục remote").font(.subheadline)
            ForEach(draft.bookmarks.indices, id: \.self) { i in
                HStack {
                    TextField("Tên", text: $draft.bookmarks[i].name)
                    TextField("Đường dẫn", text: $draft.bookmarks[i].path)
                    Button {
                        draft.bookmarks.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Thêm bookmark") { draft.bookmarks.append(RemoteBookmark(name: "", path: "")) }
        }
    }

    /// Trường kèm thông báo lỗi ngay bên dưới.
    private func field<C: View>(
        _ label: String, _ f: HostDraft.Field, @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
            if let e = errors[f] { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if case .edit(let h) = target {
            base = h
            draft = HostDraft(host: h)
            showAdvanced = true
            hasSavedPassword = model.hasStoredPassword(h)
        }
    }

    /// Chỉ lấy đường dẫn; không đọc nội dung file khoá.
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh")
        panel.prompt = "Chọn"
        if panel.runModal() == .OK, let url = panel.url { draft.identityFile = url.path }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let profile = draft.profile(basedOn: base)
        // Lấy giá trị ra rồi xoá khỏi state ngay: không giữ password trong view sau khi lưu.
        let password = storePassword && !passwordInput.isEmpty ? passwordInput : nil
        passwordInput = ""
        if await model.save(profile, isNew: isNew, password: password) { dismiss() }
    }
}
