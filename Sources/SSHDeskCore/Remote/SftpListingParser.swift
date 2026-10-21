import Foundation

public enum RemoteEntryKind: Sendable, Equatable {
    case file, directory, symlink, other
}

public struct RemoteEntry: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let kind: RemoteEntryKind
    public let size: Int64
    /// Chuỗi 10 ký tự, vd `drwxr-xr-x`.
    public let permissions: String
    public let owner: String
    public let group: String
    public let modified: Date?
    public let rawDate: String

    /// Tên chứa ký tự điều khiển không thể thao tác an toàn qua batch (UI hiển thị "tên không hỗ trợ").
    public var hasSupportedName: Bool {
        !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    public init(
        name: String, kind: RemoteEntryKind, size: Int64, permissions: String, owner: String,
        group: String, modified: Date?, rawDate: String
    ) {
        self.name = name
        self.kind = kind
        self.size = size
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.modified = modified
        self.rawDate = rawDate
    }
}

public struct ParsedListing: Sendable, Equatable {
    public var entries: [RemoteEntry]
    public var unparsedLines: Int
}

/// Parse output `ls -la` của sftp (ADR-013). Pure.
///
/// Giới hạn: tên có xuống dòng làm vỡ dòng → tính vào `unparsedLines`; owner/group có khoảng trắng
/// không được hỗ trợ. Múi giờ của ngày là múi giờ máy local (server không báo múi giờ).
public enum SftpListingParser {
    // perms(10) nlink(? | số) owner group size  Mmm dd  (HH:MM | YYYY) <1 khoảng trắng> tên
    private static let pattern =
        #"^([-dlcbpsD?][rwxsStT?-]{9}[+@.]?)\s+(\?|\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}:\d{2}|\d{4}) (.*)$"#
    private static let regex = try! NSRegularExpression(pattern: pattern)
    private static let months = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    public static func parse(
        _ output: String, now: Date = Date(), calendar: Calendar = .current
    ) -> ParsedListing {
        var entries: [RemoteEntry] = []
        var unparsed = 0
        // "\r\n" là MỘT Character trong Swift nên chuẩn hoá trước khi tách.
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines {
            if line.isEmpty || line.hasPrefix("sftp> ") || line == "sftp>" { continue }
            if line.hasPrefix("total ") { continue }
            guard let entry = parseLine(line, now: now, calendar: calendar) else {
                unparsed += 1
                continue
            }
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry)
        }
        return ParsedListing(entries: entries, unparsedLines: unparsed)
    }

    static func parseLine(_ line: String, now: Date, calendar: Calendar) -> RemoteEntry? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
            m.numberOfRanges == 10
        else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        let perms = g(1)
        let kind: RemoteEntryKind
        switch perms.first {
        case "-": kind = .file
        case "d": kind = .directory
        case "l": kind = .symlink
        default: kind = .other
        }
        guard let size = Int64(g(5)) else { return nil }
        let rawDate = "\(g(6)) \(g(7)) \(g(8))"
        let date = parseDate(month: g(6), day: g(7), timeOrYear: g(8), now: now, calendar: calendar)
        return RemoteEntry(
            name: g(9), kind: kind, size: size, permissions: String(perms.prefix(10)),
            owner: g(3), group: g(4), modified: date, rawDate: rawDate)
    }

    static func parseDate(month: String, day: String, timeOrYear: String, now: Date, calendar: Calendar)
        -> Date?
    {
        guard let mon = months[month], let d = Int(day) else { return nil }
        func make(_ year: Int, _ hour: Int, _ minute: Int) -> Date? {
            var c = DateComponents()
            c.year = year
            c.month = mon
            c.day = d
            c.hour = hour
            c.minute = minute
            guard let date = calendar.date(from: c) else { return nil }
            // Chặn ngày không tồn tại bị "lăn" sang tháng khác (vd 30/02).
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            return back.year == year && back.month == mon && back.day == d ? date : nil
        }
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let mi = Int(parts[1]) else { return nil }
            let year = calendar.component(.year, from: now)
            var date = make(year, h, mi)
            if let dt = date, dt.timeIntervalSince(now) > 86_400 { date = make(year - 1, h, mi) }
            if date == nil { date = make(year - 1, h, mi) }  // 29/02 của năm không nhuận
            return date
        }
        guard let y = Int(timeOrYear) else { return nil }
        return make(y, 0, 0)
    }
}
