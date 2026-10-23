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

    init(plan: InventorySyncPlan, wizard: InventoryWizard?, title: String) {
        self.plan = plan
        self.wizard = wizard
        self.title = title
    }
}

enum InventoryRoute {
    case list
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
    var confirmDelete: InventorySource?
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

    /// Mở app / app được kích hoạt: so mtime rồi SHA-256 với vân tay đã lưu. KHÔNG tự áp dụng.
    func checkChanges() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await refreshData()
        let snapshot = sources.filter { $0.kind.isTabular }
        var result: [UUID: InventoryFile.Change] = [:]
        for s in snapshot {
            let change = await Task.detached {
                InventoryFile.detectChange(path: s.path, kind: s.kind, lastFingerprint: s.lastFingerprint)
            }.value
            if change != .unchanged { result[s.id] = change }
        }
        for (id, change) in result where changes[id] != change { dismissedBanner.remove(id) }
        changes = result
    }

    // MARK: - Hub

    func openHub() {
        route = .list
        showHub = true
        Task { await checkChanges() }
    }

    func close() {
        showHub = false
        route = .list
    }

    // MARK: - Thêm / sửa nguồn

    func addSource() {
        guard let url = pickFile(title: "Chọn file Excel hoặc CSV") else { return }
        Task { await open(url: url, editing: nil) }
    }

    private func pickFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = "Chỉ nhận .xlsx và .csv. App không đọc mật khẩu từ file."
        var types: [UTType] = [.commaSeparatedText]
        if let x = UTType(filenameExtension: "xlsx") { types.append(x) }
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
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
        let url = wizard.url
        do {
            let loaded = try await Task.detached { try InventoryFile.load(url: url, headerRow: row) }.value
            wizard.loaded = loaded
            wizard.headerRow = row
            if let sheet = wizard.sheet {
                wizard.mapping = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
                wizard.mapping.sheet = loaded.kind == .csv ? nil : sheet.name
            }
        } catch { app?.show(error, title: "Không đọc được file") }
    }

    func changeSheet(_ wizard: InventoryWizard, to name: String) {
        wizard.sheetName = name
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
                    defaultEnvironment: wizard.environment, lastSyncedAt: wizard.editing?.lastSyncedAt,
                    lastFingerprint: wizard.editing?.lastFingerprint)
            }
            let plan = try InventoryFile.plan(
                source: source, loaded: wizard.loaded, parsed: parsed, existingHosts: app.hosts,
                credentialSets: app.credentialSets)
            route = .preview(InventoryPreview(plan: plan, wizard: wizard, title: wizard.url.lastPathComponent))
        } catch { app.show(error, title: "Không dựng được bản xem trước") }
    }

    // MARK: - Thao tác trên nguồn đã lưu

    func resync(_ source: InventorySource, newFile: URL? = nil) async {
        guard let app else { return }
        busy = true
        defer { busy = false }
        let hosts = app.hosts
        let sets = app.credentialSets
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
        guard let url = pickFile(title: "Chọn file mới cho nguồn “\(source.name)”") else { return }
        Task { await resync(source, newFile: url) }
    }

    func editMapping(_ source: InventorySource) {
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
        guard let app, let service = app.service else { return false }
        busy = true
        defer { busy = false }
        do {
            try await service.applyInventory(preview.plan)
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
