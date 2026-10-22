import SSHDeskCore
import SwiftUI

/// Màn "SSH Keys" (ADR-014): bảng key trong ~/.ssh, panel chi tiết bên phải.
struct KeysView: View {
    @Bindable var model: AppModel
    @Bindable var keys: KeysModel

    private static let typeWidth: CGFloat = 96
    private static let fingerprintWidth: CGFloat = 250
    private static let commentWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let task = keys.task { taskBar(task) }
                Group {
                    if !keys.loaded {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if keys.keys.isEmpty {
                        ContentUnavailableView(
                            "Chưa có key nào", systemImage: "key",
                            description: Text(
                                "Không thấy cặp key (*.pub + private) trong ~/.ssh. Tạo key mới để bắt đầu."))
                    } else {
                        table
                    }
                }
                .cardStyle()
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            Divider().overlay(Theme.divider)
            if let key = keys.selected {
                KeyDetailPanel(model: model, keys: keys, key: key)
            } else {
                ContentUnavailableView(
                    "Chọn một key", systemImage: "key",
                    description: Text("Chọn key ở danh sách để xem chi tiết.")
                )
                .frame(width: Theme.detailWidth)
            }
        }
        .task { await keys.refresh() }
        .sheet(isPresented: $keys.showGenerate) { GenerateKeySheet(keys: keys) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SSH Keys").font(.system(size: 26, weight: .bold))
                Text("Khoá SSH trong ~/.ssh — tạo mới, copy public key, cài lên máy chủ")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await keys.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(OutlineButtonStyle()).help("Làm mới danh sách")
            .accessibilityLabel("Làm mới")
            Button {
                keys.showGenerate = true
            } label: {
                Label("Tạo key mới", systemImage: "plus")
            }
            .buttonStyle(ProminentButtonStyle())
            .disabled(keys.isBusy)
        }
    }

    private func taskBar(_ task: KeyTaskInfo) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(task.title).font(.system(size: 13))
            Spacer()
            Button("Huỷ") { keys.cancelTask() }.controlSize(.small)
        }
        .padding(12)
        .cardStyle()
    }

    // MARK: Bảng

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("TÊN").padding(.leading, 34).frame(maxWidth: .infinity, alignment: .leading)
                Text("LOẠI").frame(width: Self.typeWidth, alignment: .leading)
                Text("FINGERPRINT").frame(width: Self.fingerprintWidth + 30, alignment: .leading)
                Text("COMMENT").frame(width: Self.commentWidth, alignment: .leading)
                Text("CẢNH BÁO").frame(width: 70, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold)).tracking(0.5)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Theme.divider)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(keys.keys) { key in row(key) }
                }
            }
        }
    }

    private func row(_ key: SSHKeyInfo) -> some View {
        let selected = keys.selectionName == key.name
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .foregroundStyle(selected ? Theme.green : Theme.textSecondary).frame(width: 24)
                Text(key.name).font(.system(size: 14.5)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(key.typeText).font(.system(size: 13, design: .monospaced))
                .frame(width: Self.typeWidth, alignment: .leading)
            HStack(spacing: 6) {
                Text(key.fingerprint ?? "—")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if let fp = key.fingerprint {
                    Button {
                        model.copyValue(fp, label: "fingerprint")
                    } label: {
                        Image(systemName: "doc.on.doc").foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain).help("Copy fingerprint").accessibilityLabel("Copy fingerprint")
                }
            }
            .frame(width: Self.fingerprintWidth + 30, alignment: .leading)
            Text(key.comment ?? "—").font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Self.commentWidth, alignment: .leading)
            HStack {
                if !key.warnings.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                        .help(key.warnings.joined(separator: "\n"))
                        .accessibilityLabel(key.warnings.joined(separator: ". "))
                }
            }
            .frame(width: 70, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(selected ? Theme.rowSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { keys.selectionName = key.name }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Panel chi tiết

struct KeyDetailPanel: View {
    @Bindable var model: AppModel
    @Bindable var keys: KeysModel
    let key: SSHKeyInfo
    @Local private var showHostPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key")
                        .font(.system(size: 22)).foregroundStyle(Theme.green)
                        .frame(width: 52, height: 52)
                        .background(Theme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.green.opacity(0.4)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.name).font(.system(size: 18, weight: .bold)).lineLimit(2)
                        Text(key.typeText).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Button {
                    keys.copyPublicKey(key)
                } label: {
                    Label("Copy public key", systemImage: "doc.on.doc")
                }
                .buttonStyle(ProminentButtonStyle(fullWidth: true))
                .disabled(key.isSymlink)
                .help("Copy nội dung file .pub (public key — không phải private key)")
                HStack(spacing: 10) {
                    Button {
                        keys.revealInFinder(key)
                    } label: {
                        Label("Hiện trong Finder", systemImage: "folder")
                    }
                    .buttonStyle(OutlineButtonStyle(fullWidth: true))
                    Button {
                        showHostPicker = true
                    } label: {
                        Label("Cài lên máy chủ…", systemImage: "arrow.up.to.line")
                    }
                    .buttonStyle(OutlineButtonStyle(fullWidth: true))
                    .disabled(keys.isBusy || key.isSymlink)
                    .popover(isPresented: $showHostPicker, arrowEdge: .bottom) {
                        KeyInstallHostPicker(model: model) { host in
                            showHostPicker = false
                            keys.requestInstall(key: key, host: host)
                        }
                    }
                }
                detailCard
                if !key.warnings.isEmpty { warningsCard }
            }
            .padding(18)
        }
        .frame(width: Theme.detailWidth)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chi tiết").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 12)
            row("Loại", key.typeText, mono: true)
            row("Fingerprint", key.fingerprint ?? "—", mono: true, copy: key.fingerprint)
            row("Comment", key.comment ?? "—")
            row("Public key", key.publicKeyPath, mono: true)
            row("Private key", key.privateKeyPath ?? "Không có", mono: key.hasPrivateKey)
        }
        .cardStyle()
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, copy: String? = nil) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.divider)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(Theme.textSecondary).frame(width: 92, alignment: .leading)
                Text(value)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let copy {
                    Button {
                        model.copyValue(copy, label: label.lowercased())
                    } label: {
                        Image(systemName: "doc.on.doc").foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain).help("Copy \(label)").accessibilityLabel("Copy \(label)")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(key.warnings, id: \.self) { w in
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    Text(w).font(.system(size: 12.5))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Chọn máy chủ để cài key, nhóm theo môi trường.
struct KeyInstallHostPicker: View {
    @Bindable var model: AppModel
    let pick: (HostProfile) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if HostPresentation.sshHosts(model.hosts).isEmpty {
                    Text("Chưa có máy chủ nào.").foregroundStyle(Theme.textSecondary).padding(8)
                }
                ForEach(HostPresentation.environmentOrder, id: \.self) { env in
                    let group = HostPresentation.sortedByName(
                        HostPresentation.sshHosts(model.hosts).filter { $0.environment == env },
                        ascending: true)
                    if !group.isEmpty {
                        Text(HostPresentation.title(for: env).uppercased())
                            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 8).padding(.top, 8)
                        ForEach(group) { host in
                            Button {
                                pick(host)
                            } label: {
                                HStack {
                                    Text(host.displayName).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(HostPresentation.addressText(host))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    EnvironmentBadge(environment: host.environment)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 380, height: 320)
    }
}

// MARK: - Sheet tạo key

struct GenerateKeySheet: View {
    @Bindable var keys: KeysModel
    @Local private var name = "id_ed25519_new"
    @Local private var comment = "\(NSUserName())@\(ProcessInfo.processInfo.hostName)"
    @Local private var working = false

    private var nameError: String? {
        do {
            try SSHKeyNaming.validateName(name)
            let dir = SSHKeyInventory.defaultDirectory
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
                || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name + ".pub").path)
            {
                return "File đã tồn tại — app không ghi đè."
            }
            return nil
        } catch { return (error as? SSHKeyError)?.description ?? "\(error)" }
    }

    private var commentError: String? {
        do {
            try SSHKeyNaming.validateComment(comment)
            return nil
        } catch { return (error as? SSHKeyError)?.description ?? "\(error)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tạo key mới").font(.title2.bold())
            Text("Loại ed25519. Passphrase được hỏi ngay sau đó (để trống nếu không cần) và không được lưu.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tên file").font(.caption).foregroundStyle(.secondary)
                TextField("id_ed25519_new", text: $name).textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Text("~/.ssh/\(name)  và  ~/.ssh/\(name).pub")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let nameError { Text(nameError).font(.caption).foregroundStyle(Theme.red) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Comment").font(.caption).foregroundStyle(.secondary)
                TextField("user@host", text: $comment).textFieldStyle(.roundedBorder)
                if let commentError { Text(commentError).font(.caption).foregroundStyle(Theme.red) }
            }
            HStack {
                Spacer()
                Button("Huỷ") { keys.showGenerate = false }.keyboardShortcut(.cancelAction)
                Button("Tạo key") {
                    working = true
                    Task {
                        let started = await keys.generate(name: name, comment: comment)
                        working = false
                        if started { keys.showGenerate = false }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(nameError != nil || commentError != nil || working || keys.isBusy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Chọn key từ chi tiết host ("Cài key…")

struct PickKeySheet: View {
    @Bindable var keys: KeysModel
    let host: HostProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cài key lên “\(host.displayName)”").font(.title3.bold())
            if keys.keys.isEmpty {
                Text("Chưa có key nào trong ~/.ssh. Tạo key ở màn SSH Keys trước.")
                    .foregroundStyle(.secondary)
            } else {
                List(keys.keys.filter { !$0.isSymlink }) { key in
                    Button {
                        keys.pickKeyForHost = nil
                        keys.requestInstall(key: key, host: host)
                    } label: {
                        HStack {
                            Image(systemName: "key")
                            Text(key.name)
                            Spacer()
                            Text(key.typeText).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Đóng") { keys.pickKeyForHost = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await keys.refresh() }
    }
}

// MARK: - Hộp thoại dùng chung (gắn ở MainView)

struct KeysDialogs: ViewModifier {
    @Bindable var model: AppModel
    @Bindable var keys: KeysModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $keys.pickKeyForHost) { host in PickKeySheet(keys: keys, host: host) }
            .confirmationDialog(
                "Cài key lên máy PRODUCTION?",
                isPresented: Binding(
                    get: { keys.confirmProdInstall != nil },
                    set: { if !$0 { keys.confirmProdInstall = nil } }),
                titleVisibility: .visible
            ) {
                Button("Cài key lên “\(keys.confirmProdInstall?.host.displayName ?? "")”", role: .destructive) {
                    if let c = keys.confirmProdInstall {
                        keys.confirmProdInstall = nil
                        Task { await keys.install(key: c.key, host: c.host) }
                    }
                }
                Button("Huỷ", role: .cancel) { keys.confirmProdInstall = nil }
            } message: {
                Text(
                    "Key “\(keys.confirmProdInstall?.key.name ?? "")” sẽ được thêm vào authorized_keys của máy production này, cho phép đăng nhập bằng key đó."
                )
            }
            .confirmationDialog(
                "Đổi \(keys.adoptionOffer?.host.displayName ?? "") sang xác thực bằng key \(keys.adoptionOffer?.key.name ?? "")?",
                isPresented: Binding(
                    get: { keys.adoptionOffer != nil },
                    set: { if !$0 { keys.adoptionOffer = nil } }),
                titleVisibility: .visible
            ) {
                Button("Đổi sang key này") {
                    if let o = keys.adoptionOffer { Task { await keys.confirmAdoption(o) } }
                }
                Button("Giữ nguyên", role: .cancel) { keys.adoptionOffer = nil }
            } message: {
                Text("Hồ sơ sẽ dùng file private key của cặp này (chỉ lưu đường dẫn). Có thể đổi lại trong form Sửa.")
            }
    }
}
