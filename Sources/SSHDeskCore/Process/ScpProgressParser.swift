import Foundation

public struct ScpProgress: Sendable, Equatable {
    public let fileName: String
    /// 0...1
    public let fraction: Double?
    public let bytes: Int64?
    public let bytesPerSecond: Double?
    /// Chỉ có khi dòng thực sự chứa ETA dạng `mm:ss`/`hh:mm:ss`; không suy đoán.
    public let etaSeconds: Int?
}

/// Parse dòng progress meter của scp (chỉ xuất hiện khi stdout là tty), ví dụ
/// `file.bin                 45%  1234KB   1.2MB/s   00:03 ETA`. Đơn vị theo scp: 1 KB = 1024 B.
public enum ScpProgressParser {
    private static let pattern =
        #"^(.*\S)\s+(\d{1,3})%\s+(\d+(?:\.\d+)?)\s*([KMGTP]?)i?B?\s+(\d+(?:\.\d+)?)\s*([KMGTP]?)i?B/s\s+(?:(\d+):(\d{2})(?::(\d{2}))?)(?:\s+ETA)?\s*$"#
    private static let regex = try? NSRegularExpression(pattern: pattern)

    public static func parse(_ rawLine: String) -> ScpProgress? {
        let line = OutputSanitizer.clean(rawLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex else { return nil }
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let name = group(1), let pctText = group(2), let pct = Double(pctText), pct <= 100 else { return nil }
        let bytes = group(3).flatMap(Double.init).map { v -> Int64 in
            Int64(v * multiplier(group(4) ?? ""))
        }
        let rate = group(5).flatMap(Double.init).map { $0 * multiplier(group(6) ?? "") }
        var eta: Int?
        if let a = group(7).flatMap(Int.init), let b = group(8).flatMap(Int.init) {
            if let c = group(9).flatMap(Int.init) {
                eta = a * 3600 + b * 60 + c
            } else {
                eta = a * 60 + b
            }
        }
        return ScpProgress(
            fileName: name, fraction: pct / 100, bytes: bytes, bytesPerSecond: rate, etaSeconds: eta)
    }

    private static func multiplier(_ unit: String) -> Double {
        switch unit {
        case "K": return 1024
        case "M": return 1024 * 1024
        case "G": return 1024 * 1024 * 1024
        case "T": return 1024.0 * 1024 * 1024 * 1024
        case "P": return 1024.0 * 1024 * 1024 * 1024 * 1024
        default: return 1
        }
    }
}
