import CryptoKit
import Foundation

/// Đọc nguồn dạng bảng (Excel/CSV), vân tay file và phát hiện thay đổi (ADR-026).
public enum InventoryFile {
    public struct Loaded: Sendable {
        public var url: URL
        public var kind: InventorySourceKind
        public var workbook: TableWorkbook
        public var fingerprint: String
        /// Nhận ra là file mẫu của SSH Desk -> bỏ qua bước ghép cột.
        public var template: (sheet: TableSheet, mapping: TableMapping)?
        /// Giá trị cột mật khẩu được giữ (ADR-031); nil = không giữ. Không nằm trong `workbook`.
        public var secrets: SecretColumnValues?
    }

    public static func kind(for url: URL) -> InventorySourceKind? {
        switch url.pathExtension.lowercased() {
        case "xlsx": return .excel
        case "csv", "tsv", "txt": return .csv
        default: return nil
        }
    }

    /// Đọc file (chỉ `.xlsx` / `.csv`). `headerRow` nil = tự đoán từng sheet.
    public static func load(
        url: URL, headerRow: Int? = nil, xlsxLimits: XLSXLimits = XLSXLimits(), keepSecretColumn: String? = nil
    ) throws -> Loaded {
        guard let kind = kind(for: url) else {
            throw SpreadsheetError.unsupportedExtension("." + url.pathExtension.lowercased())
        }
        let fingerprint = try fingerprint(of: url, kind: kind)
        let workbook: TableWorkbook
        let secrets = keepSecretColumn.map { SecretColumnValues(title: $0) }
        do {
            switch kind {
            case .excel:
                workbook = try XLSXReader.read(url: url, headerRow: headerRow, limits: xlsxLimits, keepSecret: secrets)
            default: workbook = try CSVReader.read(url: url, headerRow: headerRow, keepSecret: secrets)
            }
        } catch {
            secrets?.wipe()
            throw error
        }
        let template = kind == .excel ? InventoryTemplateFormat.recognize(workbook) : nil
        return Loaded(
            url: url, kind: kind, workbook: workbook, fingerprint: fingerprint, template: template,
            secrets: secrets)
    }

    // MARK: - Vân tay

    public static func sizeLimit(for kind: InventorySourceKind) -> Int {
        kind == .excel ? XLSXLimits().maxFileBytes : CSVReader.maxBytes
    }

