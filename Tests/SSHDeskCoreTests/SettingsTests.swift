import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - AppSettings: mặc định, kẹp phạm vi, giá trị hỏng

@Suite struct AppSettingsTests {
    @Test func defaultsMatchADR021() {
        let s = AppSettings.default
        #expect(s.defaultLocalDirectory == "" && s.closeBehavior == .quit && s.warpOpenMode == .tab)
        #expect(s.transferConcurrency == 1 && s.transferHistoryLimit == 500)
        #expect(s.userSSHConfigPath == "" && s.autofillEnabled && s.clipboardClearSeconds == 30)
        #expect(s.analystRetention == 50 && s.analystProbeTimeout.seconds == 3)
        #expect(s.monitorIntervalSeconds == 5)
        #expect(s.monitorThresholds.warning == 80 && s.monitorThresholds.danger == 90)
        #expect(s.rdpFullScreen && !s.rdpMultiMonitor && s.rdpRedirectClipboard)
        // Rỗng / khoá lạ → đúng mặc định.
        #expect(AppSettings(values: [:]) == .default)
        #expect(AppSettings(values: ["khoa.la": "x", "": "y"]) == .default)
    }

    @Test func roundTripThroughValues() {
        var s = AppSettings()
        s.closeBehavior = .keepRunning
        s.warpOpenMode = .window
        s.transferConcurrency = 3
        s.transferHistoryLimit = 0
        s.autofillEnabled = false
        s.clipboardClearSeconds = 90
        s.windowsAutotypePassword = false
        s.analystRetention = 120
        s.analystProbeTimeout = ProbeTimeout(7)
        s.monitorIntervalSeconds = 30
        s.monitorThresholds = MonitorThresholds(warning: 60, danger: 75)
        s.rdpFullScreen = false
        s.rdpMultiMonitor = true
        s.rdpRedirectClipboard = false
        s.defaultLocalDirectory = "/Users/me/Work"
        s.userSSHConfigPath = "/Users/me/custom config"
        #expect(AppSettings(values: s.values) == s)
    }

    @Test func numbersAreClampedAndGarbageFallsBack() {
        func load(_ k: String, _ v: String) -> AppSettings { AppSettings(values: [k: v]) }
        #expect(load("transfer.concurrency", "0").transferConcurrency == 1)
        #expect(load("transfer.concurrency", "99").transferConcurrency == 4)
        #expect(load("transfer.concurrency", "abc").transferConcurrency == 1)
        #expect(load("transfer.concurrency", "").transferConcurrency == 1)
        #expect(load("analyst.retention", "1").analystRetention == 10)
        #expect(load("analyst.retention", "100000").analystRetention == 200)
        #expect(load("analyst.retention", "-5").analystRetention == 10)
        #expect(load("analyst.retention", "1.5").analystRetention == 50)
        #expect(load("analyst.probe_timeout", "0").analystProbeTimeout.seconds == 1)
        #expect(load("analyst.probe_timeout", "999").analystProbeTimeout.seconds == 10)
        #expect(load("analyst.probe_timeout", "3; rm -rf /").analystProbeTimeout.seconds == 3)
        // Tập lựa chọn: ngoài tập → mặc định.
        #expect(load("transfer.history_limit", "250").transferHistoryLimit == 500)
        #expect(load("transfer.history_limit", "0").transferHistoryLimit == 0)
        #expect(load("security.clipboard_clear_seconds", "45").clipboardClearSeconds == 30)
        #expect(load("security.clipboard_clear_seconds", "10").clipboardClearSeconds == 10)
        #expect(load("monitor.interval", "7").monitorIntervalSeconds == 5)
        #expect(load("monitor.interval", "30").monitorIntervalSeconds == 30)
        // Enum / bool lạ.
        #expect(load("general.close_behavior", "explode").closeBehavior == .quit)
        #expect(load("warp.open_mode", "").warpOpenMode == .tab)
        #expect(load("security.autofill_enabled", "maybe").autofillEnabled)
        #expect(!load("security.autofill_enabled", "0").autofillEnabled)
        #expect(!load("security.autofill_enabled", "false").autofillEnabled)
        // ADR-018b: mặc định bật; khoá lưu đúng tên.
        #expect(AppSettings.default.windowsAutotypePassword)
        #expect(load("windows.autotype_password", "maybe").windowsAutotypePassword)
        #expect(!load("windows.autotype_password", "0").windowsAutotypePassword)
        #expect(AppSettings.default.values["windows.autotype_password"] == "1")
    }

