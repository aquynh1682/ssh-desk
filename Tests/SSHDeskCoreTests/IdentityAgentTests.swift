import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - Validator (ADR-024)

@Suite struct IdentityAgentValidatorTests {
    @Test(arguments: [
        "SSH_AUTH_SOCK",
        "/var/run/agent.sock",
        "~/.bitwarden-ssh-agent.sock",
        "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock",
        "/tmp/a\"b\\c.sock",
        "/tmp/đường dẫn/agent.sock",
    ])
    func accepts(_ value: String) throws {
        try IdentityAgentPath.validate(value)
    }

    @Test(arguments: [
        ("", IdentityAgentError.empty),
        ("/tmp/a\nProxyCommand evil", .controlCharacter),
        ("/tmp/a\rb", .controlCharacter),
        ("/tmp/a\u{0}b", .controlCharacter),
        ("/tmp/a\u{7F}b", .controlCharacter),
        ("/tmp/a\u{1B}[0m", .controlCharacter),
        ("/tmp/a\u{85}b", .controlCharacter),
        ("/tmp/a\tb", .controlCharacter),
        ("relative/agent.sock", .badPrefix),
        ("~agent.sock", .badPrefix),
        ("ssh_auth_sock", .badPrefix),
        ("SSH_AUTH_SOCK ", .badPrefix),
        ("none", .badPrefix),
        ("/tmp/%d/agent", .forbiddenCharacter),
        ("/tmp/$HOME/agent", .forbiddenCharacter),
        ("~/${X}", .forbiddenCharacter),
    ])
    func rejects(_ value: String, _ error: IdentityAgentError) {
        #expect(throws: error) { try IdentityAgentPath.validate(value) }
    }

    @Test func lengthLimitIsInBytes() throws {
        try IdentityAgentPath.validate("/" + String(repeating: "a", count: 1023))
        #expect(throws: IdentityAgentError.tooLong) {
            try IdentityAgentPath.validate("/" + String(repeating: "a", count: 1024))
        }
        // 'đ' = 2 byte: 512 ký tự = 1024 byte + '/' vượt giới hạn dù chỉ 513 ký tự.
        #expect(throws: IdentityAgentError.tooLong) {
            try IdentityAgentPath.validate("/" + String(repeating: "đ", count: 512))
        }
    }

    @Test func warningsAreAdvisoryOnly() {
        let env = ["SSH_AUTH_SOCK": "/tmp/sys.sock"]
        #expect(
            IdentityAgentPath.warnings(for: "~/a.sock", home: "/Users/me", environment: env, exists: { _ in false })
                == [.socketMissing(path: "/Users/me/a.sock")])
        #expect(
            IdentityAgentPath.warnings(
                for: "~/a.sock", home: "/Users/me", environment: env, exists: { $0 == "/Users/me/a.sock" }
            )
            .isEmpty)
        let long = "/" + String(repeating: "a", count: 110)
        #expect(
            IdentityAgentPath.warnings(for: long, environment: env, exists: { _ in true })
                == [.pathTooLong(bytes: 111)])
        #expect(IdentityAgentPath.warnings(for: "SSH_AUTH_SOCK", environment: env, exists: { _ in true }).isEmpty)
        #expect(
            IdentityAgentPath.warnings(for: "SSH_AUTH_SOCK", environment: [:], exists: { _ in true }) == [
                .systemVariableMissing
            ])
        #expect(IdentityAgentPath.warnings(for: "bad", exists: { _ in false }).isEmpty)
    }

    @Test func presetsMatchStoredValues() {
        #expect(IdentityAgentPreset.matching("SSH_AUTH_SOCK") == .system)
        #expect(IdentityAgentPreset.matching("~/.bitwarden-ssh-agent.sock") == .bitwarden)
        #expect(IdentityAgentPreset.matching("/x/y") == .custom)
        for p in IdentityAgentPreset.allCases {
            if let path = p.path { #expect(IdentityAgentPath.isValid(path)) }
        }
    }
}

// MARK: - Giá trị hiệu lực

