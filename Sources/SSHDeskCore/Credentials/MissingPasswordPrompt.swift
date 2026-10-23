import Foundation

/// Quyết định có hiện sheet "Nhập mật khẩu cho user@host" trước khi kết nối không (ADR-029). Thuần logic.
public enum MissingPasswordPrompt {
    public enum Decision: Equatable, Sendable {
        /// Không hỏi: giữ luồng cũ (askpass / PTY hỏi như hiện nay).
        case none
        /// Sheet cho máy SSH (có kiểm tra đăng nhập trước khi lưu).
        case ssh
        /// Sheet cho máy Windows (ADR-018): không kiểm tra được, chỉ copy clipboard + tuỳ chọn lưu.
        case windows
    }

    /// - Parameters:
    ///   - resolved: kết quả `CredentialResolution.resolve` của host (nil = chỉ dùng trường của host).
    ///   - store: kho thật (Secure Enclave). Mục `missing` hoặc `undecryptable` đều coi là chưa có password.
    public static func decide(
        host: HostProfile, resolved: ResolvedCredentials?, settings: AppSettings,
        store: any CredentialStore
    ) -> Decision {
        // Tắt tự điền hoặc tắt cài đặt hỏi → luôn luồng cũ.
        guard settings.autofillEnabled, settings.promptMissingPassword else { return .none }
        guard host.authMethod == .interactive else { return .none }
        // Hold (ADR-026): không hỏi, và bastion (ADR-010b): không bao giờ gửi password qua ProxyJump.
        guard !host.autofillHold, resolved?.autofillHold != true else { return .none }
        guard host.jumpHostID == nil else { return .none }

        let ref = resolved?.passwordRef ?? host.effectiveCredentialReference
        if let ref, !ref.isEmpty, store.status(ref: ref) == .present { return .none }

        switch host.kind {
        case .windowsRDP:
            return .windows
        case .ssh:
            // Hồ sơ alias có sẵn: user/host nằm trong ~/.ssh/config của người dùng, app không biết nên
            // không dựng được sheet "user@host" và không kiểm tra được an toàn.
            guard host.connectionMode == .managed else { return .none }
            return .ssh
        }
    }
}