    @Test func thresholdsKeepDangerAboveWarning() {
        #expect(MonitorThresholds(warning: 10, danger: 20).warning == 50)
        #expect(MonitorThresholds(warning: 500, danger: 600) == MonitorThresholds(warning: 95, danger: 99))
        let t = MonitorThresholds(warning: 85, danger: 70)  // đỏ <= vàng → đẩy lên vàng + 1
        #expect(t.warning == 85 && t.danger == 86)
        #expect(MonitorThresholds(warning: 95, danger: 95).danger == 96)
        #expect(MonitorThresholds(warning: 60, danger: 1000).danger == 99)
        let s = AppSettings(values: ["monitor.warning": "90", "monitor.danger": "40"])
        #expect(s.monitorThresholds.danger > s.monitorThresholds.warning)
        let bad = AppSettings(values: ["monitor.warning": "x", "monitor.danger": "y"])
        #expect(bad.monitorThresholds == .default)
    }

    @Test func monitorLevelUsesThresholds() {
        let t = MonitorThresholds(warning: 50, danger: 60)
        #expect(MonitorLevel.level(forPercent: 49.9, thresholds: t) == .normal)
        #expect(MonitorLevel.level(forPercent: 50, thresholds: t) == .warning)
        #expect(MonitorLevel.level(forPercent: 60, thresholds: t) == .danger)
        #expect(MonitorLevel.level(forPercent: nil, thresholds: t) == .unknown)
        #expect(MonitorLevel.level(forPercent: 85) == .warning)  // mặc định 80/90
        #expect(MonitorLevel.level(forPercent: 95) == .danger)
    }

    @Test func pathValuesWithControlCharsOrRelativeAreDropped() {
        #expect(AppSettings(values: ["ssh.user_config_path": "relative/config"]).userSSHConfigPath == "")
        #expect(AppSettings(values: ["ssh.user_config_path": "/a\nInclude /etc/passwd"]).userSSHConfigPath == "")
        #expect(AppSettings(values: ["ssh.user_config_path": "/a/%d/config"]).userSSHConfigPath == "")
        #expect(AppSettings(values: ["general.default_local_directory": "~/x"]).defaultLocalDirectory == "")
        #expect(AppSettings(values: ["ssh.user_config_path": "/ok/config"]).userSSHConfigPath == "/ok/config")
    }

    @Test func normalizedClampsDirectAssignments() {
        var s = AppSettings()
        s.transferConcurrency = 50
        s.analystRetention = 1
        s.monitorThresholds = MonitorThresholds(warning: 90, danger: 91)
        s.clipboardClearSeconds = 5
        let n = s.normalized
        #expect(n.transferConcurrency == 4 && n.analystRetention == 10 && n.clipboardClearSeconds == 30)
    }
}

// MARK: - Đường dẫn config người dùng

