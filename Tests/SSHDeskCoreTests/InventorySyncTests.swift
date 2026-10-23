import Foundation
import Testing

@testable import SSHDeskCore

private struct SyncEnv {
    let dir = HostTempDir()
    let db: Database
    let repo: HostRepository

    init() throws {
        db = try Database(url: dir.dbURL)
        repo = HostRepository(database: db)
    }

    func source(
        _ name: String = "Khách A", folder: String = "", env: HostEnvironment? = nil
    ) -> InventorySource {
        InventorySource(
            name: name, kind: .csv, path: "/tmp/\(name).csv", folder: folder, defaultEnvironment: env)
    }

    @discardableResult
    func run(
        _ source: InventorySource?, _ records: [InventoryRecord], managesJump: Bool = true,
        failedKeys: Set<String> = [], apply: Bool = true
    ) async throws -> InventorySyncPlan {
        let plan = try InventorySync.plan(
            source: source, records: records, failedKeys: failedKeys, managesJump: managesJump,
            existingHosts: try await repo.all(), credentialSets: try await repo.credentialSets(),
            fingerprint: "fp-\(records.count)")
        if apply { try await repo.applyInventory(plan) }
        return plan
    }

    func host(_ name: String) async throws -> HostProfile {
        try #require(try await repo.all().first { $0.displayName == name })
    }
}

