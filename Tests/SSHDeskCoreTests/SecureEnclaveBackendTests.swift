import CredentialBackend
import CryptoKit
import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - Hỗ trợ

/// Kho item trong bộ nhớ, có thể ép lỗi ghi.
final class FakeItemStorage: SecretItemStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWrites = false
    var failDeletes = false
    var readError: Int32?  // ép lỗi đọc (ACL từ chối, keychain khoá...)
    /// Tài khoản ép lỗi ghi. Với `.replace` mô phỏng Keychain thật: xoá trước rồi mới lỗi khi thêm.
    var failingAccounts: Set<String> = []
    /// Số lần đọc DỮ LIỆU (kích hoạt kiểm ACL trên Keychain thật); `exists` không tính.
    private(set) var reads = 0
    var onWrite: (@Sendable (String, Data) -> Data)?  // sửa dữ liệu khi ghi (mô phỏng ghi hỏng)

    private(set) var modes: [String: [SecretWriteMode]] = [:]
    func saveData(account: String, data: Data, mode: SecretWriteMode) throws {
        try lock.withLock {
            modes[account, default: []].append(mode)
            if failingAccounts.contains(account) {
                if mode == .replace { items[account] = nil }
                throw KeychainBackendError.status(-25299)
            }
            if failWrites { throw KeychainBackendError.status(-25299) }
            items[account] = onWrite?(account, data) ?? data
        }
    }
    func readData(account: String) -> Data? {
        lock.withLock {
            reads += 1
            return items[account]
        }
    }
    func delete(account: String) throws {
        try lock.withLock {
            if failDeletes { throw KeychainBackendError.status(-25299) }
            items[account] = nil
        }
    }
    func exists(account: String) -> Bool { lock.withLock { items[account] != nil } }
    func readItem(account: String) -> SecretItemRead {
        lock.withLock {
            reads += 1
            if let e = readError { return .error(e) }
            return items[account].map { .found($0) } ?? .notFound
        }
    }
    func put(_ account: String, _ data: Data) { lock.withLock { items[account] = data } }
    var accounts: [String] { lock.withLock { Array(items.keys) } }
}

/// Provider phần mềm cho test (blob = raw representation).
struct SoftwareProvider: SealingKeyProvider {
    var isAvailable = true
    func generate() throws -> (key: any SealingKey, blob: Data) {
        let k = P256.KeyAgreement.PrivateKey()
        return (SoftwareSealingKey(privateKey: k), k.rawRepresentation)
    }
    func restore(blob: Data) throws -> any SealingKey {
        do { return SoftwareSealingKey(privateKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: blob)) } catch {
            throw SealingError.keyFailure
        }
    }
}

struct Fixture {
    let keys = FakeItemStorage()
    let sealed = FakeItemStorage()
    let legacy = FakeItemStorage()
    let backend: SecureEnclaveBackend
    init(available: Bool = true) {
        backend = SecureEnclaveBackend(
            keyStorage: keys, sealedStorage: sealed, legacyStorage: legacy,
            provider: SoftwareProvider(isAvailable: available))
    }
    func putLegacy(_ ref: String, _ value: String) { legacy.put(ref, Data(value.utf8)) }
    /// Backend mới trên cùng kho: mô phỏng khởi động lại tiến trình (khoá nhớ trong bộ nhớ bị mất).
    func restarted() -> SecureEnclaveBackend {
        SecureEnclaveBackend(
            keyStorage: keys, sealedStorage: sealed, legacyStorage: legacy, provider: SoftwareProvider())
    }
}

// MARK: - Seal / open thuần

@Test func sealOpenRoundTripAndFormat() throws {
    let key = SoftwareSealingKey()
    let sealed = try CredentialSealing.seal("p@ss é 密码", ref: "set-1", key: key)
    #expect(sealed[0] == 0x01)
    #expect(sealed.count >= 1 + 65 + 12 + 16)
    #expect(try CredentialSealing.open(sealed, ref: "set-1", key: key) == "p@ss é 密码")
    // ephPub x963 hợp lệ và không lộ plaintext
    #expect(sealed[1] == 0x04)
    #expect(!sealed.contains(Data("p@ss".utf8)))
    // hai lần seal cho ciphertext khác nhau
    #expect(try CredentialSealing.seal("x", ref: "r", key: key) != CredentialSealing.seal("x", ref: "r", key: key))
}

