import Foundation

public enum SftpBatchError: Error, Equatable {
    /// Đường dẫn/tên chứa ký tự điều khiển (U+0000–U+001F, U+007F).
    case controlCharacter(String)
    case emptyPath
}

/// Dựng script batch cho `sftp -b -`. Pure.
public enum SftpBatch {
    /// `"` + escape `\`→`\\`, `"`→`\"` + `"`. Từ chối ký tự điều khiển.
    public static func quote(_ path: String) throws -> String {
        guard !path.isEmpty else { throw SftpBatchError.emptyPath }
        for u in path.unicodeScalars where u.value < 0x20 || u.value == 0x7F {
            throw SftpBatchError.controlCharacter(path)
        }
        var out = "\""
        for ch in path.unicodeScalars {
            if ch == "\\" || ch == "\"" { out.unicodeScalars.append("\\") }
            out.unicodeScalars.append(ch)
        }
        return out + "\""
    }

    public static func list(_ dir: String) throws -> String { "cd \(try quote(dir))\nls -la\n" }
    public static func mkdir(_ dir: String) throws -> String { "mkdir \(try quote(dir))\n" }
    public static func rename(_ from: String, _ to: String) throws -> String {
        "rename \(try quote(from)) \(try quote(to))\n"
    }
    public static func rm(_ file: String) throws -> String { "rm \(try quote(file))\n" }
    public static func rmdir(_ dir: String) throws -> String { "rmdir \(try quote(dir))\n" }
    public static var pwd: String { "pwd\n" }
}
