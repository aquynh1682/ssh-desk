import Darwin
import Foundation

public enum BatchItemKind: String, Codable, Sendable, Equatable {
    case file, directory, symlink

    public var transferKind: TransferItemKind { self == .directory ? .directory : .file }
}

/// Một mục trong lô kéo thả.
public struct BatchItem: Codable, Sendable, Equatable {
    public let name: String
    /// Đường dẫn nguồn (local khi upload, remote khi download).
    public let path: String
    public let kind: BatchItemKind

    public init(name: String, path: String, kind: BatchItemKind) {
        self.name = name
        self.path = path
        self.kind = kind
    }

    public init(row: BrowserRow) {
        self.init(
            name: row.name, path: row.id,
            kind: row.isDirectory ? .directory : (row.isSymlink ? .symlink : .file))
    }
}

/// Dữ liệu kéo thả nội bộ giữa hai khung. Chỉ chứa đường dẫn, không đọc file.
public struct BrowserDragPayload: Codable, Sendable, Equatable {
    public enum Origin: Codable, Sendable, Equatable {
        case local
        case remote(hostID: UUID)
    }

    /// UTType riêng của app (khai báo trong Info.plist).
    public static let typeIdentifier = "local.sshdesk.browser-items"
    public static let maxItems = 5000

    public let origin: Origin
    public let items: [BatchItem]

    public init(origin: Origin, items: [BatchItem]) {
        self.origin = origin
        self.items = items
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Từ chối dữ liệu quá lớn hoặc có tên/đường dẫn chứa ký tự điều khiển.
    public static func decode(_ data: Data) -> BrowserDragPayload? {
        guard data.count < 8_000_000,
            let p = try? JSONDecoder().decode(BrowserDragPayload.self, from: data),
            !p.items.isEmpty, p.items.count <= maxItems
        else { return nil }
        for item in p.items {
            if item.name.isEmpty || item.name.contains("/") { return nil }
            if item.path.unicodeScalars.contains(where: BrowserRow.isControl) { return nil }
            if item.name.unicodeScalars.contains(where: BrowserRow.isControl) { return nil }
        }
        return p
    }
}

public enum BatchConflictChoice: Sendable, Equatable {
    case overwriteAll
    case skipConflicts
    /// Chỉ download.
    case autoRename
}

/// Một job dự kiến (chưa gắn host).
public struct PlannedTransfer: Sendable, Equatable {
    public let direction: TransferDirection
    public let source: String
    public let destination: String
    public let kind: TransferItemKind
    public let policy: OverwritePolicy
}

public struct TransferBatchPlan: Sendable, Equatable {
    public let direction: TransferDirection
    /// Thư mục đích (remote khi upload, local khi download).
    public let destinationDirectory: String
    public let items: [BatchItem]
    /// Tên trùng ở đích.
    public let conflicts: [String]
    /// Tên có ký tự điều khiển: không thao tác.
    public let unsupported: [String]

    public var hasConflicts: Bool { !conflicts.isEmpty }
    public var isEmpty: Bool { items.isEmpty }
}

public enum SourceRejection: Equatable, Sendable {
    case missing(String)
    case symlink(String)
    case containsSymlinks(name: String, links: [String])
    case notRegular(String)

    public var message: String {
        switch self {
        case .missing(let n): return "“\(n)” không còn tồn tại."
        case .symlink(let n): return "“\(n)” là symbolic link: chưa hỗ trợ tải lên."
        case .containsSymlinks(let n, let links):
            let shown = links.prefix(TransferFormLimits.symlinkDisplay).joined(separator: ", ")
            let more =
                links.count > TransferFormLimits.symlinkDisplay
                ? " … và \(links.count - TransferFormLimits.symlinkDisplay) mục khác" : ""
            return "Thư mục “\(n)” chứa symbolic link (scp sẽ theo link ra ngoài cây): \(shown)\(more)"
        case .notRegular(let n): return "“\(n)” không phải file hoặc thư mục thường."
        }
    }
}

public enum BrowserTransferPlanner {
    // MARK: - Nguồn local (upload)

    /// Kiểm tra từng đường dẫn local (lstat): không theo symlink; cây có symlink bị từ chối (ADR-008).
    public static func inspectLocalSources(_ paths: [String]) -> (
        items: [BatchItem], rejections: [SourceRejection]
    ) {
        var items: [BatchItem] = []
        var rejections: [SourceRejection] = []
        for path in paths {
            let name = BrowserPath.lastComponent(path)
            var st = stat()
            guard lstat(path, &st) == 0 else {
                rejections.append(.missing(name))
                continue
            }
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                rejections.append(.symlink(name))
            case S_IFDIR:
                let links = LocalTreeInspector.symlinks(
                    at: path, limit: TransferFormLimits.symlinkDisplay + 1)
                if links.isEmpty {
                    items.append(BatchItem(name: name, path: path, kind: .directory))
                } else {
                    rejections.append(.containsSymlinks(name: name, links: links))
                }
            case S_IFREG:
                items.append(BatchItem(name: name, path: path, kind: .file))
            default:
                rejections.append(.notRegular(name))
            }
        }
        return (items, rejections)
    }

