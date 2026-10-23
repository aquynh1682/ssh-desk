import Foundation

public enum ConnectionServiceError: Error, Equatable {
    /// Hồ sơ imported thiếu alias.
    case missingAlias
    /// Hồ sơ imported: app không sửa (cấu hình nằm trong `~/.ssh/config` của người dùng).
    case importedHostReadOnly
    case hostNotFound
    /// Thao tác chỉ dành cho máy Linux/SSH, nhưng host là máy Windows.
    case notSSHHost
    /// Thao tác chỉ dành cho máy Windows.
    case notWindowsHost
    /// Không có kho Keychain (không thể xoá mật khẩu thật).
    case credentialsUnavailable
    /// Bộ đã xoá khỏi DB nhưng `count` mục trong kho (Keychain) không xoá được.
    case setDeletedButKeychainFailed(count: Int)
}

/// Kết quả import: hồ sơ mới tạo và alias bị bỏ qua vì đã import từ cùng file.
public struct ImportOutcome: Sendable, Equatable {
    public var imported: [HostProfile]
    public var skippedAliases: [String]
}

/// Kết quả copy mật khẩu Windows lên clipboard (ADR-018). Không chứa mật khẩu.
public enum PasswordCopyOutcome: Sendable, Equatable {
    /// Không có mật khẩu lưu (hoặc không áp dụng): không làm gì.
    case none
    case copied
    /// Cài đặt "tự điền mật khẩu đã lưu" đang tắt: không copy (ADR-021).
    case disabled
    /// Host đang bị hold tự điền (ADR-026/030): không copy cho tới khi người dùng xác nhận.
    case held
    case failed(String)
}

/// Kết quả "Xoá mọi mật khẩu đã lưu" (ADR-021). Không chứa mật khẩu.
public struct PasswordPurgeResult: Sendable, Equatable {
    /// Số host đã gỡ tham chiếu.
    public var removed: Int
    /// Số host không xoá được (Keychain/DB lỗi); tham chiếu của các host này được giữ nguyên để thử lại.
    public var failed: Int
    /// Số item Keychain của bộ đăng nhập (`set-*`, `setkey-*`) đã xoá (bộ và việc gán được giữ, ADR-030).
    public var setItemsRemoved = 0
    /// Số item của bộ đăng nhập không xoá được.
    public var setItemsFailed = 0
}

public struct WindowsOpenReport: Sendable, Equatable {
    public var result: RDPLaunchResult
    public var passwordCopy: PasswordCopyOutcome
}

