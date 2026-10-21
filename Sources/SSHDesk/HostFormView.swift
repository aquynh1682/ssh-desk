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
    @Local private var changingPassword = false
    @Local private var confirmClear = false
    @Local private var confirmRemoveOnSave = false
    @Local private var passwordInput = ""
    @Local private var hasSavedPassword = false
    @Local private var creatingFolder = false

    private var isNew: Bool { base == nil }
    private var isImported: Bool { base?.connectionMode == .existingSSHConfigAlias }
    private var errors: [HostDraft.Field: String] {
        draft.errors(
            basedOn: base, hasSavedPassword: hasSavedPassword,
            passwordEntered: !passwordInput.isEmpty)
    }

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
                    }
                    authSection
                }
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
                        folderField
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
                Button("Lưu") {
                    if draft.removesStoredPassword(hasSavedPassword: hasSavedPassword) {
                        confirmRemoveOnSave = true
                    } else {
                        Task { await save() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty || folderError != nil || saving)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: load)
        .confirmationDialog("Xoá mật khẩu đã lưu?", isPresented: $confirmClear) {
            Button("Xoá", role: .destructive) { Task { await clearSavedPassword() } }
        } message: {
            Text("Mật khẩu sẽ bị xoá khỏi Keychain.")
        }
        .confirmationDialog("Xoá mật khẩu đã lưu?", isPresented: $confirmRemoveOnSave) {
            Button("Xoá và lưu", role: .destructive) { Task { await save() } }
        } message: {
            Text("Bạn đã chuyển khỏi \"Mật khẩu\"; mật khẩu trong Keychain sẽ bị xoá.")
        }
    }

    private var authChoices: [(HostDraft.AuthChoice, String)] {
        let all: [(HostDraft.AuthChoice, String)] = [
            (.agent, "ssh-agent / mặc định"), (.keyFile, "File khoá riêng"),
            (.password, "Mật khẩu (lưu trong Keychain)"), (.prompt, "Nhập khi kết nối"),
        ]
        // Hồ sơ imported: cấu hình key/agent nằm ở alias; chỉ cho đặt/bỏ mật khẩu.
        guard isImported else { return all }
        let cur = draft.authChoice
        var list = all.filter { $0.0 == .password || $0.0 == .prompt }
        if cur == .agent || cur == .keyFile { list.insert((cur, "Theo cấu hình alias"), at: 0) }
        return list
    }

    @ViewBuilder
    private var authSection: some View {
        Picker("Xác thực", selection: $draft.authChoice) {
            ForEach(authChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        if draft.authChoice == .keyFile && !isImported {
            field("File khoá", .identityFile) {
                HStack {
                    TextField("Đường dẫn", text: $draft.identityFile)
                    Button("Chọn…") { chooseKey() }
                }
            }
        }
        if draft.authChoice == .password {
            if hasSavedPassword && !changingPassword {
                HStack {
                    Label("Đã lưu mật khẩu", systemImage: "checkmark.shield")
                    Spacer()
                    Button("Đổi") { changingPassword = true }
                    Button("Xoá") { confirmClear = true }
                }
            } else {
                field("Mật khẩu", .password) {
                    SecureField(
                        "Mật khẩu", text: $passwordInput,
                        prompt: Text(hasSavedPassword ? "Để trống = giữ mật khẩu hiện tại" : "Mật khẩu SSH"))
                }
            }
        }
        Text(authNote).font(.caption).foregroundStyle(.secondary)
    }

    private var authNote: String {
        switch draft.authChoice {
        case .agent: return "Dùng key trong ssh-agent hoặc cấu hình SSH mặc định."
        case .keyFile: return "Passphrase (nếu có) nhập khi kết nối."
        case .password:
            return "Mật khẩu chỉ nằm trong Keychain của Mac; tự đăng nhập khi mở Warp (trừ host có bastion)."
        case .prompt: return "Mật khẩu/OTP nhập trong Warp, app không lưu."
        }
    }

    private func clearSavedPassword() async {
        guard let b = base, let updated = await model.clearPassword(hostID: b.id) else { return }
        base = updated
        hasSavedPassword = false
        changingPassword = false
        passwordInput = ""
        if draft.authChoice == .password { draft.authChoice = .prompt }
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
            hasSavedPassword = model.hasStoredPassword(h)
            draft = HostDraft(host: h, hasSavedPassword: hasSavedPassword)
            showAdvanced = true
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

    private static let newFolderTag = "\u{1}new-folder"

    private var folderError: String? {
        let t = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        do { _ = try HostFolders.normalize(t) } catch { return AppModel.message(for: error) }
        return nil
    }

    /// Chọn thư mục sẵn có hoặc "Thư mục mới…" (hiện ô nhập tên).
    private var folderField: some View {
        let creating = creatingFolder
        return VStack(alignment: .leading, spacing: 6) {
            Picker(
                "Thư mục",
                selection: Binding(
                    get: { creating ? Self.newFolderTag : draft.project },
                    set: { value in
                        if value == Self.newFolderTag {
                            creatingFolder = true
                            draft.project = ""
                        } else {
                            creatingFolder = false
                            draft.project = value
                        }
                    })
            ) {
                Text(HostFolders.uncategorizedTitle).tag("")
                ForEach(folderChoices, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("Thư mục mới…").tag(Self.newFolderTag)
            }
            if creating {
                TextField("Tên thư mục mới", text: $draft.project)
            }
            if let folderError { Text(folderError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var folderChoices: [String] {
        let cur = draft.project
        return cur.isEmpty || model.folders.contains(cur) ? model.folders : model.folders + [cur]
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var profile = draft.profile(basedOn: base)
        profile.project = model.canonicalFolder(profile.project)
        // Lấy giá trị ra rồi xoá khỏi state ngay: không giữ password trong view sau khi lưu.
        let password = draft.authChoice == .password && !passwordInput.isEmpty ? passwordInput : nil
        passwordInput = ""
        let removeStored = draft.removesStoredPassword(hasSavedPassword: hasSavedPassword)
        if await model.save(profile, isNew: isNew, password: password) {
            if removeStored { _ = await model.clearPassword(hostID: profile.id) }
            dismiss()
        }
    }
}
