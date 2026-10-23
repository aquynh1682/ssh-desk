import Foundation

/// Kiểm một bản ghi bằng đúng validator của form/ADR-020 (`HostDraft` + `HostProfile.validate`).
public enum InventoryValidator {
    public struct Problem: Equatable, Sendable {
        public var field: InventoryField?
        public var message: String
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool { PortForward.isControl(s) }
    static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains(where: isControl) }

    /// Dựng host tạm từ bản ghi (id/ngày do bên gọi truyền).
    static func profile(from r: InventoryRecord, folder: String, id: UUID = UUID(), now: Date = Date()) -> HostProfile {
        if r.kind == .windowsRDP {
            return HostProfile(
                id: id, displayName: r.name, project: folder, environment: r.environment ?? .other,
                notes: r.notes ?? "", kind: .windowsRDP, rdpUsername: r.user, hostName: r.hostName, port: r.port,
                createdAt: now, updatedAt: now)
        }
        return HostProfile(
            id: id, displayName: r.name, project: folder, environment: r.environment ?? .other, notes: r.notes ?? "",
            hostName: r.hostName, port: r.port, user: r.user, createdAt: now, updatedAt: now)
    }

    /// nil = hợp lệ.
    public static func check(_ r: InventoryRecord) -> Problem? {
        let singleLine: [(InventoryField, String)] = [
            (.name, r.name), (.hostName, r.hostName), (.user, r.user), (.folder, r.folder ?? ""),
            (.jumpHost, r.jumpRef ?? ""), (.credentialSet, r.credentialSetName ?? ""),
        ]
        for (field, value) in singleLine where hasControl(value) {
            return Problem(field: field, message: "\(field.title) chứa ký tự điều khiển hoặc xuống dòng.")
        }
        if let n = r.notes,
            n.unicodeScalars.contains(where: { isControl($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" })
        {
            return Problem(field: .notes, message: "Ghi chú chứa ký tự điều khiển.")
        }
        if r.name.count > 200 { return Problem(field: .name, message: "Tên quá dài (tối đa 200 ký tự).") }
        if (r.notes ?? "").count > 20_000 { return Problem(field: .notes, message: "Ghi chú quá dài.") }
        if r.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Problem(field: .name, message: "Thiếu Tên.")
        }
        if r.hostName.trimmingCharacters(in: .whitespaces).isEmpty {
            return Problem(field: .hostName, message: "Thiếu IP/Hostname.")
        }
        do { try SSHConfigWriter.validateHostName(r.hostName) } catch {
            return Problem(field: .hostName, message: "IP/Hostname không hợp lệ.")
        }
        if !(1...65535).contains(r.port) { return Problem(field: .port, message: "Port ngoài khoảng 1–65535.") }
        if let f = r.folder, !f.isEmpty {
            do { _ = try HostFolders.normalize(f) } catch {
                return Problem(field: .folder, message: "Tên thư mục không hợp lệ.")
            }
        }
        let host = profile(from: r, folder: r.folder ?? "")
        let draft = HostDraft(host: host)
        let problems = draft.errors(basedOn: nil)
        if let (field, message) = problems.sorted(by: { "\($0.key)" < "\($1.key)" }).first {
            return Problem(field: map(field), message: message)
        }
        do { try host.validate() } catch let e as HostValidationError {
            let (field, message) = HostDraft.describe(e)
            return Problem(field: map(field), message: message)
        } catch { return Problem(field: nil, message: "Dữ liệu không hợp lệ.") }
        return nil
    }

    private static func map(_ f: HostDraft.Field) -> InventoryField? {
        switch f {
        case .displayName: return .name
        case .hostName: return .hostName
        case .port: return .port
        case .user, .rdpUser: return .user
        case .jumpHost: return .jumpHost
        default: return nil
        }
    }
}

public struct InventoryParseResult: Sendable, Equatable {
    public var records: [InventoryRecord] = []
    public var issues: [InventoryIssue] = []
    /// Cảnh báo chung của file (cột mật khẩu, công thức...).
    public var warnings: [String] = []
    public var blankRows = 0
    /// Khoá của các dòng bị loại vì lỗi (nếu xác định được) — để máy đã có không bị coi là "không còn trong nguồn".
    public var failedKeys: Set<String> = []
    /// Trường nguồn thực sự quản lý (cột đã ghép được).
    public var managedFields: Set<InventoryField> = []

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
}

/// Bảng đã đọc + cách ghép -> bản ghi chuẩn hoá và lỗi theo dòng (ADR-026). Dòng lỗi bị bỏ qua,
/// dòng trống bỏ qua im lặng; lỗi một dòng không làm hỏng file.
public enum InventoryTableParser {
    public static func parse(sheet: TableSheet, mapping: TableMapping) throws -> InventoryParseResult {
        var result = InventoryParseResult()
        result.warnings = sheet.warnings
        let resolved = mapping.resolve(in: sheet)
        for (field, header) in resolved.blocked.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            result.warnings.append("Cột “\(header)” giống mật khẩu nên không được ghép vào “\(field.title)”.")
        }
        for (field, header) in resolved.missing.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            result.issues.append(
                InventoryIssue(.error, row: 0, column: header, "Không thấy cột đã ghép cho “\(field.title)”."))
        }
        guard let hostColumn = resolved.columns[.hostName] else {
            result.issues.append(InventoryIssue(.error, row: 0, "Chưa ghép cột IP/Hostname."))
            return result
        }
        _ = hostColumn
        if !result.issues.isEmpty { return result }

        let rows = sheet.dataRows
        if rows.filter({ !$0.isBlank }).count > InventoryLimits.maxRecords {
            throw InventoryError.tooManyRecords(limit: InventoryLimits.maxRecords)
        }
        result.managedFields = Set(resolved.columns.keys)
        let strict = mapping.isTemplate
        let keyField: InventoryField = resolved.columns[mapping.keyField] != nil ? mapping.keyField : .hostName
        var seenKeys: [String: Int] = [:]

        func title(_ f: InventoryField) -> String { mapping.header(for: f) ?? f.title }

        for row in rows {
            if row.isBlank {
                result.blankRows += 1
                continue
            }
            var rowKey: String?
            func cell(_ f: InventoryField) -> String? {
                guard let i = resolved.columns[f] else { return nil }
                return row.cell(i).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func fail(_ f: InventoryField?, _ message: String) {
                if let k = rowKey { result.failedKeys.insert(k) }
                result.issues.append(InventoryIssue(.error, row: row.number, column: f.map(title), message))
            }
            func warn(_ f: InventoryField?, _ message: String) {
                result.issues.append(InventoryIssue(.warning, row: row.number, column: f.map(title), message))
            }

            var name = cell(.name) ?? ""
            let hostName = cell(.hostName) ?? ""
            rowKey =
                (keyField == .hostName ? hostName : (cell(keyField) ?? "")).isEmpty
                ? (name.isEmpty ? nil : name) : (keyField == .hostName ? hostName : cell(keyField))
            if hostName.isEmpty && name.isEmpty {
                fail(.hostName, "Thiếu Tên và IP/Hostname.")
                continue
            }
            if strict && name.isEmpty {
                fail(.name, "Thiếu Tên.")
                continue
            }
            if hostName.isEmpty {
                fail(.hostName, "Thiếu IP/Hostname.")
                continue
            }
            if name.isEmpty { name = hostName }

            // Loại
            var kind = HostKind.ssh
            if let k = cell(.kind), !k.isEmpty {
                switch HeaderText.normalize(k) {
                case "ssh", "linux": kind = .ssh
                case "windows", "win", "rdp": kind = .windowsRDP
                default:
                    fail(.kind, "Loại “\(clip(k))” không hợp lệ (chỉ SSH hoặc Windows).")
                    continue
                }
            }
            // Môi trường
            var environment: HostEnvironment?
            if let e = cell(.environment) {
                if e.isEmpty {
                    environment = .other
                } else if let parsed = parseEnvironment(e, strict: strict) {
                    environment = parsed
                } else {
                    fail(.environment, "Môi trường “\(clip(e))” không hợp lệ (DEV, UAT, STG, PROD).")
                    continue
                }
            }
            // Port
            var port = kind == .windowsRDP ? HostProfile.defaultRDPPort : 22
            if let p = cell(.port), !p.isEmpty {
                guard let parsed = parsePort(p) else {
                    fail(.port, "Port “\(clip(p))” không phải số nguyên.")
                    continue
                }
                guard (1...65535).contains(parsed) else {
                    fail(.port, "Port ngoài khoảng 1–65535.")
                    continue
                }
                port = parsed
            }
            // User
            let user = cell(.user) ?? ""
            if kind == .ssh && user.isEmpty {
                fail(.user, "Thiếu User.")
                continue
            }

            // Jump host (cảnh báo, không loại dòng)
            var jump = cell(.jumpHost).flatMap { $0.isEmpty ? nil : $0 }
            if let j = jump {
                if kind == .windowsRDP {
                    warn(.jumpHost, "Máy Windows không có jump host — đã bỏ qua.")
                    jump = nil
                } else if sameKey(j, name) {
                    warn(.jumpHost, "Jump host trỏ chính nó — đã bỏ qua.")
                    jump = nil
                }
            }
            // Bộ đăng nhập
            var setName: String?
            if let s = cell(.credentialSet), !s.isEmpty {
                do { setName = try CredentialSet.normalizedName(s) } catch {
                    fail(.credentialSet, "Tên bộ đăng nhập không hợp lệ.")
                    continue
                }
            }
            var folder = cell(.folder)
            if let f = folder, f.isEmpty { folder = nil }

            let keyValue: String
            switch keyField {
            case .hostName: keyValue = hostName
            case .name: keyValue = name
            default: keyValue = (cell(keyField) ?? "").isEmpty ? name : (cell(keyField) ?? name)
            }

            var record = InventoryRecord(
                externalID: keyValue, name: name, hostName: hostName, port: port, user: user, kind: kind,
                environment: environment, folder: folder, jumpRef: jump, credentialSetName: setName,
                notes: cell(.notes), sourceRow: row.number)
            if kind == .windowsRDP { record.jumpRef = nil }

            if let problem = InventoryValidator.check(record) {
                fail(problem.field, problem.message)
                continue
            }
            let normalizedKey = normalizeKey(record.externalID)
            if let first = seenKeys[normalizedKey] {
                fail(keyField, "Trùng \(keyField == .name ? "tên" : keyField.title.lowercased()) với dòng \(first).")
                continue
            }
            seenKeys[normalizedKey] = row.number
            result.records.append(record)
        }
        return result
    }

    // MARK: - Giá trị

    /// Port: "22", "22.0", "2.2E1" -> số nguyên; nil nếu không phải số nguyên.
    static func parsePort(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let i = Int(t) { return i }
        guard !t.isEmpty, t.allSatisfy({ "0123456789.eE+-".contains($0) }) else { return nil }
        guard let d = Double(t), d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    static func parseEnvironment(_ text: String, strict: Bool) -> HostEnvironment? {
        let n = HeaderText.normalize(text)
        if strict {
            switch n {
            case "dev": return .dev
            case "uat": return .uat
            case "stg": return .stg
            case "prod": return .prod
            case "other": return .other
            default: return nil
            }
        }
        switch n {
        case "prod", "production", "prd": return .prod
        case "uat": return .uat
        case "stg", "staging": return .stg
        case "dev", "development", "test": return .dev
        default: return .other
        }
    }

    static func normalizeKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sameKey(_ a: String, _ b: String) -> Bool { normalizeKey(a) == normalizeKey(b) }

    private static func clip(_ s: String) -> String {
        String(s.unicodeScalars.filter { !InventoryValidator.isControl($0) }.prefix(40).map(Character.init))
    }
}
