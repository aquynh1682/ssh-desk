import Foundation

public enum CLICommand: Equatable, Sendable {
    case list(folder: String?, json: Bool)
    case open(query: String)
    case help
}

public struct CLIParseError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// Phân tích argv của `sshdesk` (ADR-025). Chỉ nhận đúng các lệnh dưới đây; argv lạ -> lỗi.
/// Không có lệnh nào nhận password, lệnh từ xa hay tham số ssh. (`template` thuộc K4a: chưa làm, hiện là lệnh lạ.)
public enum CLIArguments {
    public static let maxValueLength = 256

    public static let usage = """
        Dùng: sshdesk <lệnh>
          list [--folder <tên>] [--json]   Liệt kê máy chủ (chỉ đọc)
          open <id|alias|tên>              Mở máy chủ trong SSH Desk (qua Warp)
          help                             Hiện trợ giúp này
        Mã thoát: 0 ok, 1 lỗi chạy, 2 sai tham số, 3 không tìm thấy / nhiều máy khớp.
        """

    /// `args` là argv không gồm tên chương trình.
    public static func parse(_ args: [String]) throws -> CLICommand {
        guard let first = args.first else { return .help }
        let rest = Array(args.dropFirst())
        switch first {
        case "help", "--help", "-h":
            guard rest.isEmpty else { throw err("`help` không nhận tham số.") }
            return .help
        case "list":
            return try parseList(rest)
        case "open":
            guard rest.count == 1 else { throw err("`open` cần đúng một tham số: <id|alias|tên>.") }
            let q = rest[0]
            try checkValue(q, what: "tham số của `open`")
            guard !q.hasPrefix("-") else { throw err("Tham số lạ “\(HostResolver.printable(q))”.") }
            return .open(query: q)
        default:
            throw err("Lệnh lạ “\(HostResolver.printable(String(first.prefix(40))))”. Chạy `sshdesk help`.")
        }
    }

    private static func parseList(_ rest: [String]) throws -> CLICommand {
        var folder: String?
        var json = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--json":
                guard !json else { throw err("`--json` bị lặp.") }
                json = true
            case "--folder":
                guard folder == nil else { throw err("`--folder` bị lặp.") }
                guard i + 1 < rest.count else { throw err("`--folder` cần một giá trị.") }
                i += 1
                try checkValue(rest[i], what: "giá trị của --folder")
                folder = rest[i]
            default:
                throw err("Tham số lạ “\(HostResolver.printable(String(rest[i].prefix(40))))” cho `list`.")
            }
            i += 1
        }
        return .list(folder: folder, json: json)
    }

    private static func checkValue(_ v: String, what: String) throws {
        if v.isEmpty { throw err("\(what) không được rỗng.") }
        if v.count > maxValueLength { throw err("\(what) dài quá \(maxValueLength) ký tự.") }
        if v.unicodeScalars.contains(where: HostResolver.isControl) {
            throw err("\(what) chứa ký tự điều khiển.")
        }
    }

    private static func err(_ s: String) -> CLIParseError { CLIParseError(description: s) }
}
