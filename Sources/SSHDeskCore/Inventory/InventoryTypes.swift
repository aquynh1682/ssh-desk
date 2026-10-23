import Foundation

/// Loại nguồn máy chủ (ADR-026). `json`/`ansible` dành cho K4b: khung đã có sẵn chỗ.
public enum InventorySourceKind: String, Codable, Sendable, CaseIterable {
    case excel
    case csv
    case json
    case ansible

    public var title: String {
        switch self {
        case .excel: return "Excel"
        case .csv: return "CSV"
        case .json: return "JSON"
        case .ansible: return "Ansible"
        }
    }

    /// Nguồn dạng bảng (cần ghép cột).
    public var isTabular: Bool { self == .excel || self == .csv }
}

/// Nguồn máy chủ đã lưu. Không chứa secret.
public struct InventorySource: Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: InventorySourceKind
    public var path: String
    /// Thư mục mặc định cho host không có cột thư mục ("" = không đặt).
    public var folder: String
    public var defaultEnvironment: HostEnvironment?
    /// Cấu hình riêng theo loại (với Excel/CSV: `TableMapping` dạng JSON).
    public var configJSON: String
    public var lastSyncedAt: Date?
    /// `sha256hex|mtime(ms)|size` của file ở lần đồng bộ cuối.
    public var lastFingerprint: String?

    public init(
        id: UUID = UUID(), name: String, kind: InventorySourceKind, path: String, folder: String = "",
        defaultEnvironment: HostEnvironment? = nil, configJSON: String = "{}", lastSyncedAt: Date? = nil,
        lastFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.path = path
        self.folder = folder
        self.defaultEnvironment = defaultEnvironment
        self.configJSON = configJSON
        self.lastSyncedAt = lastSyncedAt
        self.lastFingerprint = lastFingerprint
    }

    public var tableMapping: TableMapping? {
        try? JSONDecoder().decode(TableMapping.self, from: Data(configJSON.utf8))
    }

    public static func encodeConfig(_ mapping: TableMapping) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(mapping)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Trường chuẩn hoá mà một cột bảng có thể ghép vào (ADR-026).
public enum InventoryField: String, Codable, Sendable, CaseIterable, Hashable {
    case name
    case hostName
    case port
    case user
    case environment
    case folder
    case kind
    case jumpHost
    case credentialSet
    case notes

    public var title: String {
        switch self {
        case .name: return "Tên"
        case .hostName: return "IP/Hostname"
        case .port: return "Port"
        case .user: return "User"
        case .environment: return "Môi trường"
        case .folder: return "Thư mục/Dự án"
        case .kind: return "Loại"
        case .jumpHost: return "Jump host"
        case .credentialSet: return "Bộ đăng nhập"
        case .notes: return "Ghi chú"
        }
    }

    /// Các trường hiện ở màn ghép cột tự do (file mẫu mới có đủ 10 cột).
    public static let freeMappingFields: [InventoryField] = [
        .name, .hostName, .port, .user, .environment, .folder, .notes,
    ]
}

/// Một bản ghi máy chủ đã chuẩn hoá từ nguồn bất kỳ (bảng, JSON, Ansible...).
public struct InventoryRecord: Sendable, Equatable {
    /// Khoá ổn định trong nguồn (đã trim).
    public var externalID: String
    public var name: String
    public var hostName: String
    public var port: Int
    /// SSH: user; Windows: rdpUsername.
    public var user: String
    public var kind: HostKind
    /// nil = nguồn không quản lý môi trường (host cũ giữ nguyên; host mới lấy mặc định của nguồn).
    public var environment: HostEnvironment?
    /// nil = nguồn không quản lý thư mục.
    public var folder: String?
    /// Tên hoặc khoá (`externalID`) của host làm jump host; rỗng/nil = không.
    public var jumpRef: String?
    /// Tên bộ đăng nhập (chỉ tên, không password).
    public var credentialSetName: String?
    /// nil = nguồn không quản lý ghi chú.
    public var notes: String?
    /// Dòng trong file (số dòng Excel/CSV) — để báo lỗi.
    public var sourceRow: Int

    public init(
        externalID: String, name: String, hostName: String, port: Int = 22, user: String = "",
        kind: HostKind = .ssh, environment: HostEnvironment? = nil, folder: String? = nil,
        jumpRef: String? = nil, credentialSetName: String? = nil, notes: String? = nil, sourceRow: Int = 0
    ) {
        self.externalID = externalID
        self.name = name
        self.hostName = hostName
        self.port = port
        self.user = user
        self.kind = kind
        self.environment = environment
        self.folder = folder
        self.jumpRef = jumpRef
        self.credentialSetName = credentialSetName
        self.notes = notes
        self.sourceRow = sourceRow
    }
}

/// Lỗi/cảnh báo gắn với một dòng của nguồn.
public struct InventoryIssue: Sendable, Equatable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }
    public var id: String { "\(severity.rawValue)|\(row)|\(column ?? "")|\(message)" }
    public var severity: Severity
    /// Số dòng Excel/CSV (0 = lỗi chung của file).
    public var row: Int
    /// Tên cột (tiêu đề) nếu biết.
    public var column: String?
    public var message: String

    public init(_ severity: Severity, row: Int, column: String? = nil, _ message: String) {
        self.severity = severity
        self.row = row
        self.column = column
        self.message = message
    }

    public var text: String {
        var head = row > 0 ? "Dòng \(row)" : "File"
        if let column { head += ", cột “\(column)”" }
        return "\(head): \(message)"
    }
}

public enum InventoryError: Error, Equatable, CustomStringConvertible {
    case tooManyRecords(limit: Int)
    case sourceNotFound(UUID)
    case invalidFolder(String)
    case invalidName
    case staleHost(UUID)
    case jumpCycle(String)

    public var description: String {
        switch self {
        case .tooManyRecords(let n): return "Nguồn có quá nhiều máy chủ (tối đa \(n))."
        case .sourceNotFound: return "Không tìm thấy nguồn."
        case .invalidFolder(let f): return "Tên thư mục không hợp lệ: \(f)"
        case .invalidName: return "Tên nguồn không hợp lệ."
        case .staleHost: return "Máy chủ đã bị xoá sau khi xem trước. Hãy xem trước lại."
        case .jumpCycle(let n): return "Jump host của “\(n)” tạo thành vòng."
        }
    }
}

enum InventoryLimits {
    static let maxRecords = 5000
}
