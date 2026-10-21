import Foundation

/// Đọc alias từ file SSH config có sẵn để người dùng chọn import.
///
/// CHỈ ĐỌC: không chạy `ssh`/`ssh -G`, không chạy lệnh nào trong file (`Match exec`,
/// `ProxyCommand`...), không ghi/sửa file nguồn, không expand `%`/biến môi trường,
/// không đọc nội dung file key. `Match` chỉ được ghi nhận, không đánh giá.
public enum SSHConfigImporter {
    public static let maxFileSize = 1_048_576
    public static let maxLines = 20_000
    public static let maxFiles = 100

    /// `~/.ssh/config` (dùng tham số `path` để test với file tạm).
    public static var defaultUserConfigURL: URL {
        defaultSSHDirectory.appendingPathComponent("config")
    }

    static var defaultSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    /// Quét `path` và các file `Include`. Lỗi từng file được gom vào `warnings`, không throw.
    /// `includeBaseDirectory`: thư mục để resolve `Include` tương đối (mặc định `~/.ssh`).
    public static func scan(
        path: URL, maxIncludeDepth: Int = 5, includeBaseDirectory: URL? = nil
    ) -> SSHConfigScanResult {
        var scanner = Scanner(
            maxDepth: maxIncludeDepth, base: includeBaseDirectory ?? defaultSSHDirectory)
        scanner.scanFile(path.standardizedFileURL, depth: 0, inheritedComplex: false, stack: [])
        return scanner.result
    }

    // MARK: - Hỗ trợ

