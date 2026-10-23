import Foundation

/// Bytes bí mật có thể ghi đè 0. Không bao giờ in nội dung.
final class SecretBytes: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }
    var snapshot: [UInt8] { bytes }
    var isAllZero: Bool { bytes.allSatisfy { $0 == 0 } }

    func wipe() {
        bytes.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress, buf.count > 0 { _ = memset_s(base, buf.count, 0, buf.count) }
        }
    }

    var description: String { "••••" }
    var debugDescription: String { "••••" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Giá trị cột mật khẩu do người dùng cho phép giữ (ADR-031): khoá theo (tên sheet, số dòng) -> bytes UTF-8.
/// Nằm ngoài `TableSheet`/`InventoryRecord`/kế hoạch. Mọi dạng in đều che hết.
public final class SecretColumnValues: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Tiêu đề cột đã chọn (không phải giá trị bí mật).
    public let title: String
    private let lock = NSLock()
    private var values: [String: [Int: SecretBytes]] = [:]

    public init(title: String) { self.title = title }

    deinit { wipe() }

    func set(sheet: String, row: Int, bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        values[sheet, default: [:]][row]?.wipe()
        values[sheet, default: [:]][row] = SecretBytes(bytes)
    }

    /// Bản sao bytes của một dòng (nil nếu không có / đã xoá).
    public func bytes(sheet: String, row: Int) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return values[sheet]?[row]?.snapshot
    }

    public func rows(sheet: String) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return (values[sheet] ?? [:]).keys.sorted()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.values.reduce(0) { $0 + $1.count }
    }

    /// Ghi đè 0 mọi buffer rồi bỏ.
    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        for sheet in values.values { for b in sheet.values { b.wipe() } }
        values.removeAll()
    }

    /// Chỉ cho test: giữ tham chiếu buffer để kiểm sau `wipe()`.
    func buffer(sheet: String, row: Int) -> SecretBytes? {
        lock.lock()
        defer { lock.unlock() }
        return values[sheet]?[row]
    }

    public var description: String { "SecretColumnValues(••••)" }
    public var debugDescription: String { "SecretColumnValues(••••)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

/// Bảng đọc xong kèm giá trị cột bí mật (nếu được bật).
public enum InventorySecretImport {
    public static let maxPasswordBytes = 1024

    public struct Entry: Sendable, Equatable {
        public var hostID: UUID
        public var row: Int
        /// Host đã có mật khẩu riêng và sẽ bị ghi đè.
        public var replaces: Bool
    }

    /// Kế hoạch lưu mật khẩu. Không chứa giá trị.
    public struct Plan: Sendable, Equatable {
        public var entries: [Entry] = []
        /// Host đã có mật khẩu riêng và bị bỏ qua vì chưa bật ghi đè.
        public var skippedExisting = 0
        /// Số dòng có mật khẩu không hợp lệ (ký tự điều khiển/NUL, > 1024 byte).
        public var invalidRows: [Int] = []

        public var newCount: Int { entries.filter { !$0.replaces }.count }
        public var replaceCount: Int { entries.filter(\.replaces).count }
        public var count: Int { entries.count }
        public var isEmpty: Bool { entries.isEmpty }
        public var invalidMessages: [String] {
            invalidRows.sorted().map { "Mật khẩu ở dòng \($0) không hợp lệ — bỏ qua máy này." }
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var saved = 0
        public var failed = 0
    }

    public static func isValid(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maxPasswordBytes,
            let s = String(bytes: bytes, encoding: .utf8)
        else { return false }
        return !s.unicodeScalars.contains(where: PortForward.isControl)
    }

    /// Ghép dòng có mật khẩu với host trong kế hoạch. `hasOwnPassword` quyết định host đã có mật khẩu riêng.
    public static func plan(
        for plan: InventorySyncPlan, secrets: SecretColumnValues, sheet: String, existingHosts: [HostProfile],
        overwrite: Bool
    ) -> Plan {
        let byID = Dictionary(existingHosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = Plan()
        var seen = Set<UUID>()
        for row in secrets.rows(sheet: sheet) {
            guard let id = plan.rowHosts[row], seen.insert(id).inserted,
                let bytes = secrets.bytes(sheet: sheet, row: row)
            else { continue }
            guard isValid(bytes) else {
                out.invalidRows.append(row)
                continue
            }
            let has = byID[id]?.hasOwnPassword == true
            if has && !overwrite {
                out.skippedExisting += 1
                continue
            }
            out.entries.append(Entry(hostID: id, row: row, replaces: has))
        }
        return out
    }

    /// Lưu từng mật khẩu sau khi transaction DB đã thành công. `save` thường là `ConnectionService.savePassword`.
    /// Lỗi chỉ được đếm, không bao giờ in giá trị. Luôn `wipe()` container khi xong.
    public static func save(
        _ plan: Plan, secrets: SecretColumnValues, sheet: String,
        using save: @Sendable (UUID, String) async throws -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        for e in plan.entries {
            guard let bytes = secrets.bytes(sheet: sheet, row: e.row), isValid(bytes),
                let password = String(bytes: bytes, encoding: .utf8)
            else {
                outcome.failed += 1
                continue
            }
            do {
                try await save(e.hostID, password)
                outcome.saved += 1
            } catch { outcome.failed += 1 }
        }
        secrets.wipe()
        return outcome
    }
}