@Suite struct UserConfigPathTests {
    private func tmp() throws -> (dir: String, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sshdesk-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url.path, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func validationRules() throws {
        let t = try tmp()
        defer { t.cleanup() }
        let file = t.dir + "/config"
        FileManager.default.createFile(atPath: file, contents: Data())
        try AppSettings.validateUserConfigPath(file)
        #expect(throws: AppSettings.ConfigPathError.notAbsolute) {
            try AppSettings.validateUserConfigPath("~/.ssh/config")
        }
        #expect(throws: AppSettings.ConfigPathError.notAbsolute) {
            try AppSettings.validateUserConfigPath("config")
        }
        #expect(throws: AppSettings.ConfigPathError.controlCharacter) {
            try AppSettings.validateUserConfigPath(file + "\nHost *")
        }
        #expect(throws: AppSettings.ConfigPathError.controlCharacter) {
            try AppSettings.validateUserConfigPath(file + "\0")
        }
        #expect(throws: AppSettings.ConfigPathError.unsupportedCharacter) {
            try AppSettings.validateUserConfigPath(t.dir + "/%h/config")
        }
        #expect(throws: AppSettings.ConfigPathError.notFound) {
            try AppSettings.validateUserConfigPath(t.dir + "/nope")
        }
        #expect(throws: AppSettings.ConfigPathError.notAFile) {
            try AppSettings.validateUserConfigPath(t.dir)
        }
    }

    @Test func effectivePathFallsBackToHomeDefaultThenNil() throws {
        let t = try tmp()
        defer { t.cleanup() }
        let home = t.dir + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        var s = AppSettings()
        #expect(s.effectiveUserConfigPath(home: home) == nil)  // ~/.ssh/config chưa có → không Include
        FileManager.default.createFile(atPath: home + "/.ssh/config", contents: Data())
        #expect(s.effectiveUserConfigPath(home: home) == home + "/.ssh/config")
        let custom = t.dir + "/custom"
        FileManager.default.createFile(atPath: custom, contents: Data())
        s.userSSHConfigPath = custom
        #expect(s.effectiveUserConfigPath(home: home) == custom)
        s.userSSHConfigPath = t.dir + "/missing"  // file biến mất → không Include (không đoán)
        #expect(s.effectiveUserConfigPath(home: home) == nil)
    }

    @Test func includeLineFollowsSettingAndNeverInjects() throws {
        let t = try tmp()
        defer { t.cleanup() }
        let custom = t.dir + "/my config"
        FileManager.default.createFile(atPath: custom, contents: Data())
        var s = AppSettings()
        s.userSSHConfigPath = custom
        let out = try SSHConfigWriter.render(
            hosts: [], userConfigPath: s.effectiveUserConfigPath(home: t.dir))
        #expect(out.contains("Include \"\(custom)\""))
        #expect(out.components(separatedBy: "\n").filter { $0.hasPrefix("Include") }.count == 1)
    }

    @Test func localDirectoryFallsBackToDownloads() throws {
        let t = try tmp()
        defer { t.cleanup() }
        var s = AppSettings()
        #expect(s.resolvedLocalDirectory(home: "/Users/x") == "/Users/x/Downloads")
        s.defaultLocalDirectory = t.dir
        #expect(s.resolvedLocalDirectory(home: "/Users/x") == t.dir)
        s.defaultLocalDirectory = t.dir + "/gone"
        #expect(s.resolvedLocalDirectory(home: "/Users/x") == "/Users/x/Downloads")
    }
}

// MARK: - Lưu trữ (migration v7)

@Suite struct SettingsRepositoryTests {
    @Test func migrationV7CreatesSettingsTable() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        #expect(Database.migrations.count >= 7)
        let cols = try db.query("PRAGMA table_info(settings)").compactMap { r -> String? in
            if case .text(let s) = r[1] { return s } else { return nil }
        }
        #expect(cols == ["key", "value"])
    }

    @Test func freshDatabaseLoadsDefaultsAndPersistsChanges() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = SettingsRepository(database: try Database(url: t.dbURL))
        #expect(repo.load() == .default)
        var s = AppSettings()
        s.transferConcurrency = 2
        s.warpOpenMode = .window
        s.monitorThresholds = MonitorThresholds(warning: 70, danger: 85)
        try repo.save(s)
        #expect(repo.load() == s)
        // Ghi lại (upsert) không nhân đôi hàng.
        s.transferConcurrency = 4
        try repo.save(s)
        let again = SettingsRepository(database: try Database(url: t.dbURL))
        #expect(again.load().transferConcurrency == 4)
    }

    @Test func corruptRowsFallBackToDefaultsWithoutCrash() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        try db.execute(
            """
            INSERT INTO settings(key, value) VALUES
              ('transfer.concurrency', 'banana'), ('analyst.retention', '99999'),
              ('security.autofill_enabled', '???'), ('mystery', 'x')
            """)
        let s = SettingsRepository(database: db).load()
        #expect(s.transferConcurrency == 1 && s.analystRetention == 200 && s.autofillEnabled)
    }

    @Test func savingNormalizesOutOfRangeValues() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = SettingsRepository(database: try Database(url: t.dbURL))
        var s = AppSettings()
        s.transferConcurrency = 100
        let saved = try repo.save(s)
        #expect(saved.transferConcurrency == 4 && repo.load().transferConcurrency == 4)
    }

    @Test func storeSharesUpdates() {
        let store = SettingsStore()
        #expect(store.current.autofillEnabled)
        var s = AppSettings()
        s.autofillEnabled = false
        s.transferConcurrency = 77
        store.update(s)
        #expect(!store.current.autofillEnabled && store.current.transferConcurrency == 4)
    }
}

// MARK: - Tự điền tắt

