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

    /// Lệnh ssh đăng nhập bằng password đã lưu: gán biến môi trường đứng trước lệnh (cú pháp zsh).
    /// Env chỉ chứa THAM CHIẾU Keychain, không chứa password.
    public static func askpassSshCommand(
        helperPath: String, hostRef: String, sshPath: String, configPath: String, alias: String
    ) throws -> String {
        let assignments = try [
            ("SSH_ASKPASS", helperPath), ("SSH_ASKPASS_REQUIRE", "force"),
            ("SSHDESK_HOST_REF", hostRef),
        ].map { "\($0.0)=\(try quote($0.1))" }
        // `-o BatchMode=no`: BatchMode yes trong config người dùng (qua Include) sẽ tắt askpass.
        let ssh = try [sshPath, "-F", configPath, "-o", "BatchMode=no", alias].map(quote)
            .joined(separator: " ")
        return (assignments + [ssh]).joined(separator: " ")
    }
}
