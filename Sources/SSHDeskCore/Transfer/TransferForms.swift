import Foundation

/// Mô tả target của host: `user@host:port` (managed) hoặc alias (imported).
public enum TransferTarget {
    public static func describe(_ host: HostProfile) -> String {
        switch host.connectionMode {
        case .managed: return "\(host.user)@\(host.hostName):\(host.port)"
        case .existingSSHConfigAlias: return "alias \(host.sshConfigAlias ?? "?")"
        }
    }
}

public enum TransferFormIssue: Equatable, Sendable {
    case remotePathEmpty
    case remotePathInvalid
    case remoteNameMissing
    case localDirectoryInvalid
    case nameInvalid
    case conflictChoiceRequired
    case renameInvalid
    case localSourceMissing
    case remoteDirectoryEmpty
    case symlinks([String])
    case hostMissingAlias

    public var message: String {
        switch self {
        case .remotePathEmpty: return "Nhập đường dẫn remote."
        case .remotePathInvalid: return "Đường dẫn remote chứa ký tự điều khiển."
        case .remoteNameMissing: return "Không suy ra được tên từ đường dẫn remote; hãy nhập tên lưu."
        case .localDirectoryInvalid: return "Chọn thư mục lưu local (đường dẫn tuyệt đối)."
        case .nameInvalid: return "Tên không hợp lệ (không rỗng, không chứa “/” hay ký tự điều khiển)."
        case .conflictChoiceRequired: return "Đích đã tồn tại — hãy chọn Ghi đè, Đổi tên hoặc Bỏ qua."
        case .renameInvalid: return "Tên mới không hợp lệ hoặc đã tồn tại."
        case .localSourceMissing: return "Chưa chọn file/thư mục local hoặc nó không còn tồn tại."
        case .remoteDirectoryEmpty: return "Nhập thư mục remote đích."
        case .symlinks(let l):
            let shown = l.prefix(TransferFormLimits.symlinkDisplay).joined(separator: ", ")
            let more =
                l.count > TransferFormLimits.symlinkDisplay
                ? " … và \(l.count - TransferFormLimits.symlinkDisplay) mục khác" : ""
            return "Thư mục chứa symbolic link nên chưa được hỗ trợ (scp sẽ theo link ra ngoài cây): \(shown)\(more)"
        case .hostMissingAlias: return "Hồ sơ thiếu alias SSH."
        }
    }
}

public enum TransferFormLimits {
    public static let symlinkDisplay = 20
}

public struct TransferFormError: Error, Equatable {
    public let issues: [TransferFormIssue]
}

enum PathText {
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// Bỏ `/` cuối (trừ khi toàn `/`).
    static func trimTrailingSlashes(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func join(_ dir: String, _ name: String) -> String {
        let d = trimTrailingSlashes(dir)
        return d == "/" ? "/" + name : d + "/" + name
    }

    static func baseName(_ path: String) -> String? {
        let t = trimTrailingSlashes(path)
        guard let last = t.split(separator: "/", omittingEmptySubsequences: true).last else {
            return nil
        }
        let name = String(last)
        return name == "." || name == ".." || name == "~" ? nil : name
    }
}

/// Lựa chọn khi đích local đã tồn tại.
public enum ConflictChoice: Sendable, Equatable {
    case overwrite
    case rename
    case skip
}

/// Form tải về. Thuần logic: UI chỉ gắn trường và gọi `issues` / `makeJob`.
public struct DownloadForm: Sendable, Equatable {
    public var remotePath = ""
    public var kind: TransferItemKind = .file
    public var localDirectory = ""
    /// Rỗng = lấy tên cuối của đường dẫn remote.
    public var localName = ""
    public var conflictChoice: ConflictChoice?
    public var renameTo = ""

    public init() {}

    public var effectiveName: String? {
        localName.isEmpty ? PathText.baseName(remotePath) : localName
    }

    /// Đường dẫn đích cuối (trước khi áp lựa chọn đổi tên).
    public var finalPath: String? {
        guard let name = effectiveName, !localDirectory.isEmpty else { return nil }
        return PathText.join(localDirectory, name)
    }

    public var hasConflict: Bool { finalPath.map(LocalFinalizer.localConflict) ?? false }

    public var suggestedRename: String? {
        guard let name = effectiveName, !localDirectory.isEmpty else { return nil }
        return LocalFinalizer.suggestUniqueName(name, in: localDirectory)
    }

    /// Đường dẫn thực sự sẽ có file sau khi hoàn tất (theo lựa chọn hiện tại).
    public var resultPath: String? {
        guard let final = finalPath else { return nil }
        if hasConflict, conflictChoice == .rename, !renameTo.isEmpty {
            return PathText.join(localDirectory, renameTo)
        }
        return final
    }

