import Foundation
import Testing

@testable import SSHDeskCore

private final class HoldWarp: WarpURLHandler, @unchecked Sendable {
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
}

private final class HoldPasteboard: SecretPasteboard, @unchecked Sendable {
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

private struct HoldWindowsApp: WindowsAppHandler {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

private struct HoldRig {
    let dir = HostTempDir()
    let store = InMemoryCredentialStore()
    let pasteboard = HoldPasteboard()
    let paths: AppPaths
    let repo: HostRepository
    let service: ConnectionService
    let source = InventorySource(name: "Khách", kind: .csv, path: "/tmp/k.csv")

    init() throws {
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: HoldWarp()),
            rdpLauncher: WindowsAppLauncher(
                directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: HoldWindowsApp()),
            credentials: store, secretClipboard: SecretClipboard(pasteboard: pasteboard, scheduler: { _, _ in {} }),
            askpassHelper: URL(fileURLWithPath: "/Applications/SSH Desk.app/Contents/MacOS/sshdesk-askpass"),
            settings: SettingsStore(.default))
    }

    func sync(_ records: [InventoryRecord]) async throws {
        let plan = try InventorySync.plan(
            source: source, records: records, existingHosts: try await repo.all(),
            credentialSets: try await repo.credentialSets(), fingerprint: "fp")
        try await service.applyInventory(plan)
    }

    func host(_ name: String) async throws -> HostProfile {
        try #require(try await repo.all().first { $0.displayName == name })
    }
}

