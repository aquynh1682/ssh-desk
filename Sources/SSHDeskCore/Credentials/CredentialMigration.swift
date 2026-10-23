import CredentialBackend
import Foundation

/// Migration một lần từ Keychain plaintext sang sealed (ADR-004c). Chỉ app gọi, không phải helper.
/// Không log giá trị; lỗi → giữ item cũ, lần khởi động sau thử lại.
public enum CredentialMigration {
    /// Cờ trong bảng `settings` khi mọi tham chiếu đã chuyển xong.
    public static let flagKey = "credential_migration_se1"

    /// Mọi tham chiếu trong DB: password riêng của host, `set-<id>`, `setkey-<id>`.
    public static func references(hosts: [HostProfile], sets: [CredentialSet]) -> [String] {
        var refs = hosts.compactMap { $0.credentialReference }.filter { !$0.isEmpty }
        for set in sets { refs += [set.passwordReference, set.passphraseReference] }
        return Array(Set(refs)).sorted()
    }

    /// nil nếu đã chạy xong từ trước (cờ) hoặc máy không có Secure Enclave.
    @discardableResult
    public static func runIfNeeded(
        store: SecureEnclaveCredentialStore, repository: HostRepository, settings: SettingsRepository
    ) async -> SealedMigrationReport? {
        await runIfNeeded(store: store, settings: settings) {
            (try await repository.all(), try await repository.credentialSets())
        }
    }

    /// Đọc DB lỗi → không đặt cờ (lần khởi động sau quét lại), trả báo cáo `failed = 1`.
    static func runIfNeeded(
        store: SecureEnclaveCredentialStore, settings: SettingsRepository,
        load: () async throws -> ([HostProfile], [CredentialSet])
    ) async -> SealedMigrationReport? {
        if settings.flag(flagKey) { return nil }
        let backend = store.backend
        guard backend.isAvailable else { return nil }
        let refs: [String]
        do {
            let (hosts, sets) = try await load()
            refs = references(hosts: hosts, sets: sets)
        } catch {
            var failed = SealedMigrationReport()
            failed.failed = 1
            return failed
        }
        let report = await Task.detached(priority: .utility) { backend.migrateLegacy(accounts: refs) }.value
        if report.failed == 0 { try? settings.setFlag(flagKey) }
        return report
    }
}
