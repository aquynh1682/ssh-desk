import Darwin
import Foundation

public struct LocalEntry: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: RemoteEntryKind
    public let size: Int64
    public let modified: Date?
    public let isHidden: Bool
}

public enum LocalFileError: Error, Equatable {
    case invalidName(String)
    case destinationExists(String)
    case notFound(String)
    case failed(String)
}

/// Thao tác filesystem local cho khung trái. Không đi theo symlink (dùng `lstat`).
public struct LocalFileService: Sendable {
    public init() {}

    public func list(_ dir: String) throws -> [LocalEntry] {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dir)
        } catch {
            throw LocalFileError.failed(error.localizedDescription)
        }
        var result: [LocalEntry] = []
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let kind: RemoteEntryKind
            switch st.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            let mtime = Date(
                timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                    + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            result.append(
                LocalEntry(
                    name: name, path: path, kind: kind, size: Int64(st.st_size), modified: mtime,
                    isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func mkdir(in parent: String, name: String) throws -> String {
        try Self.validate(name)
        let path = (parent as NSString).appendingPathComponent(name)
        if Darwin.mkdir(path, 0o755) != 0 {
            throw errno == EEXIST ? LocalFileError.destinationExists(path) : errnoError()
        }
        return path
    }

    /// Đổi tên, không ghi đè (RENAME_EXCL nguyên tử).
    @discardableResult
    public func rename(path: String, newName: String) throws -> String {
        try Self.validate(newName)
        let dest = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(newName)
        if renamex_np(path, dest, UInt32(RENAME_EXCL)) != 0 {
            switch errno {
            case EEXIST: throw LocalFileError.destinationExists(dest)
            case ENOENT: throw LocalFileError.notFound(path)
            default: throw errnoError()
            }
        }
        return dest
    }

    /// Chuyển vào Thùng rác (không xoá vĩnh viễn). Symlink: chuyển chính link.
    @discardableResult
    public func moveToTrash(path: String) throws -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw LocalFileError.notFound(path) }
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
        } catch {
            throw LocalFileError.failed(error.localizedDescription)
        }
        return (result as URL?)?.path
    }

    private static func validate(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/")
            || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        {
            throw LocalFileError.invalidName(name)
        }
    }

    private func errnoError() -> LocalFileError {
        LocalFileError.failed(String(cString: strerror(errno)))
    }
}
