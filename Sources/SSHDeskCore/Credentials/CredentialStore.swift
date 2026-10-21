@_exported import AskpassKit
import Foundation
import Security

public enum CredentialStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(status: Int32)
    case invalidReference

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "lỗi \(status)"
            return "Keychain: \(message) (\(status))"
        case .invalidReference: return "Tham chiếu Keychain không hợp lệ."
        }
    }
}

/// Kho bí mật. Không bao giờ log hay trả password qua `description`.
public protocol CredentialStore: Sendable {
    func save(ref: String, password: String) throws
    /// nil nếu không có item hoặc không đọc được.
    func read(ref: String) -> String?
    func delete(ref: String) throws
    func exists(ref: String) -> Bool
}

/// Keychain thật: generic password, account = credentialReference.
public struct KeychainCredentialStore: CredentialStore, CustomStringConvertible {
    public let service: String
    /// Đường dẫn app/helper được tin cậy trong ACL (ngoài chính tiến trình gọi). Rỗng = ACL mặc định.
    public let trustedApplicationPaths: [String]

    public init(
        service: String = CredentialConstants.service, trustedApplicationPaths: [String] = []
    ) {
        self.service = service
        self.trustedApplicationPaths = trustedApplicationPaths
    }

    public var description: String { "KeychainCredentialStore(service: \(service))" }

    private func query(_ ref: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
    }

    public func save(ref: String, password: String) throws {
        guard !ref.isEmpty else { throw CredentialStoreError.invalidReference }
        // Xoá rồi thêm để ACL luôn được làm mới (đường dẫn helper có thể đổi sau mỗi lần build).
        try delete(ref: ref)
        var attrs = query(ref)
        attrs[kSecValueData as String] = Data(password.utf8)
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
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }

    public func read(ref: String) -> String? {
        var q = query(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(ref: String) throws {
        let status = SecItemDelete(query(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status)
        }
    }

    /// Chỉ hỏi thuộc tính (không lấy dữ liệu) nên không kích hoạt hộp thoại ACL.
    public func exists(ref: String) -> Bool {
        var q = query(ref)
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

/// Kho trong bộ nhớ cho test.
public final class InMemoryCredentialStore: CredentialStore, CustomStringConvertible,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var readCount = 0

    public init() {}

    public var description: String { "InMemoryCredentialStore(count: \(lock.withLock { items.count }))" }
    /// Số lần `read` đã gọi (test dùng để chắc chắn không đọc thừa).
    public var reads: Int { lock.withLock { readCount } }

    public func save(ref: String, password: String) throws {
        guard !ref.isEmpty else { throw CredentialStoreError.invalidReference }
        lock.withLock { items[ref] = password }
    }
    public func read(ref: String) -> String? {
        lock.withLock {
            readCount += 1
            return items[ref]
        }
    }
    public func delete(ref: String) throws { lock.withLock { items[ref] = nil } }
    public func exists(ref: String) -> Bool { lock.withLock { items[ref] != nil } }
}
