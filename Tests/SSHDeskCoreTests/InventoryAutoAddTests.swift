import Foundation
import Testing

@testable import SSHDeskCore

private final class AutoWarp: WarpURLHandler, @unchecked Sendable {
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
}

private struct AutoWindowsApp: WindowsAppHandler {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

private final class AutoPasteboard: SecretPasteboard, @unchecked Sendable {
    private(set) var string: String?
    private(set) var changeCount = 0
    @discardableResult func clearContents() -> Int {
        changeCount += 1
        string = nil
        return changeCount
    }
    func write(string: String, markerTypes: [String]) -> Int {
        self.string = string
        changeCount += 1
        return changeCount
    }
}

private struct AutoRig {
    let dir = HostTempDir()
    let store = InMemoryCredentialStore()
    let paths: AppPaths
    let database: Database
    let repo: HostRepository
    let forwards: PortForwardRepository
    let service: ConnectionService
    let source = InventorySource(name: "Khách", kind: .csv, path: "/tmp/k.csv")
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        database = try Database(url: paths.databaseURL)
        repo = HostRepository(database: database)
        forwards = PortForwardRepository(database: database)
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: AutoWarp()),
            rdpLauncher: WindowsAppLauncher(
                directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: AutoWindowsApp()),
            credentials: store,
            secretClipboard: SecretClipboard(pasteboard: AutoPasteboard(), scheduler: { _, _ in {} }),
            askpassHelper: URL(fileURLWithPath: "/Applications/SSH Desk.app/Contents/MacOS/sshdesk-askpass"),
            settings: SettingsStore(.default))
    }

    func plan(_ records: [InventoryRecord], source: InventorySource? = nil) async throws -> InventorySyncPlan {
        try InventorySync.plan(
            source: source ?? self.source, records: records, existingHosts: try await repo.all(),
            credentialSets: try await repo.credentialSets(), fingerprint: "fp", now: stamp)
    }

    func host(_ name: String) async throws -> HostProfile {
        try #require(try await repo.all().first { $0.displayName == name })
    }

    func configText() throws -> String { try String(contentsOf: paths.sshConfigURL, encoding: .utf8) }
}

@Suite struct InventoryAutoAddPlanTests {
    private let src = InventorySource(name: "n", kind: .csv, path: "/tmp/n.csv")

    private func plan(
        _ records: [InventoryRecord], existing: [HostProfile] = [], issues: [InventoryIssue] = [],
        warnings: [String] = [], sets: [CredentialSet] = [], source: InventorySource? = nil
    ) throws -> InventorySyncPlan {
        try InventorySync.plan(
            source: source ?? src, records: records, issues: issues, warnings: warnings, existingHosts: existing,
            credentialSets: sets)
    }

    @Test func onlyNewHostsIsAdditionsOnly() throws {
        let p = try plan([testRecord("a"), testRecord("b", host: "10.0.0.2", row: 3)])
        #expect(InventorySync.isAdditionsOnly(p))
    }

    @Test func additionsPlusUnchangedStillQualifies() throws {
        let first = try plan([testRecord("a")])
        var existing = first.additions.map(\.host)
        existing[0].sourceID = src.id
        existing[0].externalID = "a"
        let p = try plan([testRecord("a"), testRecord("b", host: "10.0.0.2", row: 3)], existing: existing)
        #expect(p.unchangedCount == 1 && p.additions.count == 1)
        #expect(InventorySync.isAdditionsOnly(p))
    }

    @Test func nothingToAddOrNoSourceIsNotAutoApplied() throws {
        #expect(!InventorySync.isAdditionsOnly(try plan([])))
        #expect(!InventorySync.isAdditionsOnly(try plan([testRecord("a")], source: nil).withoutSource()))
    }

    @Test func anyUpdateBlocks() throws {
        var existing = try plan([testRecord("a")]).additions.map(\.host)
        existing[0].sourceID = src.id
        existing[0].externalID = "a"
        // Đổi địa chỉ -> update (có hold).
        let p = try plan(
            [testRecord("a", host: "10.9.9.9"), testRecord("b", host: "10.0.0.2", row: 3)], existing: existing)
        #expect(p.updates.count == 1 && p.additions.count == 1)
        #expect(!InventorySync.isAdditionsOnly(p))
        // Đổi ghi chú / thư mục cũng chặn.
        let q = try plan(
            [testRecord("a", notes: "mới"), testRecord("b", host: "10.0.0.2", row: 3)], existing: existing)
        #expect(!InventorySync.isAdditionsOnly(q))
    }