@Suite struct InventorySyncTests {
    @Test func firstSyncAddsHostsWithLinkEnvironmentAndFolder() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source(folder: "Khách A", env: .uat)
        let plan = try await env.run(
            src,
            [
                testRecord("web-01"), testRecord("web-02", env: .prod, folder: "Web"),
                testRecord("win", port: 3389, kind: .windowsRDP),
            ])
        #expect(plan.additions.count == 3 && plan.updates.isEmpty && plan.missing.isEmpty)
        let web1 = try await env.host("web-01")
        #expect(web1.sourceID == src.id && web1.externalID == "web-01" && !web1.sourceMissing)
        #expect(web1.environment == .uat && web1.project == "Khách A" && !web1.autofillHold)
        let web2 = try await env.host("web-02")
        #expect(web2.environment == .prod && web2.project == "Web")
        let win = try await env.host("win")
        #expect(win.kind == .windowsRDP && win.rdpUsername == "deploy" && win.user.isEmpty)
        let stored = try #require(try await env.repo.inventorySource(id: src.id))
        #expect(stored.lastFingerprint == "fp-3" && stored.lastSyncedAt != nil && stored.name == "Khách A")
        #expect(try await env.repo.folders().contains("Khách A"))
        // Không thay đổi -> kế hoạch rỗng.
        let again = try await env.run(
            src,
            [
                testRecord("web-01"), testRecord("web-02", env: .prod, folder: "Web"),
                testRecord("win", port: 3389, kind: .windowsRDP),
            ], apply: false)
        #expect(!again.hasChanges && again.unchangedCount == 3)
    }

    enum AddressCase: String, CaseIterable, CustomTestStringConvertible {
        case hostName, port, user, jump
        var testDescription: String { rawValue }
    }

    @Test(arguments: AddressCase.allCases)
    func changingAddressFieldHoldsAutofillWithOldToNewReason(_ c: AddressCase) async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        let base = [testRecord("bastion", host: "10.9.9.9"), testRecord("web")]
        try await env.run(src, base)
        let before = try await env.host("web")
        #expect(!before.autofillHold)
        var web = testRecord("web")
        var expected = ""
        switch c {
        case .hostName:
            web.hostName = "10.0.0.2"
            expected = "IP/Hostname 10.0.0.1 → 10.0.0.2"
        case .port:
            web.port = 2222
            expected = "Port 22 → 2222"
        case .user:
            web.user = "root"
            expected = "User deploy → root"
        case .jump:
            web.jumpRef = "bastion"
            expected = "Jump host (không) → bastion"
        }
        let plan = try await env.run(src, [testRecord("bastion", host: "10.9.9.9"), web])
        let update = try #require(plan.updates.first)
        #expect(update.holdReason?.contains(expected) == true)
        #expect(update.changes.contains { $0.text.contains("→") })
        let after = try await env.host("web")
        #expect(after.autofillHold)
        #expect(after.autofillHoldReason?.contains(expected) == true)
        #expect(after.autofillHoldReason?.hasPrefix("Địa chỉ đổi từ nguồn") == true)
        // Sửa tay qua form không xoá hold; chỉ xác nhận mới bỏ.
        var edited = after
        edited.autofillHold = false
        edited.autofillHoldReason = nil
        try await env.repo.update(edited)
        #expect(try await env.host("web").autofillHold)
        try await env.repo.confirmAutofillHold(id: after.id)
        let confirmed = try await env.host("web")
        #expect(!confirmed.autofillHold && confirmed.autofillHoldReason == nil)
    }

    @Test func windowsUserChangeHoldsToo() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("win", user: "Administrator", kind: .windowsRDP)])
        let plan = try await env.run(src, [testRecord("win", user: "Admin2", kind: .windowsRDP)])
        #expect(plan.updates.first?.holdReason?.contains("User Administrator → Admin2") == true)
        let w = try await env.host("win")
        #expect(w.autofillHold && w.rdpUsername == "Admin2")
    }

    @Test func otherFieldChangesDoNotHold() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("web", env: .dev, folder: "A", notes: "cũ")])
        let plan = try await env.run(src, [testRecord("web", env: .prod, folder: "B", notes: "mới")])
        let u = try #require(plan.updates.first)
        #expect(u.holdReason == nil && plan.holdCount == 0)
        #expect(
            Set(u.changes.map(\.label)) == ["Môi trường", "Thư mục", "Ghi chú"])
        #expect(u.changes.contains { $0.label == "Môi trường" && $0.old == "DEV" && $0.new == "PROD" })
        let h = try await env.host("web")
        #expect(!h.autofillHold && h.environment == .prod && h.project == "B" && h.notes == "mới")
    }

    @Test func notesAreKeptWhenSourceDoesNotMapNotesAndAppFieldsSurvive() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("web")])
        var h = try await env.host("web")
        h.notes = "ghi chú của tôi"
        h.isFavorite = true
        h.authMethod = .keyFile
        h.identityFile = "/keys/mine"
        h.identityAgent = "/tmp/agent.sock"
        h.credentialReference = "ref-riêng"
        h.remoteBookmarks = [RemoteBookmark(name: "logs", path: "/var/log")]
        h.defaultRemoteDirectory = "/srv"
        h.defaultLocalDirectory = "/Users/x"
        h.tags = ["a", "b"]
        try await env.repo.update(h)
        // Nguồn đổi môi trường + hostName.
        try await env.run(src, [testRecord("web", host: "10.0.0.8", env: .prod)])
        let after = try await env.host("web")
        #expect(after.notes == "ghi chú của tôi" && after.isFavorite && after.authMethod == .keyFile)
        #expect(after.identityFile == "/keys/mine" && after.identityAgent == "/tmp/agent.sock")
        #expect(after.credentialReference == "ref-riêng" && after.remoteBookmarks == h.remoteBookmarks)
        #expect(
            after.defaultRemoteDirectory == "/srv" && after.defaultLocalDirectory == "/Users/x"
                && after.tags == ["a", "b"])
        #expect(after.hostName == "10.0.0.8" && after.environment == .prod && after.autofillHold)
        #expect(after.id == h.id && after.sourceID == src.id)
    }

    @Test func missingHostsAreMarkedNotDeletedAndRestoredWhenBack() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("a"), testRecord("b")])
        let plan = try await env.run(src, [testRecord("a")])
        #expect(plan.missing.map(\.displayName) == ["b"])
        var all = try await env.repo.all()
        #expect(all.count == 2)
        #expect(all.first { $0.displayName == "b" }?.sourceMissing == true)
        #expect(all.first { $0.displayName == "a" }?.sourceMissing == false)
        // Lần sau không báo lại.
        let again = try await env.run(src, [testRecord("a")], apply: false)
        #expect(again.missing.isEmpty)
        let back = try await env.run(src, [testRecord("a"), testRecord("b")])
        #expect(back.updates.first?.restored == true && back.additions.isEmpty)
        all = try await env.repo.all()
        #expect(all.allSatisfy { !$0.sourceMissing } && all.count == 2)
        // Dòng lỗi (khoá đã biết) không bị coi là biến mất.
        let failed = try await env.run(src, [testRecord("a")], failedKeys: ["b"])
        #expect(failed.missing.isEmpty)
        // Nguồn trống -> cảnh báo.
        let empty = try await env.run(src, [], apply: false)
        #expect(empty.missing.count == 2 && !empty.warnings.isEmpty)
    }

    @Test func onlyHostsOfTheSourceAreTouched() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let manual = managedHost("web", hostName: "manual.example.com")
        try await env.repo.insert(manual)
        let other = env.source("Nguồn khác")
        try await env.run(other, [testRecord("other-1")])
        let src = env.source()
        let plan = try await env.run(src, [testRecord("web")])
        #expect(plan.additions.count == 1 && plan.missing.isEmpty)
        #expect(plan.issues.contains { $0.severity == .warning && $0.message.contains("cùng tên") })
        let all = try await env.repo.all()
        #expect(all.count == 3)
        #expect(try await env.repo.host(id: manual.id)?.hostName == "manual.example.com")
        #expect(try await env.repo.host(id: manual.id)?.sourceID == nil)
        // Nguồn thứ nhất không đánh dấu máy của nguồn khác là biến mất.
        let p2 = try await env.run(src, [testRecord("web")], apply: false)
        #expect(!p2.hasChanges)
    }

    @Test func oneTimeImportWithoutSourceLeavesNoLink() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let plan = try await env.run(nil, [testRecord("a"), testRecord("b")])
        #expect(plan.additions.count == 2)
        let all = try await env.repo.all()
        #expect(all.allSatisfy { $0.sourceID == nil && $0.externalID == nil })
        #expect(try await env.repo.inventorySources().isEmpty)
    }

    @Test func kindChangeIsReportedNotApplied() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("x")])
        let plan = try await env.run(src, [testRecord("x", port: 3389, kind: .windowsRDP)])
        #expect(plan.updates.isEmpty && plan.issues.contains { $0.severity == .error && $0.row == 2 })
        #expect(try await env.host("x").kind == .ssh)
    }

    // MARK: - Jump host

    @Test func jumpResolvesInFileThenExistingByExactName() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let existing = managedHost("bastion-cũ", hostName: "b.example.com")
        try await env.repo.insert(existing)
        let src = env.source()
        // `web` đứng trước `gw` trong file nhưng vẫn trỏ được tới gw (cùng file).
        let plan = try await env.run(
            src,
            [
                testRecord("web", jump: "gw"), testRecord("gw", host: "10.9.9.1"),
                testRecord("app", jump: "bastion-cũ"), testRecord("lost", jump: "không-có"),
                testRecord("me", jump: "me"),
            ])
        let web = try await env.host("web")
        let gw = try await env.host("gw")
        #expect(web.jumpHostID == gw.id)
        #expect(try await env.host("app").jumpHostID == existing.id)
        #expect(try await env.host("lost").jumpHostID == nil)
        #expect(try await env.host("me").jumpHostID == nil)
        let msgs = plan.issues.filter { $0.severity == .warning }.map(\.message)
        #expect(msgs.contains { $0.contains("không-có") } && msgs.contains { $0.contains("chính nó") })
        // SSH config sinh được (không vòng, alias hợp lệ).
        let specs = try await env.repo.sshSpecs()
        #expect(
            specs.first { $0.alias == HostProfile.managedAlias(for: web.id) }?.jumpAlias
                == HostProfile.managedAlias(for: gw.id))
    }

    @Test func jumpCycleInFileIsBrokenWithWarning() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let plan = try await env.run(env.source(), [testRecord("a", jump: "b"), testRecord("b", jump: "a")])
        #expect(plan.issues.contains { $0.message.contains("vòng") })
        let a = try await env.host("a")
        let b = try await env.host("b")
        #expect((a.jumpHostID == nil) != (b.jumpHostID == nil))
    }

    // MARK: - Bộ đăng nhập

    @Test func assigningCredentialSetFromSourceHoldsAndCreatesEmptySet() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        let plan = try await env.run(src, [testRecord("web", set: "Team A")])
        #expect(plan.setsToCreate == ["Team A"] && plan.holdCount == 1)
        let sets = try await env.repo.credentialSets()
        #expect(sets.map(\.name) == ["Team A"])
        let h = try await env.host("web")
        #expect(h.credentialSetID == sets[0].id && h.autofillHold && h.authMethod == .interactive)
        #expect(h.autofillHoldReason == "Bộ đăng nhập Team A được gán từ nguồn")
        #expect(h.autofillCredentialReference == nil && h.effectiveCredentialReference == sets[0].passwordReference)
        // Cùng bộ lần nữa: không đổi, không giữ thêm.
        try await env.repo.confirmAutofillHold(id: h.id)
        let same = try await env.run(src, [testRecord("web", set: "team a")], apply: false)
        #expect(!same.hasChanges)
        // Đổi sang bộ có sẵn (tên khác hoa thường) -> gán + hold lại.
        let other = try await env.repo.createCredentialSet(CredentialSet(name: "Team B"))
        let swap = try await env.run(src, [testRecord("web", set: "TEAM b")])
        #expect(swap.updates.first?.holdReason == "Bộ đăng nhập Team B được gán từ nguồn")
        let after = try await env.host("web")
        #expect(after.credentialSetID == other.id && after.autofillHold)
        #expect(swap.setsToCreate.isEmpty)
    }

    @Test func setColumnLeftBlankNeverRemovesExistingAssignment() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("web", set: "Team A")])
        let plan = try await env.run(src, [testRecord("web", set: nil)])
        #expect(!plan.hasChanges)
        #expect(try await env.host("web").credentialSetID != nil)
    }

    @Test func existingHoldReasonIsKeptAndExtended() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("web")])
        try await env.run(src, [testRecord("web", host: "10.0.0.2")])
        try await env.run(src, [testRecord("web", host: "10.0.0.2", port: 2200)])
        let reason = try #require(try await env.host("web").autofillHoldReason)
        #expect(reason.contains("10.0.0.1 → 10.0.0.2") && reason.contains("Port 22 → 2200"))
        #expect(reason.count <= InventorySync.maxHoldReasonLength + 2)
    }

    // MARK: - Transaction

    @Test func failedApplyRollsBackSourceHostsSetsAndFlags() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("keep"), testRecord("gone")])
        let beforeHosts = try await env.repo.all()
        var plan = try await env.run(
            env.source("Nguồn mới"), [testRecord("n1", set: "Bộ mới"), testRecord("n2")], apply: false)
        // Làm hỏng host cuối: sai ở bước ghi, sau khi nguồn/bộ/host đầu đã ghi.
        plan.additions[1].host.hostName = "máy hỏng!"
        await #expect(throws: (any Error).self) { try await env.repo.applyInventory(plan) }
        #expect(try await env.repo.all() == beforeHosts)
        #expect(try await env.repo.inventorySources().map(\.name) == ["Khách A"])
        #expect(try await env.repo.credentialSets().isEmpty)

        // Cập nhật + đánh missing cũng được hoàn tác khi addition lỗi.
        var p2 = try await env.run(
            src, [testRecord("keep", host: "10.0.0.50"), testRecord("new1")], apply: false)
        #expect(p2.missing.count == 1 && p2.updates.count == 1)
        p2.additions[0].host.port = 0
        await #expect(throws: (any Error).self) { try await env.repo.applyInventory(p2) }
        #expect(try await env.repo.all() == beforeHosts)
    }

    @Test func stalePlanFailsWholeTransaction() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("a"), testRecord("b")])
        let plan = try await env.run(src, [testRecord("a", host: "10.1.1.1"), testRecord("c")], apply: false)
        let a = try await env.host("a")
        try await env.repo.delete(id: a.id)  // host bị xoá sau khi xem trước
        let before = try await env.repo.all()
        await #expect(throws: InventoryError.self) { try await env.repo.applyInventory(plan) }
        #expect(try await env.repo.all() == before)
    }

    @Test func recordLimitAndNameValidation() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let many = (0..<5001).map { testRecord("h\($0)") }
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) {
            try InventorySync.plan(source: nil, records: many, existingHosts: [], credentialSets: [])
        }
        let ok = (0..<5000).map { testRecord("h\($0)", host: "10.0.\($0 / 250).\($0 % 250 + 1)") }
        let plan = try InventorySync.plan(source: nil, records: ok, existingHosts: [], credentialSets: [])
        #expect(plan.additions.count == 5000)
        await #expect(throws: InventoryError.invalidName) {
            try await env.repo.updateInventorySource(InventorySource(name: " ", kind: .csv, path: "/x"))
        }
    }

    // MARK: - Nguồn

    @Test func deletingSourceKeepsHostsAndClearsLinks() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("a"), testRecord("b")])
        try await env.run(src, [testRecord("a")])
        let n = try await env.repo.deleteInventorySource(id: src.id)
        #expect(n == 2)
        let all = try await env.repo.all()
        #expect(all.count == 2 && all.allSatisfy { $0.sourceID == nil && $0.externalID == nil && !$0.sourceMissing })
        #expect(try await env.repo.inventorySources().isEmpty)
        await #expect(throws: InventoryError.self) { try await env.repo.deleteInventorySource(id: src.id) }
    }

    @Test func detachKeepsValuesAndUsageCounts() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("a"), testRecord("b")])
        try await env.run(src, [testRecord("a")])
        let usage = try await env.repo.inventorySourceUsage()
        #expect(usage[src.id]?.hosts == 2 && usage[src.id]?.missing == 1)
        let a = try await env.host("a")
        try await env.repo.detachFromSource(hostID: a.id)
        let after = try await env.host("a")
        #expect(after.sourceID == nil && after.externalID == nil && after.hostName == "10.0.0.1")
        // Lần đồng bộ sau coi "a" là máy mới (không còn liên kết).
        let plan = try await env.run(src, [testRecord("a")], apply: false)
        #expect(plan.additions.count == 1)
    }

    @Test func formUpdateCannotChangeSourceLink() async throws {
        let env = try SyncEnv()
        defer { env.dir.cleanup() }
        let src = env.source()
        try await env.run(src, [testRecord("a")])
        var a = try await env.host("a")
        a.sourceID = nil
        a.externalID = "khác"
        a.sourceMissing = true
        try await env.repo.update(a)
        let after = try await env.host("a")
        #expect(after.sourceID == src.id && after.externalID == "a" && !after.sourceMissing)
        let copy = after.duplicated(existingNames: ["a"])
        #expect(copy.sourceID == nil && copy.externalID == nil)
    }

    // MARK: - Migration v10

    @Test func migrationV10UpgradesV9AndKeepsHosts() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        #expect(Database.currentSchemaVersion >= 10)
        let id = UUID().uuidString
        do {
            let old = try Database(url: dir.dbURL, migrations: Array(Database.migrations.prefix(9)))
            #expect(try old.schemaVersion() == 9)
            try old.execute(
                """
                INSERT INTO hosts (id, display_name, project, environment, tags_json, notes, is_favorite,
                  connection_mode, host_name, port, user, auth_method, bookmarks_json,
                  default_local_directory, default_remote_directory, created_at, updated_at)
                VALUES (?, 'legacy', '', 'DEV', '[]', '', 0, 'managed', 'h.example.com', 22, 'u', 'interactive',
                  '[]', '', '', 1, 1)
                """, [.text(id)])
        }
        let db = try Database(url: dir.dbURL)
        #expect(try db.schemaVersion() == Database.currentSchemaVersion)
        let repo = HostRepository(database: db)
        let hosts = try await repo.all()
        #expect(hosts.count == 1 && hosts[0].sourceID == nil && hosts[0].externalID == nil && !hosts[0].sourceMissing)
        #expect(try await repo.inventorySources().isEmpty)
        // Ràng buộc kind của bảng nguồn.
        #expect(throws: (any Error).self) {
            try db.execute(
                "INSERT INTO inventory_sources(id, name, kind, path) VALUES ('x', 'n', 'yaml', '/p')")
        }
    }
}
