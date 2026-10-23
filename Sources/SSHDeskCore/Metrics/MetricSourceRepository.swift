import Foundation

/// Bảng `metric_sources` + `metric_folder_sources` (migration v11). Không bao giờ chứa token/password.
public final class MetricSourceRepository: @unchecked Sendable {
    private let db: Database
    private let now: @Sendable () -> Date

    private static let columns =
        "id, name, kind, base_url, auth_kind, basic_user, credential_ref, instance_template, allow_insecure_http, created_at"

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = database
        self.now = now
    }

    // MARK: - Đọc

    public func all() throws -> [MetricsSource] {
        try db.query("SELECT \(Self.columns) FROM metric_sources ORDER BY name COLLATE NOCASE, id")
            .compactMap(Self.decode)
    }

    public func source(id: UUID) throws -> MetricsSource? {
        try db.query(
            "SELECT \(Self.columns) FROM metric_sources WHERE id = ?", [.text(id.uuidString)]
        ).compactMap(Self.decode).first
    }

    // MARK: - Ghi

    @discardableResult
    public func insert(_ source: MetricsSource) throws -> MetricsSource {
        var s = try source.validated()
        s.createdAt = now()
        try db.execute(
            "INSERT INTO metric_sources(\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            Self.values(s))
        return s
    }

    @discardableResult
    public func update(_ source: MetricsSource) throws -> MetricsSource {
        var s = try source.validated()
        guard let stored = try self.source(id: s.id) else { throw MetricsSourceError.notFound(s.id) }
        s.createdAt = stored.createdAt
        try db.execute(
            """
            UPDATE metric_sources SET name = ?, kind = ?, base_url = ?, auth_kind = ?, basic_user = ?,
            credential_ref = ?, instance_template = ?, allow_insecure_http = ? WHERE id = ?
            """,
            Array(Self.values(s).dropFirst().dropLast()) + [.text(s.id.uuidString)])
        return s
    }

    /// Xoá nguồn; gán thư mục biến mất theo CASCADE. Việc xoá item bí mật do service lo.
    public func delete(id: UUID) throws {
        try db.execute("DELETE FROM metric_sources WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Gán thư mục

    /// Nguồn của thư mục; nil = đo qua SSH (mặc định).
    public func assignedSourceID(folder: String) throws -> UUID? {
        let rows = try db.query(
            "SELECT source_id FROM metric_folder_sources WHERE folder = ?", [.text(folder)])
        if case .text(let s)? = rows.first?.first { return UUID(uuidString: s) }
        return nil
    }

    public func assignments() throws -> [String: UUID] {
        var out: [String: UUID] = [:]
        for row in try db.query("SELECT folder, source_id FROM metric_folder_sources") {
            if case .text(let f) = row[0], case .text(let s) = row[1], let id = UUID(uuidString: s) {
                out[f] = id
            }
        }
        return out
    }

    /// `sourceID == nil` -> trả thư mục về nguồn SSH.
    public func assign(folder: String, sourceID: UUID?) throws {
        try db.transaction {
            guard let sourceID else {
                try db.execute("DELETE FROM metric_folder_sources WHERE folder = ?", [.text(folder)])
                return
            }
            guard try source(id: sourceID) != nil else { throw MetricsSourceError.notFound(sourceID) }
            try db.execute(
                """
                INSERT INTO metric_folder_sources(folder, source_id) VALUES (?, ?)
                ON CONFLICT(folder) DO UPDATE SET source_id = excluded.source_id
                """, [.text(folder), .text(sourceID.uuidString)])
        }
    }

    // MARK: - Chuyển đổi dòng

    private static func values(_ s: MetricsSource) -> [SQLValue] {
        [
            .text(s.id.uuidString), .text(s.name), .text(s.kind.rawValue), .text(s.baseURL),
            .text(s.authKind.rawValue), s.basicUser.map { .text($0) } ?? .null,
            s.credentialRef.map { .text($0) } ?? .null, .text(s.instanceTemplate),
            .int(s.allowInsecureHTTP ? 1 : 0), .real(s.createdAt.timeIntervalSince1970),
        ]
    }

    private static func decode(_ row: [SQLValue]) -> MetricsSource? {
        guard row.count == 10, case .text(let idText) = row[0], let id = UUID(uuidString: idText),
            case .text(let name) = row[1], case .text(let kindText) = row[2],
            let kind = MetricsSourceKind(rawValue: kindText), case .text(let url) = row[3],
            case .text(let authText) = row[4], let auth = MetricsAuthKind(rawValue: authText),
            case .text(let template) = row[7], case .int(let insecure) = row[8],
            case .real(let created) = row[9]
        else { return nil }
        var user: String?
        if case .text(let u) = row[5] { user = u }
        return MetricsSource(
            id: id, name: name, kind: kind, baseURL: url, authKind: auth, basicUser: user,
            instanceTemplate: template, allowInsecureHTTP: insecure != 0,
            createdAt: Date(timeIntervalSince1970: created))
    }
}