@Test func openFailsOnWrongRefTamperedOrMalformed() throws {
    let key = SoftwareSealingKey()
    let sealed = try CredentialSealing.seal("secret", ref: "a", key: key)
    #expect(throws: SealingError.authenticationFailed) { try CredentialSealing.open(sealed, ref: "b", key: key) }
    #expect(throws: SealingError.authenticationFailed) {
        try CredentialSealing.open(sealed, ref: "a", key: SoftwareSealingKey())
    }
    var tampered = sealed
    tampered[tampered.count - 1] ^= 0x01
    #expect(throws: SealingError.authenticationFailed) { try CredentialSealing.open(tampered, ref: "a", key: key) }
    var tamperedCT = sealed
    tamperedCT[1 + 65 + 12] ^= 0x01
    #expect(throws: SealingError.authenticationFailed) { try CredentialSealing.open(tamperedCT, ref: "a", key: key) }
    var badVersion = sealed
    badVersion[0] = 0x02
    #expect(throws: SealingError.unsupportedVersion) { try CredentialSealing.open(badVersion, ref: "a", key: key) }
    #expect(throws: SealingError.badFormat) { try CredentialSealing.open(Data(), ref: "a", key: key) }
    #expect(throws: SealingError.badFormat) { try CredentialSealing.open(sealed.prefix(60), ref: "a", key: key) }
    #expect(throws: SealingError.badFormat) { try CredentialSealing.open(sealed.prefix(80), ref: "a", key: key) }
    // ephPub không phải điểm P-256 hợp lệ
    var badPoint = sealed
    for i in 2..<66 { badPoint[i] = 0 }
    #expect(throws: SealingError.authenticationFailed) { try CredentialSealing.open(badPoint, ref: "a", key: key) }
}

// MARK: - Backend với kho giả

@Test func backendSaveReadStatusDelete() throws {
    let f = Fixture()
    #expect(f.backend.status(account: "r") == .missing)
    try f.backend.save(account: "r", secret: "pw1")
    #expect(f.backend.read(account: "r") == "pw1")
    #expect(f.backend.exists(account: "r"))
    #expect(f.backend.status(account: "r") == .present)
    #expect(f.keys.accounts == ["default"])
    // Ciphertext không chứa plaintext; legacy không được ghi.
    #expect(f.sealed.readData(account: "r").map { !$0.contains(Data("pw1".utf8)) } == true)
    #expect(f.legacy.accounts.isEmpty)
    try f.backend.save(account: "r", secret: "pw2")
    #expect(f.backend.read(account: "r") == "pw2")
    // Khoá chỉ tạo một lần.
    let blob = f.keys.readData(account: "default")
    try f.backend.save(account: "other", secret: "x")
    #expect(f.keys.readData(account: "default") == blob)
    try f.backend.delete(account: "r")
    #expect(f.backend.status(account: "r") == .missing)
    #expect(throws: SecureEnclaveBackendError.invalidAccount) { try f.backend.save(account: "", secret: "x") }
}

@Test func swappedCiphertextBetweenRefsIsUndecryptable() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    try f.backend.save(account: "b", secret: "B")
    f.sealed.put("b", f.sealed.readData(account: "a")!)
    #expect(f.backend.status(account: "b") == .undecryptable)
    #expect(f.backend.read(account: "b") == nil)
}

