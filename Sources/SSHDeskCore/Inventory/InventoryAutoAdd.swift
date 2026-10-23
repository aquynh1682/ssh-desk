import Foundation

// ADR-026b: tự áp dụng khi nguồn chỉ có máy mới + Hoàn tác.

extension InventorySource {
    /// Khoá trong `config_json`. Thiếu khoá = bật (mặc định).
    static let autoAddKey = "autoAddNew"

    /// Nguồn có được tự thêm máy mới khi file đổi không (mặc định bật khi thiếu khoá hoặc config hỏng).
    public var autoAddNew: Bool {
        guard let data = configJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let flag = obj[Self.autoAddKey] as? Bool
        else { return true }
        return flag
    }

    /// `configJSON` mới với cờ tự thêm; giữ nguyên mọi khoá khác (vd. ghép cột).
    public static func configJSON(_ json: String, settingAutoAddNew value: Bool) -> String {
        var obj: [String: Any] = [:]
        if let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            obj = parsed
        }
        obj[autoAddKey] = value
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    /// Cờ tự thêm đã ghi tường minh trong `json` (nil = chưa ghi).
    static func explicitAutoAdd(in json: String) -> Bool? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[autoAddKey] as? Bool
    }
}

extension InventorySync {
    /// Kế hoạch **chỉ có thêm mới** và đủ sạch để tự áp dụng không cần người xem (ADR-026b).
    /// Đúng khi: có nguồn, có ít nhất một máy mới, và KHÔNG có bất kỳ điều nào sau (nghi ngờ thì chặn):
    /// - cập nhật máy đã có (`updates`), kể cả "có lại trong nguồn";
    /// - máy "không còn trong nguồn" (`missing`);
    /// - mọi `issues` (lỗi dòng, và cả cảnh báo dòng: jump host không thấy/trùng tên/vòng/là Windows/trỏ chính nó,
    ///   trùng tên host ngoài nguồn, cột bí mật bị bỏ...);
    /// - mọi `warnings` chung (cột mật khẩu bị bỏ qua, biến mật khẩu Ansible, nguồn rỗng, thiếu ansible_user...);
    /// - bộ đăng nhập chưa tồn tại phải tạo mới (`setsToCreate`).
    public static func isAdditionsOnly(_ plan: InventorySyncPlan) -> Bool {
        plan.source != nil && !plan.additions.isEmpty && plan.updates.isEmpty && plan.missing.isEmpty
            && plan.issues.isEmpty && plan.warnings.isEmpty && plan.setsToCreate.isEmpty
    }
}

/// Ghi nhận lần tự thêm gần nhất (chỉ trong phiên chạy app) để Hoàn tác. Không chứa secret.
public struct InventoryAutoAddRecord: Sendable, Equatable {
    public var sourceID: UUID
    public var sourceName: String
    public var hostIDs: [UUID]
    /// `updatedAt` của các host lúc thêm; khác đi = host đã bị sửa.
    public var stamp: Date

    public init(plan: InventorySyncPlan) {
        sourceID = plan.source?.id ?? UUID()
        sourceName = plan.source?.name ?? ""
        hostIDs = plan.additions.map(\.id)
        stamp = plan.syncedAt
    }
}

public struct InventoryUndoOutcome: Sendable, Equatable {
    public var removed: [UUID] = []
    /// Giữ vì đã bị sửa / có mật khẩu riêng / có port forward / là jump host của host khác / đã tách nguồn.
    public var kept: [UUID] = []
    /// Đã bị xoá từ trước (không phải do Hoàn tác).
    public var alreadyGone = 0
}

extension HostRepository {
    /// Bật/tắt "Tự thêm máy mới" của nguồn (chỉ đổi cờ trong config_json).
    public func setInventoryAutoAdd(sourceID: UUID, enabled: Bool) throws {
        try db.transaction {
            guard var s = try inventorySource(id: sourceID) else { throw InventoryError.sourceNotFound(sourceID) }
            s.configJSON = InventorySource.configJSON(s.configJSON, settingAutoAddNew: enabled)
            try Self.writeSource(db, s, insert: false)
        }
    }

    /// Hoàn tác lần tự thêm trong MỘT transaction: xoá các host vừa thêm chỉ khi còn nguyên (updatedAt không đổi,
    /// vẫn thuộc nguồn, không mật khẩu riêng, không port forward, không là jump host của host nằm ngoài tập xoá),
    /// rồi tắt "Tự thêm máy mới" của nguồn (nếu nguồn còn).
    public func undoAutoAdd(_ record: InventoryAutoAddRecord) throws -> InventoryUndoOutcome {
        try db.transaction {
            var outcome = InventoryUndoOutcome()
            var candidates: [UUID: HostProfile] = [:]
            for id in record.hostIDs {
                guard let h = try host(id: id) else {
                    outcome.alreadyGone += 1
                    continue
                }
                let untouched = abs(h.updatedAt.timeIntervalSince(record.stamp)) < 0.001
                let own = h.sourceID == record.sourceID && untouched && !h.hasOwnPassword
                let forwards = try db.query(
                    "SELECT COUNT(*) FROM port_forwards WHERE host_id = ?", [.text(id.uuidString)])
                var hasForward = true
                if case .int(let n)? = forwards.first?.first { hasForward = n > 0 }
                if own && !hasForward { candidates[id] = h } else { outcome.kept.append(id) }
            }
            // Host ngoài tập xoá đang dùng làm jump -> giữ; lặp tới khi ổn định (giữ một host có thể kéo theo host khác).
            let all = try self.all()
            var changed = true
            while changed {
                changed = false
                for other in all {
                    guard let j = other.jumpHostID, candidates[j] != nil, candidates[other.id] == nil else { continue }
                    candidates[j] = nil
                    outcome.kept.append(j)
                    changed = true
                }
            }
            // Xoá máy dùng jump trước, bastion sau (khoá ngoại jump_host_id).
            var remaining = Set(candidates.keys)
            while !remaining.isEmpty {
                let usedByRemaining = Set(remaining.compactMap { candidates[$0]?.jumpHostID })
                let leaves = remaining.filter { !usedByRemaining.contains($0) }
                if leaves.isEmpty { throw InventoryError.jumpCycle("") }
                for id in record.hostIDs where leaves.contains(id) {
                    try db.execute("DELETE FROM hosts WHERE id = ?", [.text(id.uuidString)])
                    outcome.removed.append(id)
                }
                remaining.subtract(leaves)
            }
            if var s = try inventorySource(id: record.sourceID) {
                s.configJSON = InventorySource.configJSON(s.configJSON, settingAutoAddNew: false)
                try Self.writeSource(db, s, insert: false)
            }
            return outcome
        }
    }
}
