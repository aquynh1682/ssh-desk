import Foundation

/// Đường dẫn dữ liệu của app. Nhận thư mục gốc để test dùng thư mục tạm.
public struct AppPaths: Sendable, Equatable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// `~/Library/Application Support/SSHDesk/`
    public static var `default`: AppPaths {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(baseDirectory: support.appendingPathComponent("SSHDesk", isDirectory: true))
    }

    public var databaseURL: URL { baseDirectory.appendingPathComponent("sshdesk.sqlite") }
    public var sshConfigURL: URL {
        baseDirectory.appendingPathComponent("ssh", isDirectory: true).appendingPathComponent("config")
    }

    /// Tạo thư mục gốc với quyền 0700 (và siết lại nếu đã tồn tại).
    public func prepareDirectories() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDirectory.path) {
            try fm.createDirectory(
                at: baseDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
    }

    /// `~/.ssh/config` tuyệt đối; nil nếu file không tồn tại (khi đó không có `Include`).
    public static func existingUserConfigPath() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
