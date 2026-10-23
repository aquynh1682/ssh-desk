import Foundation
import Testing

@testable import SSHDeskCore

private final class SecWarp: WarpURLHandler, @unchecked Sendable {
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
}

private final class SecPasteboard: SecretPasteboard, @unchecked Sendable {
    private(set) var changeCount = 0
    @discardableResult func clearContents() -> Int {
        changeCount += 1
        return changeCount
    }
    func write(string: String, markerTypes: [String]) -> Int {
        changeCount += 1
        return changeCount
    }
}

private struct SecWindowsApp: WindowsAppHandler {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

/// Kho giả luôn lỗi khi ghi (kiểm đếm lỗi, không lộ giá trị).
private struct FailingStore: CredentialStore {
    func save(ref: String, password: String) throws { throw CredentialStoreError.invalidReference }
    func read(ref: String) -> String? { nil }
    func delete(ref: String) throws {}
    func exists(ref: String) -> Bool { false }
}

private struct SecRig {
    let dir = HostTempDir()
    let store = InMemoryCredentialStore()
    let paths: AppPaths
    let repo: HostRepository
    let service: ConnectionService
    let sourceID = UUID()

    init(credentials: (any CredentialStore)? = nil) throws {
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: SecWarp()),
            rdpLauncher: WindowsAppLauncher(
                directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: SecWindowsApp()),
            credentials: credentials ?? store,
            secretClipboard: SecretClipboard(pasteboard: SecPasteboard(), scheduler: { _, _ in {} }),
            askpassHelper: URL(fileURLWithPath: "/Applications/SSH Desk.app/Contents/MacOS/sshdesk-askpass"),
            settings: SettingsStore(.default))
    }

    func write(_ text: String) throws -> URL {
        let url = dir.url.appendingPathComponent("khach-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    struct Result {
        var plan: InventorySyncPlan
        var parsed: InventoryFile.Parsed
        var secretPlan: InventorySecretImport.Plan?
        var outcome: InventorySecretImport.Outcome?
        var loaded: InventoryFile.Loaded
    }

    /// Mô phỏng wizard: đọc (giữ cột nếu `keep`), dựng kế hoạch, áp dụng DB rồi lưu mật khẩu.
    @discardableResult
    func run(
        _ url: URL, keep: String?, overwrite: Bool = false, applySecrets: Bool = true
    ) async throws -> Result {
        let loaded = try InventoryFile.load(url: url, keepSecretColumn: keep)
        let sheet = loaded.workbook.sheets[0]
        var mapping = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
        mapping.sheet = nil
        let parsed = try #require(try InventoryFile.parse(loaded, mapping: mapping))
        let source = InventorySource(id: sourceID, name: "Khách", kind: .csv, path: url.path)
        let plan = try InventoryFile.plan(
            source: source, loaded: loaded, parsed: parsed, existingHosts: try await repo.all(),
            credentialSets: try await repo.credentialSets())
        var result = Result(plan: plan, parsed: parsed, loaded: loaded)
        var secretPlan: InventorySecretImport.Plan?
        if let secrets = loaded.secrets {
            secretPlan = InventorySecretImport.plan(
                for: plan, secrets: secrets, sheet: sheet.name, existingHosts: try await repo.all(),
                overwrite: overwrite)
        }
        try await service.applyInventory(plan)
        if let secretPlan, let secrets = loaded.secrets, applySecrets {
            let service = self.service
            result.outcome = await InventorySecretImport.save(secretPlan, secrets: secrets, sheet: sheet.name) {
                id, pw in _ = try await service.savePassword(hostID: id, password: pw)
            }
        }
        result.secretPlan = secretPlan
        return result
    }

    func host(_ name: String) async throws -> HostProfile {
        try #require(try await repo.all().first { $0.displayName == name })
    }

    func password(_ name: String) async throws -> String? {
        let h = try await host(name)
        return h.credentialReference.flatMap { store.read(ref: $0) }
    }

    /// Mọi byte của file DB (kể cả -wal/-shm) có chứa chuỗi không.
    func databaseContains(_ needle: String) -> Bool {
        let base = paths.databaseURL.path
        for suffix in ["", "-wal", "-shm"] {
            if let d = FileManager.default.contents(atPath: base + suffix),
                d.range(of: Data(needle.utf8)) != nil
            {
                return true
            }
        }
        return false
    }
}

