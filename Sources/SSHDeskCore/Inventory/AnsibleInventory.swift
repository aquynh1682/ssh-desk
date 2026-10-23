import Foundation

/// Đọc Ansible inventory TĨNH (INI / YAML) thành `InventoryRecord` (ADR-026).
/// Tự parse trong tiến trình: KHÔNG chạy `ansible-inventory` hay bất kỳ process nào, không đọc `host_vars/` `group_vars/`.
/// Chỉ giữ ba nhóm biến kết nối (`ansible_host|ssh_host`, `ansible_port|ssh_port`, `ansible_user|ssh_user`); mọi biến
/// khác — kể cả biến mật khẩu và giá trị `!vault` — bị loại ngay khi đọc, không vào model/log/preview.
public enum AnsibleInventory {
    public static let maxBytes = 5 * 1_048_576
    public static let maxHosts = InventoryLimits.maxRecords
    public static let maxGroups = 20_000

    public enum Format: Sendable { case ini, yaml }

    /// Biến mật khẩu: bỏ qua + cảnh báo.
    static let secretKeys: Set<String> = [
        "ansible_password", "ansible_ssh_pass", "ansible_become_pass", "ansible_become_password",
    ]
    static let keyFileKey = "ansible_ssh_private_key_file"
    static let hostKeys = ["ansible_host", "ansible_ssh_host"]
    static let portKeys = ["ansible_port", "ansible_ssh_port"]
    static let userKeys = ["ansible_user", "ansible_ssh_user"]
    static let wantedKeys: Set<String> = Set(hostKeys + portKeys + userKeys)
    /// Group không làm tag.
    static let implicitGroups: Set<String> = ["all", "ungrouped"]

    // MARK: - Vào

