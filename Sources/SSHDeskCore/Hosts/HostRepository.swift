import Foundation

public enum HostRepositoryError: Error, Equatable {
    case notFound(UUID)
    case duplicateID(UUID)
    case jumpHostNotFound(UUID)
    /// Chuỗi id tạo thành vòng (vd A→B→A).
    case jumpCycle([UUID])
    /// Không xoá được vì các host này đang dùng nó làm jump host.
    case referencedAsJumpHost([UUID])
    /// Đổi tên trùng một thư mục khác (giá trị = tên thư mục đang có).
    case folderNameExists(String)
}

public actor HostRepository {
    let db: Database
    let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = database
        self.now = now
    }

    private static let columns = """
        id, display_name, project, environment, tags_json, notes, is_favorite, connection_mode, \
        host_name, port, user, auth_method, identity_file, jump_host_id, ssh_config_path, \
        ssh_config_alias, credential_reference, bookmarks_json, default_local_directory, \
        default_remote_directory, created_at, updated_at, last_launch_requested_at, \
        kind, rdp_username, rdp_domain, rdp_gateway, rdp_screen_mode, rdp_multi_monitor, \
        rdp_redirect_clipboard, rdp_admin_session, identity_agent, credential_set_id, \
        autofill_hold, autofill_hold_reason, source_id, external_id, source_missing
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

    /// Tên thư mục (một cấp) đang có: thư mục có host + thư mục rỗng đã tạo, sắp theo tên.
    public func folders() throws -> [String] {
        let rows = try db.query(
            "SELECT project FROM hosts WHERE project <> '' UNION SELECT name FROM host_folders")
        let names = rows.compactMap { row -> String? in
            if case .text(let s)? = row.first { return s } else { return nil }
        }
        return HostFolders.sortedUnique(names)
    }

    /// Tạo thư mục rỗng. Đã có thư mục trùng tên (không phân biệt hoa thường/dấu) thì dùng lại tên đó.
    /// Trả tên thư mục thực sự dùng.
    @discardableResult
    public func createFolder(_ rawName: String) throws -> String {
        let name = try HostFolders.normalize(rawName)
        return try db.transaction {
            if let existing = try matchingFolder(name, excluding: nil) { return existing }
            try db.execute("INSERT INTO host_folders(name) VALUES (?)", [.text(name)])
            return name
        }
    }

    /// Đổi tên thư mục: đổi `project` của mọi host trong đó, một transaction.
    /// Trùng tên thư mục khác → ném `folderNameExists` trừ khi `merge` (gộp vào thư mục đó, giữ cách viết của nó).
    /// Trả tên thư mục kết quả.
    @discardableResult
    public func renameFolder(from old: String, to rawName: String, merge: Bool = false) throws
        -> String
    {
        let new = try HostFolders.normalize(rawName)
        return try db.transaction {
            var target = new
            if let other = try matchingFolder(new, excluding: old) {
                if !merge { throw HostRepositoryError.folderNameExists(other) }
                target = other
            }
            if target == old { return old }
            try db.execute(
                "UPDATE hosts SET project = ?, updated_at = ? WHERE project = ?",
                [.text(target), .real(now().timeIntervalSince1970), .text(old)])
            try db.execute("DELETE FROM host_folders WHERE name = ?", [.text(old)])
            try db.execute("INSERT OR IGNORE INTO host_folders(name) VALUES (?)", [.text(target)])
            return target
        }
    }

    /// Xoá thư mục: host trong đó về "Chưa phân loại". KHÔNG xoá host. Trả số host bị ảnh hưởng.
    @discardableResult
    public func deleteFolder(_ name: String) throws -> Int {
        try db.transaction {
            let n = try db.query(
                "SELECT COUNT(*) FROM hosts WHERE project = ?", [.text(name)])
            try db.execute(
                "UPDATE hosts SET project = '', updated_at = ? WHERE project = ?",
                [.real(now().timeIntervalSince1970), .text(name)])
            try db.execute("DELETE FROM host_folders WHERE name = ?", [.text(name)])
            if case .int(let c)? = n.first?.first { return Int(c) }
            return 0
        }
    }

    /// Chuyển host vào thư mục (`nil`/rỗng = Chưa phân loại). Thư mục dùng cách viết sẵn có nếu trùng tên.
    public func moveHosts(ids: [UUID], toFolder rawName: String?) throws {
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try db.transaction {
            var target = ""
            if !trimmed.isEmpty {
                let name = try HostFolders.normalize(trimmed)
                target = try matchingFolder(name, excluding: nil) ?? name
            }
            for id in ids {
                guard let stored = try self.host(id: id) else {
                    throw HostRepositoryError.notFound(id)
                }
                try keepFolder(stored.project, ifLeftBy: target)
                try db.execute(
                    "UPDATE hosts SET project = ?, updated_at = ? WHERE id = ?",
                    [.text(target), .real(now().timeIntervalSince1970), .text(id.uuidString)])
            }
        }
    }

    /// Host rời thư mục cũ thì thư mục đó vẫn được giữ lại (kể cả khi thành rỗng).
    func keepFolder(_ old: String, ifLeftBy new: String) throws {
        guard !old.isEmpty, old != new else { return }
        try db.execute("INSERT OR IGNORE INTO host_folders(name) VALUES (?)", [.text(old)])
    }

    /// Thư mục đã có trùng `name` (không phân biệt hoa thường/dấu), bỏ qua đúng tên `excluding`.
    func matchingFolder(_ name: String, excluding: String?) throws -> String? {
        try folders().first { $0 != excluding && HostFolders.sameFolder($0, name) }
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
        try db.transaction {
            try host.validate(credentialSet: try credentialSet(for: host))
            if try fetchExists(host.id) { throw HostRepositoryError.duplicateID(host.id) }
            try checkJump(host)
            try write(host, insert: true)
        }
    }

    /// `updatedAt` luôn do repository đặt; `createdAt` giữ giá trị đã lưu.
    @discardableResult
    public func update(_ host: HostProfile) throws -> HostProfile {
        return try db.transaction {
            try host.validate(credentialSet: try credentialSet(for: host))
            guard let stored = try self.host(id: host.id) else {
                throw HostRepositoryError.notFound(host.id)
            }
            try checkJump(host)
            try keepFolder(stored.project, ifLeftBy: host.project)
            var saved = host
            saved.createdAt = stored.createdAt
            // Hold chỉ bỏ bằng `confirmAutofillHold` (ADR-026): sửa tay qua form/bản cũ không được xoá hold.
            saved.autofillHold = stored.autofillHold
            saved.autofillHoldReason = stored.autofillHoldReason
            // Liên kết nguồn chỉ đổi qua đồng bộ / "Tách khỏi nguồn" (ADR-026), không qua form.
            saved.sourceID = stored.sourceID
            saved.externalID = stored.externalID
            saved.sourceMissing = stored.sourceMissing
            saved.updatedAt = now()
            try write(saved, insert: false)
            return saved
        }
    }

    /// Ghi kết quả nhập (ADR-020) trong MỘT transaction: thư mục, máy (bastion trước), port forward.
    /// Bất kỳ lỗi nào → không ghi gì. Không bao giờ ghi `credentialReference`/lần mở cuối từ file.
    public func applyImport(_ plan: HostExchange.Plan) throws {
        try db.transaction {
            for name in plan.foldersToCreate {
                let n = try HostFolders.normalize(name)
                if try matchingFolder(n, excluding: nil) == nil {
                    try db.execute("INSERT INTO host_folders(name) VALUES (?)", [.text(n)])
                }
            }
            let stamp = now()
            for host in plan.hosts {
                var h = host
                h.credentialReference = nil
                h.lastLaunchRequestedAt = nil
                h.createdAt = stamp
                h.updatedAt = stamp
                h.autofillHold = false
                h.autofillHoldReason = nil
                h.credentialSetID = nil
                // Gán bộ đăng nhập từ file (ADR-030): tạo bộ rỗng nếu chưa có, gán và HOLD tự điền
                // tới khi người dùng xác nhận (chống chuyển password sang máy lạ qua file).
                if let name = plan.setAssignments[host.id],
                    let set = try credentialSet(named: name, createIfMissing: true)
                {
                    h.credentialSetID = set.id
                    h.autofillHold = true
                    h.autofillHoldReason = "Bộ đăng nhập \(set.name) được gán từ file"
                }
                // Bộ mới tạo còn rỗng: máy `.keyFile` lấy key từ bộ vẫn nhập được (key đặt cho bộ sau).
                var validationSet = try credentialSet(for: h)
                if h.authMethod == .keyFile, validationSet != nil, (h.identityFile ?? "").isEmpty,
                    (validationSet?.identityFile ?? "").isEmpty
                {
                    validationSet?.identityFile = "/placeholder"
                }
                try h.validate(credentialSet: validationSet)
                if try fetchExists(h.id) { throw HostRepositoryError.duplicateID(h.id) }
                try checkJump(h)
                try write(h, insert: true)
            }
            for forward in plan.forwards {
                var f = try forward.validated()
                f.createdAt = stamp
                try PortForwardRepository.checkHost(db, f.hostID)
                try PortForwardRepository.checkPortFree(db, f.localPort, excluding: nil)
                try PortForwardRepository.insertRow(db, f)
            }
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
    /// `defaultIdentityAgent`: mặc định trong Cài đặt (ADR-024); rỗng/nil = không ghi directive.
    /// User/IdentityFile/IdentityAgent lấy từ `CredentialResolution` (host > bộ đăng nhập > Cài đặt, ADR-030).
    public func sshSpecs(defaultIdentityAgent: String? = nil) throws -> [SSHHostSpec] {
        let hosts = try all()
        let byID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        let sets = Dictionary(uniqueKeysWithValues: try credentialSets().map { ($0.id, $0) })
        return hosts.filter { $0.kind == .ssh && $0.connectionMode == .managed }.map { h in
            var jump: String?
            if let jid = h.jumpHostID, let bastion = byID[jid] { jump = bastion.sshAlias }
            let resolved = CredentialResolution.resolve(
                host: h, set: h.credentialSetID.flatMap { sets[$0] },
                settingsDefaultAgent: defaultIdentityAgent)
            return SSHHostSpec(
                alias: HostProfile.managedAlias(for: h.id), hostName: h.hostName, port: h.port,
                user: resolved.user, identityFile: resolved.identityFile, jumpAlias: jump,
                identityAgent: resolved.identityAgent)
        }
    }

    /// Alias để chạy `ssh -F <config app> <alias>`.
    public nonisolated func sshAlias(for host: HostProfile) -> String? { host.sshAlias }

    // MARK: - Nội bộ

    func fetchExists(_ id: UUID) throws -> Bool {
        !(try db.query("SELECT 1 FROM hosts WHERE id = ?", [.text(id.uuidString)])).isEmpty
    }

    /// Jump host phải tồn tại và chuỗi bastion không quay lại chính host.
    func checkJump(_ host: HostProfile) throws {
        guard var current = host.jumpHostID else { return }
        var path = [host.id]
        while true {
            if let idx = path.firstIndex(of: current) {
                throw HostRepositoryError.jumpCycle(Array(path[idx...]) + [current])
            }
            guard let next = try self.host(id: current), next.kind == .ssh else {
                throw HostRepositoryError.jumpHostNotFound(current)
            }
            path.append(current)
            guard let n = next.jumpHostID else { return }
            current = n
        }
    }

    func write(_ h: HostProfile, insert: Bool) throws {
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
            .text(h.kind.rawValue), .text(h.rdpUsername), opt(h.rdpDomain), opt(h.rdpGateway),
            .text(h.rdpScreenMode.rawValue), .int(h.rdpMultiMonitor ? 1 : 0),
            .int(h.rdpRedirectClipboard ? 1 : 0), .int(h.rdpAdminSession ? 1 : 0),
            opt(h.identityAgent), opt(h.credentialSetID?.uuidString), .int(h.autofillHold ? 1 : 0),
            opt(h.autofillHoldReason), opt(h.sourceID?.uuidString), opt(h.externalID),
            .int(h.sourceMissing ? 1 : 0),
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
        guard row.count == 38, let id = UUID(uuidString: try text(0)),
            let env = HostEnvironment(rawValue: try text(3)),
            let mode = HostConnectionMode(rawValue: try text(7)),
            let auth = HostAuthMethod(rawValue: try text(11)),
            let kind = HostKind(rawValue: try text(23)),
            let screen = RDPScreenMode(rawValue: try text(27))
        else { throw bad("giá trị") }
        let tags = try? JSONDecoder().decode([String].self, from: Data(try text(4).utf8))
        let marks = try? JSONDecoder().decode(
            [RemoteBookmark].self, from: Data(try text(17).utf8))
        guard let tags, let marks else { throw bad("JSON") }
        var launch: Date?
        if case .null = row[22] {} else { launch = try date(22) }
        return HostProfile(
            id: id, displayName: try text(1), project: try text(2), environment: env, tags: tags,
            notes: try text(5), isFavorite: try int(6) != 0, connectionMode: mode, kind: kind,
            rdpUsername: try text(24), rdpDomain: optText(25), rdpGateway: optText(26),
            rdpScreenMode: screen, rdpMultiMonitor: try int(28) != 0,
            rdpRedirectClipboard: try int(29) != 0, rdpAdminSession: try int(30) != 0,
            hostName: try text(8), port: Int(try int(9)), user: try text(10), authMethod: auth,
            identityFile: optText(12), identityAgent: optText(31),
            jumpHostID: optText(13).flatMap(UUID.init(uuidString:)),
            sshConfigPath: optText(14), sshConfigAlias: optText(15),
            credentialReference: optText(16), credentialSetID: optText(32).flatMap(UUID.init(uuidString:)),
            autofillHold: try int(33) != 0, autofillHoldReason: optText(34),
            sourceID: optText(35).flatMap(UUID.init(uuidString:)), externalID: optText(36),
            sourceMissing: try int(37) != 0, remoteBookmarks: marks,
            defaultLocalDirectory: try text(18), defaultRemoteDirectory: try text(19),
            createdAt: try date(20), updatedAt: try date(21), lastLaunchRequestedAt: launch)
    }
}
