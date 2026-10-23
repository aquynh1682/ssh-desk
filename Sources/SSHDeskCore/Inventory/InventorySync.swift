import Foundation

/// Một thay đổi của một trường: giá trị cũ -> mới (hiện ở màn xem trước).
public struct InventoryFieldChange: Sendable, Equatable {
    public var label: String
    public var old: String
    public var new: String

    public var text: String { "\(label): \(old) → \(new)" }
}

/// Kế hoạch đồng bộ một chiều (ADR-026). Thuần: không chạm DB/Keychain/file.
public struct InventorySyncPlan: Sendable, Equatable {
    /// Giá trị mới sẽ ghi vào host đã có (chỉ trường do nguồn quản lý).
    public struct Patch: Sendable, Equatable {
        public var displayName: String?
        public var hostName: String?
        public var port: Int?
        /// SSH: `user`; Windows: `rdpUsername`.
        public var user: String?
        public var environment: HostEnvironment?
        public var folder: String?
        public var setsJump = false
        public var jumpHostID: UUID?
        public var credentialSetName: String?
        public var notes: String?
        /// Toàn bộ tag mới của host (tag cũ + tag còn thiếu từ nguồn).
        public var tags: [String]?

        public var isEmpty: Bool {
            displayName == nil && hostName == nil && port == nil && user == nil && environment == nil
                && folder == nil && !setsJump && credentialSetName == nil && notes == nil && tags == nil
        }
    }

    public struct Addition: Sendable, Equatable, Identifiable {
        public var id: UUID { host.id }
        public var host: HostProfile
        public var record: InventoryRecord
        public var jumpHostID: UUID?
        /// Tên bộ đăng nhập sẽ gán (kèm hold tự điền).
        public var credentialSetName: String?
    }

    public struct Update: Sendable, Equatable, Identifiable {
        public var id: UUID { hostID }
        public var hostID: UUID
        public var displayName: String
        public var changes: [InventoryFieldChange]
        public var patch: Patch
        /// Có lý do hold -> đặt `autofill_hold` (đổi địa chỉ / gán bộ từ nguồn).
        public var holdReason: String?
        /// Host từng bị đánh "Không còn trong nguồn" nay có lại.
        public var restored: Bool
    }

    public struct Missing: Sendable, Equatable, Identifiable {
        public var id: UUID { hostID }
        public var hostID: UUID
        public var displayName: String
    }

    /// Nguồn sẽ được ghi (tạo mới hoặc cập nhật) cùng transaction. nil = nhập một lần, không lưu nguồn.
    public var source: InventorySource?
    public var additions: [Addition] = []
    public var updates: [Update] = []
    public var missing: [Missing] = []
    public var unchangedCount = 0
    public var issues: [InventoryIssue] = []
    public var warnings: [String] = []
    public var setsToCreate: [String] = []
    /// Số dòng nguồn -> id host sẽ có sau khi áp dụng (để gắn mật khẩu cột bí mật, ADR-031). Không chứa giá trị.
    public var rowHosts: [Int: UUID] = [:]
    public var fingerprint: String?
    public var syncedAt = Date()

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count + warnings.count }
    public var holdCount: Int {
        additions.filter { $0.credentialSetName != nil }.count + updates.filter { $0.holdReason != nil }.count
    }
    public var hasChanges: Bool {
        !additions.isEmpty || !updates.isEmpty || !missing.isEmpty
    }
}

/// Diff thuần giữa bản ghi từ nguồn và host hiện có của nguồn (ADR-026).
public enum InventorySync {
    public static let maxHoldReasonLength = 500