    public static func detectFormat(text: String, fileName: String?) -> Format {
        let ext = fileName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        if ext == "yml" || ext == "yaml" { return .yaml }
        if ext == "ini" || ext == "cfg" { return .ini }
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") { continue }
            if t == "---" || t.hasPrefix("--- ") { return .yaml }
            if t.hasPrefix("[") { return .ini }
            // `key:` hoặc `key: value` không có “=” trước dấu hai chấm -> YAML.
            if let colon = t.firstIndex(of: ":"), !t[..<colon].contains("="), !t[..<colon].contains(" "),
                t[t.index(after: colon)...].first.map({ $0 == " " }) ?? true
            {
                return .yaml
            }
            return .ini
        }
        return .ini
    }

    public static func parse(
        data: Data, fileName: String? = nil, format: Format? = nil, defaultUser: String = NSUserName()
    ) throws -> InventoryParseResult {
        guard data.count <= maxBytes else { throw SpreadsheetError.fileTooLarge(limitMB: maxBytes / 1_048_576) }
        let text = try CSVReader.decode(data)
        return try parse(
            text: text, format: format ?? detectFormat(text: text, fileName: fileName), defaultUser: defaultUser)
    }

    /// `defaultUser`: máy không có `ansible_user` dùng tên này (giống mặc định của Ansible/ssh: user đang đăng nhập),
    /// vì hồ sơ SSH bắt buộc có user.
    public static func parse(
        text: String, format: Format, defaultUser: String = NSUserName()
    ) throws -> InventoryParseResult {
        var builder = AnsibleBuilder()
        switch format {
        case .ini: try INIParser.parse(text, into: &builder)
        case .yaml: try YAMLInventory.parse(text, into: &builder)
        }
        return try builder.finish(defaultUser: defaultUser)
    }

    // MARK: - Mở rộng khoảng

    struct PatternError: Error { var message: String }
    static let maxPatternLength = 255
    static let maxRangesPerPattern = 8
    static let maxTagsPerHost = 100
    static let maxAncestorDepth = 32
    static let maxAncestorsPerGroup = 256
    static let maxLayers = 300

    /// `web[01:03]` -> web01..web03; `db-[a:c]` -> db-a..db-c; `[1:10:2]` có bước. Nhiều khoảng -> tích. Khoảng không
    /// hợp lệ dạng `[::1]` (IPv6) giữ nguyên là văn bản. Quá `limit` -> `tooManyRecords`.
    static func expand(_ pattern: String, limit: Int = AnsibleInventory.maxHosts) throws -> [String] {
        enum Seg {
            case lit(String)
            case values([String])
        }
        guard pattern.count <= maxPatternLength else {
            throw PatternError(message: "Tên máy quá dài (tối đa \(maxPatternLength) ký tự).")
        }
        guard pattern.reduce(0, { $1 == "[" ? $0 + 1 : $0 }) <= maxRangesPerPattern else {
            throw PatternError(message: "Tên máy có quá nhiều khoảng [..] (tối đa \(maxRangesPerPattern)).")
        }
        let chars = Array(pattern)
        var segs: [Seg] = []
        var lit = ""
        var i = 0
        var total = 1
        while i < chars.count {
            guard chars[i] == "[", let close = chars[(i + 1)...].firstIndex(of: "]") else {
                lit.append(chars[i])
                i += 1
                continue
            }
            let inner = String(chars[(i + 1)..<close])
            guard let values = try rangeValues(inner, limit: limit) else {
                lit += String(chars[i...close])
                i = close + 1
                continue
            }
            if !lit.isEmpty {
                segs.append(.lit(lit))
                lit = ""
            }
            total *= values.count
            if total > limit { throw InventoryError.tooManyRecords(limit: limit) }
            segs.append(.values(values))
            i = close + 1
        }
        if !lit.isEmpty { segs.append(.lit(lit)) }
        var results = [""]
        for seg in segs {
            switch seg {
            case .lit(let s): results = results.map { $0 + s }
            case .values(let vs): results = results.flatMap { r in vs.map { r + $0 } }
            }
        }
        return results
    }

    /// nil = không phải khoảng (giữ làm văn bản).
    private static func rangeValues(_ inner: String, limit: Int) throws -> [String]? {
        let shown = AnsibleBuilder.clip(inner)
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let a = parts[0]
        let b = parts[1]
        func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        func letter(_ s: String) -> Bool { s.count == 1 && s.first!.isASCII && s.first!.isLetter }
        var stride = 1
        if parts.count == 3 {
            guard digits(parts[2]), let s = Int(parts[2]), s >= 1 else {
                throw PatternError(message: "Bước của khoảng “[\(shown)]” không hợp lệ.")
            }
            stride = s
        }
        if digits(a) && digits(b) {
            guard a.count <= 9, b.count <= 9, let lo = Int(a), let hi = Int(b) else {
                throw PatternError(message: "Số trong khoảng “[\(shown)]” quá lớn.")
            }
            guard lo <= hi else { throw PatternError(message: "Khoảng “[\(shown)]” bị ngược (đầu > cuối).") }
            let count = (hi - lo) / stride + 1
            if count > limit { throw InventoryError.tooManyRecords(limit: limit) }
            let width = (a.count > 1 && a.hasPrefix("0")) ? a.count : 0
            return Swift.stride(from: lo, through: hi, by: stride).map { n in
                let s = String(n)
                return s.count < width ? String(repeating: "0", count: width - s.count) + s : s
            }
        }
        if letter(a) && letter(b), let lo = a.unicodeScalars.first?.value, let hi = b.unicodeScalars.first?.value {
            guard lo <= hi else { throw PatternError(message: "Khoảng “[\(shown)]” bị ngược (đầu > cuối).") }
            return Swift.stride(from: lo, through: hi, by: stride).compactMap { Unicode.Scalar($0).map { String($0) } }
        }
        return nil
    }
}

// MARK: - Mô hình trung gian

struct AnsibleBuilder {
    struct Group {
        var vars: [String: String] = [:]
        var children: [String] = []
    }
    struct HostData {
        var vars: [String: String] = [:]
        var groups: [String] = []
        var line: Int
    }

