import AppKit
import Foundation
import Observation
import SSHDeskCore
import UniformTypeIdentifiers

/// Bước ghép cột của một nguồn bảng đang thêm / sửa (ADR-026). Không giữ giá trị cột mật khẩu: Core đã bỏ.
@MainActor @Observable
final class InventoryWizard: Identifiable {
    let id = UUID()
    var url: URL
    var loaded: InventoryFile.Loaded
    /// Nguồn đang sửa; nil = thêm mới.
    let editing: InventorySource?
    var sheetName: String
    var headerRow: Int
    var mapping: TableMapping
    var sourceName: String
    var folder: String
    var environment: HostEnvironment?
    var saveAsSource = true
    var reloading = false
    var note: String?
    /// ADR-031: bật từng lần, không lưu vào config_json.
    var keepPassword = false
    var overwritePassword = false
    /// Cột mật khẩu được chọn (một cột).
    var secretHeader = ""

    init(url: URL, loaded: InventoryFile.Loaded, editing: InventorySource?, suggestedNote: String? = nil) {
        self.url = url
        self.loaded = loaded
        self.editing = editing
        self.note = suggestedNote
        let saved = editing?.tableMapping
        let initial = saved.flatMap { InventoryFile.sheet(in: loaded.workbook, for: $0) } ?? loaded.workbook.sheets[0]
        var map =
            saved.flatMap { $0.resolve(in: initial).needsRemap ? nil : $0 }
            ?? TableMapping.guess(sheet: initial, restrictTo: InventoryField.freeMappingFields)
        map.sheet = loaded.kind == .csv ? nil : initial.name
        self.sheetName = initial.name
        self.headerRow = initial.headerRow
        self.mapping = map
        self.sourceName = editing?.name ?? url.deletingPathExtension().lastPathComponent
        self.folder = editing?.folder ?? ""
        self.environment = editing?.defaultEnvironment
        self.secretHeader = initial.passwordColumns.sorted { $0.key < $1.key }.first?.value ?? ""
    }

    /// Xoá bộ nhớ giá trị cột mật khẩu và tắt lựa chọn.
    func discardSecrets() {
        loaded.secrets?.wipe()
        loaded.secrets = nil
        keepPassword = false
        overwritePassword = false
    }

    var sheet: TableSheet? { loaded.workbook.sheets.first { $0.name == sheetName } }

    var isTemplate: Bool { loaded.template != nil }

