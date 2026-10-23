import Foundation

/// Nguồn máy chủ + áp dụng kế hoạch đồng bộ trong cùng actor với host để mọi thay đổi là một transaction (ADR-026).
extension HostRepository {
    static let sourceColumns =
        "id, name, kind, path, folder, default_environment, config_json, last_synced_at, last_fingerprint"

    // MARK: - Đọc

    public func inventorySources() throws -> [InventorySource] {
        try db.query("SELECT \(Self.sourceColumns) FROM inventory_sources ORDER BY name COLLATE NOCASE, id")
            .map(Self.decodeSource)
    }

    public func inventorySource(id: UUID) throws -> InventorySource? {
        try db.query(
            "SELECT \(Self.sourceColumns) FROM inventory_sources WHERE id = ?", [.text(id.uuidString)]
        ).first.map(Self.decodeSource)
    }

    /// Số host của mỗi nguồn / số host đang "không còn trong nguồn".
    public func inventorySourceUsage() throws -> [UUID: (hosts: Int, missing: Int)] {
        var result: [UUID: (Int, Int)] = [:]
        let rows = try db.query(
            "SELECT source_id, COUNT(*), SUM(source_missing) FROM hosts WHERE source_id IS NOT NULL GROUP BY source_id")
        for row in rows {
            if case .text(let s) = row[0], let id = UUID(uuidString: s), case .int(let n) = row[1] {
                var m = 0
                if case .int(let v) = row[2] { m = Int(v) }
                result[id] = (Int(n), m)
            }
        }
        return result
    }

    // MARK: - Ghi nguồn

    /// Đổi tên/đường dẫn/ghép cột... của nguồn đã có (không đụng host).
    public func updateInventorySource(_ source: InventorySource) throws {
        let source = try Self.validatedSource(source)
        try db.transaction {
            guard try inventorySource(id: source.id) != nil else { throw InventoryError.sourceNotFound(source.id) }
            try Self.writeSource(db, source, insert: false)
        }
    }

    /// Xoá nguồn: gỡ `source_id`/`external_id`/`source_missing` khỏi host (KHÔNG xoá host) rồi xoá nguồn.
    /// Trả số host đã gỡ.
    @discardableResult
    public func deleteInventorySource(id: UUID) throws -> Int {
        try db.transaction {
            guard try inventorySource(id: id) != nil else { throw InventoryError.sourceNotFound(id) }
            let n = try db.query("SELECT COUNT(*) FROM hosts WHERE source_id = ?", [.text(id.uuidString)])
            try db.execute(
                "UPDATE hosts SET source_id = NULL, external_id = NULL, source_missing = 0, updated_at = ? WHERE source_id = ?",
                [.real(now().timeIntervalSince1970), .text(id.uuidString)])
            try db.execute("DELETE FROM inventory_sources WHERE id = ?", [.text(id.uuidString)])
            if case .int(let c)? = n.first?.first { return Int(c) }
            return 0
        }
    }

    /// "Tách khỏi nguồn": host thành máy tạo tay, giữ nguyên mọi giá trị.
    public func detachFromSource(hostID: UUID) throws {
        try db.transaction {
            guard try self.host(id: hostID) != nil else { throw HostRepositoryError.notFound(hostID) }
            try db.execute(
                "UPDATE hosts SET source_id = NULL, external_id = NULL, source_missing = 0, updated_at = ? WHERE id = ?",
                [.real(now().timeIntervalSince1970), .text(hostID.uuidString)])
        }
    }

    // MARK: - Áp dụng đồng bộ

    /// Áp dụng kế hoạch trong MỘT transaction: lưu/cập nhật nguồn, thêm host (jump trước), đổi trường do nguồn quản lý,
    /// đặt `autofill_hold`, đánh `source_missing` (không xoá host). Bất kỳ lỗi nào -> không ghi gì.
    /// Chỉ ghi trường do nguồn quản lý: ghi chú (khi không ghép), yêu thích, forward, mật khẩu riêng,
    /// auth, IdentityFile, IdentityAgent, bookmark của host đã có luôn giữ nguyên.
    public func applyInventory(_ plan: InventorySyncPlan) throws {
        try db.transaction {
            let stamp = plan.syncedAt
            if var source = plan.source {
                source = try Self.validatedSource(source)
                source.lastSyncedAt = stamp
                source.lastFingerprint = plan.fingerprint ?? source.lastFingerprint
                let exists = try inventorySource(id: source.id) != nil
                try Self.writeSource(db, source, insert: !exists)
            }
            for name in plan.setsToCreate { _ = try credentialSet(named: name, createIfMissing: true) }

            // Thêm: jump host đã có/đã thêm trước.
            var pending = plan.additions
            var guardCount = pending.count + 1
            while !pending.isEmpty, guardCount > 0 {
                guardCount -= 1
                var next: [InventorySyncPlan.Addition] = []
                for add in pending {
                    if let j = add.jumpHostID, !(try fetchExists(j)) {
                        next.append(add)
                        continue
                    }
                    try insertAddition(add, stamp: stamp)
                }
                if next.count == pending.count { throw InventoryError.jumpCycle(next[0].host.displayName) }
                pending = next
            }

            for update in plan.updates { try applyUpdate(update, stamp: stamp) }

            for m in plan.missing {
                guard try fetchExists(m.hostID) else { continue }
                try db.execute(
                    "UPDATE hosts SET source_missing = 1, updated_at = ? WHERE id = ?",
                    [.real(stamp.timeIntervalSince1970), .text(m.hostID.uuidString)])
            }
        }
    }

