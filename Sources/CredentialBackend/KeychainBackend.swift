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
        guard !account.isEmpty else { throw KeychainBackendError.invalidAccount }
        // Xoá rồi thêm để ACL luôn được làm mới (đường dẫn helper có thể đổi sau mỗi lần build).
        try delete(account: account)
        var attrs = query(account)
        attrs[kSecValueData as String] = Data(secret.utf8)
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
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
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