    /// `^[A-Za-z0-9][A-Za-z0-9._-]*$`, tối đa 255 ký tự: an toàn để làm argv.
    static func isValidAlias(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 255 else { return false }
        func alnum(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
        }
        guard alnum(scalars[0]) else { return false }
        return scalars.allSatisfy { alnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    static func isPattern(_ s: String) -> Bool {
        s.contains { $0 == "*" || $0 == "?" || $0 == "!" }
    }

    /// Làm sạch chuỗi để đưa vào thông báo (không để ký tự điều khiển lọt ra UI/log).
    static func sanitized(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars.prefix(80) {
            if u.value < 0x20 || u.value == 0x7F {
                out += "\\u{" + String(u.value, radix: 16) + "}"
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Tách `Key value` / `Key=value` / `Key = value`. Trả về (keyword, phần còn lại).
    static func splitKeyword(_ line: String) -> (String, String)? {
        let s = Array(line.unicodeScalars)
        var i = 0
        func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
        while i < s.count, isBlank(s[i]) { i += 1 }
        let start = i
        while i < s.count, !isBlank(s[i]), s[i] != "=" { i += 1 }
        guard i > start else { return nil }
        var key = String.UnicodeScalarView()
        key.append(contentsOf: s[start..<i])
        while i < s.count, isBlank(s[i]) { i += 1 }
        if i < s.count, s[i] == "=" { i += 1 }
        while i < s.count, isBlank(s[i]) { i += 1 }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: s[i...])
        return (String(key), String(rest))
    }

    /// Tách theo khoảng trắng/tab, hỗ trợ `"..."` (với `\"` và `\\`). Token bắt đầu bằng `#`
    /// (ngoài nháy) kết thúc dòng. Trả nil nếu nháy không đóng.
    static func tokenize(_ text: String) -> [String]? {
        var tokens: [String] = []
        var cur = String.UnicodeScalarView()
        var hasToken = false
        var inQuote = false
        let s = Array(text.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            if inQuote {
                if c == "\\", i + 1 < s.count, s[i + 1] == "\"" || s[i + 1] == "\\" {
                    cur.append(s[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inQuote = false } else { cur.append(c) }
            } else if c == "\"" {
                inQuote = true
                hasToken = true
            } else if c == " " || c == "\t" {
                if hasToken {
                    tokens.append(String(cur))
                    cur = String.UnicodeScalarView()
                    hasToken = false
                }
            } else if c == "#", !hasToken {
                break
            } else {
                cur.append(c)
                hasToken = true
            }
            i += 1
        }
        if inQuote { return nil }
        if hasToken { tokens.append(String(cur)) }
        return tokens
    }

    /// Khớp wildcard đơn giản chỉ với `*` trong tên file (không match file ẩn trừ khi pattern bắt đầu bằng `.`).
    static func globMatch(pattern: String, name: String) -> Bool {
        if name.hasPrefix(".") && !pattern.hasPrefix(".") { return false }
        let parts = pattern.components(separatedBy: "*")
        if parts.count == 1 { return pattern == name }
        var rest = Substring(name)
        guard rest.hasPrefix(parts[0]) else { return false }
        rest = rest.dropFirst(parts[0].count)
        for mid in parts.dropFirst().dropLast() {
            guard let r = rest.range(of: mid) else { return false }
            rest = rest[r.upperBound...]
        }
        let last = parts[parts.count - 1]
        guard rest.count >= last.count, rest.hasSuffix(last) else { return false }
        return true
    }

    // MARK: - Scanner

    private struct Scanner {
        let maxDepth: Int
        let base: URL
        var result = SSHConfigScanResult()
        var seenAliases: [String: Int] = [:]  // alias -> index trong candidates
        var skipped = Set<String>()
        var filesRead = 0
        let fm = FileManager.default

        init(maxDepth: Int, base: URL) {
            self.maxDepth = maxDepth
            self.base = base
        }

        mutating func warn(_ kind: ScanWarning.Kind, _ file: URL, _ line: Int, _ msg: String) {
            result.warnings.append(ScanWarning(kind: kind, file: file, line: line, message: msg))
        }

        static func canonical(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        mutating func scanFile(_ url: URL, depth: Int, inheritedComplex: Bool, stack: [String]) {
            guard filesRead < SSHConfigImporter.maxFiles else {
                warn(.tooManyFiles, url, 0, "Đã đọc quá \(SSHConfigImporter.maxFiles) file; bỏ qua file này.")
                return
            }
            filesRead += 1
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
                warn(.fileUnreadable, url, 0, "Không đọc được file (không tồn tại hoặc không có quyền).")
                return
            }
            if (attrs[.type] as? FileAttributeType) != .typeRegular {
                // Symlink tới file thường vẫn ổn: attributesOfItem không theo symlink.
                let real = url.resolvingSymlinksInPath()
                let t = (try? fm.attributesOfItem(atPath: real.path))?[.type] as? FileAttributeType
                if t != .typeRegular {
                    warn(.fileUnreadable, url, 0, "Không phải file thường.")
                    return
                }
            }
            let size =
                ((try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?
                .intValue ?? 0
            if size > SSHConfigImporter.maxFileSize {
                warn(.fileTooLarge, url, 0, "File lớn hơn \(SSHConfigImporter.maxFileSize) byte; không đọc.")
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                warn(.fileUnreadable, url, 0, "Không đọc được file.")
                return
            }
            if data.count > SSHConfigImporter.maxFileSize {
                warn(.fileTooLarge, url, 0, "File lớn hơn \(SSHConfigImporter.maxFileSize) byte; không đọc.")
                return
            }
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
                warn(.notUTF8, url, 0, "File không phải văn bản UTF-8 (có thể là file nhị phân); bỏ qua.")
                return
            }
            parse(
                data: data, url: url, depth: depth, inheritedComplex: inheritedComplex,
                stack: stack + [Self.canonical(url)])
        }

        mutating func parse(data: Data, url: URL, depth: Int, inheritedComplex: Bool, stack: [String]) {
            var rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            if rawLines.count > SSHConfigImporter.maxLines {
                warn(
                    .tooManyLines, url, SSHConfigImporter.maxLines,
                    "Quá \(SSHConfigImporter.maxLines) dòng; bỏ phần còn lại.")
                rawLines = Array(rawLines.prefix(SSHConfigImporter.maxLines))
            }
            var current: [Int] = []  // chỉ số candidate của khối Host hiện tại
            var matchSeen = false
            var hostSeen = false

            for (idx, raw) in rawLines.enumerated() {
                let lineNo = idx + 1
                var line = String(decoding: raw, as: UTF8.self)
                if idx == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
                if line.hasSuffix("\r") { line.removeLast() }
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                // Ký tự điều khiển (vd \r giữa dòng) có thể giả newline: bỏ cả dòng, đóng khối hiện tại.
                if line.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) {
                    warn(.malformedLine, url, lineNo, "Dòng chứa ký tự điều khiển; bỏ qua: \(sanitized(trimmed))")
                    current = []
                    continue
                }
                guard let (keyword, rest) = splitKeyword(line) else { continue }
                guard let tokens = tokenize(rest) else {
                    warn(.malformedLine, url, lineNo, "Dấu nháy không đóng; bỏ qua dòng.")
                    if keyword.lowercased() == "host" { current = [] }
                    continue
                }
                switch keyword.lowercased() {
                case "host":
                    hostSeen = true
                    current = handleHost(tokens, url: url, line: lineNo, complex: inheritedComplex || matchSeen)
                case "match":
                    matchSeen = true
                    current = []
                    warn(
                        .matchNotEvaluated, url, lineNo,
                        "Match chưa được đánh giá; các khối sau nó có thể có điều kiện.")
                    if tokens.contains(where: { $0.lowercased() == "exec" }) {
                        warn(
                            .matchExec, url, lineNo,
                            "Match exec: lệnh KHÔNG được chạy khi quét; cấu hình hiệu lực phụ thuộc kết quả lệnh.")
                    }
                case "include":
                    for i in current { result.candidates[i].hasMatchOrComplexity = true }
                    handleInclude(
                        tokens, url: url, line: lineNo, depth: depth,
                        complex: inheritedComplex || matchSeen || hostSeen, stack: stack)
                case "proxycommand":
                    warn(
                        .proxyCommand, url, lineNo,
                        "ProxyCommand: lệnh KHÔNG được chạy khi quét; nên kiểm tra kỹ trước khi dùng.")
                    for i in current { result.candidates[i].hasProxyCommand = true }
                case "hostname":
                    setFirst(current, tokens, \.hostName)
                case "user":
                    setFirst(current, tokens, \.user)
                case "identityfile":
                    setFirst(current, tokens, \.identityFile)
                case "proxyjump":
                    setFirst(current, tokens, \.proxyJump)
                case "port":
                    guard let t = tokens.first else { break }
                    if let p = Int(t), (1...65535).contains(p) {
                        for i in current where result.candidates[i].port == nil { result.candidates[i].port = p }
                    } else {
                        warn(.invalidValue, url, lineNo, "Port không hợp lệ: \(sanitized(t))")
                    }
                default:
                    break
                }
            }
        }

        mutating func setFirst(
            _ idxs: [Int], _ tokens: [String], _ key: WritableKeyPath<ImportCandidate, String?>
        ) {
            guard let v = tokens.first else { return }
            for i in idxs where result.candidates[i][keyPath: key] == nil {
                result.candidates[i][keyPath: key] = v
            }
        }

        mutating func handleHost(_ tokens: [String], url: URL, line: Int, complex: Bool) -> [Int] {
            let hasPattern = tokens.contains(where: { SSHConfigImporter.isPattern($0) })
            var indices: [Int] = []
            for tok in tokens {
                if SSHConfigImporter.isPattern(tok) {
                    if skipped.insert(tok).inserted { result.skippedPatterns.append(tok) }
                    continue
                }
                guard SSHConfigImporter.isValidAlias(tok) else {
                    warn(
                        .invalidAlias, url, line,
                        "Alias không hợp lệ (chỉ cho phép A-Z a-z 0-9 . _ -): \(sanitized(tok))")
                    continue
                }
                if let first = seenAliases[tok] {
                    let f = result.candidates[first]
                    if f.sourceFile.path == url.path, f.line == line { continue }
                    warn(
                        .duplicateAlias, url, line,
                        "Trùng alias \(tok); giữ bản đầu tiên (\(f.sourceFile.lastPathComponent):\(f.line)).")
                    continue
                }
                seenAliases[tok] = result.candidates.count
                indices.append(result.candidates.count)
                result.candidates.append(
                    ImportCandidate(
                        alias: tok, sourceFile: url, line: line, hasMatchOrComplexity: complex || hasPattern))
            }
            return indices
        }

        mutating func handleInclude(_ tokens: [String], url: URL, line: Int, depth: Int, complex: Bool, stack: [String])
        {
            for tok in tokens {
                let targets = resolveInclude(tok, url: url, line: line)
                for target in targets {
                    if stack.contains(Self.canonical(target)) {
                        warn(.includeCycle, url, line, "Vòng Include tới \(target.lastPathComponent); bỏ qua.")
                    } else if depth + 1 > maxDepth {
                        warn(
                            .includeDepthExceeded, url, line,
                            "Include vượt độ sâu tối đa \(maxDepth): \(target.lastPathComponent) chưa được đọc.")
                    } else {
                        scanFile(target, depth: depth + 1, inheritedComplex: complex, stack: stack)
                    }
                }
            }
        }

        mutating func resolveInclude(_ token: String, url: URL, line: Int) -> [URL] {
            func unresolved(_ why: String) -> [URL] {
                warn(.includeUnresolved, url, line, "Include chưa resolve (\(why)): \(sanitized(token))")
                return []
            }
            if token.contains("%") || token.contains("$") { return unresolved("có token/biến, không expand") }
            var p = token
            if p == "~" || p.hasPrefix("~/") {
                p = fm.homeDirectoryForCurrentUser.path + p.dropFirst()
            } else if p.hasPrefix("~") {
                return unresolved("~user không được hỗ trợ")
            } else if !p.hasPrefix("/") {
                p = base.appendingPathComponent(p).path
            }
            let full = URL(fileURLWithPath: p).standardizedFileURL
            let dir = full.deletingLastPathComponent()
            let name = full.lastPathComponent
            if dir.path.contains("*") || dir.path.contains("?") || dir.path.contains("[") || name.contains("?")
                || name.contains("[")
            {
                return unresolved("chỉ hỗ trợ `*` trong tên file")
            }
            if !name.contains("*") {
                guard fm.fileExists(atPath: full.path) else { return unresolved("file không tồn tại") }
                return [full]
            }
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
                return unresolved("không đọc được thư mục")
            }
            let matched = names.filter { SSHConfigImporter.globMatch(pattern: name, name: $0) }.sorted()
            if matched.isEmpty { return unresolved("không có file khớp") }
            return matched.map { dir.appendingPathComponent($0) }
        }
    }
}