    var groups: [String: Group] = [:]
    var groupOrder: [String] = []
    var hosts: [String: HostData] = [:]
    var hostOrder: [String] = []
    var issues: [InventoryIssue] = []
    /// Tên máy của dòng bị lỗi cú pháp — để máy đã có không bị coi là “không còn trong nguồn”.
    var failedNames = Set<String>()
    private var secretNames = Set<String>()
    private var keyFileSeen = false
    private var vaultCount = 0

    init() {}

    mutating func ensureGroup(_ name: String) throws {
        guard groups[name] == nil else { return }
        guard groups.count < AnsibleInventory.maxGroups else {
            throw InventoryError.tooManyRecords(limit: AnsibleInventory.maxGroups)
        }
        groups[name] = Group()
        groupOrder.append(name)
    }

    mutating func link(parent: String, child: String) throws {
        try ensureGroup(parent)
        try ensureGroup(child)
        if !(groups[parent]?.children.contains(child) ?? false) { groups[parent]?.children.append(child) }
    }

    /// Lọc một biến: true = giữ (biến kết nối). Biến mật khẩu / key file / `!vault` chỉ được đếm, không giữ giá trị.
    mutating func screen(key rawKey: String, vault: Bool = false) -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespaces).lowercased()
        if vault {
            vaultCount += 1
            if AnsibleInventory.secretKeys.contains(key) { secretNames.insert(key) }
            return false
        }
        if AnsibleInventory.secretKeys.contains(key) {
            secretNames.insert(key)
            return false
        }
        if key == AnsibleInventory.keyFileKey {
            keyFileSeen = true
            return false
        }
        if AnsibleInventory.wantedKeys.contains(key) { return true }
        if PasswordHeader.matches(key) { secretNames.insert(key) }
        return false
    }

    static func canonical(_ key: String) -> String { key.trimmingCharacters(in: .whitespaces).lowercased() }

    mutating func setGroupVar(group: String, key: String, value: String?, vault: Bool = false, line: Int) {
        guard screen(key: key, vault: vault), let value else { return }
        groups[group]?.vars[Self.canonical(key)] = value
    }

    mutating func addHost(name: String, group: String, vars: [String: String], line: Int) throws {
        try ensureGroup(group)
        if hosts[name] == nil {
            guard hosts.count < AnsibleInventory.maxHosts else {
                throw InventoryError.tooManyRecords(limit: AnsibleInventory.maxHosts)
            }
            hosts[name] = HostData(line: line)
            hostOrder.append(name)
        }
        if !(hosts[name]?.groups.contains(group) ?? false) { hosts[name]?.groups.append(group) }
        for (k, v) in vars { hosts[name]?.vars[k] = v }
    }

    mutating func issue(_ severity: InventoryIssue.Severity, line: Int, _ message: String) {
        issues.append(InventoryIssue(severity, row: line, message))
    }

    // MARK: Kết quả

    mutating func finish(defaultUser: String) throws -> InventoryParseResult {
        var result = InventoryParseResult()
        var defaultedUsers = 0
        for n in failedNames { result.failedKeys.insert(InventoryTableParser.normalizeKey(n)) }
        removeCycles()
        var parents: [String: [String]] = [:]
        for g in groupOrder { for c in groups[g]?.children ?? [] { parents[c, default: []].append(g) } }
        var truncated = false
        var tagsCut = 0
        var memo: [String: [String: Int]] = [:]
        func ancestry(_ g: String) -> [String: Int] {
            if let m = memo[g] { return m }
            var depth: [String: Int] = [g: 0]
            var frontier = [g]
            var level = 0
            while !frontier.isEmpty, level < AnsibleInventory.maxAncestorDepth,
                depth.count < AnsibleInventory.maxAncestorsPerGroup
            {
                level += 1
                var next: [String] = []
                for x in frontier {
                    for p in parents[x] ?? [] where depth[p] == nil {
                        depth[p] = level
                        next.append(p)
                    }
                }
                frontier = next
            }
            if !frontier.isEmpty { truncated = true }
            memo[g] = depth
            return depth
        }

        for name in hostOrder {
            guard let host = hosts[name] else { continue }
            let key = InventoryTableParser.normalizeKey(name)

            // Group tổ tiên (memo theo group, có giới hạn) với khoảng cách; layer: host > group gần > group xa > all.
            var depth: [String: Int] = [:]
            if host.groups.count > 100 { truncated = true }
            for g in host.groups.prefix(100) {
                for (a, d) in ancestry(g) where depth[a].map({ d < $0 }) ?? true { depth[a] = d }
            }
            var ordered = depth.keys.filter { $0 != "all" }.sorted {
                let (a, b) = (depth[$0]!, depth[$1]!)
                return a != b ? a < b : $0 > $1
            }
            if ordered.count > AnsibleInventory.maxLayers {
                ordered = Array(ordered.prefix(AnsibleInventory.maxLayers))
                truncated = true
            }
            var layers: [[String: String]] = [host.vars]
            layers += ordered.map { groups[$0]?.vars ?? [:] }
            layers.append(groups["all"]?.vars ?? [:])
            func pick(_ keys: [String]) -> String? {
                for layer in layers { for k in keys { if let v = layer[k] { return v } } }
                return nil
            }

            func fail(_ column: String?, _ message: String) {
                result.issues.append(InventoryIssue(.error, row: host.line, column: column, message))
                result.failedKeys.insert(key)
            }
            let rawHost = pick(AnsibleInventory.hostKeys)
            let rawPort = pick(AnsibleInventory.portKeys)
            let rawUser = pick(AnsibleInventory.userKeys)
            if [rawHost, rawPort, rawUser].contains(where: { $0.map(Self.looksTemplated) ?? false }) {
                fail(nil, "Giá trị dùng mẫu Jinja ({{ }}) — app không tính biến, hãy ghi giá trị cụ thể.")
                continue
            }
            var port = 22
            if let rawPort {
                guard let p = Int(rawPort.trimmingCharacters(in: .whitespaces)) else {
                    fail(InventoryField.port.title, "ansible_port không phải số.")
                    continue
                }
                port = p
            }
            let hostName = (rawHost ?? name).trimmingCharacters(in: .whitespaces)
            var tags: [String] = []
            var seenTags = Set<String>()
            for g in ordered where !AnsibleInventory.implicitGroups.contains(g) {
                if g.count <= 64, !g.contains(","), !InventoryValidator.hasControl(g),
                    !g.trimmingCharacters(in: .whitespaces).isEmpty, seenTags.insert(g.lowercased()).inserted
                {
                    tags.append(g)
                }
            }
            tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if tags.count > AnsibleInventory.maxTagsPerHost {
                tags = Array(tags.prefix(AnsibleInventory.maxTagsPerHost))
                tagsCut += 1
            }
            var user = (rawUser ?? "").trimmingCharacters(in: .whitespaces)
            let userUnset = user.isEmpty
            if userUnset {
                user = defaultUser
                defaultedUsers += 1
            }
            var record = InventoryRecord(
                externalID: name.trimmingCharacters(in: .whitespacesAndNewlines),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), hostName: hostName, port: port,
                user: user, tags: tags, sourceRow: host.line)
            record.userIsDefault = userUnset
            if let problem = InventoryValidator.check(record) {
                fail(problem.field?.title, problem.message)
                continue
            }
            result.records.append(record)
        }

        result.issues = issues + result.issues
        if defaultedUsers > 0 {
            result.warnings.append(
                "\(defaultedUsers) máy không có ansible_user — máy MỚI dùng tên đăng nhập macOS hiện tại (“\(AnsibleBuilder.clip(defaultUser))”) như ssh mặc định; máy đã có giữ nguyên user."
            )
        }
        if tagsCut > 0 {
            result.warnings.append(
                "\(tagsCut) máy có hơn \(AnsibleInventory.maxTagsPerHost) group — chỉ lấy \(AnsibleInventory.maxTagsPerHost) tag."
            )
        }
        if truncated {
            result.warnings.append("Cây group quá lớn/sâu — một số group tổ tiên xa bị bỏ qua khi tính biến và tag.")
        }
        if !secretNames.isEmpty {
            result.warnings.append(
                "Đã bỏ qua biến mật khẩu (giá trị không được đọc vào app): "
                    + secretNames.map(Self.clip).sorted().prefix(20).joined(separator: ", ") + ".")
        }
        if vaultCount > 0 {
            result.warnings.append("Đã bỏ qua \(vaultCount) giá trị !vault (app không giải mã vault).")
        }
        if keyFileSeen {
            result.warnings.append(
                "Đã bỏ qua ansible_ssh_private_key_file (app không đọc file khoá) — hãy gán khoá hoặc bộ đăng nhập cho máy trong app."
            )
        }
        return result
    }

    private static func looksTemplated(_ s: String) -> Bool { s.contains("{{") || s.contains("{%") }

    /// Cạnh con tạo vòng bị gỡ (kèm lỗi) để phần còn lại vẫn xử lý được. DFS không đệ quy.
    private mutating func removeCycles() {
        var state: [String: Int] = [:]  // 1 = đang xét, 2 = xong
        var drop: [(String, String)] = []
        for root in groupOrder where state[root] == nil {
            var stack: [(name: String, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                let children = groups[top.name]?.children ?? []
                if top.next >= children.count {
                    state[top.name] = 2
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let c = children[top.next]
                switch state[c] {
                case 1?: drop.append((top.name, c))
                case nil:
                    state[c] = 1
                    stack.append((c, 0))
                default: break
                }
            }
        }
        for (p, c) in drop {
            groups[p]?.children.removeAll { $0 == c }
            issues.append(
                InventoryIssue(
                    .error, row: 0,
                    "Group “\(Self.clip(c))” là con của “\(Self.clip(p))” nhưng cũng là tổ tiên của nó (vòng) — bỏ liên kết này."
                ))
        }
    }

    static func clip(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !InventoryValidator.isControl($0) }.prefix(40)))
    }
}

