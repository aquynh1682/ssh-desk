import CredentialBackend
import Foundation

/// Migration một lần từ Keychain plaintext sang sealed (ADR-004c). Chỉ app gọi, không phải helper.
/// Không log giá trị; lỗi → giữ item cũ, lần khởi động sau thử lại.
public enum CredentialMigration {
    /// Cờ trong bảng `settings` khi mọi tham chiếu đã chuyển xong.
    public static let flagKey = "credential_migration_se1"

    /// Mọi tham chiếu trong DB: password riêng của host, `set-<id>`, `setkey-<id>`.
    public static func references(
        hosts: [HostProfile], sets: [CredentialSet], metricSources: [MetricsSource] = []
    ) -> [String] {
        var refs = hosts.compactMap { $0.credentialReference }.filter { !$0.isEmpty }
        for set in sets { refs += [set.passwordReference, set.passphraseReference] }
        // Token/password nguồn số liệu (ADR-028): chưa từng có bản plaintext nên thường là no-op, nhưng
        // nếu có item cũ cùng ref thì cũng được chuyển.
        refs += metricSources.compactMap(\.credentialRef)
        return Array(Set(refs)).sorted()
    }

    /// nil nếu đã chạy xong từ trước (cờ) hoặc máy không có Secure Enclave.
    @discardableResult
    public static func runIfNeeded(
        store: SecureEnclaveCredentialStore, repository: HostRepository, settings: SettingsRepository,
        metricSources: MetricSourceRepository? = nil
    ) async -> SealedMigrationReport? {
        await runIfNeeded(store: store, settings: settings) {
            (try await repository.all(), try await repository.credentialSets())
        } metricRefs: {
            try (metricSources?.all() ?? []).compactMap(\.credentialRef)
        }
    }

    /// Đọc DB lỗi → không đặt cờ (lần khởi động sau quét lại), trả báo cáo `failed = 1`.
    static func runIfNeeded(
        store: SecureEnclaveCredentialStore, settings: SettingsRepository,
        load: () async throws -> ([HostProfile], [CredentialSet]),
        metricRefs: () throws -> [String] = { [] }
    ) async -> SealedMigrationReport? {
        if settings.flag(flagKey) { return nil }
        let backend = store.backend
        guard backend.isAvailable else { return nil }
        let refs: [String]
        do {
            let (hosts, sets) = try await load()
            refs = Array(Set(references(hosts: hosts, sets: sets) + (try metricRefs()))).sorted()
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