@Suite struct IdentityAgentResolutionTests {
    @Test func hostBeatsDefault() {
        #expect(IdentityAgentResolution.effective(host: "/h.sock", settingsDefault: "/d.sock") == "/h.sock")
        #expect(IdentityAgentResolution.effective(host: nil, settingsDefault: "/d.sock") == "/d.sock")
        #expect(IdentityAgentResolution.effective(host: nil, settingsDefault: "") == nil)
        #expect(IdentityAgentResolution.effective(host: nil, settingsDefault: nil) == nil)
        // Host chọn "Hệ thống" thắng mặc định của Cài đặt và được ghi nguyên văn.
        #expect(
            IdentityAgentResolution.effective(host: "SSH_AUTH_SOCK", settingsDefault: "/d.sock")
                == "SSH_AUTH_SOCK")
    }

    @Test func layersAreExtensibleForSets() {
        #expect(IdentityAgentResolution.effective(layers: [nil, "/set.sock", "/d.sock"]) == "/set.sock")
        #expect(IdentityAgentResolution.effective(layers: ["/h.sock", "/set.sock", "/d.sock"]) == "/h.sock")
        #expect(IdentityAgentResolution.effective(layers: [nil, "", nil]) == nil)
    }
}

// MARK: - Model + Settings

@Suite struct IdentityAgentModelTests {
    @Test func hostProfileRejectsInjection() {
        var h = managedHost()
        h.identityAgent = "/tmp/a.sock\n    ProxyCommand touch /tmp/pwned"
        #expect(throws: HostValidationError.invalidIdentityAgent(.controlCharacter)) { try h.validate() }
        h.identityAgent = ""
        #expect(throws: HostValidationError.invalidIdentityAgent(.empty)) { try h.validate() }
        h.identityAgent = "/ok.sock"
        #expect(throws: Never.self) { try h.validate() }
    }

    @Test func settingsKeyValidatesAndFallsBackToEmpty() {
        #expect(AppSettings.default.defaultIdentityAgent == "")
        #expect(AppSettings(values: ["ssh.default_identity_agent": "/a.sock"]).defaultIdentityAgent == "/a.sock")
        for bad in ["relative", "/a\nProxyCommand x", "/a%d", "$HOME", ""] {
            #expect(AppSettings(values: ["ssh.default_identity_agent": bad]).defaultIdentityAgent == "")
        }
        var s = AppSettings()
        s.defaultIdentityAgent = "/x\ny"
        #expect(s.normalized.defaultIdentityAgent == "")
        s.defaultIdentityAgent = "~/ok.sock"
        #expect(AppSettings(values: s.values).defaultIdentityAgent == "~/ok.sock")
    }

    @Test func draftMapsPresetsAndCustom() {
        var d = HostDraft()
        d.displayName = "x"
        d.hostName = "h.example.com"
        d.user = "u"
        #expect(d.profile(basedOn: nil).identityAgent == nil)
        d.identityAgentPreset = .system
        #expect(d.profile(basedOn: nil).identityAgent == "SSH_AUTH_SOCK")
        d.identityAgentPreset = .custom
        d.identityAgentCustom = "  /my.sock  "
        #expect(d.profile(basedOn: nil).identityAgent == "/my.sock")
        #expect(d.errors(basedOn: nil).isEmpty)
        d.identityAgentCustom = "nope"
        #expect(d.errors(basedOn: nil)[.identityAgent] != nil)
        d.identityAgentCustom = ""
        #expect(d.errors(basedOn: nil)[.identityAgent] != nil)
        // Windows: không lưu agent.
        d.identityAgentCustom = "/my.sock"
        d.setKind(.windowsRDP)
        #expect(d.profile(basedOn: nil).identityAgent == nil)
        // Nạp lại từ host: preset được nhận diện, giá trị lạ vào ô tuỳ chỉnh.
        var h = managedHost()
        h.identityAgent = "~/.bitwarden-ssh-agent.sock"
        #expect(HostDraft(host: h).identityAgentPreset == .bitwarden)
        h.identityAgent = "/z.sock"
        let back = HostDraft(host: h)
        #expect(back.identityAgentPreset == .custom && back.identityAgentCustom == "/z.sock")
    }
}

// MARK: - Writer

@Suite struct IdentityAgentWriterTests {
    func spec(agent: String?) -> SSHHostSpec {
        SSHHostSpec(
            alias: "sshdesk-bbbbbbbb-0000-0000-0000-000000000002", hostName: "10.0.0.5", user: "deploy",
            identityAgent: agent)
    }

