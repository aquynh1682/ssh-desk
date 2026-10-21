import Darwin
import Foundation

/// Thư mục chứa socket ControlMaster: `/tmp/sshdesk-<uid>` (ADR-013).
/// Không dùng `$TMPDIR`/Application Support vì `sun_path` giới hạn ~104 byte.
public struct SocketDirectory: Sendable, Equatable {
    public enum Failure: Error, Equatable {
        case createFailed(path: String, errno: Int32)
        case notDirectory(String)
        case wrongOwner(path: String, owner: UInt32, expected: UInt32)
        case wrongMode(path: String, mode: UInt16)
        case pathTooLong(path: String, bytes: Int)
    }

    /// Độ dài tối đa của thư mục (byte): + "/" + 32 hex + hậu tố tạm của ssh (17) phải < 104.
    public static let maxDirectoryBytes = 42

    public let path: String

    /// `base` chỉ để test; mặc định `/tmp`.
    public static func ensure(base: String = "/tmp", uid: uid_t = getuid()) throws -> SocketDirectory {
        let path = base + "/sshdesk-\(uid)"
        let bytes = path.utf8.count
        guard bytes <= maxDirectoryBytes else { throw Failure.pathTooLong(path: path, bytes: bytes) }

        if mkdir(path, 0o700) != 0 {
            guard errno == EEXIST else { throw Failure.createFailed(path: path, errno: errno) }
        }
        // lstat: không đi theo symlink.
        var st = stat()
        guard lstat(path, &st) == 0 else { throw Failure.createFailed(path: path, errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure.notDirectory(path) }
        guard st.st_uid == uid else {
            throw Failure.wrongOwner(path: path, owner: UInt32(st.st_uid), expected: UInt32(uid))
        }
        let perm = UInt16(st.st_mode & 0o7777)
        guard perm == 0o700 else { throw Failure.wrongMode(path: path, mode: perm) }
        return SocketDirectory(path: path)
    }

    /// `<dir>/<32 hex của hostID>`; không dùng `%C` nên app biết chính xác đường dẫn socket.
    public func socketPath(hostID: UUID) -> String {
        path + "/" + hostID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
