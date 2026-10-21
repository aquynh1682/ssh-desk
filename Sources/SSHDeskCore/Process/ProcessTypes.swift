import Foundation

/// Kết quả cuối của một tiến trình chạy qua PTY.
public enum ProcessExit: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    /// Do `cancel()` của app (không phải bị signal từ bên ngoài).
    case cancelled
}

public enum ProcessEvent: Sendable, Equatable {
    /// Text đã làm sạch (không ANSI/ký tự điều khiển) và đã che thứ app đã `send`.
    case output(String)
    /// Luôn là event cuối cùng; sau đó stream kết thúc.
    case exit(ProcessExit)
}

public enum PTYProcessError: Error, Equatable {
    case invalidArgument(String)
    case ptyFailed(Int32)
    case spawnFailed(Int32)
    /// Không tìm thấy helper `sshdesk-ctty` (xem `ControllingTTYHelper`).
    case helperNotFound
}

/// Environment truyền cho con là danh sách tường minh, không kế thừa mặc định.
public enum ProcessEnvironment {
    public static let inheritedKeys = ["HOME", "PATH", "USER", "LANG", "LC_ALL", "SSH_AUTH_SOCK", "TMPDIR"]

    /// Chỉ lấy các khóa trong `inheritedKeys` + `TERM=dumb`. Không bao giờ chứa credential.
    public static func inherited(
        from source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in inheritedKeys {
            if let value = source[key] { env[key] = value }
        }
        env["TERM"] = "dumb"
        return env
    }
}
