import SSHDeskCore
import SwiftUI

/// Cài đặt → "Nguồn số liệu" (ADR-028): thêm/sửa/xoá nguồn Prometheus/Zabbix. Token/password chỉ vào Keychain
/// (qua `CredentialStore`); form chỉ giữ chúng trong ô SecureField.
struct MetricSourcesSection: View {
    @Bindable var model: AppModel
    @Local private var sources: [MetricsSource] = []
    @Local private var editing: EditTarget?
    @Local private var deleting: MetricsSource?
    @Local private var errorText: String?

    enum EditTarget: Identifiable {
        case new
        case edit(MetricsSource)
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
                    Text("Nguồn số liệu").font(.system(size: 13.5))
                    Text(
                        "Monitor đọc Prometheus (node_exporter) hoặc Zabbix thay vì mở SSH. Chọn nguồn cho từng thư mục ngay trên màn Monitor. Chỉ gọi API đọc; token/password nằm trong Keychain."
                    )
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Thêm nguồn…") { editing = .new }
            }
            if sources.isEmpty {
                Text("Chưa có nguồn nào.").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            ForEach(sources) { source in row(source) }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(Theme.red) }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { target in
            MetricSourceEditor(model: model, target: target)
        }
        .confirmationDialog(
            "Xoá nguồn “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá nguồn", role: .destructive) {
                if let d = deleting { delete(d) }
                deleting = nil
            }
            Button("Huỷ", role: .cancel) { deleting = nil }
        } message: {
            Text("Token/password của nguồn bị xoá khỏi Keychain. Thư mục đang dùng nguồn này quay về đo qua SSH.")
        }
    }

    private func row(_ source: MetricsSource) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .semibold))
                Text("\(source.kind.title) · \(source.baseURL) · \(source.authKind.title)")
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                if source.sendsSecretOverInsecureHTTP {
                    Text("http không mã hoá — token/password gửi dạng rõ").font(.caption)
                        .foregroundStyle(Theme.red)
                } else if source.usesHTTP {
                    Text("http (không mã hoá)").font(.caption).foregroundStyle(Theme.amber)
                }
            }
            Spacer()
            Button("Sửa…") { editing = .edit(source) }
            Button("Xoá…", role: .destructive) { deleting = source }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        sources = (try? model.metricSources?.repository.all()) ?? []
    }

    private func delete(_ source: MetricsSource) {
        do {
            try model.metricSources?.delete(id: source.id)
            errorText = nil
        } catch {
            errorText = "Không xoá được nguồn: \(error.localizedDescription)"
        }
        reload()
        model.monitor.reloadSources()
    }
}

/// Tạo / sửa nguồn. Để trống ô token/password khi sửa = giữ nguyên.
struct MetricSourceEditor: View {
    @Bindable var model: AppModel
    let target: MetricSourcesSection.EditTarget
    @Environment(\.dismiss) private var dismiss

    @Local private var loaded = false
    @Local private var original: MetricsSource?
    @Local private var name = ""
    @Local private var kind = MetricsSourceKind.prometheus
    @Local private var url = "https://"
    @Local private var auth = MetricsAuthKind.none
    @Local private var basicUser = ""
    @Local private var secret = ""
    @Local private var template = MetricsSourceKind.prometheus.defaultInstanceTemplate
    @Local private var allowHTTP = false
    @Local private var testing = false
    @Local private var testResult: String?
    @Local private var testFailed = false
    @Local private var saveError: String?

    private var isNew: Bool { original == nil }

    private var draft: MetricsSource {
        MetricsSource(
            id: original?.id ?? UUID(), name: name, kind: kind, baseURL: url, authKind: auth,
            basicUser: basicUser, instanceTemplate: template, allowInsecureHTTP: allowHTTP,
            createdAt: original?.createdAt ?? Date())
    }

    private var validationError: String? {
        do { _ = try draft.validated() } catch { return error.localizedDescription }
        if auth != .none, secret.isEmpty, isNew { return MetricsSourceError.secretRequired.localizedDescription }
        return nil
    }