// MARK: - INI

enum INIParser {
    private enum Section {
        case hosts(String)
        case vars(String)
        case children(String)
        case skip
    }

    static func parse(_ text: String, into b: inout AnsibleBuilder) throws {
        var section = Section.hosts("ungrouped")
        try b.ensureGroup("ungrouped")
        var lineNo = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") {
                section = try header(line, line: lineNo, builder: &b)
                continue
            }
            switch section {
            case .skip: continue
            case .children(let parent):
                let child = AnsibleBuilder.canonicalName(stripInlineComment(line))
                if child.isEmpty || child.contains(where: { $0.isWhitespace }) {
                    b.issue(.error, line: lineNo, "Tên group con không hợp lệ.")
                    continue
                }
                try b.link(parent: parent, child: child)
            case .vars(let group):
                guard let eq = line.firstIndex(of: "=") else {
                    b.issue(.error, line: lineNo, "Dòng biến thiếu dấu “=”.")
                    continue
                }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                if key.isEmpty {
                    b.issue(.error, line: lineNo, "Dòng biến thiếu tên.")
                    continue
                }
                let value = unquote(stripInlineComment(String(line[line.index(after: eq)...])))
                b.setGroupVar(group: group, key: key, value: value, line: lineNo)
            case .hosts(let group):
                try hostLine(line, group: group, line: lineNo, builder: &b)
            }
        }
    }

    private static func header(_ line: String, line no: Int, builder b: inout AnsibleBuilder) throws -> Section {
        guard let close = line.firstIndex(of: "]") else {
            b.issue(.error, line: no, "Tiêu đề section thiếu dấu “]” — bỏ qua section này.")
            return .skip
        }
        let tail = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty && !tail.hasPrefix("#") && !tail.hasPrefix(";") {
            b.issue(.error, line: no, "Có ký tự thừa sau tiêu đề section — bỏ qua section này.")
            return .skip
        }
        var name = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        var kind = "hosts"
        if let colon = name.lastIndex(of: ":") {
            let suffix = name[name.index(after: colon)...]
            if suffix == "vars" || suffix == "children" {
                kind = String(suffix)
                name = String(name[..<colon]).trimmingCharacters(in: .whitespaces)
            } else {
                b.issue(.error, line: no, "Section có hậu tố lạ (chỉ nhận :vars và :children) — bỏ qua section này.")
                return .skip
            }
        }
        if name.isEmpty || name.contains(where: { $0.isWhitespace }) || InventoryValidator.hasControl(name) {
            b.issue(.error, line: no, "Tên group không hợp lệ — bỏ qua section này.")
            return .skip
        }
        try b.ensureGroup(name)
        switch kind {
        case "vars": return .vars(name)
        case "children": return .children(name)
        default: return .hosts(name)
        }
    }

    private static func hostLine(_ line: String, group: String, line no: Int, builder b: inout AnsibleBuilder) throws {
        /// Dòng lỗi: ghi nhận tên máy (nếu đoán được) để không bị coi là biến mất.
        func markFailed(_ message: String) {
            b.issue(.error, line: no, message)
            if let word = line.split(whereSeparator: { $0.isWhitespace }).first,
                let names = try? AnsibleInventory.expand(String(word))
            {
                for n in names { b.failedNames.insert(n) }
            }
        }
        let tokens: [String]
        do { tokens = try tokenize(line) } catch let e as AnsibleInventory.PatternError {
            markFailed(e.message)
            return
        }
        guard var pattern = tokens.first else { return }
        var vars: [String: String] = [:]
        var pairs: [(String, String)] = []
        for t in tokens.dropFirst() {
            guard let eq = t.firstIndex(of: "="), eq != t.startIndex else {
                markFailed("Biến của máy phải có dạng khoá=giá_trị (giá trị có khoảng trắng cần đặt trong dấu nháy).")
                return
            }
            pairs.append((String(t[..<eq]), String(t[t.index(after: eq)...])))
        }
        for (k, v) in pairs where b.screen(key: k) { vars[AnsibleBuilder.canonical(k)] = v }
        // host:port (chỉ khi đúng một dấu “:” — IPv6 giữ nguyên).
        if pattern.filter({ $0 == ":" }).count == 1, let colon = pattern.lastIndex(of: ":"),
            !pattern.hasSuffix("]"), let port = Int(pattern[pattern.index(after: colon)...]),
            colon != pattern.startIndex
        {
            pattern = String(pattern[..<colon])
            if vars["ansible_port"] == nil && vars["ansible_ssh_port"] == nil { vars["ansible_port"] = String(port) }
        }
        let names: [String]
        do { names = try AnsibleInventory.expand(pattern) } catch let e as AnsibleInventory.PatternError {
            b.issue(.error, line: no, e.message)
            return
        }
        for n in names { try b.addHost(name: n, group: group, vars: vars, line: no) }
    }

    // MARK: Ký tự

    /// Tách theo khoảng trắng ngoài dấu nháy (kiểu shlex): quote đơn/kép, `\` thoát, `#` đầu token = comment.
    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var cur = ""
        var inToken = false
        var quote: Character?
        var escape = false
        for c in line {
            if escape {
                cur.append(c)
                escape = false
                continue
            }
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\" && q == "\"" {
                    escape = true
                } else {
                    cur.append(c)
                }
                continue
            }
            if c == "\\" {
                escape = true
                inToken = true
            } else if c == "\"" || c == "'" {
                quote = c
                inToken = true
            } else if c.isWhitespace {
                if inToken { tokens.append(cur) }
                cur = ""
                inToken = false
            } else if c == "#" && !inToken {
                break
            } else {
                cur.append(c)
                inToken = true
            }
        }
        if quote != nil || escape { throw AnsibleInventory.PatternError(message: "Dấu nháy không được đóng.") }
        if inToken { tokens.append(cur) }
        return tokens
    }

    /// Cắt ` #...` ngoài dấu nháy.
    static func stripInlineComment(_ s: String) -> String {
        var quote: Character?
        var prev: Character = " "
        var out = ""
        for c in s {
            if let q = quote {
                if c == q { quote = nil }
            } else if (c == "\"" || c == "'") && (prev == " " || prev == "\t" || prev == "=") {
                quote = c
            } else if c == "#" && (prev == " " || prev == "\t") {
                break
            }
            out.append(c)
            prev = c
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { return String(t.dropFirst().dropLast()) }
        return t
    }
}

