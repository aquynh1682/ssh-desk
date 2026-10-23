import Foundation

/// Lỗi khi quote đối số cho zsh.
public enum ZshQuotingError: Error, Equatable {
    /// Chuỗi chứa NUL, xuống dòng hoặc CR — không bao giờ được đưa vào lệnh.
    case forbiddenCharacter
}

/// Quote đối số cho zsh bằng single quote. Luôn quote (không có đường tắt "an toàn") để quy tắc nhất quán.
public enum ZshQuoting {
    public static func quote(_ s: String) throws -> String {
        for scalar in s.unicodeScalars where scalar == "\0" || scalar == "\n" || scalar == "\r" {
            throw ZshQuotingError.forbiddenCharacter
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ghép `ssh -F <config> <alias>`, mỗi phần là một đối số đã quote.
    public static func sshCommand(sshPath: String, configPath: String, alias: String) throws -> String {
        try [sshPath, "-F", configPath, alias].map(quote).joined(separator: " ")
    }

    /// Lệnh ssh đăng nhập bằng password / passphrase đã lưu: gán biến môi trường đứng trước lệnh (cú pháp zsh).
    /// Env chỉ chứa THAM CHIẾU Keychain (và đường dẫn key), không bao giờ chứa password/passphrase.
    /// `hostRef` hoặc `keyRef`+`keyPath` có ít nhất một (ADR-030).
    public static func askpassSshCommand(
        helperPath: String, hostRef: String?, keyRef: String? = nil, keyPath: String? = nil,
        sshPath: String, configPath: String, alias: String
    ) throws -> String {
        var pairs = [("SSH_ASKPASS", helperPath), ("SSH_ASKPASS_REQUIRE", "force")]
        if let hostRef, !hostRef.isEmpty { pairs.append((CredentialConstants.hostRefEnv, hostRef)) }
        if let keyRef, !keyRef.isEmpty, let keyPath, !keyPath.isEmpty {
            pairs.append((CredentialConstants.keyRefEnv, keyRef))
            pairs.append((CredentialConstants.keyPathEnv, keyPath))
        }
        let assignments = try pairs.map { "\($0.0)=\(try quote($0.1))" }
        // `-o BatchMode=no`: BatchMode yes trong config người dùng (qua Include) sẽ tắt askpass.
        let ssh = try [sshPath, "-F", configPath, "-o", "BatchMode=no", alias].map(quote)
            .joined(separator: " ")
        return (assignments + [ssh]).joined(separator: " ")
    }
}