@Test func lostOrCorruptKeyBlobMakesOldItemsUndecryptableAndNewSaveWorks() throws {
    let f = Fixture()
    try f.backend.save(account: "old", secret: "pw")
    try f.keys.delete(account: "default")
    // Khởi động lại tiến trình (khoá nhớ trong bộ nhớ không còn).
    let b = f.restarted()
    #expect(b.status(account: "old") == .undecryptable)
    #expect(b.read(account: "old") == nil)
    #expect(b.exists(account: "old"))
    // Blob hỏng: save tạo khoá mới; ciphertext cũ vẫn undecryptable; nhập lại ghi đè.
    f.keys.put("default", Data([1, 2, 3]))
    let c = f.restarted()
    try c.save(account: "new", secret: "n")
    #expect(c.read(account: "new") == "n")
    #expect(c.status(account: "old") == .undecryptable)
    try c.save(account: "old", secret: "pw-again")
    #expect(c.status(account: "old") == .present)
    #expect(c.read(account: "old") == "pw-again")
}

@Test func noSecureEnclaveSaveThrowsAndReadIsMissing() throws {
    let f = Fixture(available: false)
    #expect(throws: SecureEnclaveBackendError.unavailable) { try f.backend.save(account: "r", secret: "x") }
    #expect(
        SecureEnclaveBackendError.unavailable.message
            == "Máy này không có Secure Enclave — không lưu được mật khẩu")
    #expect(f.sealed.accounts.isEmpty && f.keys.accounts.isEmpty && f.legacy.accounts.isEmpty)
    #expect(f.backend.read(account: "r") == nil)
    #expect(f.backend.status(account: "r") == .missing)
    // Qua CredentialStore: lỗi map rõ ràng.
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    #expect(throws: CredentialStoreError.secureEnclave(SecureEnclaveBackendError.unavailable.message)) {
        try store.save(ref: "r", password: "x")
    }
}

@Test func storeStatusMapping() throws {
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    #expect(store.status(ref: "r") == .missing)
    try store.save(ref: "r", password: "x")
    #expect(store.status(ref: "r") == .present && store.exists(ref: "r"))
    try f.keys.delete(account: "default")
    let store2 = SecureEnclaveCredentialStore(backend: f.restarted())
    #expect(store2.status(ref: "r") == .undecryptable)
    // AutofillGated chuyển tiếp status.
    let gated = AutofillGatedCredentialStore(base: store2) { true }
    #expect(gated.status(ref: "r") == .undecryptable)
}

// MARK: - Migration

@Test func migrationSuccessRemovesPlaintextAndIsIdempotent() throws {
    let f = Fixture()
    f.putLegacy("h1", "pw-1")
    f.putLegacy("set-1", "pw-set")
    let r1 = f.backend.migrateLegacy(accounts: ["h1", "set-1", "setkey-1"])
    #expect(r1.migrated == 2 && r1.failed == 0 && r1.skipped == 1)
    #expect(f.legacy.accounts.isEmpty)
    #expect(f.backend.read(account: "h1") == "pw-1")
    #expect(f.backend.read(account: "set-1") == "pw-set")
    let r2 = f.backend.migrateLegacy(accounts: ["h1", "set-1", "setkey-1"])
    #expect(r2.migrated == 0 && r2.failed == 0)
    #expect(f.backend.read(account: "h1") == "pw-1")
}

@Test func migrationSkipsWhenSealedAlreadyExists() throws {
    let f = Fixture()
    try f.backend.save(account: "h", secret: "new")
    f.putLegacy("h", "old")
    let r = f.backend.migrateLegacy(accounts: ["h"])
    #expect(r.migrated == 0 && r.skipped == 1)
    #expect(f.backend.read(account: "h") == "new")
    #expect(f.legacy.accounts.isEmpty)  // plaintext sót được dọn khi sealed mở được
}

@Test func migrationKeepsLegacyWhenSealedUndecryptable() throws {
    let f = Fixture()
    try f.backend.save(account: "h", secret: "new")
    try f.keys.delete(account: "default")
    f.putLegacy("h", "old")
    _ = f.restarted().migrateLegacy(accounts: ["h"])
    #expect(f.legacy.exists(account: "h"))
}

@Test func saveRemovesLeftoverPlaintextOfSameRef() throws {
    let f = Fixture()
    f.putLegacy("h", "old")
    f.putLegacy("other", "keep")
    try f.backend.save(account: "h", secret: "new")
    #expect(!f.legacy.exists(account: "h") && f.legacy.exists(account: "other"))
}

