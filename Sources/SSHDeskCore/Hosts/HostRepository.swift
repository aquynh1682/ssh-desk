import Foundation

public enum HostRepositoryError: Error, Equatable {
    case notFound(UUID)
    case duplicateID(UUID)
    case jumpHostNotFound(UUID)
    /// Chuỗi id tạo thành vòng (vd A→B→A).
    case jumpCycle([UUID])
    /// Không xoá được vì các host này đang dùng nó làm jump host.
    case referencedAsJumpHost([UUID])
}

public actor HostRepository {
    private let db: Database
    private let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = database
        self.now = now
    }

    private static let columns = """
        id, display_name, project, environment, tags_json, notes, is_favorite, connection_mode, \
        host_name, port, user, auth_method, identity_file, jump_host_id, ssh_config_path, \
        ssh_config_alias, credential_reference, bookmarks_json, default_local_directory, \
        default_remote_directory, created_at, updated_at, last_launch_requested_at
        """

    // MARK: - Đọc

    public func all() throws -> [HostProfile] {
        try db.query(
            "SELECT \(Self.columns) FROM hosts ORDER BY display_name COLLATE NOCASE, id"
        ).map(Self.decode)
    }

    public func host(id: UUID) throws -> HostProfile? {
        try db.query(
            "SELECT \(Self.columns) FROM hosts WHERE id = ?", [.text(id.uuidString)]
        ).first.map(Self.decode)
    }

    public func favorites() throws -> [HostProfile] {
        try all().filter(\.isFavorite)
    }

    public func projects() throws -> [String] {
        let rows = try db.query(
            "SELECT DISTINCT project FROM hosts WHERE project <> '' ORDER BY project COLLATE NOCASE")
        return rows.compactMap { if case .text(let s)? = $0.first { return s } else { return nil } }
    }

    /// Tìm không phân biệt hoa thường/dấu theo displayName, hostName, user, tags, project.
    /// Lọc trong Swift nên `%`, `_`, `'` chỉ là ký tự thường, không có SQL nào nối dữ liệu người dùng.
    public func search(_ query: String) throws -> [HostProfile] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = try all()
        if q.isEmpty { return hosts }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func hit(_ s: String) -> Bool { s.range(of: q, options: options) != nil }
        return hosts.filter {
            hit($0.displayName) || hit($0.hostName) || hit($0.user) || hit($0.project)
                || $0.tags.contains(where: hit)
        }
    }

    // MARK: - Ghi

    public func insert(_ host: HostProfile) throws {
        try host.validate()
        try db.transaction {
            if try fetchExists(host.id) { throw HostRepositoryError.duplicateID(host.id) }
            try checkJump(host)
            try write(host, insert: true)
        }
    }

    /// `updatedAt` luôn do repository đặt; `createdAt` giữ giá trị đã lưu.
    @discardableResult
    public func update(_ host: HostProfile) throws -> HostProfile {
        try host.validate()
        return try db.transaction {
            guard let stored = try self.host(id: host.id) else {
                throw HostRepositoryError.notFound(host.id)
            }
            try checkJump(host)
            var saved = host
            saved.createdAt = stored.createdAt
            saved.updatedAt = now()
            try write(saved, insert: false)
            return saved
        }
    }

    public func delete(id: UUID) throws {
        try db.transaction {
            guard try fetchExists(id) else { throw HostRepositoryError.notFound(id) }
            let refs = try db.query(
                "SELECT id FROM hosts WHERE jump_host_id = ?", [.text(id.uuidString)])
            let ids = refs.compactMap { row -> UUID? in
                if case .text(let s)? = row.first { return UUID(uuidString: s) } else { return nil }
            }
            if !ids.isEmpty { throw HostRepositoryError.referencedAsJumpHost(ids) }
            try db.execute("DELETE FROM hosts WHERE id = ?", [.text(id.uuidString)])
        }
    }

    public func setFavorite(id: UUID, _ value: Bool) throws {
        try db.transaction {
            guard try fetchExists(id) else { throw HostRepositoryError.notFound(id) }
            try db.execute(
                "UPDATE hosts SET is_favorite = ?, updated_at = ? WHERE id = ?",
                [.int(value ? 1 : 0), .real(now().timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    public func markLaunchRequested(id: UUID, at date: Date) throws {
        try db.transaction {
            guard try fetchExists(id) else { throw HostRepositoryError.notFound(id) }
            try db.execute(
                "UPDATE hosts SET last_launch_requested_at = ? WHERE id = ?",
                [.real(date.timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    // MARK: - SSH config

    /// Spec cho các host managed (host imported dùng nguyên alias gốc, không sinh Host block).
    public func sshSpecs() throws -> [SSHHostSpec] {
        let hosts = try all()
        let byID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        return hosts.filter { $0.connectionMode == .managed }.map { h in
            var jump: String?
            if let jid = h.jumpHostID, let bastion = byID[jid] { jump = bastion.sshAlias }
            return SSHHostSpec(
                alias: HostProfile.managedAlias(for: h.id), hostName: h.hostName, port: h.port,
                user: h.user,
                identityFile: h.authMethod == .keyFile ? h.identityFile : nil,
                jumpAlias: jump)
        }
    }

    /// Alias để chạy `ssh -F <config app> <alias>`.
    public nonisolated func sshAlias(for host: HostProfile) -> String? { host.sshAlias }

    // MARK: - Nội bộ

    private func fetchExists(_ id: UUID) throws -> Bool {
        !(try db.query("SELECT 1 FROM hosts WHERE id = ?", [.text(id.uuidString)])).isEmpty
    }

    /// Jump host phải tồn tại và chuỗi bastion không quay lại chính host.
    private func checkJump(_ host: HostProfile) throws {
        guard var current = host.jumpHostID else { return }
        var path = [host.id]
        while true {
            if let idx = path.firstIndex(of: current) {
                throw HostRepositoryError.jumpCycle(Array(path[idx...]) + [current])
            }
            guard let next = try self.host(id: current) else {
                throw HostRepositoryError.jumpHostNotFound(current)
            }
            path.append(current)
            guard let n = next.jumpHostID else { return }
            current = n
        }
    }

    private func write(_ h: HostProfile, insert: Bool) throws {
        let tags = try Self.json(h.tags)
        let marks = try Self.json(h.remoteBookmarks)
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        let values: [SQLValue] = [
            .text(h.displayName), .text(h.project), .text(h.environment.rawValue), .text(tags),
            .text(h.notes), .int(h.isFavorite ? 1 : 0), .text(h.connectionMode.rawValue),
            .text(h.hostName), .int(Int64(h.port)), .text(h.user), .text(h.authMethod.rawValue),
            opt(h.identityFile), opt(h.jumpHostID?.uuidString), opt(h.sshConfigPath),
            opt(h.sshConfigAlias), opt(h.credentialReference), .text(marks),
            .text(h.defaultLocalDirectory), .text(h.defaultRemoteDirectory),
            .real(h.createdAt.timeIntervalSince1970), .real(h.updatedAt.timeIntervalSince1970),
            h.lastLaunchRequestedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
        ]
        if insert {
            let marks = Array(repeating: "?", count: values.count + 1).joined(separator: ", ")
            try db.execute(
                "INSERT INTO hosts (\(Self.columns)) VALUES (\(marks))",
                [.text(h.id.uuidString)] + values)
        } else {
            let sets = Self.columns.components(separatedBy: ", ").dropFirst()
                .map { "\($0.trimmingCharacters(in: .whitespaces)) = ?" }.joined(separator: ", ")
            try db.execute(
                "UPDATE hosts SET \(sets) WHERE id = ?", values + [.text(h.id.uuidString)])
        }
    }

    private static func json<T: Encodable>(_ v: T) throws -> String {
        String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
    }

    private static func decode(_ row: [SQLValue]) throws -> HostProfile {
        func bad(_ what: String) -> DatabaseError { .corrupt("hàng hosts không hợp lệ: \(what)") }
        func text(_ i: Int) throws -> String {
            if case .text(let s) = row[i] { return s }
            throw bad("cột \(i)")
        }
        func optText(_ i: Int) -> String? {
            if case .text(let s) = row[i] { return s } else { return nil }
        }
        func int(_ i: Int) throws -> Int64 {
            if case .int(let v) = row[i] { return v }
            throw bad("cột \(i)")
        }
        func date(_ i: Int) throws -> Date {
            switch row[i] {
            case .real(let v): return Date(timeIntervalSince1970: v)
            case .int(let v): return Date(timeIntervalSince1970: Double(v))
            default: throw bad("cột \(i)")
            }
        }
        guard row.count == 23, let id = UUID(uuidString: try text(0)),
            let env = HostEnvironment(rawValue: try text(3)),
            let mode = HostConnectionMode(rawValue: try text(7)),
            let auth = HostAuthMethod(rawValue: try text(11))
        else { throw bad("giá trị") }
        let tags = try? JSONDecoder().decode([String].self, from: Data(try text(4).utf8))
        let marks = try? JSONDecoder().decode(
            [RemoteBookmark].self, from: Data(try text(17).utf8))
        guard let tags, let marks else { throw bad("JSON") }
        var launch: Date?
        if case .null = row[22] {} else { launch = try date(22) }
        return HostProfile(
            id: id, displayName: try text(1), project: try text(2), environment: env, tags: tags,
            notes: try text(5), isFavorite: try int(6) != 0, connectionMode: mode,
            hostName: try text(8), port: Int(try int(9)), user: try text(10), authMethod: auth,
            identityFile: optText(12), jumpHostID: optText(13).flatMap(UUID.init(uuidString:)),
            sshConfigPath: optText(14), sshConfigAlias: optText(15),
            credentialReference: optText(16), remoteBookmarks: marks,
            defaultLocalDirectory: try text(18), defaultRemoteDirectory: try text(19),
            createdAt: try date(20), updatedAt: try date(21), lastLaunchRequestedAt: launch)
    }
}
