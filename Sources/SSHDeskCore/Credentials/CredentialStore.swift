@_exported import AskpassKit
import CredentialBackend
import Foundation

public enum CredentialStoreError: Error, Equatable, CustomStringConvertible {
    case keychain(status: Int32)
    case invalidReference
    /// Backend Secure Enclave (ADR-004c); `message` không chứa secret.
    case secureEnclave(String)

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = KeychainBackendError.message(for: status)
            return "Keychain: \(message) (\(status))"
        case .invalidReference: return "Tham chiếu Keychain không hợp lệ."
        case .secureEnclave(let message): return message
        }
    }
}

/// Trạng thái một mục trong kho (K4e/ADR-004c: backend Secure Enclave có thể trả `.undecryptable`).
public enum CredentialStatus: Sendable, Equatable {
    case missing, present, undecryptable
}

/// Kho bí mật. Không bao giờ log hay trả password qua `description`.
public protocol CredentialStore: Sendable {
    func save(ref: String, password: String) throws
    /// nil nếu không có item hoặc không đọc được.
    func read(ref: String) -> String?
    func delete(ref: String) throws
    func exists(ref: String) -> Bool
    /// Mặc định suy từ `exists`; backend khác Keychain có thể phân biệt thêm `.undecryptable`.
    func status(ref: String) -> CredentialStatus
}

extension CredentialStore {
    public func status(ref: String) -> CredentialStatus { exists(ref: ref) ? .present : .missing }
}

/// Keychain thật: generic password, account = tham chiếu. Mã truy cập Keychain nằm ở `CredentialBackend`
/// (ADR-004b), dùng chung với helper `sshdesk-askpass`; ở đây chỉ chuyển tiếp và đổi kiểu lỗi.
public struct KeychainCredentialStore: CredentialStore, CustomStringConvertible {
    private let backend: KeychainBackend
    public var service: String { backend.service }
    /// Đường dẫn app/helper được tin cậy trong ACL (ngoài chính tiến trình gọi). Rỗng = ACL mặc định.
    public var trustedApplicationPaths: [String] { backend.trustedApplicationPaths }

    public init(
        service: String = CredentialConstants.service, trustedApplicationPaths: [String] = []
    ) {
        backend = KeychainBackend(service: service, trustedApplicationPaths: trustedApplicationPaths)
    }

    public var description: String { "KeychainCredentialStore(service: \(service))" }

    public func save(ref: String, password: String) throws {
        do { try backend.save(account: ref, secret: password) } catch { throw Self.map(error) }
    }

    public func read(ref: String) -> String? { backend.read(account: ref) }

    public func delete(ref: String) throws {
        do { try backend.delete(account: ref) } catch { throw Self.map(error) }
    }

    public func exists(ref: String) -> Bool { backend.exists(account: ref) }

    private static func map(_ error: Error) -> CredentialStoreError {
        switch error as? KeychainBackendError {
        case .status(let s)?: return .keychain(status: s)
        case .invalidAccount?: return .invalidReference
        case nil: return .keychain(status: -1)
        }
    }
}

/// Kho thật của app (ADR-004c): ECIES với khoá Secure Enclave. Chỉ chuyển tiếp sang `SecureEnclaveBackend`
/// (dùng chung với helper `sshdesk-askpass`) và đổi kiểu lỗi. Không bao giờ đọc/ghi plaintext.
public struct SecureEnclaveCredentialStore: CredentialStore, CustomStringConvertible {
    public let backend: SecureEnclaveBackend

    public init(trustedApplicationPaths: [String] = []) {
        backend = SecureEnclaveBackend(trustedApplicationPaths: trustedApplicationPaths)
    }

    public init(backend: SecureEnclaveBackend) { self.backend = backend }

    public var description: String { "SecureEnclaveCredentialStore" }

    public func save(ref: String, password: String) throws {
        do { try backend.save(account: ref, secret: password) } catch { throw Self.map(error) }
    }
    public func read(ref: String) -> String? { backend.read(account: ref) }
    public func delete(ref: String) throws {
        do { try backend.delete(account: ref) } catch { throw Self.map(error) }
    }
    public func exists(ref: String) -> Bool { backend.exists(account: ref) }
    public func status(ref: String) -> CredentialStatus {
        switch backend.status(account: ref) {
        case .missing: return .missing
        case .present: return .present
        case .undecryptable: return .undecryptable
        }
    }

    private static func map(_ error: Error) -> CredentialStoreError {
        switch error as? SecureEnclaveBackendError {
        case .invalidAccount?: return .invalidReference
        case .keychain(let s)?: return .keychain(status: s)
        case let e?: return .secureEnclave(e.message)
        case nil: return .keychain(status: -1)
        }
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
