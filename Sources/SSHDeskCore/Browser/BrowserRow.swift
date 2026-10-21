import Foundation

/// Một dòng trong bảng file (dùng chung cho khung local và khung remote). Thuần dữ liệu.
public struct BrowserRow: Identifiable, Sendable, Equatable {
    /// Đường dẫn đầy đủ (duy nhất trong một thư mục).
    public let id: String
    public let name: String
    public let kind: RemoteEntryKind
    /// `nil` với thư mục.
    public let size: Int64?
    public let modified: Date?
    /// Chuỗi quyền 10 ký tự (chỉ remote).
    public let permissions: String?
    public let isHidden: Bool
    /// Tên có ký tự điều khiển → không thao tác được an toàn (hiển thị mờ).
    public let isSupported: Bool

    public var isDirectory: Bool { kind == .directory }
    public var isSymlink: Bool { kind == .symlink }

    /// Tên hiển thị: ký tự điều khiển thay bằng `�` để không làm vỡ giao diện.
    public var displayName: String {
        isSupported
            ? name
            : String(
                String.UnicodeScalarView(
                    name.unicodeScalars.map { BrowserRow.isControl($0) ? "\u{FFFD}" : $0 }))
    }

    public init(
        id: String, name: String, kind: RemoteEntryKind, size: Int64?, modified: Date?,
        permissions: String?, isHidden: Bool, isSupported: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.isHidden = isHidden
        self.isSupported = isSupported
    }

    public init(local entry: LocalEntry) {
        self.init(
            id: entry.path, name: entry.name, kind: entry.kind,
            size: entry.kind == .directory ? nil : entry.size, modified: entry.modified,
            permissions: nil, isHidden: entry.isHidden,
            isSupported: !entry.name.unicodeScalars.contains(where: BrowserRow.isControl))
    }

    public init(remote entry: RemoteEntry, directory: String) {
        self.init(
            id: BrowserPath.join(directory, entry.name), name: entry.name, kind: entry.kind,
            size: entry.kind == .directory ? nil : entry.size, modified: entry.modified,
            permissions: entry.permissions, isHidden: entry.name.hasPrefix("."),
            isSupported: entry.hasSupportedName)
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool { s.value < 0x20 || s.value == 0x7F }
}

public struct BrowserSort: Sendable, Equatable {
    public enum Key: Sendable, Equatable { case name, size, modified }
    public var key: Key
    public var ascending: Bool

    public init(key: Key = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// Bấm tiêu đề cột: cột khác → tăng dần; cùng cột → đảo chiều.
    public func toggled(_ newKey: Key) -> BrowserSort {
        newKey == key ? BrowserSort(key: key, ascending: !ascending) : BrowserSort(key: newKey)
    }
}

public enum BrowserRows {
    /// Lọc theo tên (không phân biệt hoa thường/dấu), ẩn file ẩn nếu cần, rồi sắp xếp.
    /// Thư mục luôn đứng trước file (như Finder); `ascending` chỉ đổi thứ tự trong từng nhóm.
    public static func arranged(
        _ rows: [BrowserRow], query: String = "", sort: BrowserSort = BrowserSort(),
        showHidden: Bool = true
    ) -> [BrowserRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = rows
        if !showHidden { list = list.filter { !$0.isHidden } }
        if !q.isEmpty {
            list = list.filter {
                $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order = compare(a, b, key: sort.key)
            if order == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ a: BrowserRow, _ b: BrowserRow, key: BrowserSort.Key)
        -> ComparisonResult
    {
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .size: return cmp(a.size ?? -1, b.size ?? -1)
        case .modified:
            return cmp(
                a.modified?.timeIntervalSince1970 ?? -.infinity,
                b.modified?.timeIntervalSince1970 ?? -.infinity)
        }
    }

    private static func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
