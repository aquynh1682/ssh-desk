import Foundation

public enum RemoteFileError: Error, Equatable {
    case invalidPath(String)
    /// Tên/đường dẫn có ký tự điều khiển.
    case unsupportedName(String)
    case destinationExists(String)
    case permissionDenied(String)
    case notFound(String)
    case directoryNotEmpty(String)
    case commandFailed(String)
    /// Master đã chết (ControlPath không còn dùng được).
    case sessionLost
    /// sftp exit 255 nhưng master còn sống.
    case connectionFailed(String)
    case timeout
    case tooManyEntries(limit: Int)
    /// Có dòng `ls` không parse được trong thư mục này — từ chối lập kế hoạch xoá đệ quy.
    case unparsedEntries(directory: String, count: Int)
    /// Xoá đệ quy dừng giữa chừng: đã xoá `deleted` mục.
    case deleteInterrupted(deleted: Int, failedPath: String, message: String)
}

public struct RemoteListing: Sendable, Equatable {
    public let path: String
    public let entries: [RemoteEntry]
    public let unparsedLines: Int
}

public struct RemoteDeleteItem: Sendable, Equatable {
    public let path: String
    public let kind: RemoteEntryKind
}

/// Kế hoạch xoá đệ quy theo thứ tự thực thi: file/symlink trước, rồi thư mục từ sâu lên, gốc cuối cùng.
public struct RemoteDeletePlan: Sendable, Equatable {
    public let root: String
    public let items: [RemoteDeleteItem]
    public var totalCount: Int { items.count }
}