@Test func keyBlobUpdatesInPlaceWhileCiphertextIsReplaced() throws {
    let f = Fixture()
    try f.backend.save(account: "r", secret: "a")
    try f.backend.save(account: "r", secret: "b")
    #expect(f.keys.modes["default"] == [.updateInPlace])
    #expect(f.sealed.modes["r"] == [.replace, .replace])
}

@Test func unreadableKeyBlobNeverOverwritesKeyOnSave() throws {
    let f = Fixture()
    try f.backend.save(account: "old", secret: "pw")
    let blob = f.keys.readData(account: "default")
    f.keys.readError = -25293  // errSecAuthFailed
    let b = f.restarted()
    #expect(throws: SecureEnclaveBackendError.keyUnreadable) { try b.save(account: "new", secret: "x") }
    #expect(
        SecureEnclaveBackendError.keyUnreadable.message == "Không mở được khoá trong Keychain — thử lại")
    f.keys.readError = nil
    #expect(f.keys.readData(account: "default") == blob)
    #expect(f.backend.read(account: "old") == "pw")
    #expect(!f.sealed.exists(account: "new"))
}

@Test func migrationWriteFailureKeepsPlaintextThenRetries() throws {
    let f = Fixture()
    f.putLegacy("h", "pw")
    f.sealed.failWrites = true
    let r = f.backend.migrateLegacy(accounts: ["h"])
    #expect(r.failed == 1 && r.migrated == 0)
    #expect(f.legacy.readData(account: "h") == Data("pw".utf8))
    #expect(f.backend.read(account: "h") == nil)
    f.sealed.failWrites = false
    let r2 = f.backend.migrateLegacy(accounts: ["h"])
    #expect(r2.migrated == 1)
    #expect(f.backend.read(account: "h") == "pw")
    #expect(f.legacy.accounts.isEmpty)
}

@Test func migrationVerifyMismatchKeepsPlaintextAndDropsBadSealed() throws {
    let f = Fixture()
    f.putLegacy("h", "pw")
    f.sealed.onWrite = { _, data in
        var d = data
        d[d.count - 1] ^= 0x01  // ghi hỏng -> mở lại không khớp
        return d
    }
    let r = f.backend.migrateLegacy(accounts: ["h"])
    #expect(r.failed == 1)
    #expect(f.legacy.readData(account: "h") == Data("pw".utf8))
    #expect(!f.sealed.exists(account: "h"))
}

@Test func migrationLegacyDeleteFailureReportsFailedButKeepsData() throws {
    let f = Fixture()
    f.putLegacy("h", "pw")
    f.legacy.failDeletes = true
    #expect(f.backend.migrateLegacy(accounts: ["h"]).failed == 1)
    #expect(f.backend.read(account: "h") == "pw")
}

@Test func migrationWithoutSecureEnclaveChangesNothing() throws {
    let f = Fixture(available: false)
    f.putLegacy("h", "pw")
    #expect(f.backend.migrateLegacy(accounts: ["h"]).failed == 1)
    #expect(f.legacy.readData(account: "h") == Data("pw".utf8))
    #expect(f.sealed.accounts.isEmpty)
}

@Test func deleteAlsoRemovesLeftoverPlaintext() throws {
    let f = Fixture()
    f.putLegacy("h", "pw")
    try f.backend.save(account: "h", secret: "x")
    try f.backend.delete(account: "h")
    #expect(f.legacy.accounts.isEmpty && f.sealed.accounts.isEmpty)
    #expect(!f.keys.accounts.isEmpty)  // giữ khoá SE
}

@Test func migrationReferencesCoverHostsAndSets() throws {
    let set = CredentialSet(id: UUID(), name: "S")
    let host = HostProfile(displayName: "h", credentialReference: "host-ref")
    let noRef = HostProfile(displayName: "n")
    let refs = CredentialMigration.references(hosts: [host, noRef], sets: [set])
    #expect(Set(refs) == ["host-ref", set.passwordReference, set.passphraseReference])
}

