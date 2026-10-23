import Foundation

/// Cài public key lên server bằng `/usr/bin/ssh-copy-id -F <config app> -i <pub> <alias>` qua PTY
/// (ADR-010/014). `ssh-copy-id` là script của OpenSSH, chạy như executable (argv), không qua `sh -c`.
/// Prompt password/host key/MFA đi lên UI; password đã lưu được tự điền đúng 1 lần theo
/// `PasswordAutofillPolicy`.
public struct SSHKeyInstaller: Sendable {
    public static let copyIDPath = "/usr/bin/ssh-copy-id"
    public static let connectTimeoutSeconds = 15

    public let configPath: String
    public let publicKeyPath: String
    public let alias: String
    private let host: HostProfile?
    private let credentials: (any CredentialStore)?
    private let executable: URL
    private let helper: URL?
    private let environment: [String: String]
    private let remoteTargetPath: String?
    private let force: Bool

    /// - Parameters:
    ///   - force: `-f` (bỏ bước "thử đăng nhập bằng key mới để lọc key đã có"). Cần khi cấu hình của host
    ///     đã có `IdentityFile` khác: bước lọc sẽ đăng nhập thành công bằng key cũ và báo nhầm
    ///     "key đã có sẵn". Hệ quả: nếu key đã nằm trên server thì dòng bị thêm lặp (vô hại).
    ///   - host: hồ sơ để áp `PasswordAutofillPolicy` (nil = không tự điền).
    ///   - remoteTargetPath: `-t` của ssh-copy-id (mặc định `.ssh/authorized_keys` của user trên server).
    ///     Chỉ cho `[A-Za-z0-9._/-]`; dùng trong test để không ghi vào authorized_keys thật.
    public init(
        configPath: String, publicKeyPath: String, alias: String, host: HostProfile? = nil,
        credentials: (any CredentialStore)? = nil, executable: String = copyIDPath,
        helper: URL? = nil, environment: [String: String] = ProcessEnvironment.inherited(),
        remoteTargetPath: String? = nil, force: Bool = false
    ) throws {
        guard publicKeyPath.hasPrefix("/"), publicKeyPath.hasSuffix(".pub"),
            !publicKeyPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
            let st = SSHKeyInventory.lstatInfo(publicKeyPath), st.isRegular
        else { throw SSHKeyError.invalidPublicKey }
        guard alias.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else { throw SSHKeyError.invalidAlias }
        if let remoteTargetPath,
            remoteTargetPath.isEmpty
                || remoteTargetPath.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) == nil
                || remoteTargetPath.hasPrefix("-")
        {
            throw SSHKeyError.invalidTargetPath
        }
        self.configPath = configPath
        self.publicKeyPath = publicKeyPath
        self.alias = alias
        self.host = host
        self.credentials = credentials
        self.executable = URL(fileURLWithPath: executable)
        self.helper = helper
        self.environment = environment
        self.remoteTargetPath = remoteTargetPath
        self.force = force
    }

    public var arguments: [String] {
        var args = ["-F", configPath, "-i", publicKeyPath]
        if force { args.insert("-f", at: 0) }
        if let remoteTargetPath { args += ["-t", remoteTargetPath] }
        args += ["-o", "ConnectTimeout=\(Self.connectTimeoutSeconds)", alias]
        return args
    }

    public func start() async throws -> KeyTaskSession {
        let latch = AutofillLatch()
        var autofill: (@Sendable (PromptKind) -> String?)?
        if let host, let ref = host.autofillCredentialReference, let credentials {
            autofill = { kind in
                guard
                    PasswordAutofillPolicy.shouldAutofill(
                        prompt: kind, host: host, alreadyFilled: latch.isFilled),
                    let password = credentials.read(ref: ref)
                else { return nil }
                latch.mark()
                return password
            }
        }
        let session = KeyTaskSession(
            executable: executable, arguments: arguments, environment: environment, helper: helper,
            autofill: autofill, evaluate: { exit, tail in Self.evaluate(exit, tail) })
        try await session.start()
        return session
    }

    static func evaluate(_ exit: ProcessExit, _ tail: [String]) -> KeyTaskOutcome {
        let joined = tail.joined(separator: "\n")
        let lower = joined.lowercased()
        guard case .exited(0) = exit else {
            let detail = tail.suffix(2).joined(separator: " ")
            switch exit {
            case .exited(let code):
                return .failure("ssh-copy-id thoát với mã \(code)" + (detail.isEmpty ? "." : ": \(detail)"))
            case .signaled(let sig): return .failure("ssh-copy-id bị dừng bởi tín hiệu \(sig).")
            case .cancelled: return .cancelled
            }
        }
        if lower.contains("number of key(s) added") { return .success("Đã cài key lên máy chủ.") }
        if lower.contains("already exist") { return .success("Key đã có sẵn trên máy chủ.") }
        return .failure("ssh-copy-id kết thúc nhưng không xác nhận được key đã được cài.")
    }
}
