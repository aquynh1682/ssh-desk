import CryptoKit
import Foundation

/// Nguồn JSON `sshdesk-hosts` v1 (ADR-020) và Ansible inventory tĩnh (ADR-026). Thuần: chỉ đọc một file, không
/// chạy process, không chạm DB/Keychain/mạng.
public enum InventoryStructured {
    public struct Loaded: Sendable {
        public var url: URL
        public var kind: InventorySourceKind
        public var fingerprint: String
        public var result: InventoryParseResult
    }

    public static func supports(_ kind: InventorySourceKind) -> Bool { kind == .json || kind == .ansible }

    // MARK: - Đọc

    /// Đọc file thường ≤ 5 MB (kiểm cả byte thực đọc được), tính vân tay từ chính các byte đó.
    static func readBounded(_ url: URL, limit: Int = 5 * 1_048_576) throws -> (Data, String) {
        let resolved = url.resolvingSymlinksInPath()
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: resolved.path) } catch {
            throw SpreadsheetError.unreadable(error.localizedDescription)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw SpreadsheetError.notRegularFile }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= limit else {
            throw SpreadsheetError.fileTooLarge(limitMB: limit / 1_048_576)
        }
        guard let fh = FileHandle(forReadingAtPath: resolved.path) else {
            throw SpreadsheetError.unreadable("không mở được file")
        }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else { throw SpreadsheetError.fileTooLarge(limitMB: limit / 1_048_576) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (data, "\(hash)|\(Int(mtime * 1000))|\(size)")
    }

    public static func load(url: URL, kind: InventorySourceKind) throws -> Loaded {
        let (data, fingerprint) = try readBounded(url)
        let result: InventoryParseResult
        switch kind {
        case .json: result = try parseJSON(data)
        case .ansible: result = try AnsibleInventory.parse(data: data, fileName: url.lastPathComponent)
        default: throw SpreadsheetError.unsupportedExtension(kind.title)
        }
        return Loaded(url: url, kind: kind, fingerprint: fingerprint, result: result)
    }

    // MARK: - JSON

    /// Mỗi host -> bản ghi; kiểm bằng đúng validator của ADR-020 (`HostExchange.convert`) rồi validator nguồn.
    /// `external_id` = `id` trong file; jump host (`jumpHostId` = id trong file) ánh xạ khi lập kế hoạch.
    public static func parseJSON(_ data: Data, now: Date = Date()) throws -> InventoryParseResult {
        let file = try HostExchange.decode(data)
        var result = InventoryParseResult()
        var firstRow: [String: Int] = [:]
        for (i, x) in file.hosts.enumerated() {
            let row = i + 1
            let id = x.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = InventoryTableParser.normalizeKey(id)
            func fail(_ column: String?, _ message: String) {
                result.issues.append(InventoryIssue(.error, row: row, column: column, message))
                if !id.isEmpty { result.failedKeys.insert(key) }
            }
            if id.isEmpty || id.count > 200 || InventoryValidator.hasControl(id) {
                fail("id", "Thiếu hoặc sai id của máy.")
                continue
            }
            if let first = firstRow[key] {
                fail("id", "Trùng id với máy thứ \(first).")
                continue
            }
            firstRow[key] = row
            let profile: HostProfile
            switch HostExchange.convert(x, newID: UUID(), now: now) {
            case .success(let p): profile = p
            case .failure(let e):
                fail(nil, e.message)
                continue
            }
            if profile.connectionMode != .managed {
                result.issues.append(
                    InventoryIssue(
                        .warning, row: row,
                        "Máy dùng alias trong ~/.ssh/config không đồng bộ được từ nguồn — bỏ qua."))
                result.failedKeys.insert(key)
                continue
            }
            let isWindows = profile.kind == .windowsRDP
            let jump = x.jumpHostId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let setName = x.credentialSet?.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = InventoryRecord(
                externalID: id, name: profile.displayName, hostName: profile.hostName, port: profile.port,
                user: isWindows ? profile.rdpUsername : profile.user, kind: profile.kind,
                environment: profile.environment, folder: profile.project.isEmpty ? nil : profile.project,
                jumpRef: isWindows || jump?.isEmpty != false ? nil : jump,
                credentialSetName: setName?.isEmpty == false ? setName : nil,
                notes: profile.notes.isEmpty ? nil : profile.notes, tags: profile.tags, sourceRow: row)
            if let problem = InventoryValidator.check(record) {
                fail(problem.field?.title, problem.message)
                continue
            }
            result.records.append(record)
        }
        if file.hosts.contains(where: { $0.needsReauth }) {
            result.warnings.append("File ghi chú một số máy cần nhập lại mật khẩu — mật khẩu không nằm trong file.")
        }
        return result
    }

    // MARK: - Kế hoạch

    public static func plan(
        source: InventorySource?, loaded: Loaded, existingHosts: [HostProfile], credentialSets: [CredentialSet],
        now: Date = Date()
    ) throws -> InventorySyncPlan {
        try InventorySync.plan(
            source: source, records: loaded.result.records, issues: loaded.result.issues,
            warnings: loaded.result.warnings, failedKeys: loaded.result.failedKeys,
            managesJump: loaded.kind == .json, existingHosts: existingHosts, credentialSets: credentialSets,
            fingerprint: loaded.fingerprint, now: now)
    }

    /// "Đồng bộ lại" / "Xem trước" một nguồn JSON / Ansible đã lưu.
    public static func resync(
        source: InventorySource, pathOverride: URL? = nil, existingHosts: [HostProfile],
        credentialSets: [CredentialSet], now: Date = Date()
    ) throws -> InventorySyncPlan {
        let url = pathOverride ?? URL(fileURLWithPath: source.path)
        let loaded = try load(url: url, kind: source.kind)
        var src = source
        src.path = url.path
        return try plan(
            source: src, loaded: loaded, existingHosts: existingHosts, credentialSets: credentialSets, now: now)
    }
}
