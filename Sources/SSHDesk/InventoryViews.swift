import SSHDeskCore
import SwiftUI

// MARK: - Banner "Nguồn có thay đổi"

struct InventoryChangeBanner: View {
    @Bindable var inventory: InventoryModel

    var body: some View {
        let list = inventory.bannerSources
        if !list.isEmpty || !inventory.autoAdded.isEmpty {
            VStack(spacing: 6) {
                ForEach(inventory.autoAdded) { notice in
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle").foregroundStyle(Theme.amber)
                        Text("Đã thêm \(notice.count) máy từ “\(notice.record.sourceName)”.")
                        Spacer(minLength: 0)
                        Button("Xem") { inventory.showAutoAdded(notice) }
                        Button("Hoàn tác") { Task { await inventory.undoAutoAdded(notice) } }
                        Button("Đóng") { inventory.dismissAutoAdded(notice) }
                    }
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.amber.opacity(0.14))
                }
                ForEach(list) { s in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.amber)
                        if inventory.changes[s.id] == .fileMissing {
                            Text("Không thấy file của nguồn “\(s.name)”. Có thể đã đổi tên hoặc chuyển chỗ.")
                        } else {
                            Text("Nguồn có thay đổi: “\(s.name)”. Chưa áp dụng gì cả — xem trước rồi mới đồng bộ.")
                        }
                        Spacer(minLength: 0)
                        if inventory.changes[s.id] == .fileMissing {
                            Button("Chọn file mới…") {
                                inventory.openHub()
                                inventory.chooseNewFile(for: s)
                            }
                        } else {
                            Button("Xem trước") {
                                inventory.showHub = true
                                Task { await inventory.resync(s) }
                            }
                        }
                        Button("Bỏ qua") { inventory.dismissedBanner.insert(s.id) }
                    }
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Theme.amber.opacity(0.14))
                }
            }
        }
    }
}

// MARK: - Huy hiệu trên host

struct SourceBadge: View {
    let host: HostProfile
    let sourceName: String?

    var body: some View {
        if host.sourceID != nil {
            if host.sourceMissing {
                Text("Không còn trong nguồn")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(Theme.amber)
                    .background(Theme.amber.opacity(0.15), in: Capsule())
                    .help("Máy vẫn được giữ lại; nguồn “\(sourceName ?? "?")” không còn dòng này.")
            } else {
                Image(systemName: "link").font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Đồng bộ từ nguồn “\(sourceName ?? "?")”")
                    .accessibilityLabel("Từ nguồn \(sourceName ?? "")")
            }
        }
    }
}

/// Thẻ trong chi tiết host: nguồn + "Tách khỏi nguồn".
struct HostSourceCard: View {
    @Bindable var model: AppModel
    let host: HostProfile
    @Local private var confirmDetach = false

    var body: some View {
        if host.sourceID != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nguồn").font(.system(size: 14, weight: .semibold))
                HStack {
                    Label(
                        "Đồng bộ từ “\(model.inventory.sourceName(for: host) ?? "nguồn đã xoá")”",
                        systemImage: "link"
                    )
                    .font(.system(size: 13))
                    Spacer(minLength: 0)
                    Button("Tách khỏi nguồn") { confirmDetach = true }.controlSize(.small)
                }
                if host.sourceMissing {
                    Label(
                        "Không còn trong nguồn — máy vẫn được giữ, không tự xoá.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                }
                Text("Tên, IP, port, user, môi trường, thư mục, jump host do nguồn quản lý và chỉ đọc.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .confirmationDialog(
                "Tách “\(host.displayName)” khỏi nguồn?", isPresented: $confirmDetach, titleVisibility: .visible
            ) {
                Button("Tách khỏi nguồn") { Task { await model.inventory.detach(host) } }
            } message: {
                Text("Máy giữ nguyên mọi giá trị, trở thành máy tạo tay; các lần đồng bộ sau không đụng tới nó nữa.")
            }
        }
    }
}

// MARK: - Hub

struct InventoryHubSheet: View {
    @Bindable var model: AppModel
    @Bindable var inventory: InventoryModel

