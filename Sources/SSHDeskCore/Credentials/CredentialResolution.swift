import Foundation

/// Kết quả giải quyết thông tin đăng nhập của một host (ADR-030). Không chứa secret, chỉ tham chiếu/đường dẫn.
public struct ResolvedCredentials: Sendable, Equatable {
    public var user: String
    public var identityFile: String?
    public var identityAgent: String?
    /// Keychain account của password: riêng của host > `set-<uuid>`.
    public var passwordRef: String?
    /// `setkey-<uuid>`: chỉ khi identityFile hiệu lực lấy từ bộ (key riêng của host thì không áp dụng).
    public var passphraseRef: String?
    /// Path key mà passphrase thuộc về (tuyệt đối, đã mở rộng `~`).
    public var passphraseKeyPath: String?
    /// Host đang bị hold (ADR-026): mọi đường tự điền phải bỏ qua passwordRef/passphraseRef.
    public var autofillHold: Bool

    /// Ref password cho đường tự điền (nil khi hold).
    public var autofillPasswordRef: String? { autofillHold ? nil : passwordRef }
    /// Ref + path passphrase cho đường tự điền (nil khi hold hoặc thiếu một trong hai).
    public var autofillPassphrase: (ref: String, keyPath: String)? {
        guard !autofillHold, let ref = passphraseRef, let path = passphraseKeyPath else { return nil }
        return (ref, path)
    }
}

/// Nguồn password để hiển thị (chi tiết host).
public enum PasswordSource: Equatable, Sendable {
    case none
    case own
    case set(name: String)
    /// Host có mật khẩu riêng VÀ bộ đăng nhập: riêng thắng.
    case ownOverridesSet(name: String)

    public var label: String {
        switch self {
        case .none: return "Chưa lưu mật khẩu"
        case .own: return "Mật khẩu riêng"
        case .set(let name): return "Bộ đăng nhập: \(name)"
        case .ownOverridesSet(let name): return "Mật khẩu riêng (ưu tiên hơn bộ \(name))"
        }
    }
}

/// Bộ giải quyết DUY NHẤT cho user/key/agent/password/passphrase (ADR-030). Thuần logic, không I/O.
/// Ưu tiên: giá trị riêng của host > bộ đăng nhập > mặc định Cài đặt (chỉ IdentityAgent).
public enum CredentialResolution {
    public static func resolve(
        host: HostProfile, set: CredentialSet?, settingsDefaultAgent: String?,
        home: String = NSHomeDirectory()
    ) -> ResolvedCredentials {
        // Bộ không thuộc host này (id lệch) thì bỏ qua: không bao giờ trộn bộ lạ vào host.
        let set = set.flatMap { $0.id == host.credentialSetID ? $0 : nil }

        let hostUser = host.user.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = hostUser.isEmpty ? (set?.user ?? "") : host.user

        // Key riêng của host chỉ có hiệu lực với xác thực key file (đúng như SSHConfigWriter trước ADR-030).
        let ownFile = host.authMethod == .keyFile ? nonEmpty(host.identityFile) : nil
        let setFile = nonEmpty(set?.identityFile)
        let identityFile = ownFile ?? setFile
        let fileFromSet = ownFile == nil && setFile != nil

        let agent = IdentityAgentResolution.effective(
            layers: [host.identityAgent, set?.identityAgent, settingsDefaultAgent])

        let passwordRef: String?
        if let own = host.credentialReference, !own.isEmpty {
            passwordRef = own
        } else if let set {
            passwordRef = set.passwordReference
        } else {
            passwordRef = nil
        }

        var passphraseRef: String?
        var keyPath: String?
        if fileFromSet, let set, let file = setFile {
            passphraseRef = set.passphraseReference
            keyPath = expandTilde(file, home: home)
        }
        return ResolvedCredentials(
            user: user, identityFile: identityFile, identityAgent: agent, passwordRef: passwordRef,
            passphraseRef: passphraseRef, passphraseKeyPath: keyPath, autofillHold: host.autofillHold)
    }

    public static func passwordSource(host: HostProfile, set: CredentialSet?) -> PasswordSource {
        let hasOwn = !(host.credentialReference ?? "").isEmpty
        let set = set.flatMap { $0.id == host.credentialSetID ? $0 : nil }
        switch (hasOwn, set) {
        case (true, let s?): return .ownOverridesSet(name: s.name)
        case (true, nil): return .own
        case (false, let s?): return .set(name: s.name)
        case (false, nil): return .none
        }
    }

    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Cách một service (phiên SFTP, tunnel, cài key...) lấy thông tin đăng nhập hiệu lực của host (có bộ đăng nhập).
/// nil / trả nil = chỉ dùng trường của chính host (không bộ).
public typealias CredentialResolver = @Sendable (HostProfile) async -> ResolvedCredentials?

extension HostRepository {
    /// Resolver gắn với repository này. `defaultAgent` đọc mỗi lần dùng (Cài đặt đổi có hiệu lực ngay).
    public nonisolated func credentialResolver(
        defaultAgent: @escaping @Sendable () -> String? = { nil }
    ) -> CredentialResolver {
        { [self] host in
            try? await resolvedCredentials(for: host, settingsDefaultAgent: defaultAgent())
        }
    }
}
