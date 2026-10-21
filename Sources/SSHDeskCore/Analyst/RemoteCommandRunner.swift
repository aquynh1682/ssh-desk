import Foundation

public struct RemoteCommandResult: Sendable, Equatable {
    public var exitStatus: Int32
    public var stdout: String
    /// Đã làm sạch (bỏ ANSI/ký tự điều khiển), cắt ở 4 KB.
    public var stderr: String
    /// Hết thời gian chờ CỤC BỘ (ssh bị treo), khác với `timeout 3` phía server (exit 124).
    public var timedOut: Bool
    public var stdoutTruncated: Bool

    public init(
        exitStatus: Int32, stdout: String, stderr: String, timedOut: Bool = false,
        stdoutTruncated: Bool = false
    ) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.stdoutTruncated = stdoutTruncated
    }
}

public enum RemoteCommandError: Error, Equatable, Sendable {
    case toolMissing(String)
    /// Master ControlMaster không còn sống.
    case sessionLost
    /// ssh thoát 255 nhưng master vẫn sống (lỗi kênh/lệnh).
    case connectionFailed(String)
    case unsupportedCommand
    case spawnFailed(String)
}

/// Nơi thực thi một lệnh whitelist trên một server (inject giả trong test).
public protocol RemoteCommandExecuting: Sendable {
    func execute(_ command: AnalystCommand) async throws -> RemoteCommandResult
}

/// Chạy lệnh whitelist qua master của `RemoteSession` (ADR-016): executable + argv, chuỗi lệnh là MỘT
/// đối số cuối (ssh gửi nó cho shell remote). Không có shell cục bộ.
public actor RemoteCommandRunner: RemoteCommandExecuting {
    public static let defaultTimeout: TimeInterval = 15
    public static let defaultMaxStdoutBytes = 2 * 1024 * 1024
    static let maxStderrBytes = 4096

    private let alias: String
    private let configPath: String
    private let controlPath: String
    private let sshPath: String
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let maxStdoutBytes: Int
    private let aliveCheck: @Sendable () async -> Bool

    public init(
        alias: String, configPath: String, controlPath: String,
        sshPath: String = "/usr/bin/ssh",
        environment: [String: String] = ProcessEnvironment.inherited(),
        timeout: TimeInterval = RemoteCommandRunner.defaultTimeout,
        maxStdoutBytes: Int = RemoteCommandRunner.defaultMaxStdoutBytes,
        aliveCheck: @escaping @Sendable () async -> Bool
    ) {
        self.alias = alias
        self.configPath = configPath
        self.controlPath = controlPath
        self.sshPath = sshPath
        self.environment = environment
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.aliveCheck = aliveCheck
    }

    public init(
        session: RemoteSession, timeout: TimeInterval = RemoteCommandRunner.defaultTimeout,
        maxStdoutBytes: Int = RemoteCommandRunner.defaultMaxStdoutBytes
    ) {
        self.init(
            alias: session.alias, configPath: session.configPath, controlPath: session.controlPath,
            timeout: timeout, maxStdoutBytes: maxStdoutBytes,
            aliveCheck: { await session.checkAlive() })
    }

    public func execute(_ command: AnalystCommand) async throws -> RemoteCommandResult {
        guard let text = command.commandString else { throw RemoteCommandError.unsupportedCommand }
        return try await executeRaw(text, toolHint: command.primaryTool)
    }

    /// argv của ssh (để test kiểm tra đúng dạng).
    nonisolated func arguments(for commandText: String) -> [String] {
        [
            "-F", configPath,
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=none",
            "-o", "ConnectTimeout=10",
            "--", alias, commandText,
        ]
    }

    /// Chỉ nội bộ/test: nhận chuỗi lệnh tuỳ ý. API công khai chỉ nhận `AnalystCommand`.
    func executeRaw(_ text: String, toolHint: String) async throws -> RemoteCommandResult {
        let out: SimpleProcessOutput
        do {
            out = try await SimpleProcess.run(
                executable: sshPath, arguments: arguments(for: text), environment: environment,
                timeout: timeout)
        } catch {
            throw RemoteCommandError.spawnFailed(String(describing: error))
        }
        let (stdout, truncated) = Self.truncate(out.stdout, maxBytes: maxStdoutBytes)
        let result = RemoteCommandResult(
            exitStatus: out.status, stdout: Self.sanitize(stdout),
            stderr: Self.sanitize(Self.truncate(out.stderr, maxBytes: Self.maxStderrBytes).0),
            timedOut: out.timedOut, stdoutTruncated: truncated)
        if out.timedOut { return result }
        if result.exitStatus == 255 {
            if await aliveCheck() {
                throw RemoteCommandError.connectionFailed(Self.firstLine(result.stderr))
            }
            throw RemoteCommandError.sessionLost
        }
        if result.exitStatus != 0, Self.looksLikeMissingTool(result) {
            throw RemoteCommandError.toolMissing(
                Self.missingToolName(stderr: result.stderr, fallback: toolHint))
        }
        return result
    }

    static func looksLikeMissingTool(_ r: RemoteCommandResult) -> Bool {
        if r.exitStatus == 127 { return true }
        return r.stderr.lowercased().contains("command not found")
    }

    /// "bash: ss: command not found", "sh: 1: nc: not found", "timeout: failed to run command 'bash'..."
    static func missingToolName(stderr: String, fallback: String) -> String {
        for line in stderr.split(separator: "\n") {
            let l = String(line)
            if let r = l.range(of: "failed to run command '") {
                let rest = l[r.upperBound...]
                if let end = rest.firstIndex(of: "'") { return String(rest[..<end]) }
            }
            // zsh: "zsh:1: command not found: name"
            if let r = l.range(of: "command not found: ") {
                let name = l[r.upperBound...].split(separator: " ").first
                if let name { return String(name) }
            }
            for marker in [": command not found", ": not found"] {
                if let r = l.range(of: marker) {
                    let head = l[..<r.lowerBound]
                    if let name = head.split(whereSeparator: { $0 == ":" || $0 == " " }).last {
                        return String(name)
                    }
                }
            }
        }
        return fallback
    }

    static func truncate(_ s: String, maxBytes: Int) -> (String, Bool) {
        let u = s.utf8
        guard u.count > maxBytes else { return (s, false) }
        return (String(decoding: Array(u.prefix(maxBytes)), as: UTF8.self), true)
    }

    static func sanitize(_ s: String) -> String {
        var sanitizer = OutputSanitizer()
        return sanitizer.feed(Array(s.utf8)) + sanitizer.finish()
    }

    static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return String(line.prefix(200))
    }
}