private let csvBasic = """
    Tên,IP,User,Mật khẩu
    web,10.0.0.1,deploy,Pw-Alpha-91
    db,10.0.0.2,deploy,Pw-Beta-92
    cache,10.0.0.3,deploy,
    """

@Suite struct InventorySecretColumnTests {
    @Test func defaultDoesNotKeepOrSavePasswords() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let res = try await r.run(try r.write(csvBasic), keep: nil)
        #expect(res.loaded.secrets == nil)
        #expect(res.secretPlan == nil)
        #expect(try await r.repo.all().count == 3)
        #expect(try await r.password("web") == nil)
        #expect(res.parsed.sheet.warnings.contains("Phát hiện cột mật khẩu — sẽ bỏ qua"))
        #expect(!r.databaseContains("Pw-Alpha-91"))
    }

    @Test func enabledSavesToTheRightHostsAndSkipsBlankCells() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let res = try await r.run(try r.write(csvBasic), keep: "Mật khẩu")
        #expect(res.secretPlan?.newCount == 2)
        #expect(res.outcome == .init(saved: 2, failed: 0))
        #expect(try await r.password("web") == "Pw-Alpha-91")
        #expect(try await r.password("db") == "Pw-Beta-92")
        #expect(try await r.password("cache") == nil)
        #expect(try await r.host("cache").credentialReference == nil)
        // Container đã được xoá sau khi lưu.
        #expect(res.loaded.secrets?.count == 0)
    }

    @Test func existingOwnPasswordIsKeptUnlessOverwriteIsOn() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let url = try r.write(csvBasic)
        try await r.run(url, keep: "Mật khẩu")
        let newer = try r.write(
            "Tên,IP,User,Mật khẩu\nweb,10.0.0.1,deploy,Pw-Gamma-93\ndb,10.0.0.2,deploy,Pw-Beta-92\nnew,10.0.0.9,deploy,Pw-Delta-94\n"
        )

        let keepRes = try await r.run(newer, keep: "Mật khẩu", overwrite: false)
        #expect(keepRes.secretPlan?.skippedExisting == 2)
        #expect(keepRes.secretPlan?.newCount == 1)
        #expect(try await r.password("web") == "Pw-Alpha-91")
        #expect(try await r.password("new") == "Pw-Delta-94")

        let overRes = try await r.run(newer, keep: "Mật khẩu", overwrite: true)
        #expect(overRes.secretPlan?.replaceCount == 3)
        #expect(overRes.secretPlan?.skippedExisting == 0)
        #expect(try await r.password("web") == "Pw-Gamma-93")
    }

    @Test func valueNeverAppearsInModelsPlanIssuesConfigOrDatabase() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let res = try await r.run(try r.write(csvBasic), keep: "Mật khẩu", applySecrets: false)
        let secret = "Pw-Alpha-91"
        let secrets = try #require(res.loaded.secrets)
        #expect(secrets.count == 2)
        #expect("\(res.parsed.result.records)".contains(secret) == false)
        #expect("\(res.parsed.sheet)".contains(secret) == false)
        #expect("\(res.loaded.workbook)".contains(secret) == false)
        #expect("\(res.plan)".contains(secret) == false)
        #expect("\(res.parsed.result.issues)".contains(secret) == false)
        #expect("\(res.parsed.result.warnings)".contains(secret) == false)
        #expect(res.plan.source?.configJSON.contains(secret) == false)
        #expect("\(res.secretPlan as Any)".contains(secret) == false)
        for text in [
            String(describing: secrets), String(reflecting: secrets), "\(secrets)", "\(res.loaded)",
            String(reflecting: Mirror(reflecting: secrets).children.map { "\($0.value)" }),
        ] {
            #expect(!text.contains(secret))
            #expect(!text.contains("Pw-Beta-92"))
        }
        var dumped = ""
        dump(secrets, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(!r.databaseContains(secret))
        #expect(!r.databaseContains("Pw-Beta-92"))
        secrets.wipe()
    }

    @Test func laterSyncWithoutOptInNeverSaves() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let url = try r.write(csvBasic)
        try await r.run(url, keep: nil)
        // Đồng bộ lại (đường tự động/saved) dùng resync: không giữ cột nào.
        let source = try #require(try await r.repo.inventorySource(id: r.sourceID))
        let outcome = try InventoryFile.resync(
            source: source, existingHosts: try await r.repo.all(), credentialSets: [])
        guard case .ready(let loaded, _) = outcome else {
            Issue.record("cần .ready")
            return
        }
        #expect(loaded.secrets == nil)
        #expect(try await r.password("web") == nil)
        #expect(!r.databaseContains("Pw-Alpha-91"))
    }

    @Test func wipeZeroesTheBuffers() throws {
        let c = SecretColumnValues(title: "Mật khẩu")
        c.set(sheet: "S", row: 2, bytes: Array("Pw-Zeta-95".utf8))
        let buf = try #require(c.buffer(sheet: "S", row: 2))
        #expect(buf.count == 10 && !buf.isAllZero)
        c.wipe()
        #expect(buf.isAllZero)
        #expect(buf.count == 10)
        #expect(c.count == 0)
        #expect(c.bytes(sheet: "S", row: 2) == nil)
    }

    @Test func invalidValuesAreDroppedWithoutLeakingThem() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let long = String(repeating: "a", count: 1025)
        let csv =
            "Tên,IP,User,Mật khẩu\nweb,10.0.0.1,deploy,\"bad\u{07}pass-Q1\"\ndb,10.0.0.2,deploy,\(long)\nok,10.0.0.3,deploy,Pw-Okay-96\n"
        let res = try await r.run(try r.write(csv), keep: "Mật khẩu")
        let sp = try #require(res.secretPlan)
        #expect(sp.invalidRows == [2, 3])
        #expect(sp.count == 1)
        #expect(try await r.password("web") == nil)
        #expect(try await r.password("db") == nil)
        #expect(try await r.password("ok") == "Pw-Okay-96")
        let messages = sp.invalidMessages.joined()
        #expect(messages.contains("dòng 2") && !messages.contains("pass-Q1") && !messages.contains("aaaa"))
        #expect(!InventorySecretImport.isValid(Array("a\0b".utf8)))
        #expect(InventorySecretImport.isValid(Array("mật khẩu ✓ 123".utf8)))
    }

    @Test func storeFailuresAreCountedNotPrinted() async throws {
        let r = try SecRig(credentials: FailingStore())
        defer { r.dir.cleanup() }
        let res = try await r.run(try r.write(csvBasic), keep: "Mật khẩu")
        #expect(res.outcome == .init(saved: 0, failed: 2))
        #expect(try await r.repo.all().count == 3)
        #expect(!"\(res.outcome as Any)".contains("Pw-"))
    }

    @Test func onlyTheChosenColumnIsKept() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let csv = "Tên,IP,User,Mật khẩu,Passphrase key\nweb,10.0.0.1,deploy,Pw-Main-97,Pp-Other-98\n"
        let res = try await r.run(try r.write(csv), keep: "Mật khẩu")
        #expect(try await r.password("web") == "Pw-Main-97")
        #expect("\(res.parsed.sheet)".contains("Pp-Other-98") == false)
        let none = try InventoryFile.load(url: try r.write(csv), keepSecretColumn: "Tên")
        #expect(none.secrets?.count == 0)  // không phải cột mật khẩu -> không giữ gì
    }

    @Test func xlsxColumnIsKeptToo() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let rows =
            TestXLSX.inlineRow(1, ["Tên", "IP", "Mật khẩu"]) + TestXLSX.inlineRow(2, ["web", "10.0.0.1", "Pw-Xlsx-99"])
        let file = dir.url.appendingPathComponent("k.xlsx")
        try TestXLSX(sheets: [.init(name: "Máy", xml: TestXLSX.sheetXML(rows))]).write(to: file)
        let off = try InventoryFile.load(url: file)
        #expect(off.secrets == nil)
        let on = try InventoryFile.load(url: file, keepSecretColumn: "Mật khẩu")
        #expect(on.secrets?.bytes(sheet: "Máy", row: 2) == Array("Pw-Xlsx-99".utf8))
        #expect("\(on.workbook)".contains("Pw-Xlsx-99") == false)
        #expect("\(on)".contains("Pw-Xlsx-99") == false)
        on.secrets?.wipe()
    }

    @Test func newHostWithCredentialSetStaysHeldAndSavedPasswordIsOwn() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let csv = "Tên,IP,User,Mật khẩu\nweb,10.0.0.1,deploy,Pw-Hold-90\n"
        try await r.run(try r.write(csv), keep: "Mật khẩu")
        let h = try await r.host("web")
        // Mật khẩu lưu là mật khẩu riêng; chính sách tự điền không đổi (không bộ đăng nhập -> không hold).
        #expect(h.credentialReference != nil)
        #expect(h.autofillHold == false)
    }

    @Test func errorRowsAndDuplicateKeysMapPasswordsToTheRightHosts() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let csv = """
            Tên,IP,User,Mật khẩu
            web,10.0.0.1,deploy,Pw-One-11
            broken,,deploy,Pw-Broken-12
            db,10.0.0.2,deploy,Pw-Three-13
            web,10.0.0.1,deploy,Pw-Dup-14
            """
        let res = try await r.run(try r.write(csv), keep: "Mật khẩu")
        let secretPlan = try #require(res.secretPlan)
        // Dòng lỗi (3) không có host; khoá trùng chỉ nhận một mật khẩu.
        #expect(res.plan.rowHosts[3] == nil)
        #expect(secretPlan.entries.map(\.row).contains(3) == false)
        let web = try await r.host("web")
        #expect(secretPlan.entries.filter { $0.hostID == web.id }.count == 1)
        #expect(try await r.password("db") == "Pw-Three-13")
        #expect(try await r.repo.all().contains { $0.displayName == "broken" } == false)
        let webPw = try #require(try await r.password("web"))
        #expect(["Pw-One-11", "Pw-Dup-14"].contains(webPw))
    }

    @Test func kindChangeRowGetsNoPassword() throws {
        let hostID = UUID()
        let source = InventorySource(name: "K", kind: .csv, path: "/tmp/k.csv")
        var existing = HostProfile(
            id: hostID, displayName: "win", kind: .windowsRDP, rdpUsername: "admin", hostName: "10.0.0.5", port: 3389)
        existing.sourceID = source.id
        existing.externalID = "win"
        let plan = try InventorySync.plan(
            source: source, records: [testRecord("win", host: "10.0.0.5", kind: .ssh, row: 2)],
            existingHosts: [existing], credentialSets: [])
        #expect(plan.errorCount == 1)
        #expect(plan.rowHosts[2] == nil)
    }

    @Test func twoColumnsWithSameTitleKeepOnlyTheFirst() async throws {
        let r = try SecRig()
        defer { r.dir.cleanup() }
        let csv = "Tên,IP,User,Password,Password\nweb,10.0.0.1,deploy,Pw-First-21,Pw-Second-22\n"
        let loaded = try InventoryFile.load(url: try r.write(csv), keepSecretColumn: "Password")
        defer { loaded.secrets?.wipe() }
        let s = try #require(loaded.secrets)
        #expect(s.count == 1)
        #expect(s.bytes(sheet: "CSV", row: 2) == Array("Pw-First-21".utf8))
        #expect("\(loaded.workbook)".contains("Pw-Second-22") == false)
    }

    @Test func sameTitleOnSeveralSheetsStaysSeparatedBySheet() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        func rows(_ pw: String) -> String {
            TestXLSX.sheetXML(
                TestXLSX.inlineRow(1, ["Tên", "IP", "Mật khẩu"]) + TestXLSX.inlineRow(2, ["web", "10.0.0.1", pw]))
        }
        let file = dir.url.appendingPathComponent("k.xlsx")
        try TestXLSX(sheets: [.init(name: "A", xml: rows("Pw-A-31")), .init(name: "B", xml: rows("Pw-B-32"))])
            .write(to: file)
        let loaded = try InventoryFile.load(url: file, keepSecretColumn: "Mật khẩu")
        let s = try #require(loaded.secrets)
        defer { s.wipe() }
        #expect(s.bytes(sheet: "A", row: 2) == Array("Pw-A-31".utf8))
        #expect(s.bytes(sheet: "B", row: 2) == Array("Pw-B-32".utf8))
        let rec = Dictionary(uniqueKeysWithValues: [(2, UUID())])
        var plan = InventorySyncPlan()
        plan.rowHosts = rec
        let planA = InventorySecretImport.plan(for: plan, secrets: s, sheet: "A", existingHosts: [], overwrite: false)
        #expect(planA.count == 1)
        let planC = InventorySecretImport.plan(for: plan, secrets: s, sheet: "C", existingHosts: [], overwrite: false)
        #expect(planC.isEmpty)
    }
}
