import CryptoKit
import Foundation

/// Lỗi của backend Secure Enclave. Không chứa dữ liệu bí mật.
public enum SecureEnclaveBackendError: Error, Equatable, Sendable {
    case unavailable
    case invalidAccount
    case keychain(Int32)
    case sealing
    case keyUnreadable

    public var message: String {
        switch self {
        case .unavailable: return "Máy này không có Secure Enclave — không lưu được mật khẩu"
        case .invalidAccount: return "Tham chiếu Keychain không hợp lệ."
        case .keychain(let s): return "Keychain: \(KeychainBackendError.message(for: s)) (\(s))"
        case .keyUnreadable: return "Không mở được khoá trong Keychain — thử lại"
        case .sealing: return "Không mã hoá được mật khẩu bằng Secure Enclave."
        }
    }
}

/// Trạng thái một mục (ADR-004c).
public enum SealedItemStatus: Sendable, Equatable {
    case missing, present, undecryptable
}

/// Nơi cấp khoá: SE thật hoặc khoá phần mềm (test).
public protocol SealingKeyProvider: Sendable {
    var isAvailable: Bool { get }
    /// Tạo khoá mới, trả khoá và blob để lưu.
    func generate() throws -> (key: any SealingKey, blob: Data)
    func restore(blob: Data) throws -> any SealingKey
}

public struct SecureEnclaveKeyProvider: SealingKeyProvider {
    public init() {}
    public var isAvailable: Bool { SecureEnclave.isAvailable }
    public func generate() throws -> (key: any SealingKey, blob: Data) {
        let key = try SecureEnclaveSealingKey.generate()
        return (key, key.blob)
    }
    public func restore(blob: Data) throws -> any SealingKey { try SecureEnclaveSealingKey(blob: blob) }
}

/// Kết quả migration một lượt. Không chứa giá trị bí mật.
public struct SealedMigrationReport: Sendable, Equatable {
    public var migrated = 0
    public var skipped = 0
    public var failed = 0
    public init() {}
}

/// Backend secret DUY NHẤT (ADR-004c): ECIES với khoá Secure Enclave. Item blob khoá ở service `sekey`
/// (account `default`), ciphertext ở service `sealed` (account = tham chiếu). Không bao giờ đọc/ghi plaintext
/// ngoài `migrateLegacy`. App và helper `sshdesk-askpass` dùng chung mã này.
public final class SecureEnclaveBackend: @unchecked Sendable {
    public static let keyService = "local.sshdesk.sekey"
    public static let sealedService = "local.sshdesk.sealed"
    public static let keyAccount = "default"

    private let keyStorage: any SecretItemStorage
    private let sealedStorage: any SecretItemStorage
    private let legacyStorage: any SecretItemStorage
    private let provider: any SealingKeyProvider
    private let lock = NSLock()

    public init(
        keyStorage: any SecretItemStorage, sealedStorage: any SecretItemStorage,
        legacyStorage: any SecretItemStorage, provider: any SealingKeyProvider
    ) {
        self.keyStorage = keyStorage
        self.sealedStorage = sealedStorage
        self.legacyStorage = legacyStorage
        self.provider = provider
    }

    /// Cấu hình thật. Service đổi được để test không đụng item của người dùng.
    public convenience init(
        keyService: String = SecureEnclaveBackend.keyService,
        sealedService: String = SecureEnclaveBackend.sealedService,
        legacyService: String = KeychainBackend.defaultService,
        trustedApplicationPaths: [String] = [],
        provider: any SealingKeyProvider = SecureEnclaveKeyProvider()
    ) {
        self.init(
            keyStorage: KeychainBackend(service: keyService, trustedApplicationPaths: trustedApplicationPaths),
            sealedStorage: KeychainBackend(
                service: sealedService, trustedApplicationPaths: trustedApplicationPaths),
            legacyStorage: KeychainBackend(
                service: legacyService, trustedApplicationPaths: trustedApplicationPaths),
            provider: provider)
    }

    public var isAvailable: Bool { provider.isAvailable }

    // MARK: Khoá

    private func existingKey() -> (any SealingKey)? {
        guard let blob = keyStorage.readData(account: Self.keyAccount) else { return nil }
        return try? provider.restore(blob: blob)
    }