@Test func gatedStoreHidesPasswordOnlyWhenDisabled() throws {
    let base = InMemoryCredentialStore()
    try base.save(ref: "r", password: "pw")
    let flag = SettingsStore()
    let gated = AutofillGatedCredentialStore(base: base) { flag.current.autofillEnabled }
    #expect(gated.read(ref: "r") == "pw")
    var off = AppSettings()
    off.autofillEnabled = false
    flag.update(off)
    #expect(gated.read(ref: "r") == nil)
    #expect(gated.exists(ref: "r"))  // UI vẫn thấy "đã lưu mật khẩu"
    try gated.delete(ref: "r")
    #expect(!base.exists(ref: "r"))
    flag.update(.default)
    try gated.save(ref: "n", password: "x")
    #expect(base.read(ref: "n") == "x")
}

// MARK: - Probe Analyst: whitelist

@Suite struct ProbeTimeoutCommandTests {
    private let ip = IPLiteral("10.0.0.5")!
    private let v6 = IPLiteral("fd00::5")!
    private let port = Port(5432)!

    @Test func clampedIntegerIsTheOnlyThingSpliced() {
        #expect(ProbeTimeout(0).seconds == 1 && ProbeTimeout(-9).seconds == 1)
        #expect(ProbeTimeout(11).seconds == 10 && ProbeTimeout(Int.max).seconds == 10)
        #expect(ProbeTimeout(Int.min).seconds == 1)
        #expect(ProbeTimeout.default.seconds == 3)
        #expect(
            AnalystCommand.probeBash(ip, port, timeout: ProbeTimeout(7)).commandString
                == "timeout 7 bash -c '</dev/tcp/10.0.0.5/5432'")
        #expect(
            AnalystCommand.probeNc(ip, port, timeout: ProbeTimeout(10)).commandString
                == "nc -z -w10 10.0.0.5 5432")
        #expect(
            AnalystCommand.probeNc(v6, port, timeout: ProbeTimeout(2)).commandString
                == "nc -z -w2 -6 fd00::5 5432")
        #expect(AnalystCommand.probeBash(v6, port, timeout: ProbeTimeout(2)).commandString == nil)
        // Mặc định giữ nguyên chuỗi cũ (3 giây).
        #expect(
            AnalystCommand.probeBash(ip, port).commandString
                == "timeout 3 bash -c '</dev/tcp/10.0.0.5/5432'")
        #expect(AnalystCommand.probeNc(ip, port).commandString == "nc -z -w3 10.0.0.5 5432")
    }

    @Test func everyTimeoutProducesOnlyWhitelistedShape() {
        for n in -3...15 {
            let t = ProbeTimeout(n)
            let bash = AnalystCommand.probeBash(ip, port, timeout: t).commandString!
            let nc = AnalystCommand.probeNc(ip, port, timeout: t).commandString!
            #expect(
                bash.range(
                    of: #"^timeout (10|[1-9]) bash -c '</dev/tcp/10\.0\.0\.5/5432'$"#, options: .regularExpression)
                    != nil)
            #expect(nc.range(of: #"^nc -z -w(10|[1-9]) 10\.0\.0\.5 5432$"#, options: .regularExpression) != nil)
        }
    }

    @Test func templatesFollowTimeout() {
        let t = AnalystCommand.probeTemplates(timeout: ProbeTimeout(6))
        #expect(t.bash == "timeout 6 bash -c '</dev/tcp/<IP đích>/<cổng>'")
        #expect(t.nc == "nc -z -w6 <IP đích> <cổng>")
    }

    @Test func presentationShowsConfiguredTimeout() {
        #expect(AnalystPresentation.timeText(.failed(.timeout)) == "3.0 s")
        #expect(AnalystPresentation.timeText(.failed(.timeout), timeout: ProbeTimeout(8)) == "8.0 s")
    }
}

// MARK: - Retention đổi lúc chạy

@Suite struct SettingsApplyTests {
    @Test func transferRetentionChangesAndZeroMeansUnlimited() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = TransferRepository(database: try Database(url: t.dbURL), retention: 500)
        await repo.setRetention(2)
        for _ in 0..<5 { try await repo.insert(sampleJob(state: .completed)) }
        #expect(try await repo.history().count == 2)
        await repo.setRetention(1)  // hạ giới hạn → cắt bớt ngay, vẫn giữ mục mới nhất
        #expect(try await repo.history().count == 1)
        await repo.setRetention(0)  // không giới hạn
        for _ in 0..<5 { try await repo.insert(sampleJob(state: .completed)) }
        #expect(try await repo.history().count == 6)
        #expect(try await repo.history(limit: 3).count == 3)
    }

    @Test func analystRetentionIsChangeable() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = AnalystRunRepository(database: try Database(url: t.dbURL), retention: 50)
        await repo.setRetention(0)  // luôn >= 1
        // Không có API đọc retention; chỉ cần không crash và vẫn hoạt động.
        #expect(try await repo.list(folder: "x").isEmpty)
    }
}

