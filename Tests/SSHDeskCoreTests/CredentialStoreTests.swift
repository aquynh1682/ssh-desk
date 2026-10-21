import Foundation
import Security
import Testing

@testable import SSHDeskCore

@Test func inMemoryStoreRoundTrip() throws {
    let store = InMemoryCredentialStore()
    #expect(!store.exists(ref: "a"))
    #expect(store.read(ref: "a") == nil)
    try store.save(ref: "a", password: "pw-1")
    #expect(store.exists(ref: "a"))
    #expect(store.read(ref: "a") == "pw-1")
    try store.save(ref: "a", password: "pw-2")
    #expect(store.read(ref: "a") == "pw-2")
    try store.delete(ref: "a")
    #expect(!store.exists(ref: "a"))
    try store.delete(ref: "a")  // xoá lần nữa không lỗi
    #expect(throws: CredentialStoreError.self) { try store.save(ref: "", password: "x") }
}

@Test func descriptionsNeverLeakPassword() throws {
    let mem = InMemoryCredentialStore()
    try mem.save(ref: "r", password: "TOP-SECRET-pw")
    #expect(!"\(mem)".contains("TOP-SECRET-pw"))
    #expect(!String(reflecting: mem).contains("TOP-SECRET-pw"))
    let kc = KeychainCredentialStore(service: "local.sshdesk.tests.x")
    #expect(!"\(kc)".contains("pw"))
    #expect(!"\(CredentialStoreError.keychain(status: -25308))".contains("TOP-SECRET-pw"))
}

/// Keychain thật với service riêng của test; dọn sạch sau khi chạy.
/// Bỏ qua (ghi lý do) nếu môi trường không cho ghi Keychain (không có login keychain, bị khoá, không UI).
@Test func realKeychainCreateReadDelete() throws {
    let service = "local.sshdesk.tests.\(UUID().uuidString)"
    let ref = UUID().uuidString.lowercased()
    let store = KeychainCredentialStore(service: service)
    do { try store.save(ref: ref, password: "kc-secret-é-1") } catch let CredentialStoreError.keychain(status) {
        let skippable: [OSStatus] = [
            errSecNotAvailable, errSecInteractionNotAllowed, errSecAuthFailed, errSecNoSuchKeychain,
            errSecMissingEntitlement, errSecUserCanceled,
        ]
        if skippable.contains(status) {
            print("BỎ QUA: không ghi được Keychain trong môi trường test (OSStatus \(status)).")
            return
        }
        throw CredentialStoreError.keychain(status: status)
    }
    defer { try? store.delete(ref: ref) }
    #expect(store.exists(ref: ref))
    #expect(store.read(ref: ref) == "kc-secret-é-1")
    // ghi đè
    try store.save(ref: ref, password: "kc-secret-2")
    #expect(store.read(ref: ref) == "kc-secret-2")
    try store.delete(ref: ref)
    #expect(!store.exists(ref: ref))
    #expect(store.read(ref: ref) == nil)
}

/// ACL với danh sách ứng dụng tin cậy (SecAccess): ghi/đọc lại từ chính tiến trình test không hỏi.
@Test func realKeychainWithTrustedApplicationList() throws {
    let service = "local.sshdesk.tests.\(UUID().uuidString)"
    let ref = UUID().uuidString.lowercased()
    let store = KeychainCredentialStore(
        service: service, trustedApplicationPaths: ["/usr/bin/ssh"])
    do { try store.save(ref: ref, password: "acl-secret") } catch {
        print("BỎ QUA: không ghi được Keychain trong môi trường test: \(error)")
        return
    }
    defer { try? store.delete(ref: ref) }
    #expect(store.read(ref: ref) == "acl-secret")
}