    @Test func writesQuotedDirectiveAfterIdentityFile() throws {
        var s = spec(agent: "~/Library/x y/agent.sock")
        s.identityFile = "/k"
        let out = try SSHConfigWriter.render(hosts: [s], userConfigPath: nil)
        #expect(
            out.contains(
                "    IdentitiesOnly yes\n    IdentityAgent \"~/Library/x y/agent.sock\"\n"))
        #expect(!(try SSHConfigWriter.render(hosts: [spec(agent: nil)], userConfigPath: nil)).contains("IdentityAgent"))
    }

    @Test func systemValueIsWrittenVerbatim() throws {
        let out = try SSHConfigWriter.render(hosts: [spec(agent: "SSH_AUTH_SOCK")], userConfigPath: nil)
        #expect(out.contains("    IdentityAgent \"SSH_AUTH_SOCK\"\n"))
    }

    @Test(arguments: [
        "/a.sock\n    ProxyCommand touch /tmp/pwned",
        "/a.sock\r\nProxyCommand x",
        "/a\u{0}",
        "relative",
        "/a%h",
        "/a$X",
        "",
    ])
    func writerRejectsInjectionAndNothingIsWritten(_ value: String) throws {
        #expect(throws: SSHConfigError.self) {
            try SSHConfigWriter.render(hosts: [spec(agent: value)], userConfigPath: nil)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdesk-test-\(UUID().uuidString)/config")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: SSHConfigError.self) {
            try SSHConfigWriter.write(to: url, hosts: [spec(agent: value)], userConfigPath: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")))
    func sshDashGReportsExactIdentityAgentWithQuotesAndBackslash() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sshdesk-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let cases: [(String, String)] = [
            ("/tmp/a\"b\\c.sock", "identityagent /tmp/a\"b\\c.sock"),
            ("SSH_AUTH_SOCK", "identityagent SSH_AUTH_SOCK"),
            ("~/s.sock", "identityagent \(NSHomeDirectory())/s.sock"),
        ]
        for (value, expected) in cases {
            let host = spec(agent: value)
            let url = root.appendingPathComponent("config")
            try SSHConfigWriter.write(to: url, hosts: [host], userConfigPath: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-G"] + (try SSHConfigWriter.sshInvocation(configPath: url.path, alias: host.alias))
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            #expect(lines.contains(expected), "\(value)")
            // Không có directive nào bị chèn thêm.
            #expect(!lines.contains { $0.hasPrefix("proxycommand ") })
        }
    }
}

// MARK: - Repository / Service / migration

private final class NoopWarp: WarpURLHandler, @unchecked Sendable {
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
}

@Suite struct IdentityAgentPersistenceTests {
    @Test func migrationV8AddsNullableColumnAndKeepsOldRows() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let id = UUID()
        #expect(Database.migrations.count >= 8)
        do {
            let db = try Database(url: t.dbURL, migrations: Array(Database.migrations.prefix(7)))
            try db.execute(
                """
                INSERT INTO hosts (id, display_name, project, environment, tags_json, notes,
                  is_favorite, connection_mode, host_name, port, user, auth_method,
                  bookmarks_json, default_local_directory, default_remote_directory,
                  created_at, updated_at)
                VALUES (?, 'old', '', 'DEV', '[]', '', 0, 'managed', 'h.example.com', 22, 'u',
                  'agent', '[]', '', '', 1, 1)
                """, [.text(id.uuidString)])
            #expect(try db.schemaVersion() == 7)
        }
        let db = try Database(url: t.dbURL)
        #expect(try db.schemaVersion() == Database.migrations.count)
        let cols = try db.query("PRAGMA table_info(hosts)").compactMap { r -> String? in
            if case .text(let s) = r[1] { return s } else { return nil }
        }
        #expect(cols.contains("identity_agent"))
        let repo = HostRepository(database: db)
        let h = try #require(try await repo.host(id: id))
        #expect(h.identityAgent == nil)
        var edited = h
        edited.identityAgent = "/x.sock"
        try await repo.update(edited)
        #expect(try await repo.host(id: id)?.identityAgent == "/x.sock")
    }

    @Test func repositoryRoundTripAndEffectiveSpecs() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = HostRepository(database: try Database(url: t.dbURL))
        var own = managedHost("own", hostName: "own.example.com")
        own.identityAgent = "/own.sock"
        var system = managedHost("sys", hostName: "sys.example.com")
        system.identityAgent = "SSH_AUTH_SOCK"
        let plain = managedHost("plain", hostName: "plain.example.com")
        let imported = importedHost()
        for h in [own, system, plain, imported] { try await repo.insert(h) }
        #expect(try await repo.host(id: own.id)?.identityAgent == "/own.sock")
        #expect(try await repo.host(id: plain.id)?.identityAgent == nil)

        let specs = try await repo.sshSpecs(defaultIdentityAgent: "/default.sock")
        func agent(_ h: HostProfile) -> String? {
            specs.first { $0.alias == h.sshAlias }?.identityAgent
        }
        #expect(agent(own) == "/own.sock")  // host > mặc định
        #expect(agent(system) == "SSH_AUTH_SOCK")  // host chọn Hệ thống thắng mặc định
        #expect(agent(plain) == "/default.sock")  // theo mặc định
        #expect(specs.count == 3)  // imported không có block
        let none = try await repo.sshSpecs(defaultIdentityAgent: "")
        #expect(none.first { $0.alias == plain.sshAlias }?.identityAgent == nil)
    }

    @Test func repositoryRefusesInvalidAgent() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = HostRepository(database: try Database(url: t.dbURL))
        var h = managedHost()
        h.identityAgent = "/a\nProxyCommand x"
        await #expect(throws: HostValidationError.self) { try await repo.insert(h) }
    }

    @Test func serviceRegeneratesWithSettingsDefaultAndImportedHasNoDirective() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        let store = SettingsStore()
        let service = ConnectionService(
            repository: HostRepository(database: try Database(url: paths.databaseURL)),
            appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: t.url.appendingPathComponent("tabs"), handler: NoopWarp()),
            settings: store)
        try await service.add(managedHost("a", hostName: "a.example.com"))
        try await service.add(importedHost())
        try await service.regenerateSSHConfig()
        var text = try String(contentsOf: paths.sshConfigURL, encoding: .utf8)
        #expect(!text.contains("IdentityAgent"))
        var s = AppSettings()
        s.defaultIdentityAgent = "/default.sock"
        store.update(s)
        try await service.regenerateSSHConfig()
        text = try String(contentsOf: paths.sshConfigURL, encoding: .utf8)
        #expect(text.components(separatedBy: "IdentityAgent").count == 2)  // đúng một directive
        #expect(text.contains("IdentityAgent \"/default.sock\""))
        #expect(!text.contains("web-u"))
    }
}