// MARK: - ConnectionService theo cài đặt

private final class RecordingWarp: WarpURLHandler, @unchecked Sendable {
    var opened: [URL] = []
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return true
    }
}

private final class SettingsPasteboard: SecretPasteboard, @unchecked Sendable {
    var changeCount = 0
    var string: String?
    func clearContents() -> Int {
        string = nil
        changeCount += 1
        return changeCount
    }
    func write(string: String, markerTypes: [String]) -> Int {
        self.string = string
        changeCount += 1
        return changeCount
    }
}

private final class DelayRecorder: @unchecked Sendable {
    var delays: [TimeInterval] = []
    var scheduler: SecretClipboard.Scheduler {
        { [self] delay, _ in
            delays.append(delay)
            return {}
        }
    }
}

private struct SettingsRig {
    let t = HostTempDir()
    let warp = RecordingWarp()
    let store = InMemoryCredentialStore()
    let settings: SettingsStore
    let timers = DelayRecorder()
    let pasteboard = SettingsPasteboard()
    let paths: AppPaths
    let service: ConnectionService

    init(_ initial: AppSettings = .default, helper: Bool = true) throws {
        settings = SettingsStore(initial)
        paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        let rdpHandler = StubWindowsApp()
        service = ConnectionService(
            repository: HostRepository(database: try Database(url: paths.databaseURL)),
            appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: t.url.appendingPathComponent("tabs"), handler: warp),
            rdpLauncher: WindowsAppLauncher(
                directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: rdpHandler),
            credentials: store,
            secretClipboard: SecretClipboard(pasteboard: pasteboard, scheduler: timers.scheduler),
            askpassHelper: helper ? URL(fileURLWithPath: "/Applications/SSH Desk.app/askpass") : nil,
            settings: settings)
    }
}

private final class StubWindowsApp: WindowsAppHandler, @unchecked Sendable {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

@Suite struct ServiceSettingsTests {
    @Test func warpUsesTabByDefaultWindowWhenSetAndExplicitWins() async throws {
        let r = try SettingsRig()
        defer { r.t.cleanup() }
        let h = managedHost()
        try await r.service.add(h)
        _ = await r.service.openInWarp(h)
        #expect(r.warp.opened.last?.absoluteString.contains("new_window") == false)
        var s = AppSettings()
        s.warpOpenMode = .window
        r.settings.update(s)
        _ = await r.service.openInWarp(h)
        #expect(r.warp.opened.last?.absoluteString.hasSuffix("?new_window=true") == true)
        _ = await r.service.openInWarp(h, newWindow: false)  // tham số tường minh thắng cài đặt
        #expect(r.warp.opened.last?.absoluteString.contains("new_window") == false)
    }

    @Test func autofillOffMeansNoAskpassReferenceInWarpCommand() async throws {
        let r = try SettingsRig()
        defer { r.t.cleanup() }
        var h = managedHost()
        h.credentialReference = "ref-1"
        try r.store.save(ref: "ref-1", password: "S3cret-pw")
        try await r.service.add(h)
        let on = try await r.service.warpSSHCommand(for: h)
        #expect(on.command.contains("SSHDESK_HOST_REF") && on.notice == nil)
        var s = AppSettings()
        s.autofillEnabled = false
        r.settings.update(s)
        let off = try await r.service.warpSSHCommand(for: h)
        #expect(!off.command.contains("SSHDESK_HOST_REF") && !off.command.contains("SSH_ASKPASS"))
        #expect(!off.command.contains("ref-1") && !off.command.contains("S3cret-pw"))
        #expect(off.notice != nil)
        let plain = try await r.service.copyableSSHCommand(for: h)
        #expect(off.command == plain)
    }