private struct LoadFailure: Error {}

@Test func runIfNeededSetsFlagOnlyWhenAllSucceed() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let settings = SettingsRepository(database: try Database(url: t.dbURL))
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    f.putLegacy("host-ref", "pw")
    let host = HostProfile(displayName: "h", credentialReference: "host-ref")

    // DB lỗi -> không đặt cờ, không đụng item.
    let failedLoad = await CredentialMigration.runIfNeeded(store: store, settings: settings) {
        throw LoadFailure()
    }
    #expect(failedLoad?.failed == 1)
    #expect(!settings.flag(CredentialMigration.flagKey))
    #expect(f.legacy.exists(account: "host-ref"))

    // Ghi sealed lỗi -> không đặt cờ.
    f.sealed.failWrites = true
    let r1 = await CredentialMigration.runIfNeeded(store: store, settings: settings) { ([host], []) }
    #expect(r1?.failed == 1 && !settings.flag(CredentialMigration.flagKey))
    f.sealed.failWrites = false

    // Thành công -> đặt cờ; cờ không bị SettingsRepository.save ghi đè; lần sau bỏ qua.
    let r2 = await CredentialMigration.runIfNeeded(store: store, settings: settings) { ([host], []) }
    #expect(r2?.migrated == 1 && r2?.failed == 0)
    #expect(settings.flag(CredentialMigration.flagKey))
    try settings.save(.default)
    #expect(settings.flag(CredentialMigration.flagKey))
    #expect(f.backend.read(account: "host-ref") == "pw")
    let r3 = await CredentialMigration.runIfNeeded(store: store, settings: settings) { throw LoadFailure() }
    #expect(r3 == nil)
}

@Test func runIfNeededWithoutSecureEnclaveReturnsNilAndNoFlag() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let settings = SettingsRepository(database: try Database(url: t.dbURL))
    let f = Fixture(available: false)
    f.putLegacy("host-ref", "pw")
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    let r = await CredentialMigration.runIfNeeded(store: store, settings: settings) { ([], []) }
    #expect(r == nil && !settings.flag(CredentialMigration.flagKey))
    #expect(f.legacy.exists(account: "host-ref"))
}

// MARK: - ADR-004d: không hỏi Keychain lặp lại

@Test func statusIsReadFromStorageOnlyOnce() throws {
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    try store.save(ref: "r", password: "pw")
    #expect(store.cachedStatus(ref: "r") == nil)  // save xoá mục nhớ
    let before = f.sealed.reads
    for _ in 0..<5 { #expect(store.status(ref: "r") == .present) }
    #expect(f.sealed.reads - before == 1)
    #expect(store.cachedStatus(ref: "r") == .present)
    // exists không giải mã và không làm thay đổi bộ nhớ.
    #expect(store.exists(ref: "r"))
    #expect(f.sealed.reads - before == 1)
}

@Test func keyBlobIsReadOnceAcrossReadsAndStatuses() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    try f.backend.save(account: "b", secret: "B")
    let b = f.restarted()
    let before = f.keys.reads
    #expect(b.read(account: "a") == "A")
    #expect(b.read(account: "b") == "B")
    #expect(b.status(account: "a") == .present)
    try b.save(account: "c", secret: "C")  // keyForSaving cũng dùng khoá đã nhớ
    #expect(f.keys.reads - before == 1)
}

@Test func keyReadFailureIsNotRemembered() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    let b = f.restarted()
    f.keys.readError = -25293
    #expect(b.status(account: "a") == .undecryptable)
    #expect(b.status(account: "a") == .undecryptable)  // lỗi: thử đọc lại, không nhớ
    f.keys.readError = nil
    #expect(b.status(account: "a") == .present)
    let before = f.keys.reads
    #expect(b.read(account: "a") == "A")
    #expect(f.keys.reads == before)  // đã nhớ sau lần đọc thành công
}

