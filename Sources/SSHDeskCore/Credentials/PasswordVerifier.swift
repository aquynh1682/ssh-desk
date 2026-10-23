import Foundation

/// Kết quả kiểm tra đăng nhập bằng một password (ADR-029). Không chứa password.
public enum PasswordVerification: Equatable, Sendable {
    case ok
    /// Prompt password lần hai hoặc `Permission denied`.
    case wrongPassword
    /// Gặp prompt xác nhận host key (máy mới): KHÔNG tự trả lời.
    case hostKeyUnconfirmed
    /// Host key đã thay đổi: dừng, không bao giờ cho tiếp tục.
    case hostKeyChanged
    /// OTP/MFA/passphrase/prompt không nhận ra (hoặc prompt password không khớp máy nên không tự điền được).
    case otherPrompt(String)
    case networkError(String)
    case timeout

    /// Không kết luận được đúng/sai (hỏi "Không kiểm tra được. Vẫn lưu?").
    public var isInconclusive: Bool {
        switch self {
        case .networkError, .timeout: return true
        default: return false
        }
    }
}

public protocol PasswordVerifying: Sendable {
    func verify(host: HostProfile, password: String) async -> PasswordVerification
}

/// Kết nối thử bằng `SessionConnector`/`RemoteSession` (ControlMaster qua PTY) với kho TRONG BỘ NHỚ chứa đúng
/// password cần kiểm, rồi đóng master (`-O exit`). Tự điền theo `PasswordAutofillPolicy` đúng một lần.
/// Không `StrictHostKeyChecking=no`, không `BatchMode`, password không vào argv/env/log/file.
public struct PasswordVerifier: PasswordVerifying {
    public static let defaultTimeout: TimeInterval = 20

    private let configPath: String
    private let helper: URL?
    private let sshPath: String
    private let socketDirectory: @Sendable () throws -> SocketDirectory
    private let timeout: TimeInterval

    public init(
        configPath: String, helper: URL?, sshPath: String = "/usr/bin/ssh",
        socketDirectory: @escaping @Sendable () throws -> SocketDirectory = { try SocketDirectory.ensure() },
        timeout: TimeInterval = PasswordVerifier.defaultTimeout
    ) {
        self.configPath = configPath
        self.helper = helper
        self.sshPath = sshPath
        self.socketDirectory = socketDirectory
        self.timeout = timeout
    }

    public func verify(host: HostProfile, password: String) async -> PasswordVerification {
        guard !password.isEmpty else { return .wrongPassword }
        // Bastion: ssh con của ProxyJump có thể hỏi password của bastion → không bao giờ thử (ADR-010b).
        guard host.kind == .ssh, host.connectionMode == .managed, host.jumpHostID == nil else {
            return .networkError("Máy này không kiểm tra được bằng mật khẩu (bastion hoặc hồ sơ alias).")
        }
        let store = InMemoryCredentialStore()
        let ref = "verify-" + UUID().uuidString.lowercased()
        do { try store.save(ref: ref, password: password) } catch {
            return .networkError("Không tạo được kho tạm.")
        }
        // Bản sao chỉ để kết nối: ref tạm, không bộ đăng nhập, không hold. Không bao giờ ghi lại DB.
        var probe = host
        probe.credentialReference = ref
        probe.credentialSetID = nil
        probe.autofillHold = false

        let connector = SessionConnector(
            configPath: configPath, credentials: store, helper: helper, sshPath: sshPath,
            socketDirectory: socketDirectory)
        let (signals, signal) = AsyncStream<PasswordVerification>.makeStream(bufferingPolicy: .unbounded)

        let connectTask = Task {
            do {
                let session = try await connector.connect(host: probe) { kind, _ in
                    // Không trả lời: mọi prompt còn lại (password lần 2, host key, OTP...) dừng phép thử.
                    signal.yield(Self.classify(prompt: kind, autofilled: store.reads > 0))
                }
                await session.close()  // `ssh -O exit`
                signal.yield(.ok)
            } catch is CancellationError {
            } catch let error as SessionConnectError {
                signal.yield(Self.classify(failure: error.message))
            } catch {
                signal.yield(.networkError("\(error)"))
            }
        }
        let seconds = timeout
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            signal.yield(.timeout)
        }
        var result = PasswordVerification.timeout
        for await r in signals {
            result = r
            break
        }
        timer.cancel()
        connectTask.cancel()
        await connectTask.value
        return result
    }

    // MARK: - Phân loại (thuần, có test)

    static func classify(prompt: PromptKind, autofilled: Bool) -> PasswordVerification {
        switch prompt {
        case .password(let text):
            // Đã điền một lần mà còn hỏi lại → sai. Chưa điền (prompt không khớp user@host) → không kết luận được.
            return autofilled ? .wrongPassword : .otherPrompt(clip(text))
        case .hostKeyConfirm: return .hostKeyUnconfirmed
        case .hostKeyChanged: return .hostKeyChanged
        case .passphrase(let t), .keyboardInteractive(let t), .unknown(let t): return .otherPrompt(clip(t))
        }
    }

    static func classify(failure reason: String) -> PasswordVerification {
        let lower = reason.lowercased()
        if lower.contains("identification has changed")
            || (lower.contains("host key") && (lower.contains("thay đổi") || lower.contains("changed")))
        {
            return .hostKeyChanged
        }
        if lower.contains("host key verification failed") { return .hostKeyUnconfirmed }
        if lower.contains("permission denied") || lower.contains("authentication fail")
            || lower.contains("too many authentication")
        {
            return .wrongPassword
        }
        if lower.contains("hết thời gian") { return .timeout }
        return .networkError(clip(reason))
    }

    private static func clip(_ s: String) -> String { String(s.prefix(200)) }
}
