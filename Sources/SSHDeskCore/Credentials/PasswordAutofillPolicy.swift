import Foundation

/// Quy tắc tự điền password đã lưu vào prompt qua PTY (ADR-010 "Quy tắc tự điền password qua PTY").
/// Dùng chung cho job truyền file (`TransferManager`) và master của tab duyệt file (UI).
///
/// - Chỉ điền cho prompt `.password`, tối đa một lần mỗi job/phiên (`alreadyFilled`).
/// - Host có bastion (`jumpHostID`): KHÔNG điền (ssh con của ProxyJump cũng hỏi password, có thể là của bastion).
/// - Host managed: chỉ điền khi prompt đúng dạng `<user>@<hostName>'s password:` (host không phân biệt
///   hoa thường, bỏ khoảng trắng cuối). Prompt của bastion hay prompt `Password:` trơn không khớp.
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
        guard let ref = host.credentialReference, !ref.isEmpty else { return false }
        guard host.jumpHostID == nil else { return false }
        switch host.connectionMode {
        case .existingSSHConfigAlias:
            return true
        case .managed:
            return matchesManagedPrompt(promptText, user: host.user, hostName: host.hostName)
        }
    }

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
}
