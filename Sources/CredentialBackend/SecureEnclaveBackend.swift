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

/// Kết quả làm mới blob khoá (ADR-004d).
public enum KeyRefreshOutcome: Sendable, Equatable {
    /// Blob khoá đã được ghi lại với ACL mới và đọc lại khớp.
    case refreshed
    /// Không có blob khoá nào để làm mới.
    case absent
    /// Lỗi giữa chừng; khoá vẫn còn ở `default` hoặc `default-refresh`.
    case failed
}

/// Kết quả "Làm mới quyền Keychain" (ADR-004d). Không chứa giá trị bí mật.
public struct SealedRefreshReport: Sendable, Equatable {
    public var key: KeyRefreshOutcome = .absent
    /// Số ciphertext đã ghi lại và đọc lại khớp.
    public var refreshed = 0
    /// Số tham chiếu không có ciphertext (bỏ qua).
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
    /// Bản sao tạm của blob khoá khi làm mới ACL (ADR-004d).
    public static let keyRefreshAccount = "default-refresh"

    private let keyStorage: any SecretItemStorage
    private let sealedStorage: any SecretItemStorage
    private let legacyStorage: any SecretItemStorage
    private let provider: any SealingKeyProvider
    private let lock = NSLock()
    /// Khoá đã khôi phục/tạo trong tiến trình này (ADR-004d). Khoá SE là handle, không phải secret thô.
    /// Chỉ đặt khi đọc/khôi phục thành công; lỗi đọc không được nhớ. Luôn truy cập dưới `lock`.
    private var cachedKey: (any SealingKey)?

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

    private enum KeyLoad {
        case key(any SealingKey)
        case notFound
        case unreadable
    }

    /// Khoá hiện có: bộ nhớ → `default` → khôi phục từ `default-refresh`. Gọi khi đang giữ `lock`.
    /// Mỗi tiến trình chỉ đọc blob khoá tối đa một lần thành công (ADR-004d).
    private func loadKeyLocked() -> KeyLoad {
        if let cachedKey { return .key(cachedKey) }
        switch keyStorage.readItem(account: Self.keyAccount) {
        case .error: return .unreadable
        case .found(let blob):
            if let key = try? provider.restore(blob: blob) {
                cachedKey = key
                return .key(key)
            }
            // Blob hỏng: thử bản sao làm mới trước khi coi là mất khoá.
            return recoverFromRefreshLocked()
        case .notFound:
            return recoverFromRefreshLocked()
        }
    }

    /// `default` mất/hỏng mà `default-refresh` còn dùng được (làm mới bị ngắt giữa chừng) → khôi phục.
    private func recoverFromRefreshLocked() -> KeyLoad {
        switch keyStorage.readItem(account: Self.keyRefreshAccount) {
        case .error: return .unreadable
        case .notFound: return .notFound
        case .found(let blob):
            guard let key = try? provider.restore(blob: blob) else { return .notFound }
            cachedKey = key
            // Ghi lại `default`; chỉ xoá bản tạm khi đọc lại khớp.
            if (try? keyStorage.saveData(account: Self.keyAccount, data: blob, mode: .updateInPlace)) != nil,
                keyStorage.readData(account: Self.keyAccount) == blob
            {
                try? keyStorage.delete(account: Self.keyRefreshAccount)
            }
            return .key(key)
        }
    }

    private func existingKey() -> (any SealingKey)? {
        lock.lock()
        defer { lock.unlock() }
        if case .key(let key) = loadKeyLocked() { return key }
        return nil
    }