/// Nối HostRepository, SSH config của app và WarpLauncher. Không chạy ssh, không mở mạng.
public actor ConnectionService {
    public let repository: HostRepository
    public let appConfigURL: URL
    private let userConfigPath: String?
    private let settings: SettingsStore?
    private let launcher: WarpLauncher
    private let rdpLauncher: WindowsAppLauncher
    private let credentials: (any CredentialStore)?
    private let secretClipboard: SecretClipboard?
    private let askpassHelper: URL?
    private let now: @Sendable () -> Date

    /// `userConfigPath`: nil = không `Include`. Chỉ truyền đường dẫn file đang tồn tại
    /// (xem `AppPaths.existingUserConfigPath()`). Khi có `settings`, đường dẫn Include lấy từ cài đặt
    /// (mỗi lần sinh config) và `userConfigPath` bị bỏ qua.
    public init(
        repository: HostRepository, appConfigURL: URL, userConfigPath: String?,
        launcher: WarpLauncher, rdpLauncher: WindowsAppLauncher = WindowsAppLauncher(),
        credentials: (any CredentialStore)? = nil, secretClipboard: SecretClipboard? = nil,
        askpassHelper: URL? = nil, settings: SettingsStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.credentials = credentials
        self.secretClipboard = secretClipboard
        self.askpassHelper = askpassHelper
        self.repository = repository
        self.appConfigURL = appConfigURL
        self.userConfigPath = userConfigPath
        self.launcher = launcher
        self.rdpLauncher = rdpLauncher
        self.now = now
    }

    // MARK: - SSH config

    public func regenerateSSHConfig() async throws {
        try SSHConfigWriter.write(
            to: appConfigURL,
            hosts: try await repository.sshSpecs(
                defaultIdentityAgent: settings?.current.defaultIdentityAgent),
            userConfigPath: effectiveUserConfigPath)
    }

    /// Đường dẫn config người dùng được `Include` ngay lúc này.
    private var effectiveUserConfigPath: String? {
        if let settings { return settings.current.effectiveUserConfigPath() }
        return userConfigPath
    }

    public func sshArguments(for host: HostProfile) throws -> [String] {
        try SSHConfigWriter.sshInvocation(configPath: appConfigURL.path, alias: try alias(of: host))
    }

    /// Lệnh để COPY: luôn là lệnh ssh thường, không askpass — người dùng có thể chạy nó ở terminal khác,
    /// nơi helper/Keychain của app không áp dụng (và biến môi trường không nên rò sang đó).
    public func copyableSSHCommand(for host: HostProfile) throws -> String {
        try ZshQuoting.sshCommand(
            sshPath: "/usr/bin/ssh", configPath: appConfigURL.path, alias: try alias(of: host))
    }

    /// Lệnh chạy trong Tab Config của Warp. Có password / passphrase đã lưu (và có helper) -> dùng SSH_ASKPASS.
    /// Password hiệu lực = riêng của host > bộ đăng nhập (ADR-030); passphrase chỉ khi key lấy từ bộ.
    /// `notice` giải thích khi phải dùng lệnh thường dù host có mật khẩu lưu.
    public func warpSSHCommand(for host: HostProfile) async throws -> (command: String, notice: String?) {
        let plain = try copyableSSHCommand(for: host)
        // Đọc lại host để lấy bộ đăng nhập / hold mới nhất (bản của UI có thể cũ).
        let current = (try? await repository.host(id: host.id)) ?? host
        let resolved = try? await repository.resolvedCredentials(for: current)
        let passwordRef = current.effectiveCredentialReference.flatMap {
            credentials?.exists(ref: $0) == true ? $0 : nil
        }
        var passphrase: (ref: String, keyPath: String)?
        if let r = resolved, let ref = r.passphraseRef, let path = r.passphraseKeyPath,
            credentials?.exists(ref: ref) == true
        {
            passphrase = (ref, path)
        }
        guard passwordRef != nil || passphrase != nil else { return (plain, nil) }
        // Hold (ADR-026/030): không đặt SSHDESK_HOST_REF/KEY_REF, ssh hỏi ngay trong Warp.
        if current.autofillHold {
            return (
                plain,
                "Đang tạm tắt tự điền mật khẩu cho máy này — mở chi tiết máy để xác nhận. Nhập mật khẩu trong Warp."
            )
        }
        // Tắt tự điền: không đặt SSHDESK_HOST_REF/SSH_ASKPASS, ssh hỏi mật khẩu ngay trong Warp.
        if let settings, !settings.current.autofillEnabled {
            return (plain, "Đang tắt tự điền mật khẩu (Cài đặt) — nhập mật khẩu trong Warp.")
        }
        guard let helper = askpassHelper else {
            return (plain, "Không tìm thấy helper đăng nhập tự động — nhập mật khẩu trong Warp.")
        }
        // ProxyJump chạy ssh con dùng chung biến môi trường: tránh gửi password của host đích cho bastion.
        if current.jumpHostID != nil {
            return (plain, "Host dùng bastion: không đăng nhập tự động bằng mật khẩu, nhập trong Warp.")
        }
        let command = try ZshQuoting.askpassSshCommand(
            helperPath: helper.path, hostRef: passwordRef, keyRef: passphrase?.ref,
            keyPath: passphrase.flatMap { $0.keyPath.isEmpty ? nil : $0.keyPath },
            sshPath: "/usr/bin/ssh", configPath: appConfigURL.path, alias: try alias(of: host))
        return (command, nil)
    }

    // MARK: - Mật khẩu đã lưu (Keychain)

    /// Có password hiệu lực đã lưu không (riêng của host hoặc từ bộ đăng nhập, ADR-030). Chỉ để hiển thị:
    /// không bị hold chặn (hold chỉ chặn việc TỰ ĐIỀN).
    public func hasStoredPassword(_ host: HostProfile) -> Bool {
        guard let ref = host.effectiveCredentialReference, let credentials else { return false }
        return credentials.exists(ref: ref)
    }

    /// Ghi password vào Keychain (tạo credentialReference nếu chưa có) rồi lưu tham chiếu vào hồ sơ.
    @discardableResult
    public func savePassword(hostID: UUID, password: String) async throws -> HostProfile {
        guard let credentials else { throw CredentialStoreError.invalidReference }
        guard var host = try await repository.host(id: hostID) else {
            throw HostRepositoryError.notFound(hostID)
        }
        let created = host.credentialReference == nil
        let ref = host.credentialReference ?? UUID().uuidString.lowercased()
        try credentials.save(ref: ref, password: password)
        if created {
            host.credentialReference = ref
            do { host = try await repository.update(host) } catch {
                try? credentials.delete(ref: ref)
                throw error
            }
        }
        return host
    }

    /// Xoá item Keychain và bỏ tham chiếu khỏi hồ sơ.
    @discardableResult
    public func clearPassword(hostID: UUID) async throws -> HostProfile {
        guard var host = try await repository.host(id: hostID) else {
            throw HostRepositoryError.notFound(hostID)
        }
        if let ref = host.credentialReference {
            try credentials?.delete(ref: ref)
            host.credentialReference = nil
            host = try await repository.update(host)
        }
        return host
    }

    /// Nhân bản mật khẩu: đọc từ item của `sourceID`, ghi thành item Keychain MỚI (ref mới) cho `hostID`.
    /// Không có password gốc thì không làm gì. Password chỉ đi qua biến cục bộ.
    @discardableResult
    public func copyPassword(from sourceID: UUID, to hostID: UUID) async throws -> HostProfile? {
        guard let credentials,
            let source = try await repository.host(id: sourceID),
            let sourceRef = source.credentialReference,
            let password = credentials.read(ref: sourceRef)
        else { return nil }
        return try await savePassword(hostID: hostID, password: password)
    }

    /// Số mục mật khẩu đã lưu: host có tham chiếu riêng + item Keychain của bộ đăng nhập (password và passphrase).
    public func savedPasswordCount() async throws -> Int {
        let own = try await repository.all().filter { ($0.credentialReference ?? "").isEmpty == false }.count
        guard let credentials else { return own }
        let sets = try await repository.credentialSets().reduce(0) { count, set in
            count + (credentials.exists(ref: set.passwordReference) ? 1 : 0)
                + (credentials.exists(ref: set.passphraseReference) ? 1 : 0)
        }
        return own + sets
    }

    /// Xoá mọi item Keychain theo tham chiếu của từng host rồi gỡ tham chiếu khỏi hồ sơ (ADR-021).
    /// Chỉ chạm item của app (theo `credentialReference` từng host + account tất định của từng bộ), không quét Keychain.
    public func clearAllPasswords() async throws -> PasswordPurgeResult {
        var result = PasswordPurgeResult(removed: 0, failed: 0)
        let hosts = try await repository.all().filter { ($0.credentialReference ?? "").isEmpty == false }
        // Không có kho Keychain thì không được gỡ tham chiếu (sẽ mồ côi item thật).
        if !hosts.isEmpty, credentials == nil { throw ConnectionServiceError.credentialsUnavailable }
        for host in hosts {
            guard let ref = host.credentialReference, let credentials else { continue }
            do {
                try credentials.delete(ref: ref)
                var updated = host
                updated.credentialReference = nil
                _ = try await repository.update(updated)
                result.removed += 1
            } catch {
                result.failed += 1
            }
        }
        // Item của mọi bộ đăng nhập (account tất định). Giữ bộ và việc gán: bộ chỉ trở thành "chưa có mật khẩu".
        if let credentials {
            for set in try await repository.credentialSets() {
                for ref in [set.passwordReference, set.passphraseReference] {
                    // Xoá cả ciphertext lẫn item plaintext cũ còn sót (ADR-004c); chỉ đếm khi có mật khẩu.
                    let had = credentials.exists(ref: ref)
                    do {
                        try credentials.delete(ref: ref)
                        if had { result.setItemsRemoved += 1 }
                    } catch {
                        result.setItemsFailed += 1
                    }
                }
            }
        }
        return result
    }

    /// File key hiệu lực (của host hoặc bộ) không tồn tại → đường dẫn đó. Chỉ `fileExists`, không đọc nội dung.
    public func missingKeyFile(
        for host: HostProfile, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) async -> String? {
        guard host.kind == .ssh, host.connectionMode == .managed,
            let resolved = try? await repository.resolvedCredentials(for: host),
            let file = resolved.identityFile
        else { return nil }
        return exists(CredentialResolution.expandTilde(file, home: NSHomeDirectory())) ? nil : file
    }

    private func alias(of host: HostProfile) throws -> String {
        guard let alias = repository.sshAlias(for: host) else {
            throw ConnectionServiceError.missingAlias
        }
        return alias
    }

    // MARK: - Bộ đăng nhập (ADR-030)

    /// Tạo bộ, tuỳ chọn lưu password/passphrase vào Keychain (account tất định). Lỗi Keychain → bỏ bộ vừa tạo.
    @discardableResult
    public func createCredentialSet(_ set: CredentialSet, password: String? = nil, passphrase: String? = nil)
        async throws -> CredentialSet
    {
        if password?.isEmpty == false || passphrase?.isEmpty == false, credentials == nil {
            throw ConnectionServiceError.credentialsUnavailable
        }
        let created = try await repository.createCredentialSet(set)
        do {
            if let password, !password.isEmpty {
                try credentials?.save(ref: created.passwordReference, password: password)
            }
            if let passphrase, !passphrase.isEmpty {
                try credentials?.save(ref: created.passphraseReference, password: passphrase)
            }
            try await regenerateSSHConfig()
        } catch {
            _ = try? await repository.deleteCredentialSet(id: created.id)
            try? credentials?.delete(ref: created.passwordReference)
            try? credentials?.delete(ref: created.passphraseReference)
            throw error
        }
        return created
    }

    /// Sửa bộ (tên, user, key, agent, ghi chú) và sinh lại config: mọi host dùng bộ nhận giá trị mới.
    @discardableResult
    public func updateCredentialSet(_ set: CredentialSet) async throws -> CredentialSet {
        let saved = try await repository.updateCredentialSet(set)
        try await regenerateSSHConfig()
        return saved
    }

    /// Đặt / đổi password của bộ (áp cho mọi host dùng bộ ngay vì ref tất định).
    public func saveSetPassword(setID: UUID, password: String) async throws {
        guard let credentials else { throw ConnectionServiceError.credentialsUnavailable }
        guard let set = try await repository.credentialSet(id: setID) else {
            throw CredentialSetError.notFound(setID)
        }
        try credentials.save(ref: set.passwordReference, password: password)
    }

    public func saveSetPassphrase(setID: UUID, passphrase: String) async throws {
        guard let credentials else { throw ConnectionServiceError.credentialsUnavailable }
        guard let set = try await repository.credentialSet(id: setID) else {
            throw CredentialSetError.notFound(setID)
        }
        try credentials.save(ref: set.passphraseReference, password: passphrase)
    }

    public func clearSetPassword(setID: UUID) throws {
        try credentials?.delete(ref: CredentialSet.passwordReference(for: setID))
    }

    public func clearSetPassphrase(setID: UUID) throws {
        try credentials?.delete(ref: CredentialSet.passphraseReference(for: setID))
    }

    public func hasSetPassword(_ setID: UUID) -> Bool {
        credentials?.exists(ref: CredentialSet.passwordReference(for: setID)) ?? false
    }

    public func hasSetPassphrase(_ setID: UUID) -> Bool {
        credentials?.exists(ref: CredentialSet.passphraseReference(for: setID)) ?? false
    }

    /// Xoá bộ: gỡ khỏi host (một transaction) rồi xoá item Keychain, sinh lại config. Trả id host bị ảnh hưởng.
    @discardableResult
    public func deleteCredentialSet(id: UUID) async throws -> [UUID] {
        let affected = try await repository.deleteCredentialSet(id: id)
        var failed = 0
        for ref in [CredentialSet.passwordReference(for: id), CredentialSet.passphraseReference(for: id)] {
            guard let credentials, credentials.exists(ref: ref) else { continue }
            do { try credentials.delete(ref: ref) } catch { failed += 1 }
        }
        try await regenerateSSHConfig()
        if failed > 0 { throw ConnectionServiceError.setDeletedButKeychainFailed(count: failed) }
        return affected
    }

    /// Gán (hoặc gỡ) bộ cho nhiều host. Gán bằng tay → không hold. Sinh lại config.
    @discardableResult
    public func assignCredentialSet(setID: UUID?, to hostIDs: [UUID]) async throws -> Int {
        let n = try await repository.assignCredentialSet(setID: setID, to: hostIDs)
        try await regenerateSSHConfig()
        return n
    }

    /// Người dùng xác nhận địa chỉ / bộ đăng nhập → bỏ hold tự điền (ADR-026).
    public func confirmAutofillHold(hostID: UUID) async throws {
        try await repository.confirmAutofillHold(id: hostID)
    }

    // MARK: - CRUD (luôn sinh lại config)

    public func add(_ host: HostProfile) async throws {
        try await repository.insert(host)
        try await regenerateSSHConfig()
    }

    @discardableResult
    public func update(_ host: HostProfile) async throws -> HostProfile {
        let saved = try await repository.update(host)
        try await regenerateSSHConfig()
        return saved
    }

    /// Đổi host managed sang xác thực bằng key file (sau khi cài key). Host imported: từ chối, không sửa.
    @discardableResult
    public func useKey(hostID: UUID, privateKeyPath: String) async throws -> HostProfile {
        guard var host = try await repository.host(id: hostID) else { throw ConnectionServiceError.hostNotFound }
        guard host.kind == .ssh else { throw ConnectionServiceError.notSSHHost }
        guard host.connectionMode == .managed else { throw ConnectionServiceError.importedHostReadOnly }
        host.authMethod = .keyFile
        host.identityFile = privateKeyPath
        return try await update(host)
    }

    public func delete(id: UUID) async throws {
        let stored = try await repository.host(id: id)
        let ref = stored?.credentialReference
        try await repository.delete(id: id)
        if let ref { try? credentials?.delete(ref: ref) }
        try await regenerateSSHConfig()
        if stored?.kind == .windowsRDP {
            try rdpLauncher.removeFile(hostID: id)
        } else {
            try launcher.removeConfig(hostID: id)
        }
    }

    // MARK: - Warp

    /// `newWindow`: nil = theo cài đặt "Warp mở Tab mới / Cửa sổ mới".
    public func openInWarp(_ host: HostProfile, newWindow: Bool? = nil) async -> LaunchResult {
        await openInWarpReport(host, newWindow: newWindow).result
    }

    public struct WarpOpenReport: Sendable, Equatable {
        public var result: LaunchResult
        /// Lý do không đăng nhập tự động được (nếu host có mật khẩu lưu).
        public var notice: String?
    }

    public func openInWarpReport(_ host: HostProfile, newWindow: Bool? = nil) async -> WarpOpenReport {
        let newWindow = newWindow ?? settings?.current.warpOpenMode.opensNewWindow ?? false
        var notice: String?
        guard host.kind == .ssh else {
            return WarpOpenReport(result: .failed("Máy Windows không mở bằng Warp."), notice: nil)
        }
        do {
            try host.validate(credentialSet: try await repository.credentialSet(for: host))
            try await regenerateSSHConfig()
            let (command, why) = try await warpSSHCommand(for: host)
            notice = why
            if let missing = await missingKeyFile(for: host) {
                notice = [why, "Không thấy file key \(missing)."].compactMap { $0 }.joined(separator: " ")
            }
            let result = await launcher.launch(
                hostID: host.id, displayName: host.displayName, sshCommand: command,
                newWindow: newWindow)
            if result == .requested {
                try await repository.markLaunchRequested(id: host.id, at: now())
            }
            return WarpOpenReport(result: result, notice: notice)
        } catch {
            return WarpOpenReport(result: .failed("\(error)"), notice: nil)
        }
    }

    // MARK: - Windows App (RDP)

    /// Sinh file .rdp rồi nhờ Windows App mở. Ghi `lastLaunchRequestedAt` khi `.requested`.
    public func openInWindowsApp(_ host: HostProfile) async -> RDPLaunchResult {
        await openInWindowsAppReport(host).result
    }

    /// Như `openInWindowsApp`; khi `.requested` và host có mật khẩu lưu thì copy mật khẩu lên clipboard
    /// (đọc Keychain tại đây, không đi qua view). Chỉ máy Windows, đúng một lần mỗi lần mở.
    public func openInWindowsAppReport(_ host: HostProfile) async -> WindowsOpenReport {
        guard host.kind == .windowsRDP else {
            return WindowsOpenReport(result: .failed("Đây không phải máy Windows."), passwordCopy: .none)
        }
        let result = await rdpLauncher.launch(host)
        guard result == .requested else { return WindowsOpenReport(result: result, passwordCopy: .none) }
        do { try await repository.markLaunchRequested(id: host.id, at: now()) } catch {
            return WindowsOpenReport(result: .failed("\(error)"), passwordCopy: .none)
        }
        return WindowsOpenReport(result: result, passwordCopy: await copyStoredWindowsPassword(host))
    }

    /// Copy mật khẩu đã lưu của máy Windows lên clipboard (tự xoá sau 30 giây). Host SSH: `.failed`.
    public func copyStoredWindowsPassword(_ host: HostProfile) async -> PasswordCopyOutcome {
        guard host.kind == .windowsRDP else { return .failed("Đây không phải máy Windows.") }
        guard let credentials, let secretClipboard else { return .none }
        let current = settings?.current
        if let current, !current.autofillEnabled { return .disabled }
        // Đọc lại host: bộ đăng nhập và hold có thể đã đổi từ lúc UI nạp.
        let fresh = (try? await repository.host(id: host.id)) ?? host
        if fresh.autofillHold, fresh.effectiveCredentialReference != nil { return .held }
        guard let ref = fresh.autofillCredentialReference else { return .none }
        guard let password = credentials.read(ref: ref) else {
            return credentials.exists(ref: ref)
                ? .failed("Không đọc được mật khẩu từ Keychain.") : .none
        }
        secretClipboard.copy(
            password, clearAfter: TimeInterval(current?.clipboardClearSeconds ?? 30))
        return .copied
    }

    /// Ghi file .rdp (không mở app) để hiện trong Finder.
    public func prepareRDPFile(for host: HostProfile) throws -> URL {
        guard host.kind == .windowsRDP else { throw ConnectionServiceError.notWindowsHost }
        return try rdpLauncher.prepare(host)
    }

    // MARK: - Nhập từ file (ADR-020)

    /// Ghi kế hoạch nhập (một transaction) rồi sinh lại SSH config của app.
    public func applyImport(_ plan: HostExchange.Plan) async throws {
        try await repository.applyImport(plan)
        try await regenerateSSHConfig()
    }

    // MARK: - Nguồn máy chủ (ADR-026)

    /// Áp dụng kế hoạch đồng bộ (một transaction) rồi sinh lại SSH config của app.
    public func applyInventory(_ plan: InventorySyncPlan) async throws {
        try await repository.applyInventory(plan)
        try await regenerateSSHConfig()
    }

    /// Xoá nguồn (gỡ liên kết khỏi host, không xoá host). SSH config không đổi.
    @discardableResult
    public func deleteInventorySource(id: UUID) async throws -> Int {
        try await repository.deleteInventorySource(id: id)
    }

    /// "Tách khỏi nguồn".
    public func detachFromSource(hostID: UUID) async throws {
        try await repository.detachFromSource(hostID: hostID)
    }

    // MARK: - Import

    public func importAliases(_ candidates: [ImportCandidate], sourcePath: String) async throws
        -> ImportOutcome
    {
        var existing = Set(
            try await repository.all().compactMap { h -> String? in
                guard h.connectionMode == .existingSSHConfigAlias, let a = h.sshConfigAlias,
                    let p = h.sshConfigPath
                else { return nil }
                return p + "\n" + a
            })
        var outcome = ImportOutcome(imported: [], skippedAliases: [])
        for c in candidates {
            let key = sourcePath + "\n" + c.alias
            if !existing.insert(key).inserted {
                outcome.skippedAliases.append(c.alias)
                continue
            }
            let host = HostProfile(
                displayName: c.alias, environment: .other,
                connectionMode: .existingSSHConfigAlias, sshConfigPath: sourcePath,
                sshConfigAlias: c.alias)
            try await repository.insert(host)
            outcome.imported.append(host)
        }
        try await regenerateSSHConfig()
        return outcome
    }
}