@Suite struct InventoryHoldAutofillTests {
    @Test func sshAddressChangeStopsEveryAutofillPathUntilConfirmed() async throws {
        let r = try HoldRig()
        defer { r.dir.cleanup() }
        try await r.sync([testRecord("web")])
        var web = try await r.host("web")
        web.authMethod = .interactive
        try await r.repo.update(web)
        web = try await r.service.savePassword(hostID: web.id, password: "Pw-Zq9-secret")
        #expect(web.autofillCredentialReference == web.credentialReference && web.credentialReference != nil)

        // Trước khi đổi: tự điền và askpass hoạt động.
        let prompt = "deploy@10.0.0.1's password: "
        #expect(PasswordAutofillPolicy.shouldAutofill(promptText: prompt, host: web, alreadyFilled: false))
        var warp = try await r.service.warpSSHCommand(for: web)
        #expect(warp.command.contains("SSHDESK_HOST_REF="))

        // Nguồn đổi IP -> hold.
        try await r.sync([testRecord("web", host: "10.0.0.99")])
        let held = try await r.host("web")
        #expect(held.autofillHold && held.hostName == "10.0.0.99")
        #expect(held.autofillHoldReason?.contains("10.0.0.1 → 10.0.0.99") == true)
        #expect(held.credentialReference == web.credentialReference)  // password riêng vẫn còn, chỉ bị chặn dùng
        #expect(held.autofillCredentialReference == nil)
        #expect(
            !PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@10.0.0.99's password: ", host: held, alreadyFilled: false))
        warp = try await r.service.warpSSHCommand(for: held)
        #expect(!warp.command.contains("SSHDESK_") && !warp.command.contains("SSH_ASKPASS"))
        #expect(!warp.command.contains("Pw-Zq9-secret") && warp.notice != nil)

        // Xác nhận -> dùng lại.
        try await r.service.confirmAutofillHold(hostID: held.id)
        let ok = try await r.host("web")
        #expect(!ok.autofillHold)
        #expect(
            PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@10.0.0.99's password: ", host: ok, alreadyFilled: false))
        warp = try await r.service.warpSSHCommand(for: ok)
        #expect(warp.command.contains("SSHDESK_HOST_REF="))
        // Config của app được sinh lại với địa chỉ mới.
        let config = try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)
        #expect(config.contains("10.0.0.99") && !config.contains("\"10.0.0.1\""))
    }

    @Test func windowsClipboardRespectsSourceHold() async throws {
        let r = try HoldRig()
        defer { r.dir.cleanup() }
        try await r.sync([testRecord("win", port: 3389, kind: .windowsRDP)])
        var w = try await r.host("win")
        w.authMethod = .interactive
        try await r.repo.update(w)
        w = try await r.service.savePassword(hostID: w.id, password: "Win-Pw-1")
        #expect(await r.service.copyStoredWindowsPassword(w) == .copied)
        r.pasteboard.clearContents()
        try await r.sync([testRecord("win", host: "10.7.7.7", port: 3389, kind: .windowsRDP)])
        let held = try await r.host("win")
        #expect(held.autofillHold)
        #expect(await r.service.copyStoredWindowsPassword(held) == .held)
        #expect(r.pasteboard.string == nil)
        try await r.service.confirmAutofillHold(hostID: held.id)
        let ok = try await r.host("win")
        #expect(await r.service.copyStoredWindowsPassword(ok) == .copied)
        #expect(r.pasteboard.string == "Win-Pw-1")
    }

    @Test func setAssignedFromSourceHoldsAskpassAndPolicyEvenOnNewHost() async throws {
        let r = try HoldRig()
        defer { r.dir.cleanup() }
        let set = try await r.service.createCredentialSet(CredentialSet(name: "Team"), password: "Set-Pw-7")
        try await r.sync([testRecord("web", set: "Team")])
        let web = try await r.host("web")
        #expect(web.credentialSetID == set.id && web.autofillHold)
        #expect(
            !PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@10.0.0.1's password: ", host: web, alreadyFilled: false))
        var warp = try await r.service.warpSSHCommand(for: web)
        #expect(!warp.command.contains("SSHDESK_") && warp.notice != nil)
        try await r.service.confirmAutofillHold(hostID: web.id)
        let ok = try await r.host("web")
        #expect(
            PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@10.0.0.1's password: ", host: ok, alreadyFilled: false))
        warp = try await r.service.warpSSHCommand(for: ok)
        #expect(warp.command.contains("SSHDESK_HOST_REF='\(set.passwordReference)'"))
        #expect(!warp.command.contains("Set-Pw-7"))
    }

    @Test func nonAddressChangeKeepsAutofillWorking() async throws {
        let r = try HoldRig()
        defer { r.dir.cleanup() }
        try await r.sync([testRecord("web", env: .dev)])
        var web = try await r.host("web")
        web.authMethod = .interactive
        try await r.repo.update(web)
        _ = try await r.service.savePassword(hostID: web.id, password: "pw")
        try await r.sync([testRecord("web", env: .prod, folder: "Mới")])
        let after = try await r.host("web")
        #expect(!after.autofillHold && after.environment == .prod)
        let warp = try await r.service.warpSSHCommand(for: after)
        #expect(warp.command.contains("SSHDESK_HOST_REF="))
    }
}

// MARK: - Đồng bộ lại từ file

@Suite struct InventoryResyncTests {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func csvSourceResyncsWithSavedMappingAndFlagsRenamedHeaders() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let file = dir.url.appendingPathComponent("khach.csv")
        try write(
            "Tên server,Địa chỉ IP,User,Mật khẩu\nweb,10.0.0.1,deploy,Sup3r-Pw\ndb,10.0.0.2,dba,Sup3r-Pw2\n", to: file)
        let env = try Database(url: dir.dbURL)
        let repo = HostRepository(database: env)

        // Lần đầu: đoán cột, lưu nguồn.
        let loaded = try InventoryFile.load(url: file)
        #expect(loaded.template == nil && loaded.kind == .csv)
        let sheet = loaded.workbook.sheets[0]
        #expect(sheet.passwordColumns == [3: "Mật khẩu"])
        let guess = TableMapping.guess(sheet: sheet, restrictTo: InventoryField.freeMappingFields)
        let src = InventorySource(name: "Khách", kind: .csv, path: file.path)
        let parsed = try #require(try InventoryFile.parse(loaded, mapping: guess))
        #expect(parsed.result.records.count == 2 && parsed.result.issues.isEmpty)
        let plan = try InventoryFile.plan(
            source: src, loaded: loaded, parsed: parsed, existingHosts: [], credentialSets: [])
        try await repo.applyInventory(plan)
        let saved = try #require(try await repo.inventorySource(id: src.id))
        #expect(saved.tableMapping == guess && saved.lastFingerprint == loaded.fingerprint)
        #expect(!(saved.configJSON.contains("Sup3r")))
        #expect(!"\(plan)".contains("Sup3r"))