    /// Khoá hiện có; chắc chắn không có item hoặc blob hỏng → tạo khoá mới (ADR-004c). Chỉ gọi khi cần lưu.
    /// Lỗi đọc blob (ACL từ chối, keychain khoá) → ném lỗi, KHÔNG đụng blob cũ. Blob mới chỉ ghi sau khi
    /// tạo khoá thành công, và ghi tại chỗ (không xoá trước).
    private func keyForSaving() throws -> any SealingKey {
        lock.lock()
        defer { lock.unlock() }
        switch loadKeyLocked() {
        case .key(let key): return key
        case .unreadable: throw SecureEnclaveBackendError.keyUnreadable
        case .notFound: break
        }
        do {
            let made = try provider.generate()
            try keyStorage.saveData(account: Self.keyAccount, data: made.blob, mode: .updateInPlace)
            cachedKey = made.key
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

    /// Như `read` nhưng kèm trạng thái (để store nhớ `present`/`undecryptable`/`missing`, ADR-004d).
    public func readResult(account: String) -> (status: SealedItemStatus, value: String?) {
        open(account: account)
    }

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

    // MARK: Làm mới ACL (ADR-004d)

    /// Ghi lại blob khoá và các ciphertext theo `accounts` để ACL mang chữ ký hiện tại của app + helper.
    /// Chỉ chạy khi người dùng chủ động bấm; có thể làm macOS hỏi quyền cho từng mục. Không giải mã,
    /// không log giá trị.
    public func refreshAccess(accounts: [String]) -> SealedRefreshReport {
        var report = SealedRefreshReport()
        report.key = refreshKeyBlob()
        for account in Set(accounts).sorted() where !account.isEmpty {
            switch sealedStorage.readItem(account: account) {
            case .notFound: report.skipped += 1
            case .error: report.failed += 1
            case .found(let data):
                if refreshCiphertext(account: account, data: data) {
                    report.refreshed += 1
                } else {
                    report.failed += 1
                }
            }
        }
        return report
    }

    /// Đọc → ghi `.replace` → đọc lại khớp. Ghi lỗi sau khi xoá thì thử ghi lại bản cũ một lần.
    private func refreshCiphertext(account: String, data: Data) -> Bool {
        do {
            try sealedStorage.saveData(account: account, data: data, mode: .replace)
        } catch {
            try? sealedStorage.saveData(account: account, data: data, mode: .replace)
            return false
        }
        guard sealedStorage.readData(account: account) == data else {
            try? sealedStorage.saveData(account: account, data: data, mode: .replace)
            return false
        }
        return true
    }

    /// Quy trình an toàn không mất khoá: bản sao `default-refresh` → đọc lại khớp → ghi lại `default`
    /// (xoá + thêm, ACL mới) → đọc lại khớp → xoá bản tạm. Lỗi giữa chừng giữ bản nào còn đọc được.
    private func refreshKeyBlob() -> KeyRefreshOutcome {
        lock.lock()
        defer { lock.unlock() }
        // Chọn nguồn: `default` nếu restore được; không thì bản tạm nếu restore được; cả hai hỏng → không ghi gì.
        let primary = keyStorage.readItem(account: Self.keyAccount)
        if case .error = primary { return .failed }
        let copy = keyStorage.readItem(account: Self.keyRefreshAccount)
        let blob: Data
        var sourceIsCopy = false
        if case .found(let data) = primary, (try? provider.restore(blob: data)) != nil {
            blob = data
        } else if case .found(let data) = copy, (try? provider.restore(blob: data)) != nil {
            blob = data
            sourceIsCopy = true
        } else if case .error = copy {
            return .failed
        } else if case .notFound = primary, case .notFound = copy {
            return .absent
        } else {
            return .failed
        }
        // Nguồn đã là bản tạm thì giữ nguyên (ghi đè kiểu xoá-rồi-thêm có thể làm mất nó).
        if !sourceIsCopy {
            do { try keyStorage.saveData(account: Self.keyRefreshAccount, data: blob, mode: .replace) } catch {
                return .failed
            }
            guard keyStorage.readData(account: Self.keyRefreshAccount) == blob else { return .failed }
        }
        do { try keyStorage.saveData(account: Self.keyAccount, data: blob, mode: .replace) } catch {
            return .failed
        }
        guard keyStorage.readData(account: Self.keyAccount) == blob else { return .failed }
        try? keyStorage.delete(account: Self.keyRefreshAccount)
        return .refreshed
    }

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
