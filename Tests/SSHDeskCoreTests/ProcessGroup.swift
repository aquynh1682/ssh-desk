import Darwin
import Testing

/// Nhóm mọi suite tạo PTY/process thật (PTYProcess, sshd tạm, scp...). `.serialized` áp cho cả cây suite
/// lồng bên trong, nên các suite này không chạy song song với nhau (tránh tranh fd/cổng/tty và
/// làm sai các phép đo như `doesNotLeakFileDescriptors`). Suite mới có spawn process: khai báo
/// `extension ProcessGroup { @Suite struct ... }`.
@Suite(.serialized) enum ProcessGroup {}

/// Chỉ đếm fd trỏ tới thiết bị pty (`/dev/ptmx`, `/dev/ttysNNN`...): fd khác của process test
/// (SQLite, pipe, socket của suite chạy song song) không làm lệch phép đo. Các suite tạo PTY đều
/// nằm trong `ProcessGroup` (tuần tự) nên không có PTY lạ xuất hiện giữa lúc đo.
func ptyFDCount() -> Int {
    (0..<1024).filter { fd in
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(Int32(fd), F_GETPATH, &buffer) != -1 else { return false }
        let path = String(cString: buffer)
        return path.hasPrefix("/dev/ptmx") || path.hasPrefix("/dev/pty") || path.hasPrefix("/dev/tty")
    }.count
}
