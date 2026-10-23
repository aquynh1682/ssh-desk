import Foundation

/// Lỗi cú pháp của file nguồn, kèm số dòng (ADR-026). Không chứa nội dung dòng (tránh lộ secret vào log/UI).
public struct InventorySyntaxError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public var description: String { line > 0 ? "Dòng \(line): \(message)" : message }
}

/// Nút của cây YAML tập con. Giá trị `!vault` được thay bằng `.vault` (nội dung bị bỏ ngay khi đọc).
indirect enum YAMLNode: Equatable {
    case null
    case scalar(String)
    case map([YAMLEntry])
    case vault
}

struct YAMLEntry: Equatable {
    var key: String
    var value: YAMLNode
    var line: Int
}

/// YAML tập con đủ cho inventory Ansible (ADR-026): mapping lồng theo thụt lề, scalar thường / quote đơn / kép,
/// `null`/`~`/trống, comment, `{}` rỗng. Tự viết, không dependency, không chạy process.
/// Từ chối có số dòng: tab thụt lề, anchor `&`, alias `*`, merge `<<`, tag `!` (trừ `!vault`), block scalar `|` `>`,
/// danh sách `-`, flow collection khác `{}`/`[]`, nhiều document.
enum MiniYAML {
    static let maxDepth = 40

    private struct Line {
        var no: Int
        var indent: Int
        var text: String
    }