/// Thao tác file remote qua `sftp -b -` dùng lại master của `RemoteSession` (ADR-013).
public actor RemoteFileService {
    public static let maxPlanEntries = 5000

    private let session: RemoteSession
    private let sftpPath: String
    private let timeout: TimeInterval
    private let environment: [String: String]

    public init(
        session: RemoteSession, sftpPath: String = "/usr/bin/sftp", timeout: TimeInterval = 30,
        environment: [String: String] = ProcessEnvironment.inherited()
    ) {
        self.session = session
        self.sftpPath = sftpPath
        self.timeout = timeout
        self.environment = environment
    }

    // MARK: - API

    public func home() async throws -> String {
        let out = try await runBatch(SftpBatch.pwd, op: .pwd, subject: "~")
        let prefix = "Remote working directory: "
        for line in out.split(separator: "\n") where line.hasPrefix(prefix) {
            let p = String(line.dropFirst(prefix.count))
            if !p.isEmpty { return p }
        }
        throw RemoteFileError.commandFailed("Không đọc được thư mục home từ server.")
    }

    public func list(_ dir: String) async throws -> RemoteListing {
        try Self.validate(dir)
        let out = try await runBatch(try batch { try SftpBatch.list(dir) }, op: .list, subject: dir)
        let parsed = SftpListingParser.parse(out)
        return RemoteListing(path: dir, entries: parsed.entries, unparsedLines: parsed.unparsedLines)
    }

    public func mkdir(_ dir: String) async throws {
        try Self.validate(dir)
        _ = try await runBatch(try batch { try SftpBatch.mkdir(dir) }, op: .mkdir, subject: dir)
    }

    /// `overwrite == false`: liệt kê thư mục đích trước, tên đã có → `.destinationExists` (có race, ADR-013).
    public func rename(from: String, to: String, overwrite: Bool) async throws {
        try Self.validate(from)
        try Self.validate(to)
        if !overwrite {
            let (parent, name) = Self.split(to)
            let listing = try await list(parent)
            if listing.entries.contains(where: { $0.name == name }) {
                throw RemoteFileError.destinationExists(to)
            }
        }
        _ = try await runBatch(try batch { try SftpBatch.rename(from, to) }, op: .rename, subject: from)
    }

    public func remove(file: String) async throws {
        try Self.validate(file)
        _ = try await runBatch(try batch { try SftpBatch.rm(file) }, op: .rm, subject: file)
    }

    public func removeEmptyDirectory(_ dir: String) async throws {
        try Self.validate(dir)
        _ = try await runBatch(try batch { try SftpBatch.rmdir(dir) }, op: .rmdir, subject: dir)
    }

    /// Duyệt cây bằng `list`, không đi vào symlink. Vượt `maxPlanEntries` → `.tooManyEntries`.
    public func planRecursiveDelete(_ dir: String) async throws -> RemoteDeletePlan {
        try Self.validate(dir)
        let root = Self.trimTrailingSlash(dir)
        var files: [RemoteDeleteItem] = []
        var dirs: [(path: String, depth: Int)] = [(root, 0)]
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var count = 1
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            let listing = try await list(current)
            if listing.unparsedLines > 0 {
                throw RemoteFileError.unparsedEntries(directory: current, count: listing.unparsedLines)
            }
            for entry in listing.entries {
                guard entry.hasSupportedName else { throw RemoteFileError.unsupportedName(entry.name) }
                let path = Self.join(current, entry.name)
                count += 1
                if count > Self.maxPlanEntries {
                    throw RemoteFileError.tooManyEntries(limit: Self.maxPlanEntries)
                }
                if entry.kind == .directory {
                    dirs.append((path, depth + 1))
                    queue.append((path, depth + 1))
                } else {
                    files.append(RemoteDeleteItem(path: path, kind: entry.kind))
                }
            }
        }
        let orderedDirs = dirs.enumerated().sorted {
            $0.element.depth != $1.element.depth
                ? $0.element.depth > $1.element.depth : $0.offset < $1.offset
        }.map { RemoteDeleteItem(path: $0.element.path, kind: .directory) }
        return RemoteDeletePlan(root: root, items: files + orderedDirs)
    }

    /// Trả về số mục đã xoá. Dừng ở lỗi đầu tiên → `.deleteInterrupted(deleted:...)`.
    @discardableResult
    public func executeRecursiveDelete(
        _ plan: RemoteDeletePlan, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Int {
        var deleted = 0
        for item in plan.items {
            do {
                try Task.checkCancellation()
                if item.kind == .directory {
                    try await removeEmptyDirectory(item.path)
                } else {
                    try await remove(file: item.path)
                }
            } catch {
                let message: String
                switch error {
                case let e as RemoteFileError: message = Self.describe(e)
                case is CancellationError: message = "Đã huỷ."
                default: message = "\(error)"
                }
                throw RemoteFileError.deleteInterrupted(
                    deleted: deleted, failedPath: item.path, message: message)
            }
            deleted += 1
            progress?(deleted, plan.totalCount)
        }
        return deleted
    }

    // MARK: - Đường dẫn

    private static func validate(_ path: String) throws {
        guard !path.isEmpty, path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else {
            throw RemoteFileError.invalidPath(path)
        }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw RemoteFileError.unsupportedName(path)
        }
    }

    static func trimTrailingSlash(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// (thư mục cha, tên cuối). `/a` → (`/`, `a`); `~/a` → (`~`, `a`).
    static func split(_ path: String) -> (String, String) {
        let p = trimTrailingSlash(path)
        guard let idx = p.lastIndex(of: "/") else { return (".", p) }
        let name = String(p[p.index(after: idx)...])
        let parent = String(p[..<idx])
        return (parent.isEmpty ? "/" : parent, name)
    }

    public static func describe(_ e: RemoteFileError) -> String {
        switch e {
        case .commandFailed(let m), .connectionFailed(let m): return m
        case .permissionDenied(let p): return "Không đủ quyền: \(p)"
        case .notFound(let p): return "Không tìm thấy: \(p)"
        case .directoryNotEmpty(let p): return "Thư mục không rỗng: \(p)"
        case .sessionLost: return "Mất kết nối tới máy chủ."
        case .timeout: return "Hết thời gian chờ."
        default: return "\(e)"
        }
    }

    // MARK: - Chạy sftp

    private enum Op { case pwd, list, mkdir, rename, rm, rmdir }

    private func batch(_ build: () throws -> String) throws -> String {
        do {
            return try build()
        } catch let e as SftpBatchError {
            switch e {
            case .controlCharacter(let s): throw RemoteFileError.unsupportedName(s)
            case .emptyPath: throw RemoteFileError.invalidPath("")
            }
        }
    }

    private func runBatch(_ script: String, op: Op, subject: String) async throws -> String {
        // Master chết thì sftp có thể âm thầm xác thực lại bằng kết nối trực tiếp: kiểm trước.
        guard await session.checkAlive() else { throw RemoteFileError.sessionLost }
        let args = [
            "-q", "-F", session.configPath,
            "-o", "ControlPath=\(session.controlPath)",
            // Không bao giờ hỏi/xác thực lại: nếu rơi khỏi master thì thất bại nhanh.
            "-o", "BatchMode=yes", "-o", "PreferredAuthentications=none", "-o", "ConnectTimeout=10",
            "-b", "-", "--", session.alias,
        ]
        let out: SimpleProcessOutput
        do {
            out = try await SimpleProcess.run(
                executable: sftpPath, arguments: args, stdin: script, environment: environment,
                timeout: timeout)
        } catch {
            throw RemoteFileError.commandFailed("Không chạy được sftp: \(error.localizedDescription)")
        }
        if out.timedOut { throw RemoteFileError.timeout }
        switch out.status {
        case 0:
            return out.stdout
        case 255:
            if await session.checkAlive() == false { throw RemoteFileError.sessionLost }
            throw RemoteFileError.connectionFailed(Self.cleanMessage(out))
        default:
            throw Self.classify(Self.cleanMessage(out), op: op, subject: subject)
        }
    }

    static func cleanMessage(_ out: SimpleProcessOutput) -> String {
        var text = out.stderr
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = out.stdout.split(separator: "\n").filter { !$0.hasPrefix("sftp>") }
                .joined(separator: "\n")
        }
        let scalars = OutputSanitizer.clean(text).unicodeScalars.filter {
            $0.value == 0x0A || ($0.value >= 0x20 && $0.value != 0x7F)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(500))
    }

    private static func classify(_ message: String, op: Op, subject: String) -> RemoteFileError {
        let lower = message.lowercased()
        if lower.contains("permission denied") { return .permissionDenied(subject) }
        if lower.contains("no such file") { return .notFound(subject) }
        if op == .rmdir, lower.contains("failure") || lower.contains("not empty") {
            return .directoryNotEmpty(subject)
        }
        return .commandFailed(message.isEmpty ? "Lệnh sftp thất bại." : message)
    }
}