    /// `sha256hex|mtime(ms)|size`.
    public static func fingerprint(of url: URL, kind: InventorySourceKind) throws -> String {
        let resolved = url.resolvingSymlinksInPath()
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: resolved.path) } catch {
            throw SpreadsheetError.unreadable(error.localizedDescription)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw SpreadsheetError.notRegularFile }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= sizeLimit(for: kind) else {
            throw SpreadsheetError.fileTooLarge(limitMB: sizeLimit(for: kind) / 1_048_576)
        }
        let data: Data
        do { data = try Data(contentsOf: resolved) } catch {
            throw SpreadsheetError.unreadable(error.localizedDescription)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(hash)|\(Int(mtime * 1000))|\(size)"
    }

    public enum Change: Sendable, Equatable {
        case unchanged
        case changed
        case fileMissing
        case unreadable(String)
    }

    /// So file hiện tại với vân tay đã lưu: mtime giống -> không đổi; mtime khác thì so SHA-256.
    public static func detectChange(path: String, kind: InventorySourceKind, lastFingerprint: String?) -> Change {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileMissing }
        guard let last = lastFingerprint else { return .changed }
        let parts = last.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let storedMTime = Int(parts[1]), let storedSize = Int(parts[2]) else { return .changed }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
            let m = attrs[.modificationDate] as? Date, Int(m.timeIntervalSince1970 * 1000) == storedMTime,
            (attrs[.size] as? NSNumber)?.intValue == storedSize
        {
            return .unchanged
        }
        do {
            let now = try fingerprint(of: url, kind: kind)
            return now.split(separator: "|").first == parts[0] ? .unchanged : .changed
        } catch { return .unreadable("\(error)") }
    }

    // MARK: - Từ file tới kế hoạch

    /// Sheet theo cách ghép (hoặc sheet nhận ra là mẫu / sheet đầu).
    public static func sheet(in workbook: TableWorkbook, for mapping: TableMapping) -> TableSheet? {
        if let name = mapping.sheet, let s = workbook.sheets.first(where: { $0.name == name }) { return s }
        return mapping.sheet == nil ? workbook.sheets.first : nil
    }

    public struct Parsed: Sendable {
        public var sheet: TableSheet
        public var mapping: TableMapping
        public var result: InventoryParseResult
    }

    /// Parse bảng theo cách ghép. File mẫu luôn dùng cách ghép cố định của mẫu.
    public static func parse(_ loaded: Loaded, mapping: TableMapping?) throws -> Parsed? {
        if let t = loaded.template, mapping == nil || mapping?.isTemplate == true {
            return Parsed(
                sheet: t.sheet, mapping: t.mapping,
                result: try InventoryTableParser.parse(sheet: t.sheet, mapping: t.mapping))
        }
        guard let mapping, let sheet = sheet(in: loaded.workbook, for: mapping) else { return nil }
        return Parsed(
            sheet: sheet, mapping: mapping, result: try InventoryTableParser.parse(sheet: sheet, mapping: mapping))
    }

    public enum Resync: Sendable {
        case ready(Loaded, InventorySyncPlan)
        /// Tiêu đề đổi / thiếu cột bắt buộc: mở lại màn ghép cột với gợi ý.
        case needsRemap(Loaded, sheet: TableSheet, suggested: TableMapping, reason: String)
    }

    /// "Đồng bộ lại" / "Xem trước" một nguồn bảng đã lưu (đọc file, kiểm tiêu đề, dựng kế hoạch).
    public static func resync(
        source: InventorySource, pathOverride: URL? = nil, existingHosts: [HostProfile],
        credentialSets: [CredentialSet], xlsxLimits: XLSXLimits = XLSXLimits(), now: Date = Date()
    ) throws -> Resync {
        let url = pathOverride ?? URL(fileURLWithPath: source.path)
        let saved = source.tableMapping
        let loaded = try load(url: url, headerRow: saved?.headerRow, xlsxLimits: xlsxLimits)
        var src = source
        src.path = url.path
        if let t = loaded.template {
            return .ready(
                loaded,
                try plan(
                    source: src, loaded: loaded,
                    parsed: Parsed(
                        sheet: t.sheet, mapping: t.mapping,
                        result: try InventoryTableParser.parse(sheet: t.sheet, mapping: t.mapping)),
                    existingHosts: existingHosts, credentialSets: credentialSets, now: now))
        }
        guard let saved, let sheet = sheet(in: loaded.workbook, for: saved) else {
            let first = loaded.workbook.sheets[0]
            return .needsRemap(
                loaded, sheet: first,
                suggested: TableMapping.guess(sheet: first, restrictTo: InventoryField.freeMappingFields),
                reason: "Không thấy sheet “\(saved?.sheet ?? "")”.")
        }
        let resolved = saved.resolve(in: sheet)
        if resolved.needsRemap {
            let titles = resolved.missing.values.sorted().joined(separator: ", ")
            return .needsRemap(
                loaded, sheet: sheet,
                suggested: TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields),
                reason: resolved.missing.isEmpty ? "Chưa ghép cột IP/Hostname." : "Tiêu đề đã đổi: \(titles).")
        }
        let parsed = Parsed(
            sheet: sheet, mapping: saved, result: try InventoryTableParser.parse(sheet: sheet, mapping: saved))
        return .ready(
            loaded,
            try plan(
                source: src, loaded: loaded, parsed: parsed, existingHosts: existingHosts,
                credentialSets: credentialSets, now: now))
    }

    /// Dựng kế hoạch đồng bộ từ kết quả parse. `source` (đã gắn cách ghép) sẽ được lưu cùng transaction khi áp dụng;
    /// nil = nhập một lần.
    public static func plan(
        source: InventorySource?, loaded: Loaded, parsed: Parsed, existingHosts: [HostProfile],
        credentialSets: [CredentialSet], now: Date = Date()
    ) throws -> InventorySyncPlan {
        var src = source
        src?.configJSON = InventorySource.encodeConfig(parsed.mapping)
        return try InventorySync.plan(
            source: src, records: parsed.result.records, issues: parsed.result.issues,
            warnings: parsed.result.warnings + loaded.workbook.warnings, failedKeys: parsed.result.failedKeys,
            managesJump: parsed.result.managedFields.contains(.jumpHost), existingHosts: existingHosts,
            credentialSets: credentialSets, fingerprint: loaded.fingerprint, now: now)
    }
}
