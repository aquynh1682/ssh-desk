import Foundation

public enum ColumnMappingError: Error, Equatable, CustomStringConvertible {
    /// Cột giống mật khẩu không ghép được vào bất kỳ trường nào (kể cả ghi chú) — ADR-026.
    case passwordColumn(header: String)

    public var description: String {
        switch self {
        case .passwordColumn(let h):
            return
                "Cột “\(h)” giống cột mật khẩu — không thể ghép vào trường nào. SSH Desk không nhập mật khẩu từ file."
        }
    }
}

/// Cách ghép cột lưu trong `config_json` của nguồn: theo **văn bản tiêu đề** (không theo chỉ số cột).
public struct TableMapping: Codable, Equatable, Sendable {
    /// Tên sheet (nil với CSV).
    public var sheet: String?
    /// Dòng tiêu đề (số dòng Excel, từ 1).
    public var headerRow: Int
    /// `InventoryField.rawValue` -> văn bản tiêu đề của cột.
    public var columns: [String: String]
    /// Trường dùng làm cột khoá (`external_id`); mặc định Tên.
    public var keyField: InventoryField
    /// Nhận ra là file mẫu của SSH Desk: kiểm tra chặt (môi trường/loại).
    public var isTemplate: Bool

    public init(
        sheet: String? = nil, headerRow: Int = 1, columns: [String: String] = [:], keyField: InventoryField = .name,
        isTemplate: Bool = false
    ) {
        self.sheet = sheet
        self.headerRow = headerRow
        self.columns = columns
        self.keyField = keyField
        self.isTemplate = isTemplate
    }

    public func header(for field: InventoryField) -> String? { columns[field.rawValue] }

    /// Ghép (hoặc bỏ ghép, `header == nil`) một trường. **Cột giống mật khẩu bị chặn ở mọi trường.**
    public mutating func set(_ field: InventoryField, header: String?) throws {
        guard let header, !header.trimmingCharacters(in: .whitespaces).isEmpty else {
            columns[field.rawValue] = nil
            return
        }
        if PasswordHeader.matches(header) { throw ColumnMappingError.passwordColumn(header: header) }
        columns[field.rawValue] = header
    }

    /// Kết quả đối chiếu với tiêu đề thật của sheet.
    public struct Resolved: Equatable, Sendable {
        public var columns: [InventoryField: Int]
        /// Trường đã ghép nhưng tiêu đề không còn trong sheet (tiêu đề đổi) — cần mở lại màn ghép.
        public var missing: [InventoryField: String]
        /// Trường bị chặn vì tiêu đề giống mật khẩu.
        public var blocked: [InventoryField: String]

        public var needsRemap: Bool { !missing.isEmpty || columns[.hostName] == nil }
    }

    public func resolve(in sheet: TableSheet) -> Resolved {
        let header = sheet.rows.first { $0.number == headerRow }?.cells ?? []
        var index: [String: Int] = [:]
        for (i, text) in header.enumerated() {
            let key = HeaderText.normalize(text)
            if !key.isEmpty, index[key] == nil { index[key] = i }
        }
        var result = Resolved(columns: [:], missing: [:], blocked: [:])
        for field in InventoryField.allCases {
            guard let text = columns[field.rawValue] else { continue }
            if PasswordHeader.matches(text) {
                result.blocked[field] = text
                continue
            }
            if let i = index[HeaderText.normalize(text)] {
                if sheet.passwordColumns[i] != nil {
                    result.blocked[field] = text
                } else {
                    result.columns[field] = i
                }
            } else {
                result.missing[field] = text
            }
        }
        return result
    }

    // MARK: - Đoán cột theo tiêu đề

    private static let synonyms: [(InventoryField, [String])] = [
        (
            .hostName,
            [
                "ip", "ip address", "ip hostname", "ip/hostname", "dia chi", "dia chi ip", "address", "host",
                "hostname", "host name", "ip server", "server ip",
            ]
        ),
        (
            .name,
            [
                "ten", "ten server", "ten may chu", "ten may", "server name", "name", "display name", "ten hien thi",
                "host name label",
            ]
        ),
        (.port, ["port", "cong", "ssh port"]),
        (.user, ["user", "username", "user name", "tai khoan", "login", "nguoi dung", "ten dang nhap"]),
        (.environment, ["moi truong", "env", "environment"]),
        (.folder, ["du an", "project", "thu muc", "nhom", "folder", "group", "thu muc du an", "thu muc/du an"]),
        (.notes, ["ghi chu", "mo ta", "note", "notes", "description", "comment"]),
        (.kind, ["loai", "kind", "type", "loai may"]),
        (.jumpHost, ["jump host", "jumphost", "jump", "bastion"]),
        (.credentialSet, ["bo dang nhap", "credential set", "credential", "credentials"]),
    ]

