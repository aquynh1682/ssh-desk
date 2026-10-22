import CryptoKit
import Foundation

/// Một public key trong agent (từ `ssh-add -L`). Chỉ public key: không bao giờ chứa private key.
public struct AgentKey: Equatable, Sendable, Identifiable {
    public var type: String
    public var comment: String
    /// `SHA256:...` tính từ public key blob (cùng định dạng `ssh-add -l`).
    public var fingerprint: String
    public var id: String { fingerprint + type }
}

public enum AgentKeyListing: Equatable, Sendable {
    case keys([AgentKey])
    /// Agent chạy nhưng chưa có key nào.
    case empty
    /// Không liên lạc được với agent (kèm lý do ngắn, không chứa dữ liệu bí mật).
    case unavailable(String)
}

/// Liệt kê key của agent bằng `/usr/bin/ssh-add -L` (ADR-024). Chỉ đọc: không thêm/xoá key.
public enum AgentKeyLister {
    public static let executable = "/usr/bin/ssh-add"
    /// argv cố định: không nhận tham số từ người dùng.
    public static let arguments = ["-L"]

    /// `agent`: giá trị IdentityAgent (đường dẫn, `~/...` hoặc `SSH_AUTH_SOCK`); nil = agent hệ thống.
    public static func list(
        agent: String?, home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String = AgentKeyLister.executable, timeout: TimeInterval = 5
    ) async -> AgentKeyListing {
        let value = agent.flatMap { $0.isEmpty ? nil : $0 } ?? IdentityAgentPath.systemValue
        guard IdentityAgentPath.isValid(value) else { return .unavailable("Đường dẫn agent không hợp lệ.") }
        guard let socket = IdentityAgentPath.expanded(value, home: home, environment: environment) else {
            return .unavailable("Không có SSH_AUTH_SOCK: chưa có agent hệ thống nào chạy.")
        }
        // Env tối thiểu: chỉ đường dẫn socket (không phải secret).
        let env = ["SSH_AUTH_SOCK": socket]
        do {
            let out = try await SimpleProcess.run(
                executable: executable, arguments: arguments, environment: env, timeout: timeout)
            if out.timedOut { return .unavailable("Agent không phản hồi (quá \(Int(timeout)) giây).") }
            return parse(stdout: out.stdout, stderr: out.stderr, status: out.status)
        } catch {
            return .unavailable("Không chạy được ssh-add.")
        }
    }

    /// `ssh-add -L`: exit 0 + mỗi dòng một public key; exit 1 + "The agent has no identities."; exit 2 = lỗi kết nối.
    static func parse(stdout: String, stderr: String, status: Int32) -> AgentKeyListing {
        if status == 0 {
            let keys = stdout.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
            return keys.isEmpty ? .empty : .keys(keys)
        }
        if status == 1 { return .empty }
        return .unavailable("Không kết nối được agent (socket chưa có hoặc agent không chạy).")
    }

    /// `<type> <base64> [comment]`. Dòng lạ → nil.
    static func parseLine(_ line: String) -> AgentKey? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty else {
            return nil
        }
        let type = String(parts[0])
        guard type.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" || $0 == "." || $0 == "_" })
        else { return nil }
        let comment = parts.count > 2 ? sanitized(String(parts[2])) : ""
        return AgentKey(type: type, comment: comment, fingerprint: fingerprint(of: blob))
    }

    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    /// Comment do agent trả về: bỏ ký tự điều khiển trước khi hiển thị.
    private static func sanitized(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.properties.generalCategory != .control }))
    }
}
