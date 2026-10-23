import Foundation

/// Một dòng của bảng (`number` = số dòng Excel/CSV, bắt đầu từ 1). `cells` đặc, cột 0 = A.
public struct TableRow: Sendable, Equatable {
    public let number: Int
    public let cells: [String]

    public init(number: Int, cells: [String]) {
        self.number = number
        self.cells = cells
    }

    public func cell(_ index: Int) -> String {
        index >= 0 && index < cells.count ? cells[index] : ""
    }

    public var isBlank: Bool { cells.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// Một sheet (hoặc cả file CSV) đã đọc. **Cột giống mật khẩu đã bị xoá giá trị** ngay khi dựng bảng:
/// model này không bao giờ chứa nội dung cột đó (ADR-026).
public struct TableSheet: Sendable, Equatable {
    public var name: String
    public var rows: [TableRow]
    /// Dòng tiêu đề đã dùng để nhận diện cột mật khẩu.
    public var headerRow: Int
    /// Cột giống mật khẩu: chỉ số cột -> văn bản tiêu đề. Giá trị cột này đã bị bỏ.
    public var passwordColumns: [Int: String]
    public var warnings: [String]

    public init(
        name: String, rows: [TableRow], headerRow: Int, passwordColumns: [Int: String] = [:],
        warnings: [String] = []
    ) {
        self.name = name
        self.rows = rows
        self.headerRow = headerRow
        self.passwordColumns = passwordColumns
        self.warnings = warnings
    }

    public var header: TableRow? { rows.first { $0.number == headerRow } }

    public var dataRows: [TableRow] { rows.filter { $0.number > headerRow } }
}

/// Sổ làm việc đã đọc: các sheet hiển thị (sheet ẩn đã bị loại).
public struct TableWorkbook: Sendable, Equatable {
    public var sheets: [TableSheet]
    public var warnings: [String]

    public init(sheets: [TableSheet], warnings: [String] = []) {
        self.sheets = sheets
        self.warnings = warnings
    }
}

public enum SpreadsheetError: Error, Equatable, CustomStringConvertible {
    case unsupportedExtension(String)
    case notRegularFile
    case unreadable(String)
    case fileTooLarge(limitMB: Int)
    case notZip
    case unsafeEntryName
    case duplicateEntry
    case tooManyEntries
    case entryTooLarge
    case totalTooLarge
    case timeout
    case unzipFailed(Int32)
    case missingPart(String)
    case externalRelationship
    case forbiddenXML
    case notUTF8
    case malformedXML(String)
    case tooManyRows(limit: Int)
    case tooManyColumns(limit: Int)
    case noSheets
    case unsupportedEncoding
    case emptyFile
    case cannotRun(String)

    public var description: String {
        switch self {
        case .unsupportedExtension(let e):
            return "Chỉ nhận file .xlsx hoặc .csv (không nhận “\(e)”; .xlsm/.xls không được hỗ trợ)."
        case .notRegularFile: return "Đường dẫn không phải file thường."
        case .unreadable(let s): return "Không đọc được file: \(s)"
        case .fileTooLarge(let mb): return "File quá lớn (tối đa \(mb) MB)."
        case .notZip: return "File không phải .xlsx hợp lệ."
        case .unsafeEntryName: return "File .xlsx có tên thành phần không an toàn — đã từ chối."
        case .duplicateEntry: return "File .xlsx có thành phần trùng tên — đã từ chối."
        case .tooManyEntries: return "File .xlsx có quá nhiều thành phần."
        case .entryTooLarge: return "Một thành phần trong file .xlsx giải nén quá lớn — đã từ chối."
        case .totalTooLarge: return "File .xlsx giải nén quá lớn — đã từ chối."
        case .timeout: return "Đọc file quá lâu — đã dừng."
        case .unzipFailed(let c): return "File .xlsx bị lỗi hoặc hỏng (mã \(c))."
        case .missingPart(let p): return "File .xlsx thiếu thành phần \(p)."
        case .externalRelationship: return "File .xlsx tham chiếu tài nguyên bên ngoài — đã từ chối."
        case .forbiddenXML: return "File .xlsx chứa khai báo XML không an toàn (DOCTYPE/ENTITY) — đã từ chối."
        case .notUTF8: return "File .xlsx chứa XML không phải UTF-8."
        case .malformedXML(let s): return "XML trong file .xlsx không hợp lệ: \(s)"
        case .tooManyRows(let n): return "Sheet có quá nhiều dòng (tối đa \(n) dòng dữ liệu)."
        case .tooManyColumns(let n): return "Sheet có quá nhiều cột (tối đa \(n))."
        case .noSheets: return "File không có sheet nào hiển thị."
        case .unsupportedEncoding: return "File CSV phải là UTF-8 hoặc UTF-16 LE có BOM."
        case .emptyFile: return "File rỗng."
        case .cannotRun(let s): return "Không chạy được công cụ hệ thống: \(s)"
        }
    }
}

/// Phát hiện tiêu đề giống mật khẩu (ADR-026).
public enum PasswordHeader {
    /// So với chuỗi đã bỏ mọi ký tự không phải chữ/số (bắt `Mật_khẩu`, `mat-khau`, `rootPassword`).
    private static let squashed = [
        "password", "passwd", "passphrase", "passcode", "matkhau", "matma", "apikey", "credential", "token",
    ]
    private static let words: Set<String> = [
        "pass", "pwd", "pw", "mk", "secret", "otp", "pin", "token", "credential", "credentials",
    ]
    /// Cặp từ liền kề.
    private static let pairs: [[String]] = [["mat", "khau"], ["mat", "ma"], ["api", "key"]]
    /// Tiêu đề cột hợp lệ của file mẫu, không phải mật khẩu.
    private static let allowed: Set<String> = ["bo dang nhap"]

    public static func matches(_ header: String) -> Bool {
        let n = HeaderText.normalize(header)
        if n.isEmpty || allowed.contains(n) { return false }
        let tokens = HeaderText.tokens(n)
        if tokens.contains(where: { words.contains($0) }) { return true }
        for p in pairs where tokens.count >= p.count {
            for i in 0...(tokens.count - p.count) where Array(tokens[i..<(i + p.count)]) == p { return true }
        }
        let flat = tokens.joined()
        return squashed.contains { flat.contains($0) }
    }
}

public enum HeaderText {
    /// Bỏ dấu, hoa thường, gộp khoảng trắng. `đ` -> `d`.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased().replacingOccurrences(of: "đ", with: "d")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Tách thành từ theo ký tự không phải chữ/số.
    public static func tokens(_ normalized: String) -> [String] {
        normalized.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
}

/// Dựng `TableSheet` từ các dòng thô và xoá cột mật khẩu trước khi trả ra ngoài.
struct TableBuilder {
    static let autoHeaderScanRows = 30
    private var raw: [TableRow] = []
    private(set) var nonEmptyRows = 0

    mutating func add(number: Int, cells: [String]) {
        raw.append(TableRow(number: number, cells: cells))
        if !TableRow(number: number, cells: cells).isBlank { nonEmptyRows += 1 }
    }

    /// Dòng tiêu đề tự đoán: dòng đầu (trong 30 dòng đầu) có ≥ 2 ô không rỗng, không thì dòng không rỗng đầu tiên.
    static func autoHeaderRow(_ rows: [TableRow]) -> Int? {
        let head = rows.filter { $0.number <= autoHeaderScanRows && !$0.isBlank }
        func filled(_ r: TableRow) -> Int {
            r.cells.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        return (head.first { filled($0) >= 2 } ?? head.first)?.number
    }

    func finish(name: String, headerRow requested: Int?, extraWarnings: [String] = []) -> TableSheet {
        let rows = raw.filter { !$0.isBlank || $0.number == requested }
        let header = requested ?? Self.autoHeaderRow(rows) ?? 1
        var passwordColumns: [Int: String] = [:]
        if let h = rows.first(where: { $0.number == header }) {
            for (i, text) in h.cells.enumerated() where PasswordHeader.matches(text) {
                passwordColumns[i] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var warnings = extraWarnings
        var kept = rows
        if !passwordColumns.isEmpty {
            // Xoá giá trị cột mật khẩu ở MỌI dòng (trừ tiêu đề) trước khi dữ liệu rời khỏi reader.
            kept = rows.map { row in
                guard row.number != header else { return row }
                var cells = row.cells
                for i in passwordColumns.keys where i < cells.count { cells[i] = "" }
                return TableRow(number: row.number, cells: cells)
            }
            warnings.append("Phát hiện cột mật khẩu — sẽ bỏ qua")
        }
        return TableSheet(
            name: name, rows: kept, headerRow: header, passwordColumns: passwordColumns, warnings: warnings)
    }
}
