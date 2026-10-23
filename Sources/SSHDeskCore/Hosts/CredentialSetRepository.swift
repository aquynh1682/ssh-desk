import Foundation

/// Bộ đăng nhập + hold tự điền trong cùng actor với host để mọi thay đổi liên quan là một transaction (ADR-030).
extension HostRepository {
    static let setColumns =
        "id, name, user, identity_file, identity_agent, note, created_at, updated_at"

    // MARK: - Đọc

    public func credentialSets() throws -> [CredentialSet] {
        try db.query("SELECT \(Self.setColumns) FROM credential_sets ORDER BY name COLLATE NOCASE, id")
            .map(Self.decodeSet)
    }

    public func credentialSet(id: UUID) throws -> CredentialSet? {
        try db.query(
            "SELECT \(Self.setColumns) FROM credential_sets WHERE id = ?", [.text(id.uuidString)]
        ).first.map(Self.decodeSet)
    }

    /// Bộ của host (nil nếu host không dùng bộ). Host trỏ tới bộ không tồn tại → `notFound`.
    func credentialSet(for host: HostProfile) throws -> CredentialSet? {
        guard let id = host.credentialSetID else { return nil }
        guard let set = try credentialSet(id: id) else { throw CredentialSetError.notFound(id) }
        return set
    }

