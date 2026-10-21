import Foundation

public enum HostEnvironment: String, Codable, Sendable, CaseIterable {
    case dev = "DEV"
    case uat = "UAT"
    case stg = "STG"
    case prod = "PROD"
    case other = "OTHER"
}

public enum HostConnectionMode: String, Codable, Sendable {
    /// App tự sinh khối `Host sshdesk-<uuid>` trong file SSH config của app.
    case managed
    /// Dùng nguyên alias có sẵn trong SSH config của người dùng.
    case existingSSHConfigAlias
}

public enum HostAuthMethod: String, Codable, Sendable, CaseIterable {
    case agent
    case keyFile
    case interactive
}

public struct RemoteBookmark: Codable, Sendable, Equatable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum HostValidationError: Error, Equatable {
    case emptyDisplayName
    case invalidHostName(String)
    case invalidUser(String)
    case invalidPort(Int)
    case identityFileRequired
    case invalidIdentityFile
    case invalidAlias(String)
    case invalidSSHConfigPath
    /// Chuỗi tự do chứa NUL. `field` là tên trường.
    case containsNUL(field: String)
    case selfJump
    /// Hồ sơ imported không được có jump host.
    case jumpHostNotAllowed
}

/// Hồ sơ máy chủ. Không bao giờ chứa password/passphrase — chỉ `credentialReference` trỏ vào Keychain.
public struct HostProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var displayName: String
    public var project: String
    public var environment: HostEnvironment
    public var tags: [String]
    public var notes: String
    public var isFavorite: Bool
    public var connectionMode: HostConnectionMode

    // Managed
    public var hostName: String
    public var port: Int
    public var user: String
    public var authMethod: HostAuthMethod
    public var identityFile: String?
    public var jumpHostID: UUID?

    // Imported
    public var sshConfigPath: String?
    public var sshConfigAlias: String?

    /// Tham chiếu Keychain, KHÔNG phải password.
    public var credentialReference: String?
    public var remoteBookmarks: [RemoteBookmark]
    public var defaultLocalDirectory: String
    public var defaultRemoteDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastLaunchRequestedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        project: String = "",
        environment: HostEnvironment = .other,
        tags: [String] = [],
        notes: String = "",
        isFavorite: Bool = false,
        connectionMode: HostConnectionMode = .managed,
        hostName: String = "",
        port: Int = 22,
        user: String = "",
        authMethod: HostAuthMethod = .agent,
        identityFile: String? = nil,
        jumpHostID: UUID? = nil,
        sshConfigPath: String? = nil,
        sshConfigAlias: String? = nil,
        credentialReference: String? = nil,
        remoteBookmarks: [RemoteBookmark] = [],
        defaultLocalDirectory: String = "",
        defaultRemoteDirectory: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastLaunchRequestedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.project = project
        self.environment = environment
        self.tags = tags
        self.notes = notes
        self.isFavorite = isFavorite
        self.connectionMode = connectionMode
        self.hostName = hostName
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.jumpHostID = jumpHostID
        self.sshConfigPath = sshConfigPath
        self.sshConfigAlias = sshConfigAlias
        self.credentialReference = credentialReference
        self.remoteBookmarks = remoteBookmarks
        self.defaultLocalDirectory = defaultLocalDirectory
        self.defaultRemoteDirectory = defaultRemoteDirectory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastLaunchRequestedAt = lastLaunchRequestedAt
    }

    /// Bản sao để nhân bản: id mới, tên `<tên> (bản sao)` (thêm số nếu trùng tên đã có), giữ mọi cấu hình.
    /// Không chép yêu thích, lần mở Warp cuối, credentialReference (mật khẩu xử lý riêng ở service).
    public func duplicated(newID: UUID = UUID(), now: Date = Date(), existingNames: [String])
        -> HostProfile
    {
        var copy = self
        copy.id = newID
        copy.displayName = Self.duplicateName(of: displayName, existingNames: existingNames)
        copy.isFavorite = false
        copy.lastLaunchRequestedAt = nil
        copy.credentialReference = nil
        copy.createdAt = now
        copy.updatedAt = now
        return copy
    }

    static func duplicateName(of name: String, existingNames: [String]) -> String {
        let taken = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var candidate = "\(name) (bản sao)"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) (bản sao \(n))"
            n += 1
        }
        return candidate
    }

    /// Alias dùng cho `ssh -F <config app> <alias>`; nil nếu hồ sơ imported thiếu alias.
    public var sshAlias: String? {
        switch connectionMode {
        case .managed: return Self.managedAlias(for: id)
        case .existingSSHConfigAlias: return sshConfigAlias
        }
    }

    static func managedAlias(for id: UUID) -> String {
        "sshdesk-" + id.uuidString.lowercased()
    }

    public func validate() throws {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HostValidationError.emptyDisplayName
        }
        try noNUL(displayName, "displayName")
        try noNUL(project, "project")
        try noNUL(notes, "notes")
        for tag in tags { try noNUL(tag, "tags") }
        for b in remoteBookmarks {
            try noNUL(b.name, "remoteBookmarks.name")
            try noNUL(b.path, "remoteBookmarks.path")
        }
        try noNUL(defaultLocalDirectory, "defaultLocalDirectory")
        try noNUL(defaultRemoteDirectory, "defaultRemoteDirectory")
        if let credentialReference { try noNUL(credentialReference, "credentialReference") }

        switch connectionMode {
        case .managed:
            do { try SSHConfigWriter.validateHostName(hostName) } catch {
                throw HostValidationError.invalidHostName(hostName)
            }
            guard (1...65535).contains(port) else { throw HostValidationError.invalidPort(port) }
            guard
                (try? SSHConfigWriter.rejectControl(user, field: "user")) != nil,
                user.range(of: #"^[A-Za-z0-9._][A-Za-z0-9._-]*$"#, options: .regularExpression)
                    != nil
            else { throw HostValidationError.invalidUser(user) }
            if authMethod == .keyFile {
                guard let identityFile, !identityFile.isEmpty else {
                    throw HostValidationError.identityFileRequired
                }
                do { try SSHConfigWriter.validatePath(identityFile, field: "identityFile") } catch {
                    throw HostValidationError.invalidIdentityFile
                }
            }
            if jumpHostID == id { throw HostValidationError.selfJump }
        case .existingSSHConfigAlias:
            let alias = sshConfigAlias ?? ""
            guard
                alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression)
                    != nil
            else { throw HostValidationError.invalidAlias(alias) }
            guard let sshConfigPath,
                (try? SSHConfigWriter.validatePath(sshConfigPath, field: "sshConfigPath")) != nil
            else { throw HostValidationError.invalidSSHConfigPath }
            if jumpHostID != nil { throw HostValidationError.jumpHostNotAllowed }
        }
    }

    private func noNUL(_ s: String, _ field: String) throws {
        if s.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw HostValidationError.containsNUL(field: field)
        }
    }
}