    // MARK: - Lập kế hoạch

    /// `remoteNames`: tên trong thư mục remote hiện tại (listing mới nhất; không nguyên tử, có race).
    public static func planUpload(
        items: [BatchItem], remoteDirectory: String, remoteNames: Set<String>
    ) -> TransferBatchPlan {
        let (ok, bad) = split(items)
        return TransferBatchPlan(
            direction: .upload, destinationDirectory: remoteDirectory, items: ok,
            conflicts: ok.map(\.name).filter { remoteNames.contains($0) }, unsupported: bad)
    }

    public static func planDownload(
        items: [BatchItem], localDirectory: String,
        exists: (String) -> Bool = LocalFinalizer.localConflict
    ) -> TransferBatchPlan {
        let (ok, bad) = split(items)
        return TransferBatchPlan(
            direction: .download, destinationDirectory: localDirectory, items: ok,
            conflicts: ok.map(\.name).filter { exists(BrowserPath.join(localDirectory, $0)) },
            unsupported: bad)
    }

    private static func split(_ items: [BatchItem]) -> ([BatchItem], [String]) {
        var ok: [BatchItem] = []
        var bad: [String] = []
        for item in items {
            let hasControl =
                item.name.unicodeScalars.contains(where: BrowserRow.isControl)
                || item.path.unicodeScalars.contains(where: BrowserRow.isControl)
            if hasControl || item.name.isEmpty || item.name.contains("/") {
                bad.append(item.name)
            } else {
                ok.append(item)
            }
        }
        return (ok, bad)
    }

    // MARK: - Từ lựa chọn của người dùng sang danh sách job

    /// Upload:
    /// - file: đích `<remoteDir>/<tên>`; trùng + ghi đè → scp ghi đè file.
    /// - thư mục: đích là CHÍNH `<remoteDir>` (đã tồn tại): scp -r tạo `<remoteDir>/<tên>` nếu chưa có,
    ///   còn nếu đã có thì GỘP vào (file trùng tên bị ghi đè, file khác giữ nguyên) — đã kiểm chứng
    ///   bằng scp thật; đặt đích là `<remoteDir>/<tên>` thì thư mục trùng bị lồng thêm một cấp.
    public static func uploadJobs(_ plan: TransferBatchPlan, choice: BatchConflictChoice)
        -> [PlannedTransfer]
    {
        let skip = choice == .skipConflicts
        return plan.items.compactMap { item in
            if skip, plan.conflicts.contains(item.name) { return nil }
            let destination =
                item.kind == .directory
                ? plan.destinationDirectory
                : BrowserPath.join(plan.destinationDirectory, item.name)
            return PlannedTransfer(
                direction: .upload, source: item.path, destination: destination,
                kind: item.kind.transferKind, policy: .overwrite)
        }
    }

    /// Download: không trùng → `.rename(tên)` (đổi tên độc quyền, không ghi đè ngầm);
    /// trùng + ghi đè → `.overwrite`; trùng + đổi tên tự động → `.rename(tên khác)`; trùng + bỏ qua → không tạo job.
    public static func downloadJobs(
        _ plan: TransferBatchPlan, choice: BatchConflictChoice,
        suggest: (String, String) -> String = { name, dir in
            LocalFinalizer.suggestUniqueName(name, in: dir)
        }
    ) -> [PlannedTransfer] {
        plan.items.compactMap { item in
            let final = BrowserPath.join(plan.destinationDirectory, item.name)
            let policy: OverwritePolicy
            if plan.conflicts.contains(item.name) {
                switch choice {
                case .overwriteAll: policy = .overwrite
                case .skipConflicts: return nil
                case .autoRename: policy = .rename(suggest(item.name, plan.destinationDirectory))
                }
            } else {
                policy = .rename(item.name)
            }
            return PlannedTransfer(
                direction: .download, source: item.path, destination: final,
                kind: item.kind.transferKind, policy: policy)
        }
    }

    public enum JobBuildError: Error, Equatable { case hostMissingAlias }

    public static func makeJobs(
        _ planned: [PlannedTransfer], host: HostProfile, configPath: String
    ) throws -> [TransferJob] {
        guard let alias = host.sshAlias else { throw JobBuildError.hostMissingAlias }
        return planned.map {
            TransferJob(
                hostID: host.id, hostDisplayNameSnapshot: host.displayName,
                targetSnapshot: TransferTarget.describe(host), sshAliasSnapshot: alias,
                configPathSnapshot: configPath, direction: $0.direction, sourcePath: $0.source,
                destinationPath: $0.destination, itemKind: $0.kind, overwritePolicy: $0.policy)
        }
    }
}