    private static func score(tokens: [String], synonym: String) -> Int {
        let syn = HeaderText.tokens(HeaderText.normalize(synonym))
        guard !syn.isEmpty, tokens.count >= syn.count else { return 0 }
        if tokens == syn { return 100 + syn.count * 10 }
        for start in 0...(tokens.count - syn.count) where Array(tokens[start..<(start + syn.count)]) == syn {
            return syn.count * 10
        }
        return 0
    }

    /// Đoán ghép cột theo tiêu đề (tiếng Việt có/không dấu + tiếng Anh). Cột giống mật khẩu bị loại.
    /// Cột khoá mặc định: Tên; không có cột tên → IP/Hostname.
    public static func guess(
        sheet: TableSheet, restrictTo fields: [InventoryField] = InventoryField.allCases
    ) -> TableMapping {
        let header = sheet.rows.first { $0.number == sheet.headerRow }?.cells ?? []
        var candidates: [(col: Int, field: InventoryField, score: Int)] = []
        for (i, text) in header.enumerated() {
            if PasswordHeader.matches(text) || sheet.passwordColumns[i] != nil { continue }
            let tokens = HeaderText.tokens(HeaderText.normalize(text))
            if tokens.isEmpty { continue }
            for (field, list) in synonyms where fields.contains(field) {
                let best = list.map { score(tokens: tokens, synonym: $0) }.max() ?? 0
                if best > 0 { candidates.append((i, field, best)) }
            }
        }
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.col != b.col { return a.col < b.col }
            return InventoryField.allCases.firstIndex(of: a.field)! < InventoryField.allCases.firstIndex(of: b.field)!
        }
        var usedColumns = Set<Int>()
        var usedFields = Set<InventoryField>()
        var mapping = TableMapping(sheet: sheet.name, headerRow: sheet.headerRow)
        for c in candidates where !usedColumns.contains(c.col) && !usedFields.contains(c.field) {
            usedColumns.insert(c.col)
            usedFields.insert(c.field)
            mapping.columns[c.field.rawValue] = header[c.col].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        mapping.keyField = mapping.columns[InventoryField.name.rawValue] != nil ? .name : .hostName
        return mapping
    }
}

/// Định dạng file Excel mẫu (ADR-026): tiêu đề cố định và dấu phiên bản.
public enum InventoryTemplateFormat {
    public static let versionMarker = "sshdesk-template v1"
    public static let dataSheetName = "Máy chủ"
    public static let guideSheetName = "Hướng dẫn"
    /// Thứ tự cột cố định, khớp `InventoryField`.
    public static let columns: [InventoryField] = [
        .name, .hostName, .port, .user, .environment, .folder, .kind, .jumpHost, .credentialSet, .notes,
    ]
    public static var headers: [String] { columns.map(\.title) }

    /// Nhận ra file mẫu: dòng 1 của một sheet khớp đúng bộ tiêu đề (không phân biệt hoa thường/khoảng trắng thừa)
    /// hoặc có dấu phiên bản ở A1 của một sheet. Trả sheet dữ liệu và cách ghép cố định (khoá = Tên).
    public static func recognize(_ workbook: TableWorkbook) -> (sheet: TableSheet, mapping: TableMapping)? {
        let wanted = headers.map(HeaderText.normalize)
        func firstRow(_ s: TableSheet) -> TableRow? { s.rows.first { $0.number == 1 } }
        func exact(_ s: TableSheet) -> Bool {
            guard let r = firstRow(s) else { return false }
            return r.cells.map(HeaderText.normalize).filter { !$0.isEmpty } == wanted
        }
        func mapping(for s: TableSheet) -> TableMapping? {
            guard let r = firstRow(s) else { return nil }
            var m = TableMapping(sheet: s.name, headerRow: 1, keyField: .name, isTemplate: true)
            for (field, title) in zip(columns, headers) {
                if let found = r.cells.first(where: { HeaderText.normalize($0) == HeaderText.normalize(title) }) {
                    m.columns[field.rawValue] = found.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard m.columns[InventoryField.name.rawValue] != nil, m.columns[InventoryField.hostName.rawValue] != nil
            else { return nil }
            return m
        }
        if let s = workbook.sheets.first(where: exact), let m = mapping(for: s) { return (s, m) }
        let marked = workbook.sheets.contains {
            firstRow($0)?.cells.first?.trimmingCharacters(in: .whitespacesAndNewlines) == versionMarker
        }
        if marked {
            let candidate =
                workbook.sheets.first { HeaderText.normalize($0.name) == HeaderText.normalize(dataSheetName) }
                ?? workbook.sheets.first { firstRow($0)?.cells.first != versionMarker }
            if let s = candidate, let m = mapping(for: s) { return (s, m) }
        }
        return nil
    }
}