    public var issues: [TransferFormIssue] {
        var out: [TransferFormIssue] = []
        if remotePath.isEmpty {
            out.append(.remotePathEmpty)
        } else if PathText.hasControl(remotePath) {
            out.append(.remotePathInvalid)
        }
        if localDirectory.isEmpty || !localDirectory.hasPrefix("/")
            || PathText.hasControl(localDirectory)
        {
            out.append(.localDirectoryInvalid)
        }
        if let name = effectiveName {
            if !LocalFinalizer.validName(name) { out.append(.nameInvalid) }
        } else if !remotePath.isEmpty, !PathText.hasControl(remotePath) {
            out.append(.remoteNameMissing)
        }
        if out.isEmpty, hasConflict {
            switch conflictChoice {
            case nil: out.append(.conflictChoiceRequired)
            case .rename:
                let target = PathText.join(localDirectory, renameTo)
                if !LocalFinalizer.validName(renameTo) || LocalFinalizer.localConflict(target) {
                    out.append(.renameInvalid)
                }
            default: break
            }
        }
        return out
    }

    public var canStart: Bool { issues.isEmpty }

    public func makeJob(host: HostProfile, configPath: String) throws -> TransferJob {
        let problems = issues
        guard problems.isEmpty, let final = finalPath, let name = effectiveName else {
            throw TransferFormError(issues: problems)
        }
        guard let alias = host.sshAlias else {
            throw TransferFormError(issues: [.hostMissingAlias])
        }
        // Không xung đột: dùng đổi tên độc quyền (RENAME_EXCL) thay vì ghi đè ngầm.
        let policy: OverwritePolicy
        if hasConflict {
            switch conflictChoice {
            case .overwrite: policy = .overwrite
            case .skip: policy = .skip
            default: policy = .rename(renameTo)
            }
        } else {
            policy = .rename(name)
        }
        return TransferJob(
            hostID: host.id, hostDisplayNameSnapshot: host.displayName,
            targetSnapshot: TransferTarget.describe(host), sshAliasSnapshot: alias,
            configPathSnapshot: configPath, direction: .download, sourcePath: remotePath,
            destinationPath: final, itemKind: kind, overwritePolicy: policy)
    }
}

/// Form tải lên.
public struct UploadForm: Sendable, Equatable {
    public var localPath = ""
    public var remoteDirectory = ""
    /// Rỗng = giữ tên local.
    public var remoteName = ""
    /// Kết quả `refreshLocal()`.
    public private(set) var symlinks: [String] = []
    public private(set) var kind: TransferItemKind = .file

    public init() {}

    public static let overwriteWarning =
        "scp không kiểm tra được file cùng tên trên server — file cùng tên sẽ bị ghi đè."

    public static func nestingWarning(name: String) -> String {
        "Nếu thư mục \(name) đã tồn tại trên server, nội dung sẽ được đặt lồng bên trong."
    }

    /// Gọi khi người dùng chọn/đổi nguồn local: đọc loại và quét symlink.
    public mutating func refreshLocal() {
        symlinks = []
        kind = .file
        guard !localPath.isEmpty, LocalFinalizer.localConflict(localPath) else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir), isDir.boolValue {
            kind = .directory
        }
        symlinks = LocalTreeInspector.symlinks(
            at: localPath, limit: TransferFormLimits.symlinkDisplay + 1)
    }

    public var effectiveName: String? {
        remoteName.isEmpty ? PathText.baseName(localPath) : remoteName
    }

    /// `<remoteDir>/<tên>`.
    public var finalRemotePath: String? {
        guard let name = effectiveName, !remoteDirectory.isEmpty else { return nil }
        return PathText.join(remoteDirectory, name)
    }

    public var warnings: [String] {
        var w = [Self.overwriteWarning]
        if kind == .directory, let n = effectiveName { w.append(Self.nestingWarning(name: n)) }
        return w
    }

    public var issues: [TransferFormIssue] {
        var out: [TransferFormIssue] = []
        if localPath.isEmpty || !localPath.hasPrefix("/") || !LocalFinalizer.localConflict(localPath) {
            out.append(.localSourceMissing)
        }
        if remoteDirectory.isEmpty {
            out.append(.remoteDirectoryEmpty)
        } else if PathText.hasControl(remoteDirectory) {
            out.append(.remotePathInvalid)
        }
        if let n = effectiveName {
            if n.isEmpty || n == "." || n == ".." || n.contains("/") || PathText.hasControl(n) {
                out.append(.nameInvalid)
            }
        } else {
            out.append(.nameInvalid)
        }
        if !symlinks.isEmpty { out.append(.symlinks(symlinks)) }
        return out
    }

    public var canStart: Bool { issues.isEmpty }

    public func makeJob(host: HostProfile, configPath: String) throws -> TransferJob {
        let problems = issues
        guard problems.isEmpty, let final = finalRemotePath else {
            throw TransferFormError(issues: problems)
        }
        guard let alias = host.sshAlias else {
            throw TransferFormError(issues: [.hostMissingAlias])
        }
        return TransferJob(
            hostID: host.id, hostDisplayNameSnapshot: host.displayName,
            targetSnapshot: TransferTarget.describe(host), sshAliasSnapshot: alias,
            configPathSnapshot: configPath, direction: .upload, sourcePath: localPath,
            destinationPath: final, itemKind: kind, overwritePolicy: .overwrite)
    }
}
