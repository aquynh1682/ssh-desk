import Darwin
import Foundation

public enum LocalFinalizeError: Error, Equatable {
    case notThisJobsPartial(String)
    case partialMissing(String)
    case invalidNewName(String)
    /// Đích (mới) đã tồn tại; không ghi đè.
    case destinationExists(String)
    case systemError(Int32)
}

public enum LocalFinalizeOutcome: Equatable, Sendable {
    case replaced(String)
    case renamed(String)
    case skipped
}

/// Hoàn tất download ở local và dọn `.part`. Chỉ đụng đúng file/thư mục `.part` của job.
public enum LocalFinalizer {
    /// Có gì đó ở đường dẫn này (kể cả symlink hỏng) → xung đột. Dùng `lstat`, không theo link.
    public static func localConflict(_ destination: String) -> Bool {
        var st = stat()
        return lstat(destination, &st) == 0
    }

    /// `a.txt` → `a (1).txt`, `a (2).txt`... trong `directory`; tên không có xung đột thì giữ nguyên.
    public static func suggestUniqueName(_ name: String, in directory: String) -> String {
        var i = 0
        while true {
            let candidate = i == 0 ? name : numbered(name, i)
            let full = URL(fileURLWithPath: directory).appendingPathComponent(candidate).path
            if !localConflict(full) { return candidate }
            i += 1
        }
    }

    /// Thuần: `numbered("a.txt", 1)` = `a (1).txt`; `.bashrc` → `.bashrc (1)`.
    public static func numbered(_ name: String, _ n: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty || ns.deletingPathExtension.isEmpty { return "\(name) (\(n))" }
        return "\(ns.deletingPathExtension) (\(n)).\(ext)"
    }

    /// Đường dẫn có đúng dạng `.part` của job này không (tên khớp `.<x>.sshdesk-<jobid>.part`).
    public static func isPartialPath(_ path: String, jobID: UUID) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".sshdesk-\(jobID.uuidString).part")
            && name.count > ".sshdesk-\(jobID.uuidString).part".count
    }

    /// Áp chính sách ghi đè lên `.part` sau download THÀNH CÔNG.
    @discardableResult
    public static func finalize(
        partialPath: String, destination: String, policy: OverwritePolicy, jobID: UUID
    ) throws -> LocalFinalizeOutcome {
        guard isPartialPath(partialPath, jobID: jobID) else {
            throw LocalFinalizeError.notThisJobsPartial(partialPath)
        }
        guard localConflict(partialPath) else { throw LocalFinalizeError.partialMissing(partialPath) }

        switch policy {
        case .skip:
            _ = cleanupPartial(path: partialPath, jobID: jobID)
            return .skipped
        case .overwrite:
            if localConflict(destination) {
                // replaceItemAt: thay thế an toàn (tạo bản sao lưu tạm rồi hoán đổi).
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: destination), withItemAt: URL(fileURLWithPath: partialPath)
                )
            } else {
                try moveExclusive(partialPath, to: destination)
            }
            return .replaced(destination)
        case .rename(let newName):
            guard validName(newName) else { throw LocalFinalizeError.invalidNewName(newName) }
            let target = URL(fileURLWithPath: destination).deletingLastPathComponent()
                .appendingPathComponent(newName).path
            try moveExclusive(partialPath, to: target)
            return .renamed(target)
        }
    }

    /// Xoá `.part` của đúng job này (lỗi/huỷ/skip). Không bao giờ xoá đường dẫn khác.
    /// Symlink bị xoá chính nó, không theo link. Trả true nếu đã xoá.
    @discardableResult
    public static func cleanupPartial(path: String, jobID: UUID) -> Bool {
        guard isPartialPath(path, jobID: jobID), localConflict(path) else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    // MARK: - Nội bộ

    static func validName(_ n: String) -> Bool {
        !n.isEmpty && n != "." && n != ".." && !n.contains("/")
            && !n.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// Đổi tên không ghi đè (RENAME_EXCL, nguyên tử): nếu đích xuất hiện giữa chừng → lỗi.
    private static func moveExclusive(_ from: String, to: String) throws {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 {
            let e = errno
            if e == EEXIST { throw LocalFinalizeError.destinationExists(to) }
            throw LocalFinalizeError.systemError(e)
        }
    }
}

/// Quét cây thư mục local TRƯỚC khi upload: `scp -r` (SFTP) theo symlink ra ngoài cây
/// (xem thí nghiệm), nên app phải từ chối/cảnh báo.
public enum LocalTreeInspector {
    /// Đường dẫn tương đối của mọi symlink trong cây (`"."` nếu chính `root` là symlink).
    public static func symlinks(at root: String, limit: Int = 100) -> [String] {
        let fm = FileManager.default
        var st = stat()
        guard lstat(root, &st) == 0 else { return [] }
        if (st.st_mode & S_IFMT) == S_IFLNK { return ["."] }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return [] }
        guard let subs = try? fm.subpathsOfDirectory(atPath: root) else { return [] }
        var found: [String] = []
        for rel in subs.sorted() {
            var s = stat()
            if lstat(root + "/" + rel, &s) == 0, (s.st_mode & S_IFMT) == S_IFLNK {
                found.append(rel)
                if found.count >= limit { break }
            }
        }
        return found.sorted()
    }
}