// MARK: - Xuất / nhập (ADR-020)

@Suite struct IdentityAgentExchangeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func roundTrip(_ hosts: [HostProfile], mutate: (inout [[String: Any]]) -> Void = { _ in })
        throws -> HostExchange.Plan
    {
        var data = try HostExchange.export(
            hosts: hosts, forwards: [], folders: [], needsReauth: [], now: now)
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try #require(root["hosts"] as? [[String: Any]])
        mutate(&rows)
        root["hosts"] = rows
        data = try JSONSerialization.data(withJSONObject: root)
        return HostExchange.plan(
            file: try HostExchange.decode(data), existingHosts: [], existingFolders: [],
            existingForwards: [], duplicates: .skip, now: now)
    }

    @Test func roundTripKeepsAgentAndFileHasNoSecret() throws {
        var h = managedHost("a", hostName: "a.example.com")
        h.identityAgent = "~/.bitwarden-ssh-agent.sock"
        let plain = managedHost("b", hostName: "b.example.com")
        let data = try HostExchange.export(
            hosts: [h, plain], forwards: [], folders: [], needsReauth: [], now: now)
        #expect(String(decoding: data, as: UTF8.self).contains("\"identityAgent\""))
        let p = try roundTrip([h, plain])
        let byName = Dictionary(uniqueKeysWithValues: p.hosts.map { ($0.displayName, $0) })
        #expect(byName["a"]?.identityAgent == "~/.bitwarden-ssh-agent.sock")
        #expect(byName["b"]?.identityAgent == nil)
    }

    @Test func oldFileWithoutFieldStillImports() throws {
        let h = managedHost("a", hostName: "a.example.com")
        let p = try roundTrip([h]) { rows in rows[0].removeValue(forKey: "identityAgent") }
        #expect(p.newCount == 1 && p.invalidCount == 0)
        #expect(p.hosts.first?.identityAgent == nil)
    }

    @Test(arguments: ["/a.sock\n    ProxyCommand evil", "relative", "/a%h", "/a$X"])
    func invalidAgentMakesOnlyThatHostInvalid(_ bad: String) throws {
        let a = managedHost("a", hostName: "a.example.com")
        let b = managedHost("b", hostName: "b.example.com")
        let p = try roundTrip([a, b]) { rows in
            let i = rows.firstIndex { ($0["displayName"] as? String) == "a" }!
            rows[i]["identityAgent"] = bad
        }
        #expect(p.invalidCount == 1)
        #expect(p.hosts.map(\.displayName) == ["b"])
    }

    @Test func importedAndWindowsHostsDropAgent() throws {
        let alias = importedHost("legacy", alias: "web-u")
        let p = try roundTrip([alias]) { rows in rows[0]["identityAgent"] = "/x.sock" }
        #expect(p.hosts.first?.identityAgent == nil)
    }
}