extension AnsibleBuilder {
    static func canonicalName(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
}

// MARK: - YAML -> mô hình

enum YAMLInventory {
    static func parse(_ text: String, into b: inout AnsibleBuilder) throws {
        let root = try MiniYAML.parse(text)
        for e in root { try group(e.key, e.value, line: e.line, parent: nil, builder: &b, depth: 0) }
    }

    private static func group(
        _ name: String, _ node: YAMLNode, line: Int, parent: String?, builder b: inout AnsibleBuilder, depth: Int
    ) throws {
        if depth > MiniYAML.maxDepth { throw InventorySyntaxError(line: line, message: "Group lồng quá sâu.") }
        try b.ensureGroup(name)
        if let parent { try b.link(parent: parent, child: name) }
        switch node {
        case .null: return
        case .vault, .scalar:
            b.issue(.error, line: line, "Group “\(AnsibleBuilder.clip(name))” phải là mapping — bỏ qua.")
            return
        case .map(let entries):
            for e in entries {
                switch e.key {
                case "hosts": try hosts(e, group: name, builder: &b)
                case "children":
                    switch e.value {
                    case .null: break
                    case .map(let kids):
                        for k in kids {
                            try group(k.key, k.value, line: k.line, parent: name, builder: &b, depth: depth + 1)
                        }
                    default: b.issue(.error, line: e.line, "“children” phải là mapping — bỏ qua.")
                    }
                case "vars":
                    switch e.value {
                    case .null: break
                    case .map(let vars):
                        for v in vars {
                            switch v.value {
                            case .scalar(let s): b.setGroupVar(group: name, key: v.key, value: s, line: v.line)
                            case .vault: b.setGroupVar(group: name, key: v.key, value: nil, vault: true, line: v.line)
                            case .null: _ = b.screen(key: v.key)
                            case .map: _ = b.screen(key: v.key)
                            }
                        }
                    default: b.issue(.error, line: e.line, "“vars” phải là mapping — bỏ qua.")
                    }
                default:
                    b.issue(
                        .warning, line: e.line,
                        "Khoá “\(AnsibleBuilder.clip(e.key))” không được hỗ trợ trong group — bỏ qua.")
                }
            }
        }
    }

    private static func hosts(_ entry: YAMLEntry, group: String, builder b: inout AnsibleBuilder) throws {
        switch entry.value {
        case .null: return
        case .map(let list):
            for h in list {
                var vars: [String: String] = [:]
                switch h.value {
                case .null: break
                case .map(let kv):
                    for v in kv {
                        switch v.value {
                        case .scalar(let s): if b.screen(key: v.key) { vars[AnsibleBuilder.canonical(v.key)] = s }
                        case .vault: _ = b.screen(key: v.key, vault: true)
                        case .null, .map: _ = b.screen(key: v.key)
                        }
                    }
                default:
                    b.issue(.error, line: h.line, "Máy “\(AnsibleBuilder.clip(h.key))” phải là mapping hoặc để trống.")
                    continue
                }
                let names: [String]
                do { names = try AnsibleInventory.expand(h.key) } catch let e as AnsibleInventory.PatternError {
                    b.issue(.error, line: h.line, e.message)
                    continue
                }
                for n in names { try b.addHost(name: n, group: group, vars: vars, line: h.line) }
            }
        default:
            b.issue(.error, line: entry.line, "“hosts” phải là mapping — bỏ qua.")
        }
    }
}