    private func insertAddition(_ add: InventorySyncPlan.Addition, stamp: Date) throws {
        var h = add.host
        h.createdAt = stamp
        h.updatedAt = stamp
        h.credentialSetID = nil
        h.sourceMissing = false
        h.autofillHold = false
        h.autofillHoldReason = nil
        if !h.project.isEmpty {
            let name = try Self.normalizeFolder(h.project)
            h.project = try matchingFolder(name, excluding: nil) ?? name
        }
        if let name = add.credentialSetName, let set = try credentialSet(named: name, createIfMissing: true) {
            // Gán bộ đăng nhập từ nguồn -> hold tới khi người dùng xác nhận (chống chuyển password sang máy lạ).
            h.credentialSetID = set.id
            h.autofillHold = true
            h.autofillHoldReason = "Bộ đăng nhập \(set.name) được gán từ nguồn"
        }
        try h.validate(credentialSet: try credentialSet(for: h))
        if try fetchExists(h.id) { throw HostRepositoryError.duplicateID(h.id) }
        try checkJump(h)
        try write(h, insert: true)
    }

    private func applyUpdate(_ u: InventorySyncPlan.Update, stamp: Date) throws {
        guard let stored = try self.host(id: u.hostID) else { throw InventoryError.staleHost(u.hostID) }
        var h = stored
        let p = u.patch
        if let v = p.displayName { h.displayName = v }
        if let v = p.hostName { h.hostName = v }
        if let v = p.port { h.port = v }
        if let v = p.user {
            if h.kind == .windowsRDP { h.rdpUsername = v } else { h.user = v }
        }
        if let v = p.environment { h.environment = v }
        if let v = p.folder {
            let name = try Self.normalizeFolder(v)
            h.project = try matchingFolder(name, excluding: nil) ?? name
        }
        if p.setsJump { h.jumpHostID = p.jumpHostID }
        if let name = p.credentialSetName, let set = try credentialSet(named: name, createIfMissing: true) {
            h.credentialSetID = set.id
        }
        if let v = p.notes { h.notes = v }
        if let v = p.tags { h.tags = v }
        if u.restored { h.sourceMissing = false }
        if let reason = u.holdReason {
            h.autofillHold = true
            if let old = stored.autofillHoldReason, stored.autofillHold, !old.isEmpty, !old.contains(reason) {
                h.autofillHoldReason = String((old + ". " + reason).suffix(InventorySync.maxHoldReasonLength))
            } else {
                h.autofillHoldReason = reason
            }
        }
        h.updatedAt = stamp
        try h.validate(credentialSet: try credentialSet(for: h))
        try checkJump(h)
        try keepFolder(stored.project, ifLeftBy: h.project)
        try write(h, insert: false)
    }

    // MARK: - Nội bộ

    private static func normalizeFolder(_ raw: String) throws -> String {
        do { return try HostFolders.normalize(raw) } catch { throw InventoryError.invalidFolder(raw) }
    }

    static func validatedSource(_ source: InventorySource) throws -> InventorySource {
        var s = source
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.name.isEmpty, s.name.count <= 100, !InventoryValidator.hasControl(s.name) else {
            throw InventoryError.invalidName
        }
        guard !s.path.isEmpty, !s.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw InventoryError.invalidName
        }
        s.folder = s.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.folder.isEmpty { s.folder = try normalizeFolder(s.folder) }
        return s
    }

    static func writeSource(_ db: Database, _ s: InventorySource, insert: Bool) throws {
        let values: [SQLValue] = [
            .text(s.name), .text(s.kind.rawValue), .text(s.path), .text(s.folder),
            s.defaultEnvironment.map { .text($0.rawValue) } ?? .null, .text(s.configJSON),
            s.lastSyncedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            s.lastFingerprint.map { .text($0) } ?? .null,
        ]
        if insert {
            try db.execute(
                "INSERT INTO inventory_sources(\(sourceColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(s.id.uuidString)] + values)
        } else {
            try db.execute(
                "UPDATE inventory_sources SET name = ?, kind = ?, path = ?, folder = ?, default_environment = ?, config_json = ?, last_synced_at = ?, last_fingerprint = ? WHERE id = ?",
                values + [.text(s.id.uuidString)])
        }
    }

    private static func decodeSource(_ row: [SQLValue]) throws -> InventorySource {
        func bad() -> DatabaseError { .corrupt("hàng inventory_sources không hợp lệ") }
        func text(_ i: Int) -> String? { if case .text(let s) = row[i] { return s } else { return nil } }
        guard row.count == 9, let idText = text(0), let id = UUID(uuidString: idText), let name = text(1),
            let kindText = text(2), let kind = InventorySourceKind(rawValue: kindText), let path = text(3),
            let folder = text(4), let config = text(6)
        else { throw bad() }
        var synced: Date?
        switch row[7] {
        case .real(let v): synced = Date(timeIntervalSince1970: v)
        case .int(let v): synced = Date(timeIntervalSince1970: Double(v))
        default: break
        }
        return InventorySource(
            id: id, name: name, kind: kind, path: path, folder: folder,
            defaultEnvironment: text(5).flatMap(HostEnvironment.init(rawValue:)), configJSON: config,
            lastSyncedAt: synced, lastFingerprint: text(8))
    }
}