    @Test func missingHostBlocks() throws {
        var existing = try plan([testRecord("a")]).additions.map(\.host)
        existing[0].sourceID = src.id
        existing[0].externalID = "a"
        let p = try plan([testRecord("b", host: "10.0.0.2", row: 3)], existing: existing)
        #expect(p.missing.count == 1 && p.additions.count == 1)
        #expect(!InventorySync.isAdditionsOnly(p))
    }

    @Test func rowErrorsAndWarningsBlock() throws {
        let rec = [testRecord("a")]
        #expect(!InventorySync.isAdditionsOnly(try plan(rec, issues: [InventoryIssue(.error, row: 5, "hỏng")])))
        #expect(!InventorySync.isAdditionsOnly(try plan(rec, issues: [InventoryIssue(.warning, row: 5, "ô lạ")])))
        #expect(!InventorySync.isAdditionsOnly(try plan(rec, warnings: ["Phát hiện cột mật khẩu — sẽ bỏ qua"])))
    }

    @Test func missingJumpHostWarningBlocks() throws {
        let p = try plan([testRecord("a", jump: "khong-co")])
        #expect(p.issues.contains { $0.column == InventoryField.jumpHost.title })
        #expect(!InventorySync.isAdditionsOnly(p))
    }

    @Test func missingCredentialSetBlocks() throws {
        let p = try plan([testRecord("a", set: "Bộ chưa có")])
        #expect(p.setsToCreate == ["Bộ chưa có"])
        #expect(!InventorySync.isAdditionsOnly(p))
        // Bộ đã có -> vẫn là additions-only (host mới vẫn bị hold khi áp dụng).
        let set = CredentialSet(name: "Bộ chưa có")
        let q = try plan([testRecord("a", set: "Bộ chưa có")], sets: [set])
        #expect(InventorySync.isAdditionsOnly(q))
    }

    @Test func jumpHostWithinSameFileIsFine() throws {
        let p = try plan([testRecord("bastion"), testRecord("web", host: "10.0.0.2", jump: "bastion", row: 3)])
        #expect(p.issues.isEmpty)
        #expect(InventorySync.isAdditionsOnly(p))
    }

    @Test func autoAddFlagDefaultsOnAndSurvivesMappingRewrite() {
        #expect(InventorySource(name: "x", kind: .csv, path: "/x").autoAddNew)
        var s = InventorySource(name: "x", kind: .csv, path: "/x", configJSON: "không phải json")
        #expect(s.autoAddNew)
        s.configJSON = InventorySource.configJSON("{}", settingAutoAddNew: false)
        #expect(!s.autoAddNew)
        let mapping = TableMapping(headerRow: 2, columns: ["hostName": "IP"], keyField: .hostName)
        let rewritten = InventorySource.encodeConfig(mapping, preserving: s.configJSON)
        let reread = InventorySource(name: "x", kind: .csv, path: "/x", configJSON: rewritten)
        #expect(!reread.autoAddNew)
        #expect(reread.tableMapping == mapping)
        // Nguồn chưa ghi cờ -> ghi lại ghép cột không tự thêm cờ.
        #expect(!InventorySource.encodeConfig(mapping).contains("autoAddNew"))
    }
}

extension InventorySyncPlan {
    fileprivate func withoutSource() -> InventorySyncPlan {
        var p = self
        p.source = nil
        return p
    }
}