        // Không đổi file -> không phát hiện thay đổi, kế hoạch rỗng.
        #expect(
            InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: saved.lastFingerprint)
                == .unchanged)
        guard
            case .ready(_, let same) = try InventoryFile.resync(
                source: saved, existingHosts: try await repo.all(), credentialSets: [])
        else {
            Issue.record("cần .ready")
            return
        }
        #expect(!same.hasChanges && same.unchangedCount == 2)

        // Khách gửi file mới (đổi IP, thêm máy, bỏ một máy): phát hiện + diff.
        try write("Tên server,Địa chỉ IP,User,Mật khẩu\nweb,10.0.0.77,deploy,x\napp,10.0.0.3,app,y\n", to: file)
        let changed = InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: saved.lastFingerprint)
        #expect(changed == .changed)
        guard
            case .ready(_, let diff) = try InventoryFile.resync(
                source: saved, existingHosts: try await repo.all(), credentialSets: [])
        else {
            Issue.record("cần .ready")
            return
        }
        #expect(diff.additions.map(\.host.displayName) == ["app"])
        #expect(diff.updates.first?.holdReason?.contains("10.0.0.1 → 10.0.0.77") == true)
        #expect(diff.missing.map(\.displayName) == ["db"])
        #expect(!"\(diff)".contains("Sup3r") && !"\(diff)".contains("\"x\""))

        // Tiêu đề đổi -> mở lại màn ghép cột (không áp dụng bừa).
        try write("Tên server,Máy,User\nweb,10.0.0.77,deploy\n", to: file)
        guard
            case .needsRemap(_, _, let suggested, let reason) = try InventoryFile.resync(
                source: saved, existingHosts: try await repo.all(), credentialSets: [])
        else {
            Issue.record("cần .needsRemap")
            return
        }
        #expect(reason.contains("Địa chỉ IP") && suggested.header(for: .hostName) == nil)

        // Chọn file mới cho nguồn (pathOverride) giữ cùng cách ghép.
        let other = dir.url.appendingPathComponent("moi.csv")
        try write("Tên server,Địa chỉ IP,User\nweb,10.0.0.9,deploy\n", to: other)
        guard
            case .ready(let l2, let p2) = try InventoryFile.resync(
                source: saved, pathOverride: other, existingHosts: try await repo.all(), credentialSets: [])
        else {
            Issue.record("cần .ready")
            return
        }
        #expect(p2.source?.path == other.path && l2.url == other)
        #expect(p2.updates.first?.changes.contains { $0.label == "IP/Hostname" } == true)
    }

    @Test func detectChangeUsesMTimeThenHashAndReportsMissingFile() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let file = dir.url.appendingPathComponent("a.csv")
        try write("Tên,IP\na,1.1.1.1\n", to: file)
        let fp = try InventoryFile.fingerprint(of: file, kind: .csv)
        #expect(fp.split(separator: "|").count == 3 && fp.split(separator: "|")[0].count == 64)
        #expect(InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: fp) == .unchanged)
        // mtime đổi nhưng nội dung giống -> không đổi.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: file.path)
        #expect(InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: fp) == .unchanged)
        // Nội dung đổi -> đổi.
        try write("Tên,IP\na,2.2.2.2\n", to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: file.path)
        #expect(InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: fp) == .changed)
        #expect(InventoryFile.detectChange(path: file.path, kind: .csv, lastFingerprint: nil) == .changed)
        #expect(
            InventoryFile.detectChange(
                path: dir.url.appendingPathComponent("none.csv").path, kind: .csv, lastFingerprint: fp) == .fileMissing)
    }

    @Test func templateFileSkipsMappingAndSyncsEndToEnd() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let sheetRows =
            TestXLSX.inlineRow(1, InventoryTemplateFormat.headers)
            + TestXLSX.inlineRow(
                2, ["web-01", "10.0.0.5", "22", "deploy", "PROD", "Khách A", "SSH", "", "Team A", "Máy web"])
            + TestXLSX.inlineRow(3, ["bastion", "203.0.113.5", nil, "admin", "PROD", "Khách A", nil, nil, nil, nil])
            + TestXLSX.inlineRow(4, ["web-02", "10.0.0.6", nil, "deploy", "UAT", "Khách A", nil, "bastion", nil, nil])
        let file = dir.url.appendingPathComponent("mau.xlsx")
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try TestXLSX(sheets: [.init(name: "Máy chủ", xml: TestXLSX.sheetXML(sheetRows))]).write(to: file)
        let loaded = try InventoryFile.load(url: file)
        #expect(loaded.template != nil)
        let parsed = try #require(try InventoryFile.parse(loaded, mapping: nil))
        #expect(parsed.mapping.isTemplate && parsed.result.issues.isEmpty && parsed.result.records.count == 3)
        let repo = HostRepository(database: try Database(url: dir.dbURL))
        let src = InventorySource(name: "Mẫu", kind: .excel, path: file.path)
        let plan = try InventoryFile.plan(
            source: src, loaded: loaded, parsed: parsed, existingHosts: [], credentialSets: [])
        #expect(plan.setsToCreate == ["Team A"] && plan.holdCount == 1)
        try await repo.applyInventory(plan)
        let hosts = try await repo.all()
        #expect(hosts.count == 3)
        let web2 = try #require(hosts.first { $0.displayName == "web-02" })
        let bastion = try #require(hosts.first { $0.displayName == "bastion" })
        #expect(web2.jumpHostID == bastion.id && web2.environment == .uat && web2.project == "Khách A")
        #expect(hosts.first { $0.displayName == "web-01" }?.autofillHold == true)
        #expect(hosts.first { $0.displayName == "web-01" }?.notes == "Máy web")
        #expect(bastion.port == 22 && !bastion.autofillHold)
        // Bật lại qua resync: không có thay đổi.
        let saved = try #require(try await repo.inventorySource(id: src.id))
        guard
            case .ready(_, let again) = try InventoryFile.resync(
                source: saved, existingHosts: hosts, credentialSets: try await repo.credentialSets())
        else {
            Issue.record("cần .ready")
            return
        }
        #expect(!again.hasChanges)
    }
}

