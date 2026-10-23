import Foundation
import Security

/// Lỗi của backend Keychain. Không bao giờ chứa dữ liệu bí mật.
public enum KeychainBackendError: Error, Equatable, Sendable {
    case status(Int32)
    case invalidAccount

    /// Mô tả OSStatus (không chứa secret).
    public static func message(for status: Int32) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "lỗi \(status)"
    }
}

/// Backend Keychain DUY NHẤT của SSH Desk (ADR-004b). Mọi `SecItem*` / `kSecClass` nằm ở đây:
/// app (qua `KeychainCredentialStore`) và helper `sshdesk-askpass` dùng chung đúng mã này.
/// Generic password: service cố định, account = tham chiếu (`<uuid>`, `set-<uuid>`, `setkey-<uuid>`, ...).
public struct KeychainBackend: Sendable {
    /// Service mặc định của app.
    public static let defaultService = "local.sshdesk.credentials"

    public let service: String
    /// Đường dẫn app/helper được tin cậy trong ACL (ngoài chính tiến trình gọi). Rỗng = ACL mặc định.
    public let trustedApplicationPaths: [String]

    public init(service: String = KeychainBackend.defaultService, trustedApplicationPaths: [String] = []) {
        self.service = service
        self.trustedApplicationPaths = trustedApplicationPaths
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(account: String, secret: String) throws {
        try saveData(account: account, data: Data(secret.utf8), mode: .replace)
    }

    /// Ghi dữ liệu nhị phân (blob khoá SE, ciphertext đã seal — ADR-004c).
    /// `.replace`: xoá rồi thêm kèm SecAccess mới (làm mới ACL; lỗi add sau khi xoá thì ném lỗi).
    /// `.updateInPlace`: item đã có → `SecItemUpdate` (không bao giờ mất item khi ghi lỗi; ACL giữ nguyên),
    /// chưa có → thêm mới. Dùng cho blob khoá SE.
    public func saveData(account: String, data: Data, mode: SecretWriteMode = .replace) throws {
        guard !account.isEmpty else { throw KeychainBackendError.invalidAccount }
        if mode == .replace {
            // Xoá rồi thêm để ACL luôn được làm mới (đường dẫn/danh tính ký có thể đổi).
            try delete(account: account)
        } else {
            let updateStatus = SecItemUpdate(
                query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { throw KeychainBackendError.status(updateStatus) }
        }
        try add(account: account, data: data)
    }

    private func add(account: String, data: Data) throws {
        var attrs = query(account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attrs[kSecAttrLabel as String] = "SSH Desk"
        if !trustedApplicationPaths.isEmpty, let access = makeAccess() {
            var withAccess = attrs
            withAccess[kSecAttrAccess as String] = access
            let status = SecItemAdd(withAccess as CFDictionary, nil)
            if status == errSecSuccess { return }
            // Môi trường không chấp nhận kết hợp thuộc tính: rơi về ACL mặc định.
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainBackendError.status(status) }
    }

    /// nil nếu không có item hoặc không đọc được.
    public func read(account: String) -> String? {
        readData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// nil nếu không có item hoặc không đọc được.
    public func readData(account: String) -> Data? {
        if case .found(let data) = readItem(account: account) { return data }
        return nil
    }

    /// Phân biệt "không có item" với "đọc lỗi" (ACL từ chối, keychain khoá...).
    public func readItem(account: String) -> SecretItemRead {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = out as? Data else { return .error(status) }
        return .found(data)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainBackendError.status(status)
        }
    }

    /// Chỉ hỏi thuộc tính (không lấy dữ liệu) nên không kích hoạt hộp thoại ACL.
    public func exists(account: String) -> Bool {
        var q = query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// ACL: chính tiến trình hiện tại + các đường dẫn được liệt kê (API cũ, deprecated nhưng còn hoạt động).
    @available(macOS, deprecated: 10.10)
    private func makeAccess() -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { trusted.append(me) }
        for path in trustedApplicationPaths {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app {
                trusted.append(app)
            }
        }
        var access: SecAccess?
        guard SecAccessCreate("SSH Desk" as CFString, trusted as CFArray, &access) == errSecSuccess
        else { return nil }
        return access
    }
}

/// Kho item theo (service cố định, account). `KeychainBackend` là cài đặt thật; test dùng bản trong bộ nhớ.
public enum SecretItemRead: Sendable, Equatable {
    case found(Data)
    case notFound
    case error(Int32)
}

public enum SecretWriteMode: Sendable, Equatable {
    case replace
    case updateInPlace
}

public protocol SecretItemStorage: Sendable {
    func saveData(account: String, data: Data, mode: SecretWriteMode) throws
    func readData(account: String) -> Data?
    func readItem(account: String) -> SecretItemRead
    func delete(account: String) throws
    func exists(account: String) -> Bool
}

extension SecretItemStorage {
    public func readItem(account: String) -> SecretItemRead {
        readData(account: account).map { .found($0) } ?? .notFound
    }
}

extension KeychainBackend: SecretItemStorage {}