    @Test func windowsClipboardHonoursSecondsAndAutofillOff() async throws {
        let r = try SettingsRig()
        defer { r.t.cleanup() }
        let w = HostProfile(
            displayName: "Win", kind: .windowsRDP, rdpUsername: "CORP\\a", hostName: "10.0.0.5", port: 3389)
        try await r.service.add(w)
        try await r.service.savePassword(hostID: w.id, password: "pw-win")
        #expect(await r.service.copyStoredWindowsPassword(w) == .copied)
        #expect(r.timers.delays == [30])
        var s = AppSettings()
        s.clipboardClearSeconds = 90
        r.settings.update(s)
        #expect(await r.service.copyStoredWindowsPassword(w) == .copied)
        #expect(r.timers.delays == [30, 90])
        s.autofillEnabled = false
        r.settings.update(s)
        r.pasteboard.string = nil
        #expect(await r.service.copyStoredWindowsPassword(w) == .disabled)
        #expect(r.pasteboard.string == nil)
        #expect(r.timers.delays.count == 2)
        let report = await r.service.openInWindowsAppReport(w)
        #expect(report.passwordCopy == .disabled && r.pasteboard.string == nil)
    }

    @Test func includeFollowsSettingsAndChangesRegenerate() async throws {
        let r = try SettingsRig()
        defer { r.t.cleanup() }
        let cfg = r.t.url.appendingPathComponent("my-config").path
        FileManager.default.createFile(atPath: cfg, contents: Data())
        try await r.service.regenerateSSHConfig()
        var text = try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)
        // ~/.ssh/config thật của máy có thể có hoặc không; chỉ cần KHÔNG chứa file tuỳ chỉnh.
        #expect(!text.contains(cfg))
        var s = AppSettings()
        s.userSSHConfigPath = cfg
        r.settings.update(s)
        try await r.service.regenerateSSHConfig()
        text = try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)
        #expect(text.contains("Include \"\(cfg)\""))
        // File biến mất → không Include dòng nào trỏ vào nó.
        try FileManager.default.removeItem(atPath: cfg)
        try await r.service.regenerateSSHConfig()
        text = try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)
        #expect(!text.contains(cfg))
    }

    @Test func clearAllPasswordsRemovesKeychainItemsAndReferences() async throws {
        let r = try SettingsRig()
        defer { r.t.cleanup() }
        let a = managedHost("a", hostName: "a.example.com")
        let b = managedHost("b", hostName: "b.example.com")
        let none = managedHost("c", hostName: "c.example.com")
        for h in [a, b, none] { try await r.service.add(h) }
        try await r.service.savePassword(hostID: a.id, password: "pw-a")
        try await r.service.savePassword(hostID: b.id, password: "pw-b")
        // Item Keychain KHÔNG thuộc host nào: không được đụng tới.
        try r.store.save(ref: "unrelated", password: "keep-me")
        #expect(try await r.service.savedPasswordCount() == 2)

        let res = try await r.service.clearAllPasswords()
        #expect(res == PasswordPurgeResult(removed: 2, failed: 0))
        #expect(try await r.service.savedPasswordCount() == 0)
        for id in [a.id, b.id, none.id] {
            let h = try #require(try await r.service.repository.host(id: id))
            #expect(h.credentialReference == nil)
        }
        #expect(r.store.read(ref: "unrelated") == "keep-me")
        // Chạy lần nữa không làm gì.
        #expect(try await r.service.clearAllPasswords() == PasswordPurgeResult(removed: 0, failed: 0))
    }

    @Test func clearAllPasswordsThrowsWithoutCredentialStoreAndKeepsReferences() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        let repo = HostRepository(database: try Database(url: paths.databaseURL))
        let service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: t.url.appendingPathComponent("tabs"), handler: RecordingWarp()),
            credentials: nil)
        var h = managedHost("a", hostName: "a.example.com")
        h.credentialReference = "ref-a"
        try await service.add(h)
        await #expect(throws: ConnectionServiceError.credentialsUnavailable) {
            try await service.clearAllPasswords()
        }
        let kept = try #require(try await repo.host(id: h.id))
        #expect(kept.credentialReference == "ref-a")
    }

    @Test func newHostDraftTakesRDPDefaults() {
        var s = AppSettings()
        s.rdpFullScreen = false
        s.rdpMultiMonitor = true
        s.rdpRedirectClipboard = false
        let d = HostDraft(newHostDefaults: s)
        #expect(d.rdpScreenMode == .window && d.rdpMultiMonitor && !d.rdpRedirectClipboard)
        let plain = HostDraft(newHostDefaults: .default)
        #expect(plain.rdpScreenMode == .fullScreen && !plain.rdpMultiMonitor && plain.rdpRedirectClipboard)
        #expect(plain == HostDraft())
    }
}