    static func parse(_ source: String) throws -> [YAMLEntry] {
        var lines: [Line] = []
        var started = false
        var sawMarker = false
        var no = 0
        for raw in source.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            no += 1
            var indent = 0
            var hasTab = false
            var rest = Substring(raw)
            while let c = rest.first, c == " " || c == "\t" {
                if c == "\t" { hasTab = true }
                indent += 1
                rest = rest.dropFirst()
            }
            let text = String(rest).trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if hasTab { throw InventorySyntaxError(line: no, message: "Thụt lề bằng tab không hợp lệ trong YAML.") }
            if indent == 0 && (text == "---" || text.hasPrefix("--- ") || text.hasPrefix("---\t")) {
                if started || sawMarker {
                    throw InventorySyntaxError(line: no, message: "Nhiều document YAML không được hỗ trợ.")
                }
                sawMarker = true
                let after = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !after.isEmpty && !after.hasPrefix("#") {
                    throw InventorySyntaxError(line: no, message: "Nội dung ngay sau “---” không được hỗ trợ.")
                }
                continue
            }
            if indent == 0 && (text == "..." || text.hasPrefix("... ")) { break }
            started = true
            lines.append(Line(no: no, indent: indent, text: text))
        }
        guard let first = lines.first else { return [] }
        var index = 0
        let entries = try parseMap(lines, &index, indent: first.indent, depth: 1)
        if index < lines.count {
            throw InventorySyntaxError(line: lines[index].no, message: "Thụt lề không khớp với các dòng trước.")
        }
        return entries
    }

    // MARK: - Cấu trúc

    private static func parseMap(_ lines: [Line], _ index: inout Int, indent: Int, depth: Int) throws -> [YAMLEntry] {
        if depth > maxDepth { throw InventorySyntaxError(line: lines[index].no, message: "YAML lồng quá sâu.") }
        var entries: [YAMLEntry] = []
        var seen = Set<String>()
        while index < lines.count {
            let l = lines[index]
            if l.indent < indent { break }
            if l.indent > indent {
                throw InventorySyntaxError(line: l.no, message: "Thụt lề không khớp (thừa so với dòng trước).")
            }
            let (key, rest) = try splitKey(l)
            guard seen.insert(key).inserted else {
                throw InventorySyntaxError(line: l.no, message: "Khoá bị trùng trong cùng một mapping.")
            }
            index += 1
            let value = try scalarOrMarker(rest, line: l.no)
            switch value {
            case .child:
                if index < lines.count, lines[index].indent > l.indent {
                    let sub = try parseMap(lines, &index, indent: lines[index].indent, depth: depth + 1)
                    entries.append(YAMLEntry(key: key, value: .map(sub), line: l.no))
                } else {
                    entries.append(YAMLEntry(key: key, value: .null, line: l.no))
                }
            case .node(let node):
                if index < lines.count, lines[index].indent > l.indent {
                    throw InventorySyntaxError(
                        line: lines[index].no, message: "Giá trị nhiều dòng hoặc thụt lề thừa không được hỗ trợ.")
                }
                entries.append(YAMLEntry(key: key, value: node, line: l.no))
            case .vaultBlock:
                // Nội dung vault (kể cả dòng thụt vào của block scalar) bị bỏ ngay, không lưu.
                while index < lines.count, lines[index].indent > l.indent { index += 1 }
                entries.append(YAMLEntry(key: key, value: .vault, line: l.no))
            }
        }
        return entries
    }

    private enum Value {
        case child
        case node(YAMLNode)
        case vaultBlock
    }

    private static func splitKey(_ l: Line) throws -> (String, String) {
        let t = l.text
        if t == "-" || t.hasPrefix("- ") {
            throw InventorySyntaxError(line: l.no, message: "Danh sách (“- ”) không được hỗ trợ trong inventory YAML.")
        }
        guard let first = t.first else { throw InventorySyntaxError(line: l.no, message: "Dòng trống.") }
        switch first {
        case "&": throw InventorySyntaxError(line: l.no, message: "Anchor (&) không được hỗ trợ.")
        case "*": throw InventorySyntaxError(line: l.no, message: "Alias (*) không được hỗ trợ.")
        case "!": throw InventorySyntaxError(line: l.no, message: "Tag (!) không được hỗ trợ ở vị trí khoá.")
        case "?": throw InventorySyntaxError(line: l.no, message: "Khoá phức (?) không được hỗ trợ.")
        case "|", ">": throw InventorySyntaxError(line: l.no, message: "Block scalar (| hoặc >) không được hỗ trợ.")
        case "{", "[":
            throw InventorySyntaxError(line: l.no, message: "Flow collection không được hỗ trợ ở vị trí khoá.")
        default: break
        }
        var key: String
        var after: String
        if first == "\"" || first == "'" {
            let (value, end) = try parseQuoted(Array(t), from: 0, line: l.no)
            key = value
            let tail = String(Array(t)[end...]).trimmingCharacters(in: .whitespaces)
            guard tail.hasPrefix(":") else {
                throw InventorySyntaxError(line: l.no, message: "Thiếu dấu “:” sau khoá.")
            }
            after = String(tail.dropFirst())
            if !(after.isEmpty || after.first == " " || after.first == "\t") {
                throw InventorySyntaxError(line: l.no, message: "Thiếu khoảng trắng sau dấu “:”.")
            }
        } else {
            let chars = Array(t)
            var cut: Int?
            for i in chars.indices where chars[i] == ":" {
                if i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" {
                    cut = i
                    break
                }
            }
            guard let cut else { throw InventorySyntaxError(line: l.no, message: "Thiếu dấu “:” sau khoá.") }
            key = String(chars[..<cut]).trimmingCharacters(in: .whitespaces)
            after = String(chars[(cut + 1)...])
        }
        if key == "<<" { throw InventorySyntaxError(line: l.no, message: "Merge key (<<) không được hỗ trợ.") }
        if key.isEmpty { throw InventorySyntaxError(line: l.no, message: "Khoá rỗng.") }
        return (key, stripComment(after).trimmingCharacters(in: .whitespaces))
    }

    private static func scalarOrMarker(_ rest: String, line: Int) throws -> Value {
        if rest.isEmpty { return .child }
        let chars = Array(rest)
        switch chars[0] {
        case "&": throw InventorySyntaxError(line: line, message: "Anchor (&) không được hỗ trợ.")
        case "*": throw InventorySyntaxError(line: line, message: "Alias (*) không được hỗ trợ.")
        case "|", ">": throw InventorySyntaxError(line: line, message: "Block scalar (| hoặc >) không được hỗ trợ.")
        case "!":
            let tag = rest.prefix { !$0.isWhitespace }
            guard tag == "!vault" else {
                throw InventorySyntaxError(
                    line: line, message: "Tag YAML (!) không được hỗ trợ (chỉ !vault bị bỏ qua).")
            }
            let tail = String(rest.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
            if tail.isEmpty || tail.hasPrefix("|") || tail.hasPrefix(">") { return .vaultBlock }
            return .node(.vault)
        case "{":
            if rest == "{}" { return .node(.map([])) }
            throw InventorySyntaxError(line: line, message: "Flow mapping { } không được hỗ trợ (chỉ “{}” rỗng).")
        case "[":
            if rest == "[]" { return .node(.null) }
            throw InventorySyntaxError(line: line, message: "Flow sequence [ ] không được hỗ trợ.")
        case "\"", "'":
            let (value, end) = try parseQuoted(chars, from: 0, line: line)
            let tail = String(chars[end...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty {
                throw InventorySyntaxError(line: line, message: "Có ký tự thừa sau chuỗi trong dấu nháy.")
            }
            return .node(.scalar(value))
        default:
            // Scalar thường: “: ” bên trong là lỗi YAML (mapping lồng không có xuống dòng).
            for i in chars.indices where chars[i] == ":" && (i + 1 == chars.count || chars[i + 1] == " ") {
                throw InventorySyntaxError(line: line, message: "Giá trị chứa “: ” — hãy đặt trong dấu nháy.")
            }
            if rest == "~" || ["null", "Null", "NULL"].contains(rest) { return .node(.null) }
            return .node(.scalar(rest))
        }
    }

    /// Cắt comment ` #...` ngoài dấu nháy. Dấu nháy chỉ mở khi đứng đầu giá trị hoặc sau khoảng trắng.
    static func stripComment(_ s: String) -> String {
        let chars = Array(s)
        var quote: Character?
        var out: [Character] = []
        for (i, c) in chars.enumerated() {
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
                continue
            }
            if c == "#" && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") { break }
            if (c == "\"" || c == "'") && (i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t") { quote = c }
            out.append(c)
        }
        return String(out)
    }

    /// Đọc chuỗi trong dấu nháy bắt đầu tại `from`; trả (giá trị, vị trí sau dấu đóng).
    private static func parseQuoted(_ chars: [Character], from: Int, line: Int) throws -> (String, Int) {
        let q = chars[from]
        var out = ""
        var i = from + 1
        while i < chars.count {
            let c = chars[i]
            if q == "'" {
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" {
                        out.append("'")
                        i += 2
                        continue
                    }
                    return (out, i + 1)
                }
                out.append(c)
                i += 1
            } else {
                if c == "\"" { return (out, i + 1) }
                if c == "\\" {
                    guard i + 1 < chars.count else { break }
                    let e = chars[i + 1]
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "0": out.append("\u{0}")
                    case "\\", "\"", "/": out.append(e)
                    case "x", "u":
                        let len = e == "x" ? 2 : 4
                        guard i + 2 + len <= chars.count,
                            let v = UInt32(String(chars[(i + 2)..<(i + 2 + len)]), radix: 16),
                            let scalar = Unicode.Scalar(v)
                        else { throw InventorySyntaxError(line: line, message: "Chuỗi thoát \\\(e) không hợp lệ.") }
                        out.unicodeScalars.append(scalar)
                        i += len
                    default:
                        throw InventorySyntaxError(line: line, message: "Chuỗi thoát \\\(e) không được hỗ trợ.")
                    }
                    i += 2
                    continue
                }
                out.append(c)
                i += 1
            }
        }
        throw InventorySyntaxError(line: line, message: "Chuỗi trong dấu nháy không được đóng.")
    }
}
