import Foundation

/// Quy tắc tự điền password đã lưu vào prompt qua PTY (ADR-010 "Quy tắc tự điền password qua PTY").
/// Dùng chung cho job truyền file (`TransferManager`) và master của tab duyệt file (UI).
///
/// - Chỉ điền cho prompt `.password`, tối đa một lần mỗi job/phiên (`alreadyFilled`).
/// - Host có bastion (`jumpHostID`): KHÔNG điền (ssh con của ProxyJump cũng hỏi password, có thể là của bastion).
/// - Host managed: chỉ điền khi prompt đúng dạng `<user>@<hostName>'s password:` hoặc (keyboard-interactive,
///   OpenSSH >= 8.4, ADR-010b) `(<user>@<hostName>) Password:` (host và chữ `Password:` không phân biệt
///   hoa thường, bỏ khoảng trắng cuối). Prompt của bastion, `Password:` trơn, `Verification code:` không khớp.
/// - Host imported: điền lần đầu (rủi ro ProxyJump trong `~/.ssh/config` của người dùng: KNOWN_LIMITATIONS).
public enum PasswordAutofillPolicy {
    public static func shouldAutofill(
        prompt: PromptKind, host: HostProfile, alreadyFilled: Bool
    ) -> Bool {
        guard case .password(let text) = prompt else { return false }
        return shouldAutofill(promptText: text, host: host, alreadyFilled: alreadyFilled)
    }

    public static func shouldAutofill(
        promptText: String, host: HostProfile, alreadyFilled: Bool
    ) -> Bool {
        guard !alreadyFilled else { return false }
        // Password hiệu lực (riêng > bộ đăng nhập, ADR-030); nil khi hold (ADR-026).
        guard let ref = host.autofillCredentialReference, !ref.isEmpty else { return false }
        guard host.jumpHostID == nil else { return false }
        switch host.connectionMode {
        case .existingSSHConfigAlias:
            return true
        case .managed:
            return matchesManagedPrompt(promptText, user: host.user, hostName: host.hostName)
                || matchesKeyboardInteractivePrompt(promptText, user: host.user, hostName: host.hostName)
        }
    }

    // Passphrase KHÔNG bao giờ tự điền qua PTY (ADR-030, QA K4s): server có thể in dòng giả giống prompt
    // passphrase trong banner, passphrase rơi vào prompt password kế tiếp và bị gửi lên server. Chỉ đường
    // askpass (Warp) mới điền passphrase vì chỉ ssh mới gọi được helper.

    /// `ssh` in `"%.30s@%.128s's password: "` (user cắt 30, host cắt 128 ký tự).
    static func matchesManagedPrompt(_ text: String, user: String, hostName: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "'s password:"
        guard trimmed.lowercased().hasSuffix(suffix) else { return false }
        let body = String(trimmed.dropLast(suffix.count))
        guard let at = body.lastIndex(of: "@") else { return false }
        let promptUser = String(body[..<at])
        let promptHost = String(body[body.index(after: at)...])
        guard !user.isEmpty, !hostName.isEmpty else { return false }
        return promptUser == String(user.prefix(30))
            && promptHost.caseInsensitiveCompare(String(hostName.prefix(128))) == .orderedSame
    }

    /// Prompt keyboard-interactive `(<user>@<hostName>) Password:` (ADR-010b).
    static func matchesKeyboardInteractivePrompt(_ text: String, user: String, hostName: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("("), let close = trimmed.lastIndex(of: ")") else { return false }
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard rest.caseInsensitiveCompare("password:") == .orderedSame else { return false }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        guard let at = inner.lastIndex(of: "@") else { return false }
        let promptUser = String(inner[..<at])
        let promptHost = String(inner[inner.index(after: at)...])
        guard !user.isEmpty, !hostName.isEmpty else { return false }
        return promptUser == String(user.prefix(30))
            && promptHost.caseInsensitiveCompare(String(hostName.prefix(128))) == .orderedSame
    }
}