    var body: some View {
        VStack(spacing: 0) {
            switch inventory.route {
            case .list: InventorySourceList(model: model, inventory: inventory)
            case .structured(let t): StructuredSetupView(inventory: inventory, setup: t)
            case .wizard(let w): InventoryWizardView(model: model, inventory: inventory, wizard: w)
            case .preview(let p): InventoryPreviewView(model: model, inventory: inventory, preview: p)
            }
        }
        .frame(width: 780, height: 640)
        .overlay { if inventory.busy { ProgressView().controlSize(.large) } }
        .alert(
            "Lưu ý về mật khẩu",
            isPresented: Binding(get: { inventory.notice != nil }, set: { if !$0 { inventory.notice = nil } })
        ) {
            Button("Đã hiểu") { inventory.notice = nil }
        } message: {
            Text(inventory.notice ?? "")
        }
    }
}

// MARK: - Danh sách nguồn

struct InventorySourceList: View {
    @Bindable var model: AppModel
    @Bindable var inventory: InventoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nguồn máy chủ").font(.title2.bold())
                Spacer()
                Button("Tải file mẫu…") { inventory.saveTemplate() }
                    .help("Tải file Excel mẫu (có dropdown Môi trường / Loại, sheet Hướng dẫn)")
                Menu("Thêm nguồn") {
                    Button("Excel / CSV…") { inventory.addSource() }
                    Button("JSON (.sshdesk.json)…") { inventory.addStructuredSource(kind: .json) }
                    Button("Ansible inventory (INI/YAML)…") { inventory.addStructuredSource(kind: .ansible) }
                }
                .menuStyle(.borderedButton).fixedSize()
            }
            Text(
                "Đồng bộ một chiều từ file Excel/CSV, JSON hoặc Ansible inventory tĩnh: thêm, đổi, đánh dấu “Không còn trong nguồn” (không bao giờ tự xoá máy). "
                    + "Luôn xem trước rồi mới áp dụng. Cột/biến mật khẩu trong file bị bỏ qua."
            )
            .font(.callout).foregroundStyle(.secondary)
            if inventory.sources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tablecells").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Chưa có nguồn nào").font(.headline)
                    Text("Bấm “Tải file mẫu…” để lấy file Excel chuẩn, điền rồi “Thêm nguồn”.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(inventory.sources) { s in sourceRow(s) }
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Đóng") { inventory.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .confirmationDialog(
            "Xoá nguồn “\(inventory.confirmDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { inventory.confirmDelete != nil }, set: { if !$0 { inventory.confirmDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá nguồn", role: .destructive) {
                if let s = inventory.confirmDelete { Task { await inventory.delete(s) } }
                inventory.confirmDelete = nil
            }
        } message: {
            Text("Các máy chủ KHÔNG bị xoá; chúng chỉ bị gỡ khỏi nguồn (thành máy tạo tay).")
        }
    }

    private func sourceRow(_ s: InventorySource) -> some View {
        let usage = inventory.usage[s.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(
                    systemName: s.kind == .excel ? "tablecells" : (s.kind.isTabular ? "doc.plaintext" : "shippingbox"))
                Text(s.name).font(.headline)
                Text(s.kind.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch inventory.changes[s.id] {
                case .changed?:
                    Label("Có thay đổi", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Theme.amber)
                case .fileMissing?:
                    Label("Không thấy file", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                case .unreadable?:
                    Label("Không đọc được", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.red)
                default: EmptyView()
                }
            }
            .font(.system(size: 12.5))
            Text(s.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Toggle(
                "Tự thêm máy mới (khi file chỉ có máy mới; không lưu mật khẩu)",
                isOn: Binding(
                    get: { s.autoAddNew },
                    set: { on in Task { await inventory.setAutoAdd(s, enabled: on) } })
            )
            .toggleStyle(.checkbox).controlSize(.small).font(.caption)
            HStack {
                Text(
                    "\(usage?.hosts ?? 0) máy"
                        + ((usage?.missing ?? 0) > 0 ? " · \(usage?.missing ?? 0) không còn trong nguồn" : "")
                        + " · Đồng bộ lần cuối: "
                        + (s.lastSyncedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "chưa")
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Đồng bộ lại") { Task { await inventory.resync(s) } }
                Button("Chọn file mới…") { inventory.chooseNewFile(for: s) }
                Button(s.kind.isTabular ? "Sửa ghép cột" : "Sửa nguồn") { inventory.editMapping(s) }
                Button("Xoá nguồn", role: .destructive) { inventory.confirmDelete = s }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Nguồn JSON / Ansible (không ghép cột)

struct StructuredSetupView: View {
    @Bindable var inventory: InventoryModel
    @Bindable var setup: StructuredSetup

    var body: some View {
        let result = setup.loaded.result
        VStack(alignment: .leading, spacing: 12) {
            Text(setup.editing == nil ? "Thêm nguồn \(setup.kind.title)" : "Sửa nguồn \(setup.kind.title)")
                .font(.title2.bold())
            Text(setup.url.lastPathComponent).font(.callout.monospaced()).foregroundStyle(.secondary)
            Text("Đọc được \(result.records.count) máy, \(result.errorCount) lỗi.").font(.callout)
            ForEach(result.warnings, id: \.self) {
                Label($0, systemImage: "lock.shield").font(.callout).foregroundStyle(Theme.amber)
            }
            if setup.kind == .ansible {
                Text(
                    "Tên group được dùng làm tag. Chỉ đọc ansible_host/port/user; không chạy Ansible, không đọc host_vars/group_vars."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Form {
                Toggle("Lưu làm nguồn để đồng bộ lại", isOn: $setup.saveAsSource)
                if setup.saveAsSource { TextField("Tên nguồn", text: $setup.sourceName) }
                TextField("Thư mục mặc định (máy không có thư mục)", text: $setup.folder)
                Picker("Môi trường mặc định", selection: $setup.environment) {
                    Text("OTHER").tag(HostEnvironment?.none)
                    ForEach(HostEnvironment.allCases, id: \.self) { Text($0.rawValue).tag(HostEnvironment?.some($0)) }
                }
            }
            .formStyle(.grouped)
            Spacer(minLength: 0)
            HStack {
                Button("Huỷ") { inventory.route = .list }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Xem trước") { inventory.showPreview(from: setup) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

// MARK: - Ghép cột

struct InventoryWizardView: View {
    @Bindable var model: AppModel
    @Bindable var inventory: InventoryModel
    @Bindable var wizard: InventoryWizard

    @ViewBuilder
    private var secretToggles: some View {
        if !wizard.isTemplate {
            VStack(alignment: .leading, spacing: 4) {
                if wizard.passwordHeaders.count > 1 {
                    Picker("Cột mật khẩu", selection: $wizard.secretHeader) {
                        ForEach(wizard.passwordHeaders, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(wizard.keepPassword || wizard.reloading)
                }
                Toggle(
                    "Lưu mật khẩu từ cột \(wizard.secretHeader) vào kho",
                    isOn: Binding(
                        get: { wizard.keepPassword },
                        set: { on in Task { await inventory.setKeepPassword(wizard, on) } })
                )
                .disabled(wizard.reloading || wizard.secretHeader.isEmpty)
                if wizard.keepPassword {
                    Toggle("Ghi đè mật khẩu đã lưu", isOn: $wizard.overwritePassword).padding(.leading, 16)
                    Text(
                        "Chỉ áp dụng lần này, không lưu lại. Mật khẩu chỉ ghi vào kho mã hoá, không vào file hay CSDL."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(wizard.editing == nil ? "Thêm nguồn" : "Sửa ghép cột").font(.title2.bold())
            Text(wizard.url.lastPathComponent).font(.callout.monospaced()).foregroundStyle(.secondary)
            if let note = wizard.note {
                Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                    .font(.callout)
            }
            if !wizard.passwordHeaders.isEmpty {
                Label(
                    "Phát hiện cột mật khẩu — sẽ bỏ qua (\(wizard.passwordHeaders.joined(separator: ", "))). Mặc định giá trị không được đọc vào app.",
                    systemImage: "lock.shield"
                )
                .font(.callout).foregroundStyle(Theme.amber)
                secretToggles
            }
            Form {
                if wizard.loaded.workbook.sheets.count > 1 {
                    Picker(
                        "Sheet",
                        selection: Binding(get: { wizard.sheetName }, set: { inventory.changeSheet(wizard, to: $0) })
                    ) {
                        ForEach(wizard.loaded.workbook.sheets, id: \.name) { Text($0.name).tag($0.name) }
                    }
                }
                Stepper(
                    "Dòng tiêu đề: \(wizard.headerRow)",
                    value: Binding(
                        get: { wizard.headerRow },
                        set: { v in Task { await inventory.changeHeaderRow(wizard, to: v) } }),
                    in: 1...30
                )
                .disabled(wizard.reloading)
                Section("Ghép cột") {
                    ForEach(InventoryField.freeMappingFields, id: \.self) { field in
                        Picker(
                            field.title,
                            selection: Binding(
                                get: { wizard.header(for: field) }, set: { wizard.setHeader($0, for: field) })
                        ) {
                            Text("— bỏ qua —").tag("")
                            ForEach(wizard.headerChoices, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Picker("Cột khoá", selection: $wizard.mapping.keyField) {
                        Text("Tên").tag(InventoryField.name).disabled(wizard.mapping.header(for: .name) == nil)
                        Text("IP/Hostname").tag(InventoryField.hostName)
                    }
                    .help("Dùng để nhận ra cùng một máy khi đồng bộ lại. Mặc định là Tên (đổi IP vẫn là cùng máy).")
                }
                Section("Nguồn") {
                    Toggle("Lưu làm nguồn để đồng bộ lại", isOn: $wizard.saveAsSource)
                    if wizard.saveAsSource {
                        TextField("Tên nguồn", text: $wizard.sourceName)
                    }
                    TextField("Thư mục mặc định (nếu file không có cột thư mục)", text: $wizard.folder)
                    Picker("Môi trường mặc định", selection: $wizard.environment) {
                        Text("OTHER").tag(HostEnvironment?.none)
                        ForEach(HostEnvironment.allCases, id: \.self) {
                            Text($0.rawValue).tag(HostEnvironment?.some($0))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            samplePreview
            HStack {
                Button("Huỷ") { inventory.cancelToList() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Xem trước") { inventory.showPreview(from: wizard) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(wizard.mapping.header(for: .hostName) == nil || wizard.reloading)
            }
        }
        .padding(18)
    }

    /// 3 dòng đầu theo cách ghép — chỉ các cột đã ghép, không bao giờ cột mật khẩu.
    @ViewBuilder
    private var samplePreview: some View {
        if let sheet = wizard.sheet {
            let resolved = wizard.mapping.resolve(in: sheet)
            let fields = InventoryField.freeMappingFields.filter { resolved.columns[$0] != nil }
            if !fields.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dòng đầu tiên").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(sheet.dataRows.prefix(3)), id: \.number) { row in
                        Text(
                            "Dòng \(row.number): "
                                + fields.map { row.cell(resolved.columns[$0] ?? -1) }.joined(separator: "  ·  ")
                        )
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }
}

// MARK: - Xem trước

struct InventoryPreviewView: View {
    @Bindable var model: AppModel
    @Bindable var inventory: InventoryModel
    let preview: InventoryPreview
    @Local private var confirmSecrets = false

    private let cap = 150

    var body: some View {
        let plan = preview.plan
        VStack(alignment: .leading, spacing: 10) {
            Text("Xem trước đồng bộ").font(.title2.bold())
            Text(summary(plan)).font(.callout).foregroundStyle(.secondary)
            if plan.source == nil {
                Label("Nhập một lần: không lưu nguồn, lần sau sẽ không đồng bộ lại.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !plan.additions.isEmpty {
                        header("Thêm \(plan.additions.count) máy")
                        ForEach(Array(plan.additions.prefix(cap))) { a in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("＋ \(a.host.displayName)  \(HostPresentation.addressText(a.host))")
                                if let s = a.credentialSetName {
                                    Text("   Bộ đăng nhập “\(s)” — tạm tắt tự điền mật khẩu tới khi bạn xác nhận")
                                        .font(.caption).foregroundStyle(Theme.amber)
                                }
                            }
                        }
                        more(plan.additions.count)
                    }
                    if !plan.setsToCreate.isEmpty {
                        header("Sẽ tạo bộ đăng nhập rỗng (nhập mật khẩu sau)")
                        ForEach(plan.setsToCreate, id: \.self) { Text("• \($0) — sẽ tạo bộ rỗng") }
                    }
                    if !plan.updates.isEmpty {
                        header("Đổi \(plan.updates.count) máy")
                        ForEach(Array(plan.updates.prefix(cap))) { u in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("✎ \(u.displayName)\(u.restored ? "  (có lại trong nguồn)" : "")")
                                ForEach(u.changes, id: \.label) { c in
                                    Text("   \(c.text)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                if let r = u.holdReason {
                                    Text("   Sẽ tạm tắt tự điền mật khẩu: \(r)").font(.caption).foregroundStyle(
                                        Theme.amber)
                                }
                            }
                        }
                        more(plan.updates.count)
                    }
                    if !plan.missing.isEmpty {
                        header("Không còn trong nguồn \(plan.missing.count) máy (giữ lại, không xoá)")
                        ForEach(Array(plan.missing.prefix(cap))) { Text("− \($0.displayName)") }
                        more(plan.missing.count)
                    }
                    let errors = plan.issues.filter { $0.severity == .error }
                    let warnings = plan.issues.filter { $0.severity == .warning }
                    if !errors.isEmpty {
                        header("Lỗi \(errors.count) dòng (bỏ qua, các dòng khác vẫn nhập)")
                        ForEach(Array(errors.prefix(cap))) { Text($0.text).foregroundStyle(Theme.red).font(.callout) }
                        more(errors.count)
                    }
                    if !warnings.isEmpty || !plan.warnings.isEmpty {
                        header("Cảnh báo")
                        ForEach(plan.warnings, id: \.self) { Text($0).foregroundStyle(Theme.amber).font(.callout) }
                        ForEach(Array(warnings.prefix(cap))) {
                            Text($0.text).foregroundStyle(Theme.amber).font(.callout)
                        }
                    }
                    if !plan.hasChanges && plan.errorCount == 0 {
                        Text("Không có gì thay đổi.").foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
            if let sp = preview.secretPlan {
                VStack(alignment: .leading, spacing: 2) {
                    Label(
                        "Mật khẩu sẽ lưu cho \(sp.newCount) máy mới"
                            + (sp.replaceCount > 0 ? ", ghi đè \(sp.replaceCount) máy" : "")
                            + (sp.skippedExisting > 0 ? "; bỏ qua \(sp.skippedExisting) máy đã có mật khẩu riêng" : "")
                            + ".  Mỗi dòng: ••••",
                        systemImage: "lock.fill"
                    )
                    .font(.callout).foregroundStyle(Theme.amber)
                    ForEach(sp.invalidMessages.prefix(10), id: \.self) {
                        Text($0).font(.caption).foregroundStyle(Theme.red)
                    }
                }
            } else {
                Text("Không đụng tới ~/.ssh/config. Mật khẩu không nằm trong file nguồn và không được nhập.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Huỷ") { inventory.cancelToList() }.keyboardShortcut(.cancelAction)
                if let w = preview.wizard, !w.isTemplate {
                    Button("Quay lại ghép cột") { inventory.route = .wizard(w) }
                }
                Spacer()
                Button("Áp dụng") {
                    if let sp = preview.secretPlan, !sp.isEmpty {
                        confirmSecrets = true
                    } else {
                        Task { _ = await inventory.apply(preview) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((!plan.hasChanges && plan.source == nil) || inventory.busy)
            }
        }
        .padding(18)
        .confirmationDialog(
            "Lưu mật khẩu cho \(preview.secretPlan?.count ?? 0) máy vào kho mã hoá?", isPresented: $confirmSecrets,
            titleVisibility: .visible
        ) {
            Button("Lưu mật khẩu và áp dụng") { Task { _ = await inventory.apply(preview) } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Mật khẩu được đọc từ file Excel/CSV và chỉ ghi vào kho mã hoá của app.")
        }
    }

    private func summary(_ p: InventorySyncPlan) -> String {
        "\(preview.title): thêm \(p.additions.count) · đổi \(p.updates.count) · không còn trong nguồn \(p.missing.count) · "
            + "không đổi \(p.unchangedCount) · lỗi \(p.errorCount) · cảnh báo \(p.warningCount)"
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).padding(.top, 8)
    }

    @ViewBuilder
    private func more(_ total: Int) -> some View {
        if total > cap { Text("… và \(total - cap) mục khác").foregroundStyle(.secondary) }
    }
}