// MARK: - Key trong agent

@Suite struct AgentKeyListerTests {
    // Blob giả (không phải key thật); fingerprint kiểm định dạng SHA256 không padding.
    let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUJsb2JGb3JUZXN0aW5nT25seTEyMzQ1Njc4OTA= me@laptop"

    @Test func parsesPublicKeyLines() throws {
        let r = AgentKeyLister.parse(stdout: line + "\nrác\n", stderr: "", status: 0)
        guard case .keys(let keys) = r else {
            Issue.record("phải có key")
            return
        }
        #expect(keys.count == 1)
        #expect(keys[0].type == "ssh-ed25519" && keys[0].comment == "me@laptop")
        #expect(keys[0].fingerprint.hasPrefix("SHA256:") && !keys[0].fingerprint.contains("="))
    }

    @Test func statusMapping() {
        #expect(AgentKeyLister.parse(stdout: "The agent has no identities.\n", stderr: "", status: 1) == .empty)
        if case .unavailable = AgentKeyLister.parse(stdout: "", stderr: "Could not open", status: 2) {
        } else {
            Issue.record("phải unavailable")
        }
    }

    @Test func stripsControlCharsFromComment() {
        let k = AgentKeyLister.parseLine(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUJsb2JGb3JUZXN0aW5nT25seTEyMzQ1Njc4OTA= a\u{1B}[31mb")
        #expect(k?.comment == "a[31mb")
    }

    @Test func invalidOrMissingAgentNeverRunsProcess() async {
        let a = await AgentKeyLister.list(agent: "relative/x", environment: [:])
        let b = await AgentKeyLister.list(agent: nil, environment: [:])
        for r in [a, b] {
            if case .unavailable = r {} else { Issue.record("phải unavailable") }
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-add")))
    func missingSocketIsUnavailableNotCrash() async {
        let r = await AgentKeyLister.list(agent: "/tmp/sshdesk-no-such-\(UUID().uuidString).sock")
        if case .unavailable = r {} else { Issue.record("socket không tồn tại phải unavailable, nhận \(r)") }
    }
}

// MARK: - AgentKeyLister với executable giả

@Suite struct AgentKeyListerScriptTests {
    private func script(_ body: String) throws -> (dir: URL, exe: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdesk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fake-ssh-add")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (dir, url.path)
    }

    @Test func passesOnlyDashLAndOnlySSHAuthSockEnv() async throws {
        let (dir, exe) = try script(
            """
            echo "$@" > "$(dirname "$0")/argv.txt"
            /usr/bin/env > "$(dirname "$0")/env.txt"
            echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUJsb2JGb3JUZXN0aW5nT25seTEyMzQ1Njc4OTA= c"
            """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await AgentKeyLister.list(
            agent: "~/a.sock", home: "/Users/me", environment: ["SECRET": "x", "HOME": "/h"], executable: exe)
        guard case .keys(let keys) = r else {
            Issue.record("phải có key, nhận \(r)")
            return
        }
        #expect(keys.count == 1)
        let argv = try String(contentsOf: dir.appendingPathComponent("argv.txt"), encoding: .utf8)
        #expect(argv.trimmingCharacters(in: .whitespacesAndNewlines) == "-L")
        let env = try String(contentsOf: dir.appendingPathComponent("env.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("PWD=") && !$0.hasPrefix("SHLVL=") && !$0.hasPrefix("_=") }
        #expect(env == ["SSH_AUTH_SOCK=/Users/me/a.sock"])
    }

    @Test func exitCodesAndTimeout() async throws {
        let (d1, e1) = try script("echo 'The agent has no identities.'; exit 1")
        let (d2, e2) = try script("echo 'Could not open a connection' >&2; exit 2")
        let (d3, e3) = try script("exec /bin/sleep 30")
        defer { for d in [d1, d2, d3] { try? FileManager.default.removeItem(at: d) } }
        #expect(await AgentKeyLister.list(agent: "/a.sock", environment: [:], executable: e1) == .empty)
        if case .unavailable = await AgentKeyLister.list(agent: "/a.sock", environment: [:], executable: e2) {
        } else {
            Issue.record("exit 2 phải unavailable")
        }
        let r = await AgentKeyLister.list(agent: "/a.sock", environment: [:], executable: e3, timeout: 0.5)
        if case .unavailable(let why) = r { #expect(why.contains("không phản hồi")) } else { Issue.record("timeout") }
    }
}