    /// Số host đang dùng mỗi bộ.
    public func credentialSetUsage() throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        let rows = try db.query(
            "SELECT credential_set_id, COUNT(*) FROM hosts WHERE credential_set_id IS NOT NULL GROUP BY credential_set_id"
        )
        for row in rows {
            if case .text(let s) = row[0], let id = UUID(uuidString: s), case .int(let n) = row[1] {
                result[id] = Int(n)
            }
        }
        return result
    }

    public func hosts(usingCredentialSet id: UUID) throws -> [HostProfile] {
        try all().filter { $0.credentialSetID == id }
    }

    /// Thông tin đăng nhập hiệu lực của host (đọc lại host từ DB để lấy bộ/hold mới nhất; host chưa lưu → dùng bản truyền vào).
    public func resolvedCredentials(for host: HostProfile, settingsDefaultAgent: String? = nil) throws
        -> ResolvedCredentials
    {
        let current = try self.host(id: host.id) ?? host
        let set = try current.credentialSetID.flatMap { try credentialSet(id: $0) }
        return CredentialResolution.resolve(
            host: current, set: set, settingsDefaultAgent: settingsDefaultAgent)
    }

    // MARK: - Ghi

    @discardableResult
    public func createCredentialSet(_ set: CredentialSet) throws -> CredentialSet {
        var set = try set.validated()
        return try db.transaction {
            try checkSetName(set.name, excluding: nil)
            let stamp = now()
            set.createdAt = stamp
            set.updatedAt = stamp
            try db.execute(
                "INSERT INTO credential_sets(\(Self.setColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                Self.setValues(set, forUpdate: false))
            return set
        }
    }

    /// Đổi tên/user/key/agent/ghi chú. `createdAt` giữ nguyên. Không đụng Keychain.
    @discardableResult
    public func updateCredentialSet(_ set: CredentialSet) throws -> CredentialSet {
        var set = try set.validated()
        return try db.transaction {
            guard let stored = try credentialSet(id: set.id) else {
                throw CredentialSetError.notFound(set.id)
            }
            try checkSetName(set.name, excluding: set.id)
            set.createdAt = stored.createdAt
            set.updatedAt = now()
            try db.execute(
                "UPDATE credential_sets SET name = ?, user = ?, identity_file = ?, identity_agent = ?, note = ?, updated_at = ? WHERE id = ?",
                Self.setValues(set, forUpdate: true) + [.text(set.id.uuidString)])
            return set
        }
    }

    /// Xoá bộ: gỡ khỏi mọi host trong CÙNG transaction (không xoá host). Trả id các host bị ảnh hưởng.
    /// Việc xoá item Keychain do service gọi (DB không biết Keychain).
    @discardableResult
    public func deleteCredentialSet(id: UUID) throws -> [UUID] {
        try db.transaction {
            guard try credentialSet(id: id) != nil else { throw CredentialSetError.notFound(id) }
            let affected = try db.query(
                "SELECT id FROM hosts WHERE credential_set_id = ?", [.text(id.uuidString)]
            ).compactMap { row -> UUID? in
                if case .text(let s) = row[0] { return UUID(uuidString: s) } else { return nil }
            }
            try db.execute(
                "UPDATE hosts SET credential_set_id = NULL, updated_at = ? WHERE credential_set_id = ?",
                [.real(now().timeIntervalSince1970), .text(id.uuidString)])
            try db.execute("DELETE FROM credential_sets WHERE id = ?", [.text(id.uuidString)])
            return affected
        }
    }

    /// Gán (hoặc gỡ, `setID == nil`) bộ cho nhiều host trong một transaction. Gán bằng tay trong app → không hold.
    /// `hold != nil` (gán đến từ nhập/đồng bộ file): đặt `autofill_hold` với lý do đó.
    /// Chỉ nhận host SSH managed hoặc Windows (host imported dùng nguyên cấu hình của người dùng → bỏ qua).
    /// Trả số host đã đổi.
    @discardableResult
    public func assignCredentialSet(setID: UUID?, to hostIDs: [UUID], hold holdReason: String? = nil) throws
        -> Int
    {
        try db.transaction {
            if let setID, try credentialSet(id: setID) == nil { throw CredentialSetError.notFound(setID) }
            var changed = 0
            for id in hostIDs {
                guard let h = try self.host(id: id) else { throw HostRepositoryError.notFound(id) }
                guard h.kind == .windowsRDP || h.connectionMode == .managed else { continue }
                var u = h
                u.credentialSetID = setID
                if setID != nil, let holdReason {
                    u.autofillHold = true
                    u.autofillHoldReason = holdReason
                }
                if u.credentialSetID != h.credentialSetID || u.autofillHold != h.autofillHold
                    || u.autofillHoldReason != h.autofillHoldReason
                {
                    // Gán bộ: kiểm lại host với bộ mới (vd `.keyFile` cần key hiệu lực). Gỡ bộ thì không chặn.
                    if setID != nil { try u.validate(credentialSet: try credentialSet(for: u)) }
                    try db.execute(
                        "UPDATE hosts SET credential_set_id = ?, autofill_hold = ?, autofill_hold_reason = ?, updated_at = ? WHERE id = ?",
                        [
                            setID.map { .text($0.uuidString) } ?? .null, .int(u.autofillHold ? 1 : 0),
                            u.autofillHoldReason.map { .text($0) } ?? .null,
                            .real(now().timeIntervalSince1970), .text(id.uuidString),
                        ])
                    changed += 1
                }
            }
            return changed
        }
    }

    // MARK: - Hold tự điền (ADR-026)

    /// Đặt hold cho host (đồng bộ nguồn đổi địa chỉ, gán bộ từ file...). Lý do không chứa secret.
    public func setAutofillHold(ids: [UUID], reason: String) throws {
        try db.transaction {
            for id in ids {
                guard try fetchHostExists(id) else { throw HostRepositoryError.notFound(id) }
                try db.execute(
                    "UPDATE hosts SET autofill_hold = 1, autofill_hold_reason = ?, updated_at = ? WHERE id = ?",
                    [.text(reason), .real(now().timeIntervalSince1970), .text(id.uuidString)])
            }
        }
    }

    /// Người dùng xác nhận → bỏ hold.
    public func confirmAutofillHold(id: UUID) throws {
        try db.transaction {
            guard try fetchHostExists(id) else { throw HostRepositoryError.notFound(id) }
            try db.execute(
                "UPDATE hosts SET autofill_hold = 0, autofill_hold_reason = NULL, updated_at = ? WHERE id = ?",
                [.real(now().timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    // MARK: - Nội bộ

    private func fetchHostExists(_ id: UUID) throws -> Bool {
        !(try db.query("SELECT 1 FROM hosts WHERE id = ?", [.text(id.uuidString)])).isEmpty
    }

    /// Tên duy nhất không phân biệt hoa thường/dấu (DB chỉ NOCASE ASCII nên kiểm thêm ở đây).
    func checkSetName(_ name: String, excluding: UUID?) throws {
        for other in try credentialSets() where other.id != excluding {
            if CredentialSet.sameName(other.name, name) { throw CredentialSetError.duplicateName(other.name) }
        }
    }

    /// Tạo bộ rỗng theo tên nếu chưa có (nhập file, ADR-030). Trả bộ đã có hoặc mới tạo.
    func credentialSet(named rawName: String, createIfMissing: Bool) throws -> CredentialSet? {
        let name = try CredentialSet.normalizedName(rawName)
        if let existing = try credentialSets().first(where: { CredentialSet.sameName($0.name, name) }) {
            return existing
        }
        guard createIfMissing else { return nil }
        let stamp = now()
        let set = CredentialSet(name: name, createdAt: stamp, updatedAt: stamp)
        try db.execute(
            "INSERT INTO credential_sets(\(Self.setColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            Self.setValues(set, forUpdate: false))
        return set
    }

    private static func setValues(_ set: CredentialSet, forUpdate: Bool) -> [SQLValue] {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        let tail: [SQLValue] =
            forUpdate
            ? [.text(set.note), .real(set.updatedAt.timeIntervalSince1970)]
            : [
                .text(set.note), .real(set.createdAt.timeIntervalSince1970),
                .real(set.updatedAt.timeIntervalSince1970),
            ]
        let head: [SQLValue] = [opt(set.user), opt(set.identityFile), opt(set.identityAgent)]
        return (forUpdate ? [.text(set.name)] : [.text(set.id.uuidString), .text(set.name)]) + head + tail
    }

    private static func decodeSet(_ row: [SQLValue]) throws -> CredentialSet {
        func bad() -> DatabaseError { .corrupt("hàng credential_sets không hợp lệ") }
        func optText(_ i: Int) -> String? {
            if case .text(let s) = row[i] { return s } else { return nil }
        }
        func date(_ i: Int) throws -> Date {
            switch row[i] {
            case .real(let v): return Date(timeIntervalSince1970: v)
            case .int(let v): return Date(timeIntervalSince1970: Double(v))
            default: throw bad()
            }
        }
        guard row.count == 8, let idText = optText(0), let id = UUID(uuidString: idText),
            let name = optText(1), let note = optText(5)
        else { throw bad() }
        return CredentialSet(
            id: id, name: name, user: optText(2), identityFile: optText(3), identityAgent: optText(4),
            note: note, createdAt: try date(6), updatedAt: try date(7))
    }
}
