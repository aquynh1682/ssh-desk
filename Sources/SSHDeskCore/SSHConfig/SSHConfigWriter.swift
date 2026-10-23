import Darwin
import Foundation

/// Một host do app quản lý, sẽ được sinh thành khối `Host <alias>` trong file SSH config của app.
public struct SSHHostSpec: Sendable, Equatable {
    public var alias: String
    public var hostName: String
    public var port: Int
    public var user: String
    /// Đường dẫn tuyệt đối (caller phải tự mở rộng `~`).
    public var identityFile: String?
    /// Giá trị `IdentityAgent` hiệu lực (đã chọn host > mặc định); nil = không ghi directive. Validate khi sinh.
    public var identityAgent: String?
    /// Alias bastion do app sinh hoặc alias có sẵn trong config của người dùng.
    public var jumpAlias: String?
    /// identityFile là khoá Secure Enclave (ADR-027): ghi `SecurityKeyProvider` trong Host block này.
    public var usesSecureEnclaveProvider: Bool

    public init(
        alias: String, hostName: String, port: Int = 22, user: String,
        identityFile: String? = nil, jumpAlias: String? = nil, identityAgent: String? = nil,
        usesSecureEnclaveProvider: Bool = false
    ) {
        self.usesSecureEnclaveProvider = usesSecureEnclaveProvider
        self.alias = alias
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.identityAgent = identityAgent
        self.jumpAlias = jumpAlias
    }
}

public enum SSHConfigError: Error, Equatable {
    case invalidAlias(String)
    case invalidHostName(String)
    case invalidPort(Int)
    case invalidUser(String)
    /// Giá trị chứa newline, CR, NUL hoặc ký tự điều khiển. `field` là tên trường.
    case controlCharacter(field: String)
    /// Đường dẫn không tuyệt đối (gồm cả dạng `~`).
    case pathNotAbsolute(field: String)
    /// Đường dẫn chứa `%` (ssh diễn giải token), bị từ chối.
    case unsupportedPathCharacter(field: String)
    case duplicateAlias(String)
    case selfJump(String)
    case jumpCycle([String])
    case invalidIdentityAgent(IdentityAgentError)
}

/// Sinh file SSH config do app sở hữu (ADR-006). Thuần logic: không chạy ssh, không mạng.
public enum SSHConfigWriter {
    /// Đường dẫn cố định của provider SK của macOS (ADR-027); không nhận từ input người dùng.
    public static let secureEnclaveProvider = "/usr/lib/ssh-keychain.dylib"
    public static let header = "# Do SSH Desk sinh — không sửa tay"