// MARK: - CLI template

@Suite struct InventoryCLITemplateTests {
    @Test func parsesTemplateCommandStrictly() throws {
        #expect(try CLIArguments.parse(["template", "docs/x.xlsx"]) == .template(path: "docs/x.xlsx"))
        for bad in [
            ["template"], ["template", "a.xlsx", "b"], ["template", "-o.xlsx"], ["template", "a.txt"],
            ["template", "a\u{1b}.xlsx"],
        ] {
            #expect(throws: CLIParseError.self, "\(bad)") { try CLIArguments.parse(bad) }
        }
        #expect(CLIArguments.usage.contains("template"))
    }

    @Test func writerNeverOverwritesExistingFile() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let url = dir.url.appendingPathComponent("mau.xlsx")
        try InventoryTemplate.write(to: url)
        let first = try Data(contentsOf: url)
        #expect(first.count > 1000)
        #expect(throws: InventoryTemplateError.self) { try InventoryTemplate.write(to: url) }
        #expect(try Data(contentsOf: url) == first)
        // Symlink treo cũng không bị ghi xuyên qua.
        let link = dir.url.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: dir.url.appendingPathComponent("target.xlsx"))
        #expect(throws: InventoryTemplateError.self) { try InventoryTemplate.write(to: link) }
        #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("target.xlsx").path))
    }

    @Test func repoTemplateFileIsReadableByOurReader() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/templates/sshdesk-hosts-template.xlsx")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let loaded = try InventoryFile.load(url: url)
        #expect(loaded.template != nil)
        #expect(loaded.workbook.sheets.map(\.name) == ["Máy chủ", "Hướng dẫn"])
    }
}
