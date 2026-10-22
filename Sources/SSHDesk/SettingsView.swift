import AppKit
import SSHDeskCore
import SwiftUI

/// Màn "Cài đặt" (ADR-021): dùng chung cho mục sidebar và cửa sổ Settings (⌘,). Giá trị đi qua
/// `AppModel.updateSettings` (chuẩn hoá + lưu + áp dụng ngay); logic kẹp phạm vi nằm ở `AppSettings` (Core).
struct SettingsView: View {
    @Bindable var model: AppModel

    @FocusState private var configPathFocused: Bool
    @Local private var configPathText = ""
    @Local private var configPathError: String?
    @Local private var confirmClearPasswords = false
    @Local private var savedPasswordCount = 0

    private var s: AppSettings { model.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cài đặt").font(.system(size: 22, weight: .bold))
                general
                warp
                transfer
                sshConfig
                security
                analyst
                monitor
                windows
                data
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.windowBackground)
        .onAppear { configPathText = s.userSSHConfigPath }
        .confirmationDialog(
            "Xoá mọi mật khẩu đã lưu?", isPresented: $confirmClearPasswords, titleVisibility: .visible
        ) {
            Button("Xoá \(savedPasswordCount) mật khẩu", role: .destructive) {
                Task { await model.clearAllPasswords() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(
                "Xoá \(savedPasswordCount) mật khẩu khỏi Keychain và gỡ tham chiếu khỏi các máy chủ. Hồ sơ máy chủ được giữ nguyên; lần sau đăng nhập sẽ phải nhập lại mật khẩu."
            )
        }
    }

    // MARK: - Nhóm

    private var general: some View {
        SettingsGroup("Chung") {
            SettingsRow("Thư mục local mặc định", hint: "Khung Local và hộp thoại tải về dùng thư mục này.") {
                Text(shortPath(s.resolvedLocalDirectory())).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Theme.textSecondary).frame(maxWidth: 220, alignment: .trailing)
                Button("Chọn…") { chooseLocalDirectory() }
                Button("Mặc định") { model.updateSettings { $0.defaultLocalDirectory = "" } }
                    .disabled(s.defaultLocalDirectory.isEmpty)
            }
            SettingsRow("Khi đóng cửa sổ chính") {
                Picker("", selection: bind(\.closeBehavior)) {
                    Text("Thoát app").tag(AppSettings.CloseBehavior.quit)
                    Text("Giữ chạy nền").tag(AppSettings.CloseBehavior.keepRunning)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            }
        }
    }

    private var warp: some View {
        SettingsGroup("Warp") {
            SettingsRow("Mở máy chủ trong Warp bằng") {
                Picker("", selection: bind(\.warpOpenMode)) {
                    Text("Tab mới").tag(AppSettings.WarpOpenMode.tab)
                    Text("Cửa sổ mới").tag(AppSettings.WarpOpenMode.window)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            }
        }
    }

    private var transfer: some View {
        SettingsGroup("Truyền file") {
            SettingsRow("Số tác vụ chạy đồng thời", hint: "Tăng có hiệu lực ngay; giảm không ngắt tác vụ đang chạy.") {
                Picker("", selection: bind(\.transferConcurrency)) {
                    ForEach(Array(AppSettings.transferConcurrencyRange), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 80)
            }
            SettingsRow(
                "Giữ lịch sử truyền file", hint: "Áp dụng từ lần truyền kế tiếp; tác vụ đang chạy không bị xoá."
            ) {
                Picker("", selection: bind(\.transferHistoryLimit)) {
                    ForEach(AppSettings.transferHistoryChoices, id: \.self) {
                        Text($0 == 0 ? "Không giới hạn" : "\($0) mục").tag($0)
                    }
                }
                .labelsHidden().frame(width: 150)
            }
        }
    }

    private var sshConfig: some View {
        SettingsGroup("SSH config") {
            SettingsRow(
                "File config của bạn được Include",
                hint:
                    "Đường dẫn tuyệt đối tới file có sẵn. Lưu khi nhấn Return hoặc rời khỏi ô; đường dẫn sai thì giữ giá trị cũ. Đổi thì config của app được sinh lại; app không sửa file này."
            ) {
                TextField("~/.ssh/config", text: $configPathText)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                    .focused($configPathFocused)
                    .onSubmit { commitConfigPath() }
                    .onChange(of: configPathFocused) { _, focused in
                        if !focused { commitConfigPath() }
                    }
                Button("Chọn…") { chooseConfigFile() }
                Button("Mặc định") {
                    configPathText = ""
                    commitConfigPath()
                }
            }
            if let configPathError {
                Text(configPathError).font(.caption).foregroundStyle(Theme.red)
            }
            Text(
                model.effectiveUserConfigPath.map { "Đang Include: \($0)" }
                    ?? "Hiện không Include file nào (file chưa tồn tại)."
            )
            .font(.caption).foregroundStyle(Theme.textSecondary)
            SettingsRow("Config do app sinh (chỉ xem)") {
                Text(shortPath(model.paths.sshConfigURL.path)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Theme.textSecondary).frame(maxWidth: 260, alignment: .trailing)
                    .textSelection(.enabled)
                Button("Mở trong Finder") { model.revealSSHConfigFolder() }
            }
        }
    }

    private var security: some View {
        SettingsGroup("Bảo mật") {
            SettingsRow(
                "Tự điền mật khẩu đã lưu",
                hint:
                    "Tắt: Warp, truyền file, tunnel, Analyst, Monitor và Windows App đều không dùng mật khẩu đã lưu; ssh sẽ hỏi bạn. Áp dụng cho kết nối mở sau đó; tab Warp đã mở giữ cách cũ tới khi đóng."
            ) {
                Toggle("", isOn: bind(\.autofillEnabled)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Tự xoá clipboard mật khẩu Windows sau") {
                Picker("", selection: bind(\.clipboardClearSeconds)) {
                    ForEach(AppSettings.clipboardChoices, id: \.self) { Text("\($0) giây").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            SettingsRow("Mật khẩu đã lưu trong Keychain") {
                Button("Xoá mọi mật khẩu đã lưu…", role: .destructive) {
                    Task {
                        savedPasswordCount = await model.savedPasswordCount()
                        if savedPasswordCount == 0 {
                            model.showToast("Chưa có mật khẩu nào được lưu")
                        } else {
                            confirmClearPasswords = true
                        }
                    }
                }
            }
        }
    }

    private var analyst: some View {
        SettingsGroup("Project Analyst") {
            SettingsRow("Số lần chạy giữ mỗi thư mục") {
                Stepper(value: bind(\.analystRetention), in: AppSettings.analystRetentionRange, step: 10) {
                    Text("\(s.analystRetention)").monospacedDigit()
                }
                .frame(width: 130)
            }
            SettingsRow(
                "Timeout thử kết nối", hint: "Chèn vào lệnh probe (timeout/nc -w) dưới dạng số nguyên 1–10 giây."
            ) {
                Stepper(
                    value: Binding(
                        get: { s.analystProbeTimeout.seconds },
                        set: { v in model.updateSettings { $0.analystProbeTimeout = ProbeTimeout(v) } }),
                    in: ProbeTimeout.range
                ) {
                    Text("\(s.analystProbeTimeout.seconds) giây").monospacedDigit()
                }
                .frame(width: 130)
            }
        }
    }

    private var monitor: some View {
        SettingsGroup("Monitor") {
            SettingsRow("Chu kỳ làm mới mặc định") {
                Picker("", selection: bind(\.monitorIntervalSeconds)) {
                    ForEach(AppSettings.monitorIntervalChoices, id: \.self) { Text("\($0) giây").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            SettingsRow("Ngưỡng vàng (%)") {
                Stepper(
                    value: Binding(
                        get: { s.monitorThresholds.warning },
                        set: { v in
                            model.updateSettings {
                                $0.monitorThresholds = MonitorThresholds(
                                    warning: v, danger: $0.monitorThresholds.danger)
                            }
                        }),
                    in: MonitorThresholds.warningRange
                ) {
                    Text("\(s.monitorThresholds.warning)%").monospacedDigit()
                }
                .frame(width: 130)
            }
            SettingsRow("Ngưỡng đỏ (%)", hint: "Lớn hơn ngưỡng vàng, tối đa \(MonitorThresholds.maxDanger).") {
                Stepper(
                    value: Binding(
                        get: { s.monitorThresholds.danger },
                        set: { v in
                            model.updateSettings {
                                $0.monitorThresholds = MonitorThresholds(
                                    warning: $0.monitorThresholds.warning, danger: v)
                            }
                        }),
                    in: (s.monitorThresholds.warning + 1)...MonitorThresholds.maxDanger
                ) {
                    Text("\(s.monitorThresholds.danger)%").monospacedDigit()
                }
                .frame(width: 130)
            }
        }
    }

    private var windows: some View {
        SettingsGroup("Windows App") {
            Text("Mặc định cho máy Windows tạo mới (máy đã có không đổi).")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            SettingsRow("Toàn màn hình") {
                Toggle("", isOn: bind(\.rdpFullScreen)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Nhiều màn hình") {
                Toggle("", isOn: bind(\.rdpMultiMonitor)).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow("Chia sẻ clipboard") {
                Toggle("", isOn: bind(\.rdpRedirectClipboard)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var data: some View {
        SettingsGroup("Dữ liệu") {
            SettingsRow("Danh sách máy chủ", hint: "File JSON, không chứa mật khẩu.") {
                Button("Xuất…") { model.exportHosts(.all) }.disabled(model.hosts.isEmpty)
                Button("Nhập…") { model.beginImportFile() }
            }
            SettingsRow("Thư mục dữ liệu") {
                Button("Mở trong Finder") { model.revealDataFolder() }
            }
            SettingsRow("Phiên bản") {
                Text("SSH Desk \(Self.appVersion) · schema \(Database.currentSchemaVersion)")
                    .foregroundStyle(Theme.textSecondary)
            }
            SettingsRow("File SQLite") {
                Text(shortPath(model.paths.databaseURL.path)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Theme.textSecondary).frame(maxWidth: 360, alignment: .trailing)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Hỗ trợ

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { v in model.updateSettings { $0[keyPath: keyPath] = v } })
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func shortPath(_ p: String) -> String {
        BrowserPath.display(p, home: NSHomeDirectory())
    }

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: s.resolvedLocalDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.defaultLocalDirectory = url.path }
        }
    }

    private func chooseConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            configPathText = url.path
            commitConfigPath()
        }
    }

    /// Rỗng = mặc định. Ngược lại phải qua `validateUserConfigPath`; sai thì giữ giá trị cũ và báo lỗi.
    private func commitConfigPath() {
        let text = configPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            configPathError = nil
            model.updateSettings { $0.userSSHConfigPath = "" }
            return
        }
        do {
            try AppSettings.validateUserConfigPath(text)
            configPathError = nil
            model.updateSettings { $0.userSSHConfigPath = text }
        } catch let e as AppSettings.ConfigPathError {
            configPathError = Self.message(for: e)
        } catch {
            configPathError = error.localizedDescription
        }
    }

    private static func message(for e: AppSettings.ConfigPathError) -> String {
        switch e {
        case .notAbsolute: return "Phải là đường dẫn tuyệt đối (bắt đầu bằng /), không dùng ~."
        case .controlCharacter: return "Đường dẫn chứa ký tự điều khiển hoặc xuống dòng."
        case .unsupportedCharacter: return "Đường dẫn chứa ký tự % (ssh diễn giải ký tự này)."
        case .notFound: return "Không tìm thấy file này."
        case .notAFile: return "Đây là thư mục, hãy chọn một file config."
        }
    }
}

/// Khối một nhóm cài đặt.
private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// Một dòng: nhãn (+ chú thích) bên trái, điều khiển bên phải.
private struct SettingsRow<Controls: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let controls: () -> Controls

    init(_ label: String, hint: String? = nil, @ViewBuilder controls: @escaping () -> Controls) {
        self.label = label
        self.hint = hint
        self.controls = controls
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary)
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8, content: controls)
        }
    }
}
