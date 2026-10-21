import Foundation

public enum FolderNameError: Error, Equatable {
    case empty
    case tooLong
    case controlCharacters
}

/// Một nhóm trong bảng máy chủ. `name == ""` là "Chưa phân loại".
public struct HostGroup: Equatable, Sendable {
    public let name: String
    public let hosts: [HostProfile]
    public var isUncategorized: Bool { name.isEmpty }
    public var title: String { isUncategorized ? HostFolders.uncategorizedTitle : name }
}

/// Logic thư mục máy chủ (một cấp, lưu trong `HostProfile.project`). Thuần, không phụ thuộc UI.
public enum HostFolders {
    public static let maxNameLength = 100
    public static let uncategorizedTitle = "Chưa phân loại"

    /// Chuẩn hoá tên: trim, không rỗng, không ký tự điều khiển, tối đa 100 ký tự.
    public static func normalize(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw FolderNameError.empty }
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw FolderNameError.controlCharacters
        }
        if name.count > maxNameLength { throw FolderNameError.tooLong }
        return name
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Hai tên coi là cùng một thư mục (không phân biệt hoa thường/dấu).
    public static func sameFolder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: options) == .orderedSame
    }

    /// Sắp theo tên không phân biệt hoa thường/dấu; bỏ tên rỗng và tên trùng đúng từng ký tự.
    public static func sortedUnique(_ names: [String]) -> [String] {
        Array(Set(names.filter { !$0.isEmpty })).sorted(by: nameLess)
    }

    static func nameLess(_ a: String, _ b: String) -> Bool {
        let r = a.compare(b, options: options)
        return r == .orderedSame ? a < b : r == .orderedAscending
    }

    public struct FolderCount: Equatable, Sendable {
        public let name: String
        public let count: Int
    }

    /// Mọi thư mục (kể cả rỗng, từ `emptyFolders`) kèm số host, sắp theo tên.
    public static func counts(_ hosts: [HostProfile], emptyFolders: [String] = []) -> [FolderCount] {
        var table: [String: Int] = [:]
        for h in hosts where !h.project.isEmpty { table[h.project, default: 0] += 1 }
        for f in emptyFolders where !f.isEmpty { table[f, default: 0] += 0 }
        return table.keys.sorted(by: nameLess).map { FolderCount(name: $0, count: table[$0] ?? 0) }
    }

    public static func uncategorizedCount(_ hosts: [HostProfile]) -> Int {
        hosts.filter { $0.project.isEmpty }.count
    }

    /// Gom host theo thư mục (giữ thứ tự host đầu vào trong mỗi nhóm). Thư mục rỗng vẫn có nhóm;
    /// "Chưa phân loại" ở cuối và chỉ có khi có host.
    public static func group(_ hosts: [HostProfile], emptyFolders: [String] = []) -> [HostGroup] {
        var groups = counts(hosts, emptyFolders: emptyFolders).map { c in
            HostGroup(name: c.name, hosts: hosts.filter { $0.project == c.name })
        }
        let rest = hosts.filter { $0.project.isEmpty }
        if !rest.isEmpty { groups.append(HostGroup(name: "", hosts: rest)) }
        return groups
    }

    // MARK: Kéo thả

    private static let dragPrefix = "sshdesk-hosts:"

    /// Payload kéo host: chuỗi `sshdesk-hosts:<uuid>,<uuid>`.
    public static func dragPayload(_ ids: [UUID]) -> String {
        dragPrefix + ids.map(\.uuidString).joined(separator: ",")
    }

    /// Đọc payload; `nil` nếu sai tiền tố hoặc có UUID không hợp lệ.
    public static func parseDragPayload(_ text: String) -> [UUID]? {
        guard text.hasPrefix(dragPrefix) else { return nil }
        let parts = text.dropFirst(dragPrefix.count)
            .split(separator: ",", omittingEmptySubsequences: false)
        var ids: [UUID] = []
        for p in parts {
            guard let id = UUID(uuidString: String(p)) else { return nil }
            ids.append(id)
        }
        return ids.isEmpty ? nil : ids
    }
}