    /// Tiêu đề chọn được: bỏ ô trống, bỏ cột giống mật khẩu (không bao giờ ghép được), bỏ trùng.
    var headerChoices: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for text in sheet?.header?.cells ?? [] {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !PasswordHeader.matches(t), seen.insert(HeaderText.normalize(t)).inserted else {
                continue
            }
            out.append(t)
        }
        return out
    }

    var passwordHeaders: [String] {
        (sheet?.passwordColumns ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    func header(for field: InventoryField) -> String { mapping.header(for: field) ?? "" }

    func setHeader(_ text: String, for field: InventoryField) {
        // Core chặn cột giống mật khẩu; ở đây chỉ gọi, lỗi (không thể xảy ra vì danh sách đã lọc) thì bỏ qua.
        try? mapping.set(field, header: text.isEmpty ? nil : text)
        if mapping.keyField == .name && mapping.header(for: .name) == nil { mapping.keyField = .hostName }
    }
}

/// Màn xem trước kế hoạch đồng bộ (luôn qua đây trước khi ghi).
@MainActor @Observable
final class InventoryPreview: Identifiable {
    let id = UUID()
    var plan: InventorySyncPlan
    /// Quay lại bước ghép cột (nếu đi từ wizard).
    let wizard: InventoryWizard?
    let title: String
    /// Kế hoạch lưu mật khẩu cột bí mật (ADR-031); nil = không lưu. Không chứa giá trị.
    var secretPlan: InventorySecretImport.Plan?

    init(
        plan: InventorySyncPlan, wizard: InventoryWizard?, title: String,
        secretPlan: InventorySecretImport.Plan? = nil
    ) {
        self.plan = plan
        self.wizard = wizard
        self.title = title
        self.secretPlan = secretPlan
    }
}

/// Bước đặt tên / thư mục / môi trường mặc định của nguồn JSON hoặc Ansible (không có ghép cột).
@MainActor @Observable
final class StructuredSetup: Identifiable {
    let id = UUID()
    let url: URL
    let kind: InventorySourceKind
    var loaded: InventoryStructured.Loaded
    let editing: InventorySource?
    var sourceName: String
    var folder: String
    var environment: HostEnvironment?
    var saveAsSource = true

    init(url: URL, kind: InventorySourceKind, loaded: InventoryStructured.Loaded, editing: InventorySource?) {
        self.url = url
        self.kind = kind
        self.loaded = loaded
        self.editing = editing
        self.sourceName = editing?.name ?? url.deletingPathExtension().lastPathComponent
        self.folder = editing?.folder ?? ""
        self.environment = editing?.defaultEnvironment
    }
}

/// Thông báo "Đã thêm N máy từ <nguồn>" (ADR-026b). Chỉ sống trong phiên chạy app.
struct AutoAddNotice: Identifiable {
    let id = UUID()
    let record: InventoryAutoAddRecord
    var count: Int { record.hostIDs.count }
}

enum InventoryRoute {
    case list
    case structured(StructuredSetup)
    case wizard(InventoryWizard)
    case preview(InventoryPreview)
}

@MainActor @Observable
final class InventoryModel {
    weak var app: AppModel?
    private(set) var sources: [InventorySource] = []
    private(set) var usage: [UUID: (hosts: Int, missing: Int)] = [:]
    /// Nguồn có file đổi / mất (chỉ giữ trạng thái khác `.unchanged`).
    private(set) var changes: [UUID: InventoryFile.Change] = [:]
    var dismissedBanner: Set<UUID> = []
    var showHub = false
    var route: InventoryRoute = .list
    var busy = false
    /// Thông báo cần bấm "Đã hiểu" (vd. nhắc xoá file gốc chứa mật khẩu dạng rõ).
    var notice: String?
    var confirmDelete: InventorySource?
    /// Các lần tự thêm máy chưa đóng (ADR-026b).
    var autoAdded: [AutoAddNotice] = []
    private var checking = false

    init(app: AppModel) { self.app = app }

    // MARK: - Dữ liệu

    func refreshData() async {
        guard let repo = app?.hostRepository else { return }
        do {
            sources = try await repo.inventorySources()
            usage = try await repo.inventorySourceUsage()
            changes = changes.filter { id, _ in sources.contains { $0.id == id } }
        } catch { app?.show(error, title: "Không đọc được danh sách nguồn") }
    }

    func source(id: UUID?) -> InventorySource? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    func sourceName(for host: HostProfile) -> String? { source(id: host.sourceID)?.name }

    /// Nguồn có ghép cột ghi chú -> ghi chú của host cũng do nguồn quản lý.
    func managesNotes(_ host: HostProfile) -> Bool {
        source(id: host.sourceID)?.tableMapping?.header(for: .notes) != nil
    }

    var bannerSources: [InventorySource] {
        sources.filter { s in
            if dismissedBanner.contains(s.id) { return false }
            switch changes[s.id] {
            case .changed?, .fileMissing?: return true
            default: return false
            }
        }
    }

    /// Mở app / app được kích hoạt: so mtime rồi SHA-256 với vân tay đã lưu.
    /// Nguồn bật "Tự thêm máy mới" mà kế hoạch chỉ có máy mới (ADR-026b) thì tự áp dụng; còn lại chỉ báo, không ghi gì.
    func checkChanges() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await refreshData()
        let snapshot = sources
        var result: [UUID: InventoryFile.Change] = [:]
        for s in snapshot {
            let change = await Task.detached {
                InventoryFile.detectChange(path: s.path, kind: s.kind, lastFingerprint: s.lastFingerprint)
            }.value
            if change != .unchanged { result[s.id] = change }
        }
        for (id, change) in result where changes[id] != change { dismissedBanner.remove(id) }
        changes = result
        // Không tự áp dụng khi người dùng đang ở giữa wizard / xem trước (kế hoạch của họ sẽ cũ đi).
        guard canAutoApply else { return }
        for s in snapshot where result[s.id] == .changed && s.autoAddNew {
            await autoApplyIfAdditionsOnly(s)
        }
    }

    /// Chỉ tự áp dụng khi không có hub mở ở route khác danh sách, không có việc đang chạy.
    private var canAutoApply: Bool {
        guard !busy else { return false }
        if showHub, case .list = route { return true }
        return !showHub
    }

    /// Dựng kế hoạch đồng bộ không đổi route. nil = cần ghép lại cột (không tự xử lý được).
    private func computePlan(_ source: InventorySource) async throws -> InventorySyncPlan? {
        guard let app else { return nil }
        let hosts = app.hosts
        let sets = app.credentialSets
        if InventoryStructured.supports(source.kind) {
            return try await Task.detached {
                try InventoryStructured.resync(source: source, existingHosts: hosts, credentialSets: sets)
            }.value
        }
        let outcome = try await Task.detached {
            try InventoryFile.resync(source: source, existingHosts: hosts, credentialSets: sets)
        }.value
        if case .ready(_, let plan) = outcome { return plan }
        return nil
    }

    /// Tự áp dụng nếu chỉ có máy mới. Không lưu mật khẩu, không giữ cột bí mật (resync không đọc cột đó).
    /// Mọi lỗi / kế hoạch không sạch -> im lặng, giữ banner "Nguồn có thay đổi" để xem trước.
    private func autoApplyIfAdditionsOnly(_ source: InventorySource) async {
        guard let app, let service = app.service else { return }
        guard let plan = try? await computePlan(source), InventorySync.isAdditionsOnly(plan) else { return }
        // computePlan là async: người dùng có thể đã mở hub / wizard / xem trước trong lúc chờ -> kiểm lại cổng.
        guard canAutoApply else { return }
        busy = true
        defer { busy = false }
        do {
            let record = try await service.applyAutoInventory(plan)
            autoAdded.append(AutoAddNotice(record: record))
            changes[source.id] = nil
            await app.reload()
        } catch {
            // Không ghi gì (một transaction); người dùng vẫn thấy banner và tự xem trước được.
        }
    }

    func setAutoAdd(_ source: InventorySource, enabled: Bool) async {
        guard let app, let service = app.service else { return }
        do {
            try await service.setInventoryAutoAdd(sourceID: source.id, enabled: enabled)
            await refreshData()
        } catch { app.show(error, title: "Không đổi được tuỳ chọn của nguồn") }
    }

    func dismissAutoAdded(_ notice: AutoAddNotice) {
        autoAdded.removeAll { $0.id == notice.id }
        if app?.focusHostIDs == Set(notice.record.hostIDs) { app?.focusHostIDs = nil }
    }

    /// "Xem": lọc danh sách tới đúng các máy vừa thêm và chọn máy đầu tiên.
    func showAutoAdded(_ notice: AutoAddNotice) {
        guard let app else { return }
        app.sidebar = .all
        app.searchText = ""
        app.environmentFilter = nil
        app.focusHostIDs = Set(notice.record.hostIDs)
        app.selection = notice.record.hostIDs.first { id in app.hosts.contains { $0.id == id } }
    }

    func undoAutoAdded(_ notice: AutoAddNotice) async {
        guard let app, let service = app.service else { return }
        do {
            let outcome = try await service.undoAutoAdd(notice.record)
            dismissAutoAdded(notice)
            await app.reload()
            await refreshData()
            var text = "Đã hoàn tác: xoá \(outcome.removed.count) máy"
            if !outcome.kept.isEmpty { text += ", giữ \(outcome.kept.count) máy đã bị sửa hoặc đang được dùng" }
            app.showToast(text + ". Đã tắt “Tự thêm máy mới” của “\(notice.record.sourceName)”.")
        } catch { app.show(error, title: "Không hoàn tác được") }
    }

    // MARK: - Hub

    func openHub() {
        route = .list
        showHub = true
        Task { await checkChanges() }
    }

    /// Huỷ wizard/xem trước: xoá bộ nhớ giá trị cột mật khẩu rồi về danh sách.
    func cancelToList() {
        if case .wizard(let w) = route { w.discardSecrets() }
        if case .preview(let p) = route { p.wizard?.discardSecrets() }
        route = .list
    }

    func close() {
        if case .wizard(let w) = route { w.discardSecrets() }
        if case .preview(let p) = route { p.wizard?.discardSecrets() }
        showHub = false
        route = .list
    }

    // MARK: - Thêm / sửa nguồn

    func addSource() {
        guard let url = pickFile(title: "Chọn file Excel hoặc CSV") else { return }
        Task { await open(url: url, editing: nil) }
    }

    func addStructuredSource(kind: InventorySourceKind) {
        guard let url = pickFile(title: "Chọn file \(kind.title)", kind: kind) else { return }
        Task { await openStructured(url: url, kind: kind, editing: nil) }
    }

    private func pickFile(title: String, kind: InventorySourceKind = .excel) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        switch kind {
        case .json:
            panel.message = "File xuất của SSH Desk (*.sshdesk.json). Không chứa mật khẩu."
            panel.allowedContentTypes = [.json]
        case .ansible:
            panel.message =
                "Ansible inventory tĩnh (INI hoặc YAML). App không chạy Ansible, không đọc host_vars/group_vars, bỏ qua biến mật khẩu."
            panel.allowedContentTypes = []
        default:
            panel.message =
                "Chỉ nhận .xlsx và .csv. Mật khẩu trong file chỉ được lưu khi bạn bật riêng ở bước ghép cột."
            var types: [UTType] = [.commaSeparatedText]
            if let x = UTType(filenameExtension: "xlsx") { types.append(x) }
            panel.allowedContentTypes = types
        }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func openStructured(url: URL, kind: InventorySourceKind, editing: InventorySource?) async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await Task.detached { try InventoryStructured.load(url: url, kind: kind) }.value
            route = .structured(StructuredSetup(url: url, kind: kind, loaded: loaded, editing: editing))
            showHub = true
        } catch { app?.show(error, title: "Không đọc được file") }
    }

    func showPreview(from setup: StructuredSetup) {
        guard let app else { return }
        do {
            var source: InventorySource?
            if setup.saveAsSource {
                let trimmed = setup.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
                source = InventorySource(
                    id: setup.editing?.id ?? UUID(), name: trimmed.isEmpty ? setup.url.lastPathComponent : trimmed,
                    kind: setup.kind, path: setup.url.path, folder: setup.folder,
                    defaultEnvironment: setup.environment, configJSON: setup.editing?.configJSON ?? "{}",
                    lastSyncedAt: setup.editing?.lastSyncedAt,
                    lastFingerprint: setup.editing?.lastFingerprint)
            }
            let plan = try InventoryStructured.plan(
                source: source, loaded: setup.loaded, existingHosts: app.hosts, credentialSets: app.credentialSets)
            route = .preview(InventoryPreview(plan: plan, wizard: nil, title: setup.url.lastPathComponent))
        } catch { app.show(error, title: "Không dựng được bản xem trước") }
    }

    func open(url: URL, editing: InventorySource?, note: String? = nil) async {
        busy = true
        defer { busy = false }
        do {
            let loaded = try await Task.detached {
                try InventoryFile.load(url: url, headerRow: editing?.tableMapping?.headerRow)
            }
            .value
            let wizard = InventoryWizard(url: url, loaded: loaded, editing: editing, suggestedNote: note)
            if loaded.template != nil {
                // File mẫu: bỏ bước ghép cột, vào thẳng xem trước.
                showPreview(from: wizard)
            } else {
                route = .wizard(wizard)
            }
            showHub = true
        } catch { app?.show(error, title: "Không đọc được file") }
    }

    /// Đổi dòng tiêu đề: đọc lại file (để cột mật khẩu được nhận diện theo dòng tiêu đề mới) và đoán lại cột.
    func changeHeaderRow(_ wizard: InventoryWizard, to row: Int) async {
        wizard.reloading = true
        defer { wizard.reloading = false }
        wizard.discardSecrets()
        let url = wizard.url
        do {
            let loaded = try await Task.detached { try InventoryFile.load(url: url, headerRow: row) }.value
            wizard.loaded = loaded
            wizard.headerRow = row
            wizard.secretHeader = wizard.sheet?.passwordColumns.sorted { $0.key < $1.key }.first?.value ?? ""
            if let sheet = wizard.sheet {
                wizard.mapping = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
                wizard.mapping.sheet = loaded.kind == .csv ? nil : sheet.name
            }
        } catch { app?.show(error, title: "Không đọc được file") }
    }

    /// Bật/tắt giữ cột mật khẩu: bật -> đọc lại file với cột đó được giữ; tắt -> xoá bộ nhớ.
    func setKeepPassword(_ wizard: InventoryWizard, _ on: Bool) async {
        guard on else {
            wizard.discardSecrets()
            return
        }
        let title = wizard.secretHeader
        guard !title.isEmpty else { return }
        wizard.reloading = true
        defer { wizard.reloading = false }
        let url = wizard.url
        let row = wizard.headerRow
        do {
            let loaded = try await Task.detached {
                try InventoryFile.load(url: url, headerRow: row, keepSecretColumn: title)
            }.value
            // Wizard đã bị huỷ / đổi route trong lúc đọc: wipe ngay, không gán.
            guard isShowing(wizard) else {
                loaded.secrets?.wipe()
                return
            }
            wizard.loaded.secrets?.wipe()
            wizard.loaded = loaded
            wizard.keepPassword = loaded.secrets != nil
        } catch {
            wizard.discardSecrets()
            app?.show(error, title: "Không đọc được file")
        }
    }

    private func isShowing(_ wizard: InventoryWizard) -> Bool {
        switch route {
        case .wizard(let w): return w === wizard
        case .preview(let p): return p.wizard === wizard
        default: return false
        }
    }

    func changeSheet(_ wizard: InventoryWizard, to name: String) {
        wizard.discardSecrets()
        wizard.sheetName = name
        wizard.secretHeader = wizard.sheet?.passwordColumns.sorted { $0.key < $1.key }.first?.value ?? ""

        guard let sheet = wizard.sheet else { return }
        wizard.headerRow = sheet.headerRow
        wizard.mapping = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
        wizard.mapping.sheet = wizard.loaded.kind == .csv ? nil : sheet.name
    }

    func showPreview(from wizard: InventoryWizard) {
        guard let app else { return }
        do {
            var mapping = wizard.mapping
            mapping.headerRow = wizard.headerRow
            mapping.sheet = wizard.loaded.kind == .csv ? nil : wizard.sheetName
            guard let parsed = try InventoryFile.parse(wizard.loaded, mapping: wizard.isTemplate ? nil : mapping)
            else { return }
            var source: InventorySource?
            if wizard.saveAsSource {
                let trimmed = wizard.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
                source = InventorySource(
                    id: wizard.editing?.id ?? UUID(), name: trimmed.isEmpty ? wizard.url.lastPathComponent : trimmed,
                    kind: wizard.loaded.kind, path: wizard.url.path, folder: wizard.folder,
                    defaultEnvironment: wizard.environment, configJSON: wizard.editing?.configJSON ?? "{}",
                    lastSyncedAt: wizard.editing?.lastSyncedAt,
                    lastFingerprint: wizard.editing?.lastFingerprint)
            }
            let plan = try InventoryFile.plan(
                source: source, loaded: wizard.loaded, parsed: parsed, existingHosts: app.hosts,
                credentialSets: app.credentialSets)
            var secretPlan: InventorySecretImport.Plan?
            if wizard.keepPassword, (wizard.loaded.secrets?.count ?? 0) == 0 {
                notice = "Đã bật lưu mật khẩu nhưng không có mật khẩu nào trong cột đã chọn (hoặc dữ liệu đã bị xoá)."
            }
            if wizard.keepPassword, let secrets = wizard.loaded.secrets, !wizard.isTemplate {
                secretPlan = InventorySecretImport.plan(
                    for: plan, secrets: secrets, sheet: parsed.sheet.name, existingHosts: app.hosts,
                    overwrite: wizard.overwritePassword)
            }
            route = .preview(
                InventoryPreview(
                    plan: plan, wizard: wizard, title: wizard.url.lastPathComponent, secretPlan: secretPlan))
        } catch { app.show(error, title: "Không dựng được bản xem trước") }
    }

    // MARK: - Thao tác trên nguồn đã lưu

    func resync(_ source: InventorySource, newFile: URL? = nil) async {
        guard let app else { return }
        busy = true
        defer { busy = false }
        let hosts = app.hosts
        let sets = app.credentialSets
        if InventoryStructured.supports(source.kind) {
            do {
                let plan = try await Task.detached {
                    try InventoryStructured.resync(
                        source: source, pathOverride: newFile, existingHosts: hosts, credentialSets: sets)
                }.value
                route = .preview(InventoryPreview(plan: plan, wizard: nil, title: source.name))
                showHub = true
            } catch { app.show(error, title: "Không đồng bộ được") }
            return
        }
        do {
            let outcome = try await Task.detached {
                try InventoryFile.resync(
                    source: source, pathOverride: newFile, existingHosts: hosts, credentialSets: sets)
            }.value
            switch outcome {
            case .ready(_, let plan):
                route = .preview(InventoryPreview(plan: plan, wizard: nil, title: source.name))
                showHub = true
            case .needsRemap(let loaded, _, _, let reason):
                let wizard = InventoryWizard(
                    url: newFile ?? URL(fileURLWithPath: source.path), loaded: loaded, editing: source,
                    suggestedNote: "\(reason) Hãy ghép lại cột.")
                // Gợi ý theo tiêu đề mới, không dùng cách ghép cũ đã hỏng.
                if let sheet = wizard.sheet {
                    wizard.mapping = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
                    wizard.mapping.sheet = loaded.kind == .csv ? nil : sheet.name
                }
                route = .wizard(wizard)
                showHub = true
            }
        } catch { app.show(error, title: "Không đồng bộ được") }
    }

    func chooseNewFile(for source: InventorySource) {
        guard let url = pickFile(title: "Chọn file mới cho nguồn “\(source.name)”", kind: source.kind) else { return }
        Task { await resync(source, newFile: url) }
    }

    func editMapping(_ source: InventorySource) {
        if InventoryStructured.supports(source.kind) {
            Task { await openStructured(url: URL(fileURLWithPath: source.path), kind: source.kind, editing: source) }
            return
        }
        Task { await open(url: URL(fileURLWithPath: source.path), editing: source) }
    }

    func delete(_ source: InventorySource) async {
        guard let app, let service = app.service else { return }
        do {
            let n = try await service.deleteInventorySource(id: source.id)
            await app.reload()
            await refreshData()
            app.showToast("Đã xoá nguồn “\(source.name)” (giữ nguyên \(n) máy chủ)")
        } catch { app.show(error, title: "Không xoá được nguồn") }
    }

    func apply(_ preview: InventoryPreview) async -> Bool {
        // Giá trị cột mật khẩu không được tồn tại sau khi áp dụng (xong hay lỗi), và kế hoạch lưu
        // mật khẩu không được sống lâu hơn dữ liệu của nó.
        let hadSecretPlan = preview.secretPlan.map { !$0.isEmpty } ?? false
        defer {
            busy = false
            preview.wizard?.discardSecrets()
            preview.secretPlan = nil
        }
        guard let app, let service = app.service else { return false }
        busy = true
        do {
            try await service.applyInventory(preview.plan)
            if hadSecretPlan, preview.wizard?.loaded.secrets == nil {
                notice =
                    "Chưa lưu mật khẩu: dữ liệu mật khẩu không còn trong bộ nhớ. Hãy nhập lại file và bật “Lưu mật khẩu từ cột”."
            }
            if let sp = preview.secretPlan, let wizard = preview.wizard, let secrets = wizard.loaded.secrets,
                !sp.entries.isEmpty
            {
                let sheet = wizard.sheetName
                let outcome = await InventorySecretImport.save(sp, secrets: secrets, sheet: sheet) { id, pw in
                    _ = try await service.savePassword(hostID: id, password: pw)
                }
                var parts: [String] = []
                if outcome.saved > 0 {
                    parts.append(
                        "Đã lưu mật khẩu cho \(outcome.saved) máy. Hãy xoá hoặc bảo vệ file Excel gốc — nó chứa mật khẩu dạng rõ."
                    )
                }
                if outcome.failed > 0 { parts.append("\(outcome.failed) máy không lưu được mật khẩu vào kho.") }
                if !sp.invalidRows.isEmpty {
                    parts.append(
                        "Mật khẩu ở \(sp.invalidRows.count) dòng không hợp lệ (dòng \(sp.invalidRows.sorted().prefix(10).map(String.init).joined(separator: ", ")))."
                    )
                }
                notice = parts.joined(separator: "\n")
            }
            await app.reload()
            await refreshData()
            if let id = preview.plan.source?.id { changes[id] = nil }
            let p = preview.plan
            app.showToast(
                "Đã áp dụng: thêm \(p.additions.count), đổi \(p.updates.count), không còn trong nguồn \(p.missing.count)"
            )
            route = .list
            return true
        } catch {
            app.show(error, title: "Không áp dụng được (chưa ghi gì)")
            if hadSecretPlan {
                notice = "Chưa lưu mật khẩu — bật lại “Lưu mật khẩu từ cột” ở bước ghép cột để thử lại."
            }
            await app.reload()
            return false
        }
    }

    func detach(_ host: HostProfile) async {
        guard let app, let service = app.service else { return }
        do {
            try await service.detachFromSource(hostID: host.id)
            await app.reload()
            await refreshData()
            app.showToast("Đã tách “\(host.displayName)” khỏi nguồn")
        } catch { app.show(error, title: "Không tách được khỏi nguồn") }
    }

    // MARK: - File mẫu

    func saveTemplate() {
        let panel = NSSavePanel()
        panel.title = "Tải file Excel mẫu"
        panel.message = "File mẫu có sheet “Máy chủ” và “Hướng dẫn”. Không có cột mật khẩu."
        panel.nameFieldStringValue = "sshdesk-hosts-template.xlsx"
        if let x = UTType(filenameExtension: "xlsx") { panel.allowedContentTypes = [x] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached { try InventoryTemplate.write(to: url) }.value
                app?.showToast("Đã lưu file mẫu → \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                app?.show(error, title: "Không lưu được file mẫu")
            }
        }
    }
}