@Suite struct InventoryAutoAddApplyTests {
    @Test func autoApplyWritesHostsAndNeverTouchesKeychain() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let plan = try await r.plan([testRecord("a", host: "10.1.0.1"), testRecord("b", host: "10.1.0.2", row: 3)])
        let record = try await r.service.applyAutoInventory(plan)
        #expect(Set(record.hostIDs) == Set(plan.additions.map(\.id)) && record.sourceID == r.source.id)
        let a = try await r.host("a")
        #expect(a.credentialReference == nil && !a.hasOwnPassword)
        #expect(r.store.description == "InMemoryCredentialStore(count: 0)")
        let text = try r.configText()
        #expect(text.contains("10.1.0.1") && text.contains("10.1.0.2"))
        // Nguồn được lưu cùng transaction, vân tay cập nhật.
        let saved = try #require(try await r.repo.inventorySource(id: r.source.id))
        #expect(saved.lastFingerprint == "fp" && saved.autoAddNew)
    }

    @Test func autoApplyRefusesPlansWithAnythingElse() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        try await r.service.applyInventory(try await r.plan([testRecord("a")]))
        // Lần sau: a đổi địa chỉ + b mới -> không được tự áp dụng.
        let mixed = try await r.plan([testRecord("a", host: "10.7.7.7"), testRecord("b", host: "10.1.0.2", row: 3)])
        await #expect(throws: InventoryError.notAdditionsOnly) { _ = try await r.service.applyAutoInventory(mixed) }
        #expect(try await r.repo.all().count == 1)
        #expect(try await r.host("a").hostName == "10.0.0.1")
    }

    @Test func newHostWithCredentialSetIsStillHeld() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        _ = try await r.repo.credentialSet(named: "Prod", createIfMissing: true)
        let plan = try await r.plan([testRecord("a", set: "Prod"), testRecord("b", host: "10.1.0.2", row: 3)])
        #expect(InventorySync.isAdditionsOnly(plan))
        _ = try await r.service.applyAutoInventory(plan)
        let a = try await r.host("a")
        #expect(a.credentialSetID != nil && a.autofillHold && a.autofillHoldReason?.contains("Prod") == true)
        let b = try await r.host("b")
        #expect(!b.autofillHold)
        #expect(r.store.description == "InMemoryCredentialStore(count: 0)")
    }
}

@Suite struct InventoryAutoAddUndoTests {
    @Test func undoRemovesOnlyUntouchedAndKeepsEverythingElse() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let names = ["clean1", "clean2", "edited", "withForward", "withPassword", "usedAsJump"]
        let records = names.enumerated().map { i, n in testRecord(n, host: "10.2.0.\(i + 1)", row: i + 2) }
        let record = try await r.service.applyAutoInventory(try await r.plan(records))
        #expect(record.hostIDs.count == 6)

        // Sửa tay: ghi chú.
        var edited = try await r.host("edited")
        edited.notes = "tôi đã sửa"
        try await r.repo.update(edited)
        // Forward.
        let fwdHost = try await r.host("withForward")
        _ = try await r.forwards.add(PortForward(hostID: fwdHost.id, name: "db", localPort: 15432, remotePort: 5432))
        // Mật khẩu riêng.
        var pw = try await r.host("withPassword")
        pw.authMethod = .interactive
        try await r.repo.update(pw)
        _ = try await r.service.savePassword(hostID: pw.id, password: "Pw-undo-1")
        // Là jump host của máy tạo tay.
        let jump = try await r.host("usedAsJump")
        try await r.repo.insert(managedHost("manual", hostName: "manual.example.com", jump: jump.id))

        let outcome = try await r.service.undoAutoAdd(record)
        let left = Set(try await r.repo.all().map(\.displayName))
        #expect(left == ["edited", "withForward", "withPassword", "usedAsJump", "manual"])
        #expect(outcome.removed.count == 2 && outcome.kept.count == 4 && outcome.alreadyGone == 0)