@Test func saveDeleteInvalidateAndReadUpdatesRememberedStatus() throws {
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    #expect(store.read(ref: "r") == nil)
    #expect(store.cachedStatus(ref: "r") == .missing)
    try store.save(ref: "r", password: "pw")
    #expect(store.cachedStatus(ref: "r") == nil)
    #expect(store.read(ref: "r") == "pw")
    #expect(store.cachedStatus(ref: "r") == .present)
    try store.delete(ref: "r")
    #expect(store.cachedStatus(ref: "r") == nil)
    // Đọc thật phát hiện undecryptable (khoá đã mất) và nhớ lại.
    try store.save(ref: "r", password: "pw")
    try f.keys.delete(account: "default")
    let store2 = SecureEnclaveCredentialStore(backend: f.restarted())
    #expect(store2.cachedStatus(ref: "r") == nil)
    #expect(store2.read(ref: "r") == nil)
    #expect(store2.cachedStatus(ref: "r") == .undecryptable)
}

@Test func wrappersForwardCachedStatusAndOthersDefaultToNil() throws {
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    try store.save(ref: "r", password: "pw")
    _ = store.status(ref: "r")
    let gated = AutofillGatedCredentialStore(base: store) { true }
    #expect(gated.cachedStatus(ref: "r") == .present)
    let overlay = EphemeralOverlayCredentialStore(base: store, vault: EphemeralPasswordVault())
    #expect(overlay.cachedStatus(ref: "r") == .present)
    #expect(InMemoryCredentialStore().cachedStatus(ref: "r") == nil)
}

@Test func noViewFileAsksStoreForStatus() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/SSHDesk")
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects
    let files = (all as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    #expect(files.count > 10)
    var offenders: [String] = []
    for file in files where file.lastPathComponent != "AppModel.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        if text.contains(".status(ref:") { offenders.append(file.lastPathComponent) }
    }
    #expect(offenders.isEmpty, "\(offenders)")
    // needsReauth / setNeedsReauth chỉ đọc trạng thái đã nhớ.
    let model = try String(contentsOf: root.appendingPathComponent("AppModel.swift"), encoding: .utf8)
    #expect(!model.contains("credentials.status(ref:"))
    #expect(model.contains("credentials.cachedStatus(ref: ref)"))
}

// MARK: Làm mới quyền Keychain

@Test func refreshAccessRewritesKeyAndCiphertextKeepingValues() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    try f.backend.save(account: "b", secret: "B")
    let blob = f.keys.readData(account: "default")
    let ctA = f.sealed.readData(account: "a")
    let report = f.backend.refreshAccess(accounts: ["a", "b", "ghost", "a"])
    #expect(report.key == .refreshed)
    #expect(report.refreshed == 2 && report.skipped == 1 && report.failed == 0)
    #expect(f.keys.accounts == ["default"])  // bản tạm đã xoá
    #expect(f.keys.readData(account: "default") == blob)
    #expect(f.sealed.readData(account: "a") == ctA)
    #expect(f.keys.modes["default"]?.last == .replace)
    #expect(f.sealed.modes["a"]?.last == .replace)
    #expect(f.restarted().read(account: "a") == "A")
    #expect(f.restarted().read(account: "b") == "B")
}

@Test func refreshAccessWithoutAnyKeyIsAbsent() throws {
    let f = Fixture()
    let report = f.backend.refreshAccess(accounts: ["a"])
    #expect(report.key == .absent && report.skipped == 1 && f.keys.accounts.isEmpty)
}

@Test func refreshFailureWritingTempCopyKeepsKeyUntouched() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    let blob = f.keys.readData(account: "default")
    f.keys.failingAccounts = ["default-refresh"]
    let report = f.backend.refreshAccess(accounts: ["a"])
    #expect(report.key == .failed)
    #expect(f.keys.readData(account: "default") == blob)
    #expect(f.restarted().read(account: "a") == "A")
}

