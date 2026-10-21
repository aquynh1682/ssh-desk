import Darwin
import Foundation

/// Tạo key ed25519 mới bằng `/usr/bin/ssh-keygen` qua PTY (ADR-014). Passphrase do người dùng nhập ở
/// prompt của ssh-keygen (UI SecureField, có thể để trống) — không đi qua argv/env, không lưu.
public struct SSHKeyGenerator: Sendable {
    public static let keygenPath = "/usr/bin/ssh-keygen"

    public let directory: URL
    public let name: String
    public let comment: String
    private let keygen: URL
    private let helper: URL?
    private let environment: [String: String]

    /// Ném lỗi nếu tên/comment xấu hoặc `<dir>/<name>` hoặc `<dir>/<name>.pub` đã tồn tại
    /// (kể cả symlink treo) — không bao giờ ghi đè.
    public init(
        directory: URL = SSHKeyInventory.defaultDirectory, name: String, comment: String,
        keygenPath: String = keygenPath, helper: URL? = nil,
        environment: [String: String] = ProcessEnvironment.inherited()
    ) throws {
        try SSHKeyNaming.validateName(name)
        try SSHKeyNaming.validateComment(comment)
        self.directory = directory
        self.name = name
        self.comment = comment
        self.keygen = URL(fileURLWithPath: keygenPath)
        self.helper = helper
        self.environment = environment
        for p in [privatePath, publicPath] where SSHKeyInventory.lstatInfo(p) != nil {
            throw SSHKeyError.alreadyExists(p)
        }
    }

    public var privatePath: String { directory.appendingPathComponent(name).path }
    public var publicPath: String { privatePath + ".pub" }

    /// Tạo thư mục (0700) nếu chưa có rồi chạy ssh-keygen. Kết quả qua `session.events`.
    public func start() async throws -> KeyTaskSession {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw SSHKeyError.directoryNotUsable(directory.path) }
        } else {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Kiểm tra lại ngay trước khi chạy (giữa init và start có thể có file xuất hiện).
        for p in [privatePath, publicPath] where SSHKeyInventory.lstatInfo(p) != nil {
            throw SSHKeyError.alreadyExists(p)
        }
        let priv = privatePath
        let pub = publicPath
        let session = KeyTaskSession(
            executable: keygen,
            arguments: ["-q", "-t", "ed25519", "-f", priv, "-C", comment],
            environment: environment, helper: helper, refuseOverwrite: true,
            evaluate: { exit, tail in
                guard case .exited(0) = exit else {
                    return .failure(Self.failureReason(exit, tail))
                }
                guard SSHKeyInventory.lstatInfo(priv) != nil, SSHKeyInventory.lstatInfo(pub) != nil else {
                    return .failure("ssh-keygen kết thúc nhưng không thấy file key được tạo.")
                }
                return .success("Đã tạo key \(URL(fileURLWithPath: priv).lastPathComponent).")
            })
        try await session.start()
        return session
    }

    static func failureReason(_ exit: ProcessExit, _ tail: [String]) -> String {
        let detail = tail.suffix(2).joined(separator: " ")
        switch exit {
        case .exited(let code): return "ssh-keygen thoát với mã \(code)" + (detail.isEmpty ? "." : ": \(detail)")
        case .signaled(let sig): return "ssh-keygen bị dừng bởi tín hiệu \(sig)."
        case .cancelled: return "Đã huỷ."
        }
    }
}
