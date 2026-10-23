/// Hằng số dùng chung giữa app và helper `sshdesk-askpass`.
public enum CredentialConstants {
    /// Service của generic password trong Keychain; account = credentialReference.
    public static let service = "local.sshdesk.credentials"
    /// Biến môi trường chứa THAM CHIẾU (không phải password).
    public static let hostRefEnv = "SSHDESK_HOST_REF"
    /// THAM CHIẾU passphrase của key lấy từ bộ đăng nhập (`setkey-<uuid>`, ADR-030). Không phải secret.
    public static let keyRefEnv = "SSHDESK_KEY_REF"
    /// Đường dẫn key (đã tuyệt đối) mà passphrase thuộc về. Không phải secret.
    public static let keyPathEnv = "SSHDESK_KEY_PATH"
    /// Tiến trình cha duy nhất được phép nhận password.
    public static let trustedParent = "/usr/bin/ssh"
}

/// Loại câu hỏi mà ssh gửi qua SSH_ASKPASS.
public enum AskpassPromptClass: Equatable, Sendable {
    /// Câu hỏi password của tài khoản (`user@host's password:` hoặc `(user@host) Password:` của keyboard-interactive).
    case password
    /// `Enter passphrase for key '<path>':` — prompt passphrase của ssh cho một file key cụ thể (ADR-030).
    case keyPassphrase(path: String)
    /// Bí mật khác: passphrase không rõ key, OTP, mã xác minh... (tắt echo).
    case secret
    /// yes/no (host key...) — giữ echo.
    case confirm
    /// Chỉ là thông báo, không cần trả lời.
    case info
}

public enum AskpassAction: Equatable, Sendable {
    /// Trả password đã lưu cho ssh.
    case answerFromKeychain(ref: String)
    /// Trả passphrase của key (bộ đăng nhập) cho ssh, chỉ khi prompt khớp đúng path.
    case answerPassphraseFromKeychain(ref: String)
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
        if let path = PassphrasePrompt.keyPath(in: prompt) { return .keyPassphrase(path: path) }
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
        decide(
            prompt: prompt, promptType: promptType, hostRef: hostRef, keyRef: nil, keyPath: nil,
            parentPath: parentPath, claimUse: claimUse, claimKeyUse: { false })
    }

    /// Như trên, thêm passphrase của key (ADR-030): chỉ trả khi prompt đúng `Enter passphrase for key '<path>':`,
    /// `<path>` trùng `keyPath` (ssh cắt path ở 100 byte), cha là `/usr/bin/ssh` và đây là lần đầu
    /// (marker riêng `claimKeyUse`, độc lập với password). Prompt passphrase không khớp luôn hỏi trên tty.
    public static func decide(
        prompt: String, promptType: String?, hostRef: String?, keyRef: String?, keyPath: String?,
        parentPath: String?, claimUse: () -> Bool, claimKeyUse: () -> Bool
    ) -> AskpassAction {
        switch classify(prompt: prompt, promptType: promptType) {
        case .info: return .showOnly
        case .confirm: return .askTTY(echo: true)
        case .secret: return .askTTY(echo: false)
        case .keyPassphrase(let path):
            guard parentPath == CredentialConstants.trustedParent,
                let keyRef, !keyRef.isEmpty, let keyPath,
                PassphrasePrompt.pathMatches(promptPath: path, keyPath: keyPath),
                claimKeyUse()
            else { return .askTTY(echo: false) }
            return .answerPassphraseFromKeychain(ref: keyRef)
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

/// Prompt passphrase của ssh cho một file key (ADR-030). OpenSSH 10.3 in
/// `Enter passphrase for key '%.100s': ` — path được cắt ở 100 BYTE và giữ nguyên văn (không mở rộng `~`
/// ở phía prompt; app luôn ghi path tuyệt đối vào config nên path trong prompt = path trong config).
public enum PassphrasePrompt {
    static let prefix = "Enter passphrase for key '"
    static let suffix = "':"
    /// ssh cắt path trong prompt ở đây (`%.100s`).
    public static let maxPathBytes = 100

    /// Path trong prompt đúng dạng `Enter passphrase for key '<path>':` (khoảng trắng cuối bị bỏ). Dạng khác → nil.
    public static func keyPath(in prompt: String) -> String? {
        var s = Substring(prompt)
        while let last = s.last, last == " " || last == "\t" || last == "\n" { s = s.dropLast() }
        guard s.hasPrefix(prefix), s.hasSuffix(suffix), s.count >= prefix.count + suffix.count
        else { return nil }
        let inner = s.dropFirst(prefix.count).dropLast(suffix.count)
        return String(inner)
    }

    /// `promptPath` phải đúng bằng `keyPath` (sau khi cắt 100 byte như ssh). `keyPath` rỗng/không tuyệt đối → false.
    public static func pathMatches(promptPath: String, keyPath: String) -> Bool {
        guard keyPath.hasPrefix("/"), !promptPath.isEmpty else { return false }
        let bytes = Array(keyPath.utf8)
        let expected =
            bytes.count <= maxPathBytes ? keyPath : String(decoding: bytes.prefix(maxPathBytes), as: UTF8.self)
        return Array(promptPath.utf8) == Array(expected.utf8)
    }

    /// Prompt có thuộc về đúng key này không (dùng cho PTY và Core).
    public static func matches(prompt: String, keyPath: String) -> Bool {
        guard let p = Self.keyPath(in: prompt) else { return false }
        return pathMatches(promptPath: p, keyPath: keyPath)
    }
}