@Test func refreshFailureWritingNewDefaultKeepsTempCopyAndRecovers() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    let blob = f.keys.readData(account: "default")
    f.keys.failingAccounts = ["default"]  // `.replace` xoá `default` rồi lỗi khi thêm
    let report = f.backend.refreshAccess(accounts: [])
    #expect(report.key == .failed)
    #expect(f.keys.readData(account: "default") == nil)
    #expect(f.keys.readData(account: "default-refresh") == blob)
    // Lần dùng sau (tiến trình mới): khôi phục từ bản tạm, không tạo khoá mới.
    f.keys.failingAccounts = []
    let b = f.restarted()
    #expect(b.read(account: "a") == "A")
    #expect(f.keys.readData(account: "default") == blob)
    #expect(!f.keys.exists(account: "default-refresh"))
}

@Test func refreshReadBackMismatchKeepsGoodCopy() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    let blob = f.keys.readData(account: "default")
    f.keys.onWrite = { account, data in account == "default" ? Data(data.dropLast()) : data }
    #expect(f.backend.refreshAccess(accounts: []).key == .failed)
    f.keys.onWrite = nil
    #expect(f.keys.readData(account: "default-refresh") == blob)
    // `default` đang hỏng (31 byte) -> khôi phục từ bản tạm.
    #expect(f.restarted().read(account: "a") == "A")
    #expect(f.keys.readData(account: "default") == blob)
}

@Test func recoveryFromTempCopyHappensBeforeSavingNewKey() throws {
    let f = Fixture()
    try f.backend.save(account: "old", secret: "pw")
    let blob = f.keys.readData(account: "default")!
    try f.keys.delete(account: "default")
    f.keys.put("default-refresh", blob)
    let b = f.restarted()
    try b.save(account: "new", secret: "n")  // không được sinh khoá mới
    #expect(f.keys.readData(account: "default") == blob)
    #expect(b.read(account: "old") == "pw")
    #expect(b.read(account: "new") == "n")
}

@Test func refreshWithUnreadableKeyChangesNothing() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    f.keys.readError = -25293
    let report = f.backend.refreshAccess(accounts: ["a"])
    #expect(report.key == .failed)
    f.keys.readError = nil
    #expect(f.keys.accounts == ["default"])
}

@Test func refreshCiphertextWriteFailureCountsFailedAndKeepsItem() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    try f.backend.save(account: "b", secret: "B")
    f.sealed.failWrites = true
    let report = f.backend.refreshAccess(accounts: ["a", "b"])
    #expect(report.refreshed == 0 && report.failed == 2)
    f.sealed.failWrites = false
    #expect(f.restarted().read(account: "a") == "A")
    #expect(f.restarted().read(account: "b") == "B")
}

@Test func storeRefreshClearsRememberedStatus() throws {
    let f = Fixture()
    let store = SecureEnclaveCredentialStore(backend: f.backend)
    try store.save(ref: "r", password: "pw")
    _ = store.status(ref: "r")
    #expect(store.cachedStatus(ref: "r") == .present)
    let report = store.refreshAccess(refs: ["r"])
    #expect(report.refreshed == 1)
    #expect(store.cachedStatus(ref: "r") == nil)
}

@Test func refreshWithCorruptDefaultUsesGoodTempCopyEvenWithKeyCachedInMemory() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")  // khoá còn trong RAM của f.backend
    let blob = try #require(f.keys.readData(account: "default"))
    f.keys.put("default-refresh", blob)
    f.keys.put("default", Data([1, 2, 3]))
    let report = f.backend.refreshAccess(accounts: ["a"])
    #expect(report.key == .refreshed)
    #expect(f.keys.readData(account: "default") == blob)
    #expect(f.keys.readData(account: "default-refresh") == nil)
    #expect(f.restarted().read(account: "a") == "A")
}

@Test func refreshWithBothKeyBlobsCorruptWritesNothing() throws {
    let f = Fixture()
    try f.backend.save(account: "a", secret: "A")
    f.keys.put("default", Data([1, 2, 3]))
    f.keys.put("default-refresh", Data([4, 5]))
    #expect(f.backend.refreshAccess(accounts: []).key == .failed)
    #expect(f.keys.readData(account: "default") == Data([1, 2, 3]))
    #expect(f.keys.readData(account: "default-refresh") == Data([4, 5]))
}