    private var availableAuth: [MetricsAuthKind] {
        kind == .zabbix ? [.none, .bearer] : MetricsAuthKind.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "Nguồn số liệu mới" : "Sửa nguồn số liệu") {
                    TextField("Tên", text: $name)
                    Picker("Loại", selection: $kind) {
                        ForEach(MetricsSourceKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .onChange(of: kind) { old, new in
                        if template == old.defaultInstanceTemplate { template = new.defaultInstanceTemplate }
                        if new == .zabbix, auth == .basic { auth = .bearer }
                    }
                    TextField("URL gốc", text: $url, prompt: Text("https://prometheus.example.com"))
                    if kind == .zabbix {
                        Text("Ví dụ https://zabbix.example.com (app gọi /api_jsonrpc.php).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if url.lowercased().hasPrefix("http://") {
                        Text(
                            "http không mã hoá: dữ liệu và token/password đi qua mạng dạng rõ."
                        )
                        .font(.caption).foregroundStyle(Theme.red)
                    }
                }
                Section("Xác thực") {
                    Picker("Kiểu", selection: $auth) {
                        ForEach(availableAuth, id: \.self) { Text($0.title).tag($0) }
                    }
                    if auth == .basic {
                        TextField("Tên đăng nhập", text: $basicUser)
                    }
                    if auth != .none {
                        SecureField(
                            auth == .bearer ? "Token" : "Password", text: $secret,
                            prompt: Text(isNew ? "Bắt buộc" : "Để trống = giữ giá trị đã lưu"))
                    }
                    if draft.sendsSecretOverInsecureHTTP {
                        Toggle("Tôi hiểu token/password gửi không mã hoá", isOn: $allowHTTP)
                    }
                    if kind == .zabbix {
                        Text(
                            "Zabbix: dùng token API (Zabbix ≥ 7.0 gửi qua header Bearer, bản cũ qua trường auth). Không đăng nhập bằng user/password."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Ghép máy chủ") {
                    TextField("Mẫu instance", text: $template)
                    Text(
                        kind == .prometheus
                            ? "Nhãn instance trong Prometheus. Chỉ dùng {{hostName}} và {{port}}; mặc định {{hostName}}:9100."
                            : "Tên host trong Zabbix. Chỉ dùng {{hostName}} và {{port}}; mặc định {{hostName}}."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Section("Thử kết nối") {
                    HStack {
                        Button("Thử kết nối") { Task { await test() } }
                            .disabled(testing || validationError != nil)
                        if testing { ProgressView().controlSize(.small) }
                    }
                    if let testResult {
                        Text(testResult).font(.caption)
                            .foregroundStyle(testFailed ? Theme.red : Theme.green)
                    }
                }
                if let e = saveError ?? validationError, !name.isEmpty || url != "https://" {
                    Text(e).foregroundStyle(Theme.red).font(.caption)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil)
            }
            .padding(12)
        }
        .frame(width: 540, height: 640)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard case .edit(let s) = target else { return }
        original = s
        name = s.name
        kind = s.kind
        url = s.baseURL
        auth = s.authKind
        basicUser = s.basicUser ?? ""
        template = s.instanceTemplate
        allowHTTP = s.allowInsecureHTTP
    }

    private func save() {
        guard let service = model.metricSources else { return }
        do {
            if isNew {
                try service.create(draft, secret: secret.isEmpty ? nil : secret)
            } else {
                try service.update(draft, secret: secret.isEmpty ? nil : secret)
            }
            secret = ""
            model.monitor.reloadSources()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Thử bằng bản nháp. Token vừa gõ chỉ nằm trong kho bộ nhớ tạm của lần thử, không vào Keychain.
    private func test() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let source = try draft.validated()
            let store = InMemoryCredentialStore()
            if let ref = source.credentialRef {
                if !secret.isEmpty {
                    try store.save(ref: ref, password: secret)
                } else if let orig = original, orig.sharesSecretScope(with: source),
                    let saved = model.credentials.read(ref: ref)
                {
                    try store.save(ref: ref, password: saved)
                }
            }
            let provider = MetricsClientFactory.make(source: source, credentials: store)
            testResult = try await provider.testConnection()
            testFailed = false
        } catch {
            testFailed = true
            testResult = (error as? LocalizedError)?.errorDescription ?? "Không kết nối được."
        }
    }
}
