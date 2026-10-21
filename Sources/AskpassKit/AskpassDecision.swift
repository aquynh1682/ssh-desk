/// Hằng số dùng chung giữa app và helper `sshdesk-askpass`.
public enum CredentialConstants {
    /// Service của generic password trong Keychain; account = credentialReference.
    public static let service = "local.sshdesk.credentials"
    /// Biến môi trường chứa THAM CHIẾU (không phải password).
    public static let hostRefEnv = "SSHDESK_HOST_REF"
    /// Tiến trình cha duy nhất được phép nhận password.
    public static let trustedParent = "/usr/bin/ssh"
}

/// Loại câu hỏi mà ssh gửi qua SSH_ASKPASS.
public enum AskpassPromptClass: Equatable, Sendable {
    /// Câu hỏi password của tài khoản (`user@host's password:`).
    case password
    /// Bí mật khác: passphrase, OTP, mã xác minh... (tắt echo).
    case secret
    /// yes/no (host key...) — giữ echo.
    case confirm
    /// Chỉ là thông báo, không cần trả lời.
    case info
}

public enum AskpassAction: Equatable, Sendable {
    /// Trả password đã lưu cho ssh.
    case answerFromKeychain(ref: String)
    /// Hỏi người dùng trên /dev/tty.
    case askTTY(echo: Bool)
    /// Hiển thị trên tty, không đọc gì (SSH_ASKPASS_PROMPT=none).
    case showOnly
}

/// Pure: phân loại prompt và quyết định có được trả password Keychain hay không.
public enum AskpassDecision {
    public static func classify(prompt: String, promptType: String?) -> AskpassPromptClass {
        switch promptType?.lowercased() {
        case "confirm": return .confirm
        case "none": return .info
        default: break
        }
        let lower = prompt.lowercased()
        if lower.contains("yes/no") || lower.contains("continue connecting") { return .confirm }
        if isAccountPasswordPrompt(lower) { return .password }
        return .secret
    }

    /// `claimUse` chỉ được gọi khi mọi điều kiện khác đã đủ, và phải "đánh dấu đã dùng" một cách
    /// nguyên tử (trả true nếu đây là lần đầu cho tiến trình ssh cha này).
    public static func decide(
        prompt: String, promptType: String?, hostRef: String?, parentPath: String?,
        claimUse: () -> Bool
    ) -> AskpassAction {
        switch classify(prompt: prompt, promptType: promptType) {
        case .info: return .showOnly
        case .confirm: return .askTTY(echo: true)
        case .secret: return .askTTY(echo: false)
        case .password:
            guard parentPath == CredentialConstants.trustedParent,
                let ref = hostRef, !ref.isEmpty, claimUse()
            else { return .askTTY(echo: false) }
            return .answerFromKeychain(ref: ref)
        }
    }

    /// Bỏ ký tự điều khiển/escape (giữ xuống dòng, vì prompt host key nhiều dòng) để prompt từ server không điều khiển được terminal.
    public static func sanitizeForDisplay(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x0A {
                out.append(scalar)
            } else if v == 0x09 {
                out.append(" ")
            } else if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) {
                continue
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Nội bộ

    private static let forbiddenSubstrings = [
        "passphrase", "verification", "passcode", "one-time", "onetime", "token", "new password",
        "retype", "re-enter", "again", "confirm",
    ]

    private static func isAccountPasswordPrompt(_ lower: String) -> Bool {
        var s = Substring(lower)
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        guard s.hasSuffix("password:") else { return false }
        for f in forbiddenSubstrings where lower.contains(f) { return false }
        // "otp" chỉ tính khi là cả từ (tránh hostname như "hotpot").
        let words = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        if words.contains("otp") { return false }
        return true
    }
}