    /// Khoá hiện có; chắc chắn không có item hoặc blob hỏng → tạo khoá mới (ADR-004c). Chỉ gọi khi cần lưu.
    /// Lỗi đọc blob (ACL từ chối, keychain khoá) → ném lỗi, KHÔNG đụng blob cũ. Blob mới chỉ ghi sau khi
    /// tạo khoá thành công, và ghi tại chỗ (không xoá trước).
    private func keyForSaving() throws -> any SealingKey {
        lock.lock()
        defer { lock.unlock() }
        switch keyStorage.readItem(account: Self.keyAccount) {
        case .error: throw SecureEnclaveBackendError.keyUnreadable
        case .found(let blob):
            if let key = try? provider.restore(blob: blob) { return key }
        case .notFound: break
        }
        do {
            let made = try provider.generate()
            try keyStorage.saveData(account: Self.keyAccount, data: made.blob, mode: .updateInPlace)
            return made.key
        } catch let e as KeychainBackendError {
            if case .status(let s) = e { throw SecureEnclaveBackendError.keychain(s) }
            throw SecureEnclaveBackendError.invalidAccount
        } catch { throw SecureEnclaveBackendError.sealing }
    }

    // MARK: CRUD

    public func save(account: String, secret: String) throws {
        try saveSealed(account: account, secret: secret)
        // Đã có ciphertext hợp lệ: dọn item plaintext cũ cùng ref (bỏ qua lỗi/không có).
        try? legacyStorage.delete(account: account)
    }

    private func saveSealed(account: String, secret: String) throws {
        guard !account.isEmpty else { throw SecureEnclaveBackendError.invalidAccount }
        guard provider.isAvailable else { throw SecureEnclaveBackendError.unavailable }
        let key = try keyForSaving()
        let sealed: Data
        do { sealed = try CredentialSealing.seal(secret, ref: account, key: key) } catch {
            throw SecureEnclaveBackendError.sealing
        }
        try write(sealed, account: account)
    }

    private func write(_ sealed: Data, account: String) throws {
        do { try sealedStorage.saveData(account: account, data: sealed, mode: .replace) } catch let e
            as KeychainBackendError
        {
            if case .status(let s) = e { throw SecureEnclaveBackendError.keychain(s) }
            throw SecureEnclaveBackendError.invalidAccount
        }
    }

    /// Giải mã nếu được. nil nếu thiếu, không giải mã được, hoặc máy không có SE.
    public func read(account: String) -> String? { open(account: account).value }

    /// Chỉ kiểm tra item sealed có tồn tại (rẻ, không giải mã).
    public func exists(account: String) -> Bool { sealedStorage.exists(account: account) }

    public func status(account: String) -> SealedItemStatus {
        let r = open(account: account)
        return r.status
    }

    private func open(account: String) -> (status: SealedItemStatus, value: String?) {
        guard provider.isAvailable else { return (.missing, nil) }
        guard let sealed = sealedStorage.readData(account: account) else { return (.missing, nil) }
        guard let key = existingKey(),
            let text = try? CredentialSealing.open(sealed, ref: account, key: key)
        else { return (.undecryptable, nil) }
        return (.present, text)
    }

    /// Xoá ciphertext và mọi item plaintext cũ còn sót của tham chiếu này. Giữ khoá SE.
    public func delete(account: String) throws {
        do {
            try sealedStorage.delete(account: account)
            try legacyStorage.delete(account: account)
        } catch let e as KeychainBackendError {
            if case .status(let s) = e { throw SecureEnclaveBackendError.keychain(s) }
            throw SecureEnclaveBackendError.invalidAccount
        }
    }

    /// Còn item plaintext cũ cho tham chiếu này không (chỉ hỏi thuộc tính).
    public func hasLegacy(account: String) -> Bool { legacyStorage.exists(account: account) }

    // MARK: Migration

    /// Chuyển các item plaintext cũ sang sealed (ADR-004c). Chỉ app gọi. Lỗi → giữ item cũ.
    public func migrateLegacy(accounts: [String]) -> SealedMigrationReport {
        var report = SealedMigrationReport()
        for account in Set(accounts).sorted() where !account.isEmpty {
            if sealedStorage.exists(account: account) {
                // Đã có sealed mở được → dọn plaintext còn sót.
                if legacyStorage.exists(account: account), open(account: account).status == .present {
                    try? legacyStorage.delete(account: account)
                }
                report.skipped += 1
                continue
            }
            if !legacyStorage.exists(account: account) {
                report.skipped += 1
                continue
            }
            if migrateOne(account) { report.migrated += 1 } else { report.failed += 1 }
        }
        return report
    }

    private func migrateOne(_ account: String) -> Bool {
        guard provider.isAvailable,
            let data = legacyStorage.readData(account: account),
            let plain = String(data: data, encoding: .utf8),
            (try? saveSealed(account: account, secret: plain)) != nil
        else { return false }
        // Mở lại và so khớp trước khi xoá plaintext.
        guard open(account: account).value == plain else {
            try? sealedStorage.delete(account: account)  // để lần sau thử lại
            return false
        }
        do { try legacyStorage.delete(account: account) } catch { return false }
        return true
    }
}
