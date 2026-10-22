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
}

/// Kết quả import: hồ sơ mới tạo và alias bị bỏ qua vì đã import từ cùng file.
public struct ImportOutcome: Sendable, Equatable {
    public var imported: [HostProfile]
    public var skippedAliases: [String]
}

/// Nối HostRepository, SSH config của app và WarpLauncher. Không chạy ssh, không mở mạng.
public actor ConnectionService {
    public let repository: HostRepository
    public let appConfigURL: URL
    private let userConfigPath: String?
    private let launcher: WarpLauncher
    private let rdpLauncher: WindowsAppLauncher
    private let credentials: (any CredentialStore)?
    private let askpassHelper: URL?
    private let now: @Sendable () -> Date

    /// `userConfigPath`: nil = không `Include`. Chỉ truyền đường dẫn file đang tồn tại
    /// (xem `AppPaths.existingUserConfigPath()`).
    public init(
        repository: HostRepository, appConfigURL: URL, userConfigPath: String?,
        launcher: WarpLauncher, rdpLauncher: WindowsAppLauncher = WindowsAppLauncher(),
        credentials: (any CredentialStore)? = nil,
        askpassHelper: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
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
            to: appConfigURL, hosts: try await repository.sshSpecs(),
            userConfigPath: userConfigPath)
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

    /// Lệnh chạy trong Tab Config của Warp. Có password đã lưu (và có helper) -> dùng SSH_ASKPASS.
    /// `notice` giải thích khi phải dùng lệnh thường dù host có password lưu.
    public func warpSSHCommand(for host: HostProfile) throws -> (command: String, notice: String?) {
        let plain = try copyableSSHCommand(for: host)
        guard let ref = host.credentialReference, let credentials, credentials.exists(ref: ref) else {
            return (plain, nil)
        }
        guard let helper = askpassHelper else {
            return (plain, "Không tìm thấy helper đăng nhập tự động — nhập mật khẩu trong Warp.")
        }
        // ProxyJump chạy ssh con dùng chung biến môi trường: tránh gửi password của host đích cho bastion.
        if host.jumpHostID != nil {
            return (plain, "Host dùng bastion: không đăng nhập tự động bằng mật khẩu, nhập trong Warp.")
        }
        let command = try ZshQuoting.askpassSshCommand(
            helperPath: helper.path, hostRef: ref, sshPath: "/usr/bin/ssh",
            configPath: appConfigURL.path, alias: try alias(of: host))
        return (command, nil)
    }

    // MARK: - Mật khẩu đã lưu (Keychain)

    public func hasStoredPassword(_ host: HostProfile) -> Bool {
        guard let ref = host.credentialReference, let credentials else { return false }
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

    private func alias(of host: HostProfile) throws -> String {
        guard let alias = repository.sshAlias(for: host) else {
            throw ConnectionServiceError.missingAlias
        }
        return alias
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

    public func openInWarp(_ host: HostProfile, newWindow: Bool = false) async -> LaunchResult {
        await openInWarpReport(host, newWindow: newWindow).result
    }

    public struct WarpOpenReport: Sendable, Equatable {
        public var result: LaunchResult
        /// Lý do không đăng nhập tự động được (nếu host có mật khẩu lưu).
        public var notice: String?
    }

    public func openInWarpReport(_ host: HostProfile, newWindow: Bool = false) async -> WarpOpenReport {
        var notice: String?
        guard host.kind == .ssh else {
            return WarpOpenReport(result: .failed("Máy Windows không mở bằng Warp."), notice: nil)
        }
        do {
            try host.validate()
            try await regenerateSSHConfig()
            let (command, why) = try warpSSHCommand(for: host)
            notice = why
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
        guard host.kind == .windowsRDP else { return .failed("Đây không phải máy Windows.") }
        let result = await rdpLauncher.launch(host)
        if result == .requested {
            do { try await repository.markLaunchRequested(id: host.id, at: now()) } catch {
                return .failed("\(error)")
            }
        }
        return result
    }

    /// Ghi file .rdp (không mở app) để hiện trong Finder.
    public func prepareRDPFile(for host: HostProfile) throws -> URL {
        guard host.kind == .windowsRDP else { throw ConnectionServiceError.notWindowsHost }
        return try rdpLauncher.prepare(host)
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
