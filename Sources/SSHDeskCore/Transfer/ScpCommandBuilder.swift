import Foundation

public enum ScpBuildError: Error, Equatable {
    case invalidConfigPath
    case invalidAlias(String)
    /// Đường dẫn local không tuyệt đối (sẽ làm `a:b` bị hiểu là remote).
    case localPathNotAbsolute(String)
    /// NUL, newline hoặc ký tự điều khiển trong đường dẫn local.
    case invalidLocalPath(String)
    case emptyRemotePath
    /// Ký tự không chứng minh được là truyền literal qua scp/SFTP → từ chối thay vì truyền nhầm.
    case unsupportedRemotePathCharacter(String)
    case localNameMissing
    case invalidControlPath(String)
}

public struct ScpInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    /// Chỉ download: đích tạm cạnh đích thật (`.<tên>.sshdesk-<jobid>.part`).
    public let tempPartialPath: String?
}

/// Dựng argv cho `/usr/bin/scp` (ADR-008). Thuần logic, không chạy process.
///
/// Kết quả thí nghiệm (fake ssh + sftp-server, OpenSSH 10.x, scp mặc định SFTP):
/// - Remote SOURCE (download) bị glob: `* ? [ ]` phải escape bằng `\`, và `\` cũng phải escape.
///   Sau khi escape, mọi tên trong bộ thử (khoảng trắng, Unicode, ' " $ ; & ( ) { } ~ # ! % ` | < > :,
///   tab, tên bắt đầu bằng `-`) đều tải đúng nội dung; `*`/`?`/`[a]` không escape thì khớp nhầm.
/// - Remote DESTINATION (upload) KHÔNG bị glob: truyền literal. Nếu escape sẽ tạo file tên có `\`
///   → upload tuyệt đối không escape đích.
public enum ScpCommandBuilder {
    public static let executable = "/usr/bin/scp"
    public static let connectTimeoutSeconds = 15

    /// `controlPath`: socket của ControlMaster đang sống (tab duyệt file) → scp đi qua master đó.
    public static func build(for job: TransferJob, controlPath: String? = nil) throws
        -> ScpInvocation
    {
        try validateConfig(job.configPathSnapshot)
        try validateAlias(job.sshAliasSnapshot)

        var args = ["-F", job.configPathSnapshot, "-o", "ConnectTimeout=\(connectTimeoutSeconds)"]
        if let controlPath {
            try validateControlPath(controlPath)
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if job.itemKind == .directory { args.append("-r") }
        args.append("--")

        switch job.direction {
        case .upload:
            try validateLocal(job.sourcePath)
            let remote = try validateRemote(job.destinationPath)
            // Đích upload không bị glob → không escape.
            args += [job.sourcePath, "\(job.sshAliasSnapshot):\(remote)"]
            return ScpInvocation(executable: executable, arguments: args, tempPartialPath: nil)
        case .download:
            let remote = try validateRemote(job.sourcePath)
            try validateLocal(job.destinationPath)
            let partial = try partialPath(for: job.destinationPath, jobID: job.id)
            args += ["\(job.sshAliasSnapshot):\(escapeRemoteSource(remote))", partial]
            return ScpInvocation(executable: executable, arguments: args, tempPartialPath: partial)
        }
    }

    /// `/dir/name` → `/dir/.name.sshdesk-<uuid>.part`
    public static func partialPath(for destination: String, jobID: UUID) throws -> String {
        try validateLocal(destination)
        let url = URL(fileURLWithPath: destination)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { throw ScpBuildError.localNameMissing }
        return url.deletingLastPathComponent().appendingPathComponent(
            partialName(for: name, jobID: jobID)
        ).path
    }

    static func partialName(for name: String, jobID: UUID) -> String {
        ".\(name).sshdesk-\(jobID.uuidString).part"
    }

    /// Chèn `\` trước `\ * ? [ ]` (chỉ dùng cho remote nguồn của download).
    public static func escapeRemoteSource(_ path: String) -> String {
        var out = ""
        for ch in path {
            if ch == "\\" || ch == "*" || ch == "?" || ch == "[" || ch == "]" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Kiểm tra

    private static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func validateConfig(_ p: String) throws {
        guard p.hasPrefix("/"), !hasControl(p) else { throw ScpBuildError.invalidConfigPath }
    }

    /// Tuyệt đối, không ký tự điều khiển, không khoảng trắng/`%` (ssh sẽ expand token).
    public static func validateControlPath(_ p: String) throws {
        guard p.hasPrefix("/"), !hasControl(p), !p.contains(" "), !p.contains("%"), !p.contains("\"")
        else { throw ScpBuildError.invalidControlPath(p) }
    }

    private static func validateAlias(_ a: String) throws {
        guard a.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        else { throw ScpBuildError.invalidAlias(a) }
    }

    private static func validateLocal(_ p: String) throws {
        guard !hasControl(p) else { throw ScpBuildError.invalidLocalPath(p) }
        guard p.hasPrefix("/") else { throw ScpBuildError.localPathNotAbsolute(p) }
    }

    private static func validateRemote(_ p: String) throws -> String {
        guard !p.isEmpty else { throw ScpBuildError.emptyRemotePath }
        if let bad = p.unicodeScalars.first(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            throw ScpBuildError.unsupportedRemotePathCharacter(
                String(format: "U+%04X", bad.value))
        }
        return p
    }
}