        // Cờ đã tắt; host giữ lại vẫn thuộc nguồn.
        let src = try #require(try await r.repo.inventorySource(id: r.source.id))
        #expect(!src.autoAddNew)
        #expect(try await r.host("edited").sourceID == r.source.id)
        // SSH config sinh lại: host đã xoá biến mất, host giữ còn.
        let text = try r.configText()
        #expect(!text.contains("10.2.0.1") && !text.contains("10.2.0.2"))
        #expect(text.contains("10.2.0.3") && text.contains("10.2.0.6"))
        // Mật khẩu của host giữ lại không bị đụng.
        #expect(r.store.description == "InMemoryCredentialStore(count: 1)")
    }

    @Test func jumpChainInsideTheAddedSetIsRemovedTogether() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let plan = try await r.plan([
            testRecord("bastion", host: "10.3.0.1"), testRecord("web", host: "10.3.0.2", jump: "bastion", row: 3),
        ])
        let record = try await r.service.applyAutoInventory(plan)
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(outcome.removed.count == 2 && outcome.kept.isEmpty)
        #expect(try await r.repo.all().isEmpty)
    }

    @Test func keepingAJumpedHostKeepsItsBastionToo() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let plan = try await r.plan([
            testRecord("bastion", host: "10.3.0.1"), testRecord("web", host: "10.3.0.2", jump: "bastion", row: 3),
        ])
        let record = try await r.service.applyAutoInventory(plan)
        var web = try await r.host("web")
        web.notes = "đã sửa"
        try await r.repo.update(web)
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(outcome.removed.isEmpty && outcome.kept.count == 2)
        #expect(try await r.repo.all().count == 2)
    }

    @Test func undoDisablesFlagEvenWhenNothingRemovedAndToleratesGoneHosts() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let record = try await r.service.applyAutoInventory(try await r.plan([testRecord("a")]))
        try await r.service.delete(id: record.hostIDs[0])
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(outcome.removed.isEmpty && outcome.alreadyGone == 1)
        #expect(!(try #require(try await r.repo.inventorySource(id: r.source.id))).autoAddNew)
    }

    @Test func detachedHostIsKept() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let record = try await r.service.applyAutoInventory(try await r.plan([testRecord("a")]))
        try await r.service.detachFromSource(hostID: record.hostIDs[0])
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(outcome.removed.isEmpty && outcome.kept.count == 1)
    }

    @Test func afterUndoNextDetectionIsNotAutoApplied() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let record = try await r.service.applyAutoInventory(try await r.plan([testRecord("a")]))
        _ = try await r.service.undoAutoAdd(record)
        // Model chỉ tự áp dụng khi nguồn.autoAddNew -> cờ tắt thì rơi về banner + xem trước.
        let stored = try #require(try await r.repo.inventorySource(id: r.source.id))
        #expect(!stored.autoAddNew)
        // Bật lại bằng toggle.
        try await r.service.setInventoryAutoAdd(sourceID: r.source.id, enabled: true)
        #expect(try #require(try await r.repo.inventorySource(id: r.source.id)).autoAddNew)
    }

    @Test func confirmingHoldTouchesUpdatedAtSoUndoKeepsThatHost() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        _ = try await r.repo.credentialSet(named: "Prod", createIfMissing: true)
        let record = try await r.service.applyAutoInventory(try await r.plan([testRecord("a", set: "Prod")]))
        let before = try await r.host("a")
        #expect(before.autofillHold)
        try await r.repo.confirmAutofillHold(id: before.id)
        let after = try await r.host("a")
        #expect(!after.autofillHold && after.updatedAt != record.stamp)
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(outcome.removed.isEmpty && outcome.kept == [before.id])
        #expect(try await r.repo.all().count == 1)
    }

    @Test func undoCleansWarpAndRdpFilesOfRemovedHostsOnly() async throws {
        let r = try AutoRig()
        defer { r.dir.cleanup() }
        let record = try await r.service.applyAutoInventory(
            try await r.plan([
                testRecord("ssh1", host: "10.4.0.1"),
                testRecord("win1", host: "10.4.0.2", kind: .windowsRDP, row: 3),
                testRecord("kept", host: "10.4.0.3", row: 4),
            ]))
        var kept = try await r.host("kept")
        kept.notes = "sửa"
        try await r.repo.update(kept)
        let fm = FileManager.default
        let tabs = r.dir.url.appendingPathComponent("tabs")
        try fm.createDirectory(at: tabs, withIntermediateDirectories: true)
        func warpFile(_ id: UUID) -> URL { tabs.appendingPathComponent("sshdesk_\(id.uuidString.lowercased()).toml") }
        let marker = WarpTabConfigRenderer.ownershipMarker + "\n"
        let ssh1 = try await r.host("ssh1")
        let win1 = try await r.host("win1")
        for id in [ssh1.id, kept.id] { try marker.write(to: warpFile(id), atomically: true, encoding: .utf8) }
        let stranger = tabs.appendingPathComponent("my-own.toml")
        try "x".write(to: stranger, atomically: true, encoding: .utf8)
        let rdpDir = r.paths.baseDirectory.appendingPathComponent("rdp")
        for id in [win1.id, kept.id] {
            let d = rdpDir.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try "x".write(to: d.appendingPathComponent("a.rdp"), atomically: true, encoding: .utf8)
        }
        let outcome = try await r.service.undoAutoAdd(record)
        #expect(Set(outcome.removed) == [ssh1.id, win1.id])
        #expect(!fm.fileExists(atPath: warpFile(ssh1.id).path))
        #expect(fm.fileExists(atPath: warpFile(kept.id).path) && fm.fileExists(atPath: stranger.path))
        #expect(!fm.fileExists(atPath: rdpDir.appendingPathComponent(win1.id.uuidString.lowercased()).path))
        #expect(fm.fileExists(atPath: rdpDir.appendingPathComponent(kept.id.uuidString.lowercased()).path))
    }
}
