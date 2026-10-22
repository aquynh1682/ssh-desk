import Foundation

/// Lỗi giá trị `IdentityAgent` (ADR-024).
public enum IdentityAgentError: Error, Equatable, Sendable {
    case empty
    case tooLong
    /// Có `\n`, `\r`, NUL, ký tự điều khiển Unicode (Cc) hoặc DEL.
    case controlCharacter
    /// Không bắt đầu bằng `/`, `~/` và không phải đúng `SSH_AUTH_SOCK`.
    case badPrefix
    /// Có `%` hoặc `$` (ssh mở rộng token/biến môi trường).
    case forbiddenCharacter
}

/// Cảnh báo (không chặn lưu) cho đường dẫn socket agent.
public enum IdentityAgentWarning: Hashable, Sendable {
    /// Socket chưa tồn tại (agent chưa chạy?).
    case socketMissing(path: String)
    /// Đường dẫn đã mở rộng dài hơn giới hạn `sun_path` của macOS.
    case pathTooLong(bytes: Int)
    /// Giá trị `SSH_AUTH_SOCK` nhưng app không thấy biến (thường do mở từ Finder).
    case systemVariableMissing

    public var message: String {
        switch self {
        case .socketMissing(let path): return "Chưa thấy socket tại \(path) — agent chưa chạy?"
        case .systemVariableMissing: return "App không thấy biến SSH_AUTH_SOCK (mở từ Finder?)"
        case .pathTooLong(let n):
            return
                "Đường dẫn socket dài \(n) byte, vượt giới hạn \(IdentityAgentPath.maxSocketPathBytes) byte của macOS; ssh có thể không kết nối được."
        }
    }
}

/// Validator và tiện ích cho giá trị `IdentityAgent`. Thuần logic, không chạy ssh.
public enum IdentityAgentPath {
    /// Giá trị đặc biệt: dùng agent của hệ thống (biến `SSH_AUTH_SOCK`), ghi nguyên văn.
    public static let systemValue = "SSH_AUTH_SOCK"
    public static let maxBytes = 1024
    /// Giới hạn `sun_path` của socket UNIX trên macOS.
    public static let maxSocketPathBytes = 104

    public static func validate(_ value: String) throws {
        if value.isEmpty { throw IdentityAgentError.empty }
        if value.utf8.count > maxBytes { throw IdentityAgentError.tooLong }
        for scalar in value.unicodeScalars where scalar.properties.generalCategory == .control {
            throw IdentityAgentError.controlCharacter
        }
        if value.unicodeScalars.contains(where: { $0.value == 0x7F || $0.value == 0 }) {
            throw IdentityAgentError.controlCharacter
        }
        guard value == systemValue || value.hasPrefix("/") || value.hasPrefix("~/") else {
            throw IdentityAgentError.badPrefix
        }
        if value.contains("%") || value.contains("$") { throw IdentityAgentError.forbiddenCharacter }
    }

    public static func isValid(_ value: String) -> Bool { (try? validate(value)) != nil }

    /// Đường dẫn socket thật: mở rộng `~/`; `SSH_AUTH_SOCK` → giá trị biến môi trường của app (nil nếu không có).
    public static func expanded(
        _ value: String, home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if value == systemValue {
            guard let sock = environment[systemValue], !sock.isEmpty else { return nil }
            return sock
        }
        if value.hasPrefix("~/") { return home + String(value.dropFirst(1)) }
        return value
    }

    /// Cảnh báo cho giá trị đã hợp lệ. Chỉ để hiển thị, không chặn.
    public static func warnings(
        for value: String, home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [IdentityAgentWarning] {
        guard isValid(value) else { return [] }
        guard let path = expanded(value, home: home, environment: environment) else {
            return [.systemVariableMissing]
        }
        var result: [IdentityAgentWarning] = []
        if path.utf8.count > maxSocketPathBytes { result.append(.pathTooLong(bytes: path.utf8.count)) }
        if !exists(path) { result.append(.socketMissing(path: path)) }
        return result
    }
}

/// Lựa chọn nhanh trong form. Đường dẫn preset lấy từ ADR-024 (researcher K5r).
public enum IdentityAgentPreset: String, CaseIterable, Sendable, Hashable {
    case system, onePassword, bitwarden, secretive, custom

    public var title: String {
        switch self {
        case .system: return "Hệ thống"
        case .onePassword: return "1Password"
        case .bitwarden: return "Bitwarden"
        case .secretive: return "Secretive"
        case .custom: return "Tuỳ chỉnh"
        }
    }

    /// Giá trị ghi vào config; nil với `.custom`.
    public var path: String? {
        switch self {
        case .system: return IdentityAgentPath.systemValue
        // Nguồn: tài liệu 1Password SSH agent (researcher K5r). Chưa thử trên máy thật.
        case .onePassword: return "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        // Bản .dmg; nguồn https://bitwarden.com/help/ssh-agent/. Bản App Store dùng "Tuỳ chỉnh". Chưa thử thật.
        case .bitwarden: return "~/.bitwarden-ssh-agent.sock"
        // CHƯA có nguồn chính thức (ADR-024 / KNOWN_LIMITATIONS). Chưa thử thật.
        case .secretive:
            return "~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        case .custom: return nil
        }
    }

    /// Nhận diện giá trị đã lưu: trùng preset → preset đó, khác → `.custom`.
    public static func matching(_ stored: String) -> IdentityAgentPreset {
        allCases.first { $0.path == stored } ?? .custom
    }
}

/// Chọn giá trị `IdentityAgent` hiệu lực. Thứ tự: host > mặc định Cài đặt (ADR-024).
/// ADR-030 sẽ chèn thêm tầng "set" giữa hai tầng này (host > set > mặc định).
public enum IdentityAgentResolution {
    /// nil = không ghi directive. Giá trị rỗng/chỉ khoảng trắng ở tầng nào cũng coi như "không đặt".
    public static func effective(host: String?, settingsDefault: String?) -> String? {
        effective(layers: [host, settingsDefault])
    }

    /// Tầng đầu tiên không rỗng thắng.
    public static func effective(layers: [String?]) -> String? {
        for layer in layers {
            if let layer, !layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return layer }
        }
        return nil
    }
}