/// Quy tắc an toàn cho máy PROD.
public enum BrowserSafety {
    public static func requiresUploadConfirmation(_ host: HostProfile) -> Bool {
        host.environment == .prod
    }

    public static func uploadConfirmationTitle(_ host: HostProfile) -> String {
        "Tải lên máy PROD \(host.displayName)?"
    }

    public enum DeleteConfirmation: Equatable, Sendable {
        /// Hộp xác nhận thường (PROD vẫn có cảnh báo nhấn mạnh ở UI).
        case simple
        /// Phải gõ lại tên host.
        case typeHostName
    }

    public static func deleteConfirmation(host: HostProfile, isDirectory: Bool) -> DeleteConfirmation {
        host.environment == .prod && isDirectory ? .typeHostName : .simple
    }

    /// So khớp chính xác tên hiển thị (bỏ khoảng trắng hai đầu).
    public static func isHostNameTyped(_ typed: String, host: HostProfile) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t == host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Tóm tắt kế hoạch xoá đệ quy để người dùng xác nhận.
public struct DeletePlanSummary: Equatable, Sendable {
    public static let maxListed = 50
    public let total: Int
    /// Đường dẫn tương đối với gốc (thư mục có `/` cuối), tối đa `maxListed`, thứ tự xoá.
    public let listed: [String]
    public var hiddenCount: Int { total - listed.count }

    public init(_ plan: RemoteDeletePlan) {
        total = plan.totalCount
        let root = BrowserPath.trimTrailingSlashes(plan.root)
        let rootName = BrowserPath.lastComponent(root)
        listed = plan.items.prefix(Self.maxListed).map { item in
            var rel =
                item.path == root
                ? rootName
                : rootName + String(item.path.dropFirst(root.count))
            if item.kind == .directory { rel += "/" }
            return rel
        }
    }
}

/// Khi nào khung cần làm mới sau khi job hoàn tất.
public enum BrowserRefreshRule {
    public static func shouldRefreshRemote(job: TransferJob, hostID: UUID, currentPath: String)
        -> Bool
    {
        guard job.state == .completed, job.direction == .upload, job.hostID == hostID else {
            return false
        }
        // File: đích `<dir>/<tên>`. Thư mục: đích là chính `<dir>` (gộp).
        return BrowserPath.parent(job.destinationPath) == currentPath
            || BrowserPath.trimTrailingSlashes(job.destinationPath) == currentPath
    }

    public static func shouldRefreshLocal(job: TransferJob, currentDirectory: String) -> Bool {
        guard job.state == .completed, job.direction == .download else { return false }
        return BrowserPath.parent(job.destinationPath) == currentDirectory
    }
}

/// Thông báo lỗi tiếng Việt cho thao tác duyệt file.
public enum BrowserErrorText {
    public static func message(for error: Error) -> String {
        switch error {
        case let e as RemoteFileError: return remote(e)
        case let e as LocalFileError: return local(e)
        case let e as SocketDirectory.Failure: return "Thư mục socket không an toàn: \(e)"
        case let e as RemoteSessionError:
            switch e {
            case .alreadyStarted: return "Phiên đã được khởi chạy."
            case .socketInUse: return "Máy này đã đang kết nối ở nơi khác (socket đang được dùng)."
            case .staleSocketNotRemovable(let p): return "Không xoá được socket cũ: \(p)"
            case .spawnFailed(let m): return "Không chạy được ssh: \(m)"
            }
        default: return error.localizedDescription
        }
    }

    public static func remote(_ e: RemoteFileError) -> String {
        switch e {
        case .invalidPath(let p): return "Đường dẫn không hợp lệ: \(p)"
        case .unsupportedName: return "Tên chứa ký tự điều khiển — không hỗ trợ."
        case .destinationExists(let p): return "Đã tồn tại: \(p)"
        case .permissionDenied(let p): return "Không đủ quyền: \(p) (SSH Desk không dùng sudo)."
        case .notFound(let p): return "Không tìm thấy: \(p)"
        case .directoryNotEmpty(let p): return "Thư mục không rỗng: \(p)"
        case .commandFailed(let m), .connectionFailed(let m): return m
        case .sessionLost: return "Mất kết nối tới máy chủ."
        case .timeout: return "Hết thời gian chờ."
        case .tooManyEntries(let limit):
            return "Thư mục có hơn \(limit) mục — quá lớn để xoá từ đây."
        case .unparsedEntries(let dir, let n):
            return "Không đọc được \(n) dòng trong \(dir) (tên lạ) — từ chối xoá đệ quy."
        case .deleteInterrupted(let deleted, let failed, let message):
            return "Dừng sau khi xoá \(deleted) mục. Lỗi ở \(failed): \(message)"
        }
    }

    public static func local(_ e: LocalFileError) -> String {
        switch e {
        case .invalidName: return "Tên không hợp lệ."
        case .destinationExists(let p): return "Đã tồn tại: \(p)"
        case .notFound(let p): return "Không tìm thấy: \(p)"
        case .failed(let m): return m
        }
    }
}
