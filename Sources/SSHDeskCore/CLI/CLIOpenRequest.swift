import Darwin
import Foundation

/// File yêu cầu mở host từ CLI sang app (ADR-025). Nội dung chỉ `{hostID, createdAt}`.
/// Thư mục 0700, file 0600, ghi atomically (tạo tạm O_EXCL rồi rename), đọc xong xoá ngay, hết hạn sau 30 giây.
public enum CLIOpenRequest {
    public static let timeToLive: TimeInterval = 30
    /// Cho phép đồng hồ lệch nhẹ; createdAt ở tương lai xa hơn mức này coi là không hợp lệ.
    static let clockSkew: TimeInterval = 5
    static let maxFileSize = 4096

    struct Payload: Codable, Equatable {
        let hostID: UUID
        let createdAt: Date
    }

    public enum Outcome: Equatable, Sendable {
        case valid(hostID: UUID)
        case missing
        case expired
        /// Không phải file thường của đúng user/0600, quá lớn hoặc JSON sai.
        case invalid
    }

    public static func directory(in paths: AppPaths) -> URL {
        paths.baseDirectory.appendingPathComponent("requests", isDirectory: true)
    }

    private static func fileURL(_ id: UUID, in dir: URL) -> URL {
        // UUID đã parse -> chỉ chứa hex và '-', không thể thoát khỏi thư mục.
        dir.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// Ghi yêu cầu, trả về request id. Dọn luôn các file yêu cầu cũ quá hạn.
    @discardableResult
    public static func write(hostID: UUID, in dir: URL, now: Date = Date()) throws -> UUID {
        try ensureDirectory(dir)
        purgeStale(in: dir, now: now)
        let requestID = UUID()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let data = try enc.encode(Payload(hostID: hostID, createdAt: now))

        let final = fileURL(requestID, in: dir)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posix("không tạo được file yêu cầu") }
        var ok = true
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 {
                    ok = false
                    break
                }
                off += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(temp.path, final.path) == 0 else {
            let e = posix("không ghi được file yêu cầu")
            unlink(temp.path)
            throw e
        }
        return requestID
    }

    /// Đọc rồi xoá ngay (xoá trước khi phân tích: dùng một lần dù kết quả thế nào).
    public static func consume(id: UUID, in dir: URL, now: Date = Date()) -> Outcome {
        let path = fileURL(id, in: dir).path
        var lst = stat()
        guard lstat(path, &lst) == 0 else { return .missing }
        defer { unlink(path) }
        // Thư mục requests phải là 0700 và của đúng user (nếu không, người khác có thể đã thay file).
        var dst = stat()
        guard stat(dir.path, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR, dst.st_uid == getuid(),
            (dst.st_mode & 0o077) == 0
        else { return .invalid }
        // Đọc trên fd đã mở (không theo symlink) rồi fstat: kiểm tra và đọc cùng một file.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .invalid }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
            (st.st_mode & 0o077) == 0, st.st_size <= maxFileSize
        else { return .invalid }
        var buffer = [UInt8](repeating: 0, count: maxFileSize + 1)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0, n <= maxFileSize else { return .invalid }
        let data = Data(buffer[0..<n])
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? dec.decode(Payload.self, from: data) else { return .invalid }
        let age = now.timeIntervalSince(payload.createdAt)
        if age > timeToLive || age < -clockSkew { return .expired }
        return .valid(hostID: payload.hostID)
    }

    /// CLI gọi khi không mở được app, để không để lại file.
    public static func discard(id: UUID, in dir: URL) {
        unlink(fileURL(id, in: dir).path)
    }

    // MARK: - Nội bộ

    private static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(
                    at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch { throw RequestError.io("không chuẩn bị được thư mục yêu cầu: \(error)") }
    }

    /// Xoá file `*.json`/`.tmp` có mtime quá 2x hạn dùng (kể cả file rác do tiến trình khác bỏ lại).
    static func purgeStale(in dir: URL, now: Date) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items {
            let p = dir.appendingPathComponent(name).path
            var st = stat()
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if now.timeIntervalSince(mtime) > timeToLive * 2 { unlink(p) }
        }
    }

    private static func posix(_ what: String) -> RequestError {
        .io("\(what): \(String(cString: strerror(errno)))")
    }

    public enum RequestError: Error, Equatable, CustomStringConvertible {
        case io(String)
        public var description: String {
            switch self {
            case .io(let s): return s
            }
        }
    }
}
