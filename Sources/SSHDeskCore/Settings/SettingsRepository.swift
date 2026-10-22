import Foundation

/// Lưu cài đặt trong bảng `settings` (migration v7). Chỉ khoá/giá trị văn bản, không bí mật.
public final class SettingsRepository: @unchecked Sendable {
    private let db: Database

    public init(database: Database) { self.db = database }

    /// Đọc mọi cài đặt; giá trị hỏng/khoá lạ → mặc định. Lỗi đọc DB → mặc định (không crash).
    public func load() -> AppSettings {
        guard let rows = try? db.query("SELECT key, value FROM settings") else { return .default }
        var values: [String: String] = [:]
        for row in rows {
            if case .text(let k) = row[0], case .text(let v) = row[1] { values[k] = v }
        }
        return AppSettings(values: values)
    }

    /// Ghi (đã chuẩn hoá) trong một transaction; trả cài đặt đã chuẩn hoá.
    @discardableResult
    public func save(_ settings: AppSettings) throws -> AppSettings {
        let normalized = settings.normalized
        try db.transaction {
            for (key, value) in normalized.values {
                try db.execute(
                    "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .text(value)])
            }
        }
        return normalized
    }
}

/// Bản cài đặt hiện hành dùng chung giữa UI và các service (đọc mỗi lần dùng, nên đổi có hiệu lực ngay).
public final class SettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings

    public init(_ initial: AppSettings = .default) { value = initial.normalized }

    public var current: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func update(_ settings: AppSettings) {
        lock.lock()
        defer { lock.unlock() }
        value = settings.normalized
    }
}

/// Bọc kho bí mật: khi tự điền bị tắt (ADR-021) thì `read` trả nil → mọi chỗ tự điền (PTY, tunnel, phiên SFTP,
/// cài key) rơi về hỏi người dùng. `exists/save/delete` giữ nguyên để UI vẫn thấy "đã lưu mật khẩu".
public struct AutofillGatedCredentialStore: CredentialStore {
    private let base: any CredentialStore
    private let isEnabled: @Sendable () -> Bool

    public init(base: any CredentialStore, isEnabled: @escaping @Sendable () -> Bool) {
        self.base = base
        self.isEnabled = isEnabled
    }

    public func save(ref: String, password: String) throws { try base.save(ref: ref, password: password) }
    public func read(ref: String) -> String? { isEnabled() ? base.read(ref: ref) : nil }
    public func delete(ref: String) throws { try base.delete(ref: ref) }
    public func exists(ref: String) -> Bool { base.exists(ref: ref) }
}
