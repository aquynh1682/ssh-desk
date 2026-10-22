import Foundation

public enum HostResolveError: Error, Equatable {
    case notFound(query: String)
    /// Nhiều host khớp cùng một bước; liệt kê để người dùng chọn bằng id.
    case ambiguous(query: String, matches: [Match])
    case windowsUnsupported(name: String)

    public struct Match: Equatable, Sendable {
        public let id: UUID
        public let name: String
    }
}

/// Giải `<id|alias|tên>` ra đúng một host SSH (ADR-025). Khớp chính xác theo thứ tự:
/// UUID -> alias imported (`sshConfigAlias`, phân biệt hoa thường như ssh) -> tên hiển thị
/// (không phân biệt hoa thường/dấu, bỏ khoảng trắng hai đầu). Không fuzzy. Bước nào có >= 1 kết quả thì dừng ở bước đó.
public enum HostResolver {
    public static func resolve(_ rawQuery: String, in hosts: [HostProfile]) throws -> HostProfile {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw HostResolveError.notFound(query: rawQuery) }

        var matches: [HostProfile] = []
        if let uuid = UUID(uuidString: query) {
            matches = hosts.filter { $0.id == uuid }
        }
        if matches.isEmpty {
            matches = hosts.filter {
                $0.connectionMode == .existingSSHConfigAlias && $0.sshConfigAlias == query
            }
        }
        if matches.isEmpty {
            matches = hosts.filter { sameName($0.displayName, query) }
        }
        guard !matches.isEmpty else { throw HostResolveError.notFound(query: rawQuery) }
        if matches.count > 1 {
            throw HostResolveError.ambiguous(
                query: rawQuery,
                matches: matches.map { .init(id: $0.id, name: $0.displayName) })
        }
        let host = matches[0]
        guard host.kind == .ssh else { throw HostResolveError.windowsUnsupported(name: host.displayName) }
        return host
    }

    /// Tìm theo id (đã là UUID) với cùng quy tắc loại Windows.
    public static func resolve(id: UUID, in hosts: [HostProfile]) throws -> HostProfile {
        guard let host = hosts.first(where: { $0.id == id }) else {
            throw HostResolveError.notFound(query: id.uuidString)
        }
        guard host.kind == .ssh else { throw HostResolveError.windowsUnsupported(name: host.displayName) }
        return host
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Bỏ ký tự điều khiển trước khi in ra terminal/hộp thoại (tên host do người dùng/import đặt).
    public static func printable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !isControl($0) }))
    }

    static func isControl(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}

extension HostResolveError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let q):
            return "Không tìm thấy máy chủ khớp “\(HostResolver.printable(q))”."
        case .ambiguous(let q, let matches):
            let lines = matches.map { "  \($0.id.uuidString.lowercased())  \(HostResolver.printable($0.name))" }
            return "Có \(matches.count) máy khớp “\(HostResolver.printable(q))”, hãy dùng id:\n"
                + lines.joined(separator: "\n")
        case .windowsUnsupported(let n):
            return "“\(HostResolver.printable(n))” là máy Windows — chưa hỗ trợ mở bằng CLI/URL."
        }
    }
}
