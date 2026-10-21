import Foundation

/// Xử lý đường dẫn dạng chuỗi cho cả local và remote (POSIX). Thuần, không chạm filesystem.
public enum BrowserPath {
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// Thư mục cha; `/` → `/`.
    public static func parent(_ path: String) -> String {
        let p = trimTrailingSlashes(path)
        guard let idx = p.lastIndex(of: "/") else { return p }
        let parent = String(p[..<idx])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(_ path: String) -> String {
        let p = trimTrailingSlashes(path)
        guard let idx = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: idx)...])
    }

    static func trimTrailingSlashes(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Gộp `//`, bỏ `.`, xử lý `..` (không vượt quá `/`). Chỉ nhận đường dẫn tuyệt đối.
    public static func normalize(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(comp)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Chuỗi người dùng gõ vào ô đường dẫn → đường dẫn tuyệt đối; `~` là `home`. Không hợp lệ → nil
    /// (rỗng, tương đối, có ký tự điều khiển).
    public static func resolve(_ typed: String, home: String) -> String? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.unicodeScalars.contains(where: BrowserRow.isControl) else { return nil }
        if t == "~" { return normalize(home) }
        if t.hasPrefix("~/") { return normalize(join(home, String(t.dropFirst(2)))) }
        return normalize(t)
    }

    /// Hiển thị: thư mục home thành `~`.
    public static func display(_ path: String, home: String) -> String {
        let h = trimTrailingSlashes(home)
        guard h != "/", !h.isEmpty else { return path }
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}

/// Kiểm tra tên file/thư mục người dùng nhập (tạo thư mục, đổi tên).
public enum EntryNameRules {
    public enum Issue: Equatable, Sendable {
        case empty, reserved, containsSlash, containsControl

        public var message: String {
            switch self {
            case .empty: return "Tên không được để trống."
            case .reserved: return "Tên không hợp lệ."
            case .containsSlash: return "Tên không được chứa “/”."
            case .containsControl: return "Tên không được chứa ký tự điều khiển."
            }
        }
    }

    public static func validate(_ name: String) -> Issue? {
        if name.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        if name == "." || name == ".." { return .reserved }
        if name.contains("/") { return .containsSlash }
        if name.unicodeScalars.contains(where: BrowserRow.isControl) { return .containsControl }
        return nil
    }
}