    public static func plan(
        source: InventorySource?,
        records: [InventoryRecord],
        issues: [InventoryIssue] = [],
        warnings: [String] = [],
        failedKeys: Set<String> = [],
        managesJump: Bool = true,
        existingHosts: [HostProfile],
        credentialSets: [CredentialSet],
        fingerprint: String? = nil,
        now: Date = Date(),
        newID: () -> UUID = UUID.init
    ) throws -> InventorySyncPlan {
        guard records.count <= InventoryLimits.maxRecords else {
            throw InventoryError.tooManyRecords(limit: InventoryLimits.maxRecords)
        }
        var plan = InventorySyncPlan()
        plan.source = source
        plan.issues = issues
        plan.warnings = warnings
        plan.fingerprint = fingerprint
        plan.syncedAt = now

        let key = InventoryTableParser.normalizeKey
        let sourceHosts = existingHosts.filter { source != nil && $0.sourceID == source?.id }
        var existingByKey: [String: HostProfile] = [:]
        for h in sourceHosts {
            if let e = h.externalID { existingByKey[key(e)] = h }
        }
        let hostByID = Dictionary(existingHosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let setByID = Dictionary(credentialSets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Gán id cho từng bản ghi (host có sẵn giữ id; host mới id mới).
        var idForRecord: [Int: UUID] = [:]
        var idByKey: [String: UUID] = [:]
        var idByName: [String: UUID] = [:]
        var recordByID: [UUID: InventoryRecord] = [:]
        for (i, r) in records.enumerated() {
            let id = existingByKey[key(r.externalID)]?.id ?? newID()
            idForRecord[i] = id
            idByKey[key(r.externalID)] = id
            idByName[key(r.name)] = id
            recordByID[id] = r
        }

        func displayName(of id: UUID?) -> String {
            guard let id else { return "(không)" }
            return recordByID[id]?.name ?? hostByID[id]?.displayName ?? "(không rõ)"
        }

        // 2. Jump host: trong file trước (khoá rồi tên), sau đó host đã có theo tên chính xác.
        var chain: [UUID: UUID] = [:]  // host -> jump hiện hành (để bắt vòng)
        for h in existingHosts { if let j = h.jumpHostID { chain[h.id] = j } }
        var jumpFor: [UUID: UUID?] = [:]
        for (i, r) in records.enumerated() where r.kind == .ssh {
            let id = idForRecord[i]!
            guard let ref = r.jumpRef, !ref.isEmpty else {
                if managesJump { jumpFor[id] = .some(nil) }
                continue
            }
            func warn(_ m: String) {
                plan.issues.append(InventoryIssue(.warning, row: r.sourceRow, column: InventoryField.jumpHost.title, m))
                if managesJump { jumpFor[id] = .some(nil) }
            }
            var target: UUID?
            if let t = idByKey[key(ref)] ?? idByName[key(ref)] {
                target = t
            } else {
                let matches = existingHosts.filter { $0.displayName == ref && $0.kind == .ssh }
                if matches.count == 1 {
                    target = matches[0].id
                } else if matches.count > 1 {
                    warn("Có \(matches.count) máy tên “\(ref)” — không chọn được jump host, để trống.")
                    continue
                }
            }
            guard let target else {
                warn("Không tìm thấy jump host “\(ref)” — để trống.")
                continue
            }
            if target == id {
                warn("Jump host trỏ chính nó — để trống.")
                continue
            }
            if let t = recordByID[target], t.kind != .ssh {
                warn("Jump host “\(ref)” là máy Windows — để trống.")
                continue
            }
            if let t = hostByID[target], t.kind != .ssh {
                warn("Jump host “\(ref)” là máy Windows — để trống.")
                continue
            }
            // Bắt vòng: đi theo chuỗi jump từ target.
            var cursor: UUID? = target
            var steps = 0
            var cyclic = false
            while let c = cursor, steps < 10_000 {
                if c == id {
                    cyclic = true
                    break
                }
                cursor = chain[c]
                steps += 1
            }
            if cyclic {
                warn("Jump host “\(ref)” tạo thành vòng — để trống.")
                chain[id] = nil
                continue
            }
            chain[id] = target
            jumpFor[id] = .some(target)
        }

        // 3. Thêm / đổi.
        var neededSets: [String] = []
        func setName(of h: HostProfile) -> String? { h.credentialSetID.flatMap { setByID[$0]?.name } }
        func findSet(_ name: String) -> CredentialSet? {
            credentialSets.first { CredentialSet.sameName($0.name, name) }
        }
        func effectiveFolder(_ r: InventoryRecord) -> String? {
            if let f = r.folder, !f.isEmpty { return f }
            if let f = source?.folder, !f.isEmpty { return f }
            return nil
        }
        let outsideNames = Set(
            existingHosts.filter { $0.sourceID == nil || $0.sourceID != source?.id }.map { key($0.displayName) })

        for (i, r) in records.enumerated() {
            let id = idForRecord[i]!
            let jump: UUID?? = r.kind == .ssh ? jumpFor[id] : .some(nil)
            let wantedSet: CredentialSet? = r.credentialSetName.flatMap(findSet)
            if r.sourceRow > 0 { plan.rowHosts[r.sourceRow] = id }
            if let name = r.credentialSetName, wantedSet == nil, r.kind == .ssh || r.kind == .windowsRDP,
                !neededSets.contains(where: { CredentialSet.sameName($0, name) })
            {
                neededSets.append(name)
            }

            guard let host = existingByKey[key(r.externalID)] else {
                var h = InventoryValidator.profile(from: r, folder: effectiveFolder(r) ?? "", id: id, now: now)
                h.environment = r.environment ?? source?.defaultEnvironment ?? .other
                h.sourceID = source?.id
                if let t = r.tags { h.tags = t }
                h.externalID = source == nil ? nil : r.externalID
                if r.kind == .ssh {
                    h.authMethod = r.credentialSetName == nil ? .agent : .interactive
                    h.jumpHostID = jump ?? nil
                }
                if let name = r.credentialSetName {
                    h.autofillHold = true
                    h.autofillHoldReason = "Bộ đăng nhập \(wantedSet?.name ?? name) được gán từ nguồn"
                }
                if outsideNames.contains(key(r.name)) {
                    plan.issues.append(
                        InventoryIssue(
                            .warning, row: r.sourceRow, column: InventoryField.name.title,
                            "Đã có máy cùng tên “\(r.name)” không thuộc nguồn này — vẫn sẽ thêm máy mới."))
                }
                plan.additions.append(
                    InventorySyncPlan.Addition(
                        host: h, record: r, jumpHostID: h.jumpHostID,
                        credentialSetName: r.credentialSetName.map { wantedSet?.name ?? $0 }))
                continue
            }

            if host.kind != r.kind {
                plan.rowHosts[r.sourceRow] = nil
                plan.issues.append(
                    InventoryIssue(
                        .error, row: r.sourceRow, column: InventoryField.kind.title,
                        "Loại máy đổi giữa SSH và Windows — không đồng bộ được. Hãy tách máy “\(host.displayName)” khỏi nguồn."
                    ))
                continue
            }

            var patch = InventorySyncPlan.Patch()
            var changes: [InventoryFieldChange] = []
            var holdParts: [String] = []

            if host.displayName != r.name {
                patch.displayName = r.name
                changes.append(.init(label: "Tên", old: host.displayName, new: r.name))
            }
            if host.hostName != r.hostName {
                patch.hostName = r.hostName
                changes.append(.init(label: "IP/Hostname", old: host.hostName, new: r.hostName))
                holdParts.append("IP/Hostname \(host.hostName) → \(r.hostName)")
            }
            if host.port != r.port {
                patch.port = r.port
                changes.append(.init(label: "Port", old: String(host.port), new: String(r.port)))
                holdParts.append("Port \(host.port) → \(r.port)")
            }
            let oldUser = host.kind == .windowsRDP ? host.rdpUsername : host.user
            if !r.userIsDefault && oldUser != r.user {
                patch.user = r.user
                let shown: (String) -> String = { $0.isEmpty ? "(trống)" : $0 }
                changes.append(.init(label: "User", old: shown(oldUser), new: shown(r.user)))
                holdParts.append("User \(shown(oldUser)) → \(shown(r.user))")
            }
            if let env = r.environment, env != host.environment {
                patch.environment = env
                changes.append(.init(label: "Môi trường", old: host.environment.rawValue, new: env.rawValue))
            }
            if let f = effectiveFolder(r), !HostFolders.sameFolder(f, host.project) {
                patch.folder = f
                changes.append(.init(label: "Thư mục", old: host.project.isEmpty ? "(trống)" : host.project, new: f))
            }
            if let j = jump, r.kind == .ssh, j != host.jumpHostID {
                patch.setsJump = true
                patch.jumpHostID = j
                changes.append(
                    .init(label: "Jump host", old: displayName(of: host.jumpHostID), new: displayName(of: j)))
                holdParts.append("Jump host \(displayName(of: host.jumpHostID)) → \(displayName(of: j))")
            }
            if let name = r.credentialSetName {
                let current = setName(of: host)
                let alreadySame = wantedSet != nil && wantedSet?.id == host.credentialSetID
                if !alreadySame {
                    patch.credentialSetName = wantedSet?.name ?? name
                    changes.append(
                        .init(label: "Bộ đăng nhập", old: current ?? "(không)", new: wantedSet?.name ?? name))
                }
            }
            if let wanted = r.tags {
                let missingTags = wanted.filter { t in
                    !host.tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
                }
                if !missingTags.isEmpty {
                    patch.tags = host.tags + missingTags
                    changes.append(
                        .init(
                            label: "Tag", old: host.tags.isEmpty ? "(trống)" : host.tags.joined(separator: ", "),
                            new: (host.tags + missingTags).joined(separator: ", ")))
                }
            }
            if let notes = r.notes, notes != host.notes {
                patch.notes = notes
                func clip(_ s: String) -> String {
                    let one = s.replacingOccurrences(of: "\n", with: " ")
                    return one.count > 60 ? String(one.prefix(60)) + "…" : (one.isEmpty ? "(trống)" : one)
                }
                changes.append(.init(label: "Ghi chú", old: clip(host.notes), new: clip(notes)))
            }

            var hold: String?
            var parts: [String] = []
            if !holdParts.isEmpty { parts.append("Địa chỉ đổi từ nguồn: " + holdParts.joined(separator: "; ")) }
            if let n = patch.credentialSetName { parts.append("Bộ đăng nhập \(n) được gán từ nguồn") }
            if !parts.isEmpty { hold = String(parts.joined(separator: ". ").prefix(maxHoldReasonLength)) }

            if changes.isEmpty && !host.sourceMissing {
                plan.unchangedCount += 1
            } else {
                plan.updates.append(
                    InventorySyncPlan.Update(
                        hostID: host.id, displayName: host.displayName, changes: changes, patch: patch,
                        holdReason: hold, restored: host.sourceMissing))
            }
        }

        // 4. Không còn trong nguồn.
        let presentKeys = Set(records.map { key($0.externalID) }).union(failedKeys.map(key))
        for h in sourceHosts {
            guard let e = h.externalID, !presentKeys.contains(key(e)), !h.sourceMissing else { continue }
            plan.missing.append(InventorySyncPlan.Missing(hostID: h.id, displayName: h.displayName))
        }
        if records.isEmpty && !sourceHosts.isEmpty {
            plan.warnings.append(
                "Nguồn không có máy hợp lệ nào — nếu áp dụng, mọi máy của nguồn sẽ bị đánh “Không còn trong nguồn”.")
        }
        plan.setsToCreate = neededSets
        return plan
    }
}