    public static func render(hosts: [SSHHostSpec], userConfigPath: String?) throws -> String {
        var seen = Set<String>()
        for host in hosts {
            try validate(host)
            guard seen.insert(host.alias).inserted else {
                throw SSHConfigError.duplicateAlias(host.alias)
            }
        }
        if let userConfigPath {
            try validatePath(userConfigPath, field: "userConfigPath")
        }
        try checkJumpCycles(hosts)

        var lines = [header]
        for host in hosts {
            lines.append("Host \(host.alias)")
            lines.append("    HostName \(quote(host.hostName))")
            lines.append("    Port \(host.port)")
            lines.append("    User \(quote(host.user))")
            if let identityFile = host.identityFile {
                lines.append("    IdentityFile \(quote(identityFile))")
                lines.append("    IdentitiesOnly yes")
                if host.usesSecureEnclaveProvider {
                    lines.append("    SecurityKeyProvider \(quote(secureEnclaveProvider))")
                }
            }
            if let agent = host.identityAgent {
                lines.append("    IdentityAgent \(quote(agent))")
            }
            if let jump = host.jumpAlias {
                lines.append("    ProxyJump \(jump)")
            }
        }
        if let userConfigPath {
            lines.append("Match all")
            lines.append("Include \(quote(userConfigPath))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ghi atomically, file 0600; tạo thư mục cha 0700 nếu thiếu.
    public static func write(
        to url: URL, hosts: [SSHHostSpec], userConfigPath: String?
    ) throws {
        let content = try render(hosts: hosts, userConfigPath: userConfigPath)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        // Ghi ra file tạm 0600 cùng thư mục rồi rename: không có thời điểm nào file lộ quyền rộng.
        let tmp = dir.appendingPathComponent(".sshdesk-config-\(UUID().uuidString).tmp")
        guard
            fm.createFile(
                atPath: tmp.path, contents: Data(content.utf8),
                attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// argv (không gồm executable) để chạy `/usr/bin/ssh`. Không nối chuỗi shell.
    public static func sshInvocation(configPath: String, alias: String) throws -> [String] {
        try validatePath(configPath, field: "configPath")
        try validateAlias(alias)
        return ["-F", configPath, alias]
    }

    // MARK: - Validation

    static func validate(_ host: SSHHostSpec) throws {
        try validateAlias(host.alias)
        try validateHostName(host.hostName)
        guard (1...65535).contains(host.port) else { throw SSHConfigError.invalidPort(host.port) }
        try rejectControl(host.user, field: "user")
        guard matches(host.user, #"^[A-Za-z0-9._][A-Za-z0-9._-]*$"#) else {
            throw SSHConfigError.invalidUser(host.user)
        }
        if let identityFile = host.identityFile {
            try validatePath(identityFile, field: "identityFile")
        }
        if let agent = host.identityAgent {
            do { try IdentityAgentPath.validate(agent) } catch let e as IdentityAgentError {
                throw SSHConfigError.invalidIdentityAgent(e)
            }
        }
        if let jump = host.jumpAlias {
            try validateAlias(jump, field: "jumpAlias")
            if jump == host.alias { throw SSHConfigError.selfJump(jump) }
        }
    }

    static func validateAlias(_ alias: String, field: String = "alias") throws {
        try rejectControl(alias, field: field)
        guard matches(alias, #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#) else {
            throw SSHConfigError.invalidAlias(alias)
        }
    }

    static func validateHostName(_ name: String) throws {
        try rejectControl(name, field: "hostName")
        if name.isEmpty || name.hasPrefix("-") || name.contains(where: { $0.isWhitespace }) {
            throw SSHConfigError.invalidHostName(name)
        }
        if matches(name, #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#) { return }
        if name.contains(":") {
            var addr = in6_addr()
            if inet_pton(AF_INET6, name, &addr) == 1 { return }
        }
        throw SSHConfigError.invalidHostName(name)
    }

    static func validatePath(_ path: String, field: String) throws {
        try rejectControl(path, field: field)
        guard path.hasPrefix("/") else { throw SSHConfigError.pathNotAbsolute(field: field) }
        guard !path.contains("%") else {
            throw SSHConfigError.unsupportedPathCharacter(field: field)
        }
    }

    static func rejectControl(_ value: String, field: String) throws {
        for scalar in value.unicodeScalars
        where scalar.value < 0x20 || scalar.value == 0x7F
            || (0x80...0x9F).contains(scalar.value)
        {
            throw SSHConfigError.controlCharacter(field: field)
        }
    }

    static func checkJumpCycles(_ hosts: [SSHHostSpec]) throws {
        let next = Dictionary(
            hosts.compactMap { h in h.jumpAlias.map { (h.alias, $0) } },
            uniquingKeysWith: { first, _ in first })
        for start in hosts.map(\.alias) {
            var path = [start]
            var current = start
            while let n = next[current] {
                if let idx = path.firstIndex(of: n) {
                    throw SSHConfigError.jumpCycle(Array(path[idx...]))
                }
                path.append(n)
                current = n
            }
        }
    }

    // MARK: - Helpers

    /// Bọc trong "..." và escape `\` rồi `"` (cú pháp ssh_config).
    static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
