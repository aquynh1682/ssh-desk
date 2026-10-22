import Foundation
import Testing

@testable import SSHDeskCore

private func windows(
    _ name: String = "Win", host: String = "10.0.0.5", port: Int = 3389, user: String = "",
    configure: (inout HostProfile) -> Void = { _ in }
) -> HostProfile {
    var h = HostProfile(
        displayName: name, kind: .windowsRDP, rdpUsername: user, hostName: host, port: port)
    configure(&h)
    return h
}

private final class FakeWindowsApp: WindowsAppHandler, @unchecked Sendable {
    var app: URL? = URL(fileURLWithPath: "/Applications/Windows App.app")
    var accept = true
    var opened: [(file: URL, app: URL)] = []
    func windowsAppURL() -> URL? { app }
    func open(file: URL, withApplicationAt app: URL) async -> Bool {
        opened.append((file, app))
        return accept
    }
}

private func perms(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
}

// MARK: - Renderer

@Test func rdpRendererExactOutput() throws {
    let h = windows(user: "CORP\\alice") {
        $0.rdpDomain = "CORP"
        $0.rdpGateway = "gw.example.com:4443"
        $0.rdpMultiMonitor = true
        $0.rdpAdminSession = true
        $0.rdpScreenMode = .window
        $0.port = 3390
    }
    let expected = [
        "full address:s:10.0.0.5:3390", "username:s:CORP\\alice", "domain:s:CORP",
        "screen mode id:i:1", "use multimon:i:1", "dynamic resolution:i:1",
        "redirectclipboard:i:1", "audiomode:i:0", "enablecredsspsupport:i:1",
        "administrative session:i:1", "gatewayhostname:s:gw.example.com:4443",
        "gatewayusagemethod:i:1",
    ].map { $0 + "\r\n" }.joined()
    #expect(try RDPFileRenderer.render(h) == expected)
}

@Test func rdpRendererMinimalDefaults() throws {
    let out = try RDPFileRenderer.render(windows())
    #expect(
        out
            == "full address:s:10.0.0.5\r\nscreen mode id:i:2\r\nuse multimon:i:0\r\n"
            + "dynamic resolution:i:1\r\nredirectclipboard:i:1\r\naudiomode:i:0\r\n"
            + "enablecredsspsupport:i:1\r\n")
    #expect(!out.lowercased().contains("password"))
}

@Test func rdpRendererIPv6AndUsernameFlag() throws {
    let bare = try RDPFileRenderer.render(windows(host: "fe80::1", user: "u"))
    #expect(bare.hasPrefix("full address:s:fe80::1\r\n"))
    let withPort = try RDPFileRenderer.render(windows(host: "fe80::1", port: 3390))
    #expect(withPort.hasPrefix("full address:s:[fe80::1]:3390\r\n"))
    let noUser = try RDPFileRenderer.render(windows(user: "u"), includeUsername: false)
    #expect(!noUser.contains("username"))
}

@Test func rdpRendererRejectsInjection() {
    let evil = "a\r\nalternate shell:s:cmd"
    #expect(throws: RDPRenderError.controlCharacter(field: "rdpUsername")) {
        _ = try RDPFileRenderer.render(windows(user: evil))
    }
    #expect(throws: RDPRenderError.self) {
        _ = try RDPFileRenderer.render(windows { $0.rdpDomain = evil })
    }
    #expect(throws: RDPRenderError.self) {
        _ = try RDPFileRenderer.render(windows { $0.rdpGateway = "g\n" })
    }
    #expect(throws: RDPRenderError.self) {
        _ = try RDPFileRenderer.render(windows(host: "h\nx"))
    }
    #expect(throws: RDPRenderError.notWindowsHost) {
        _ = try RDPFileRenderer.render(managedHost())
    }
}

// MARK: - Validate

@Test func windowsValidation() throws {
    try windows(user: "DOMAIN\\user").validate()
    try windows(user: "user@corp.local").validate()
    try windows(host: "fe80::1").validate()
    try windows { $0.rdpGateway = "gw.example.com" }.validate()
    try windows { $0.rdpGateway = "[fe80::1]:443" }.validate()
    #expect(throws: HostValidationError.self) { try windows(port: 0).validate() }
    #expect(throws: HostValidationError.self) { try windows(port: 65536).validate() }
    #expect(throws: HostValidationError.self) { try windows(host: "bad host").validate() }
    #expect(throws: HostValidationError.self) { try windows(host: "-x").validate() }
    #expect(throws: HostValidationError.invalidRDPField(field: "rdpUsername")) {
        try windows(user: "a\nb").validate()
    }
    #expect(throws: HostValidationError.invalidRDPField(field: "rdpUsername")) {
        try windows(user: String(repeating: "a", count: 257)).validate()
    }
    #expect(throws: HostValidationError.invalidRDPField(field: "rdpDomain")) {
        try windows { $0.rdpDomain = "x\r" }.validate()
    }
    #expect(throws: HostValidationError.self) {
        try windows { $0.rdpGateway = "gw:99999" }.validate()
    }
    #expect(throws: HostValidationError.self) {
        try windows { $0.rdpGateway = "gw host" }.validate()
    }
    // Host Windows không cần user/xác thực SSH.
    var h = windows()
    h.user = ""
    try h.validate()
    #expect(h.sshAlias == nil)
}

// MARK: - Database / Repository

@Test func migrationKeepsOldRowsAsSSH() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let id = UUID()
    do {
        let db = try Database(url: t.dbURL, migrations: Array(Database.migrations.prefix(4)))
        try db.execute(
            """
            INSERT INTO hosts (id, display_name, project, environment, tags_json, notes,
              is_favorite, connection_mode, host_name, port, user, auth_method,
              bookmarks_json, default_local_directory, default_remote_directory,
              created_at, updated_at)
            VALUES (?, 'old', '', 'DEV', '[]', '', 0, 'managed', 'h.example.com', 22, 'u',
              'agent', '[]', '', '', 1, 1)
            """, [.text(id.uuidString)])
    }
    let repo = HostRepository(database: try Database(url: t.dbURL))
    let h = try #require(try await repo.host(id: id))
    #expect(h.kind == .ssh)
    #expect(h.rdpUsername == "" && h.rdpDomain == nil && h.rdpGateway == nil)
    #expect(h.rdpScreenMode == .fullScreen && !h.rdpMultiMonitor)
    #expect(h.rdpRedirectClipboard && !h.rdpAdminSession)
    #expect(try await repo.sshSpecs().count == 1)
}

@Test func windowsHostRoundTripAndNoSSHSpec() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let repo = HostRepository(database: try Database(url: t.dbURL))
    let w = windows(user: "CORP\\a") {
        $0.rdpDomain = "CORP"
        $0.rdpGateway = "gw:443"
        $0.rdpMultiMonitor = true
        $0.rdpRedirectClipboard = false
        $0.rdpAdminSession = true
        $0.rdpScreenMode = .window
    }
    try await repo.insert(w)
    try await repo.insert(managedHost())
    let back = try #require(try await repo.host(id: w.id))
    #expect(back.kind == .windowsRDP)
    #expect(back.rdpUsername == "CORP\\a" && back.rdpDomain == "CORP" && back.rdpGateway == "gw:443")
    #expect(back.rdpMultiMonitor && !back.rdpRedirectClipboard && back.rdpAdminSession)
    #expect(back.rdpScreenMode == .window)
    #expect(back.credentialReference == nil)
    let specs = try await repo.sshSpecs()
    #expect(specs.count == 1)
    #expect(!specs.contains { $0.alias.contains(w.id.uuidString.lowercased()) })
    // Không dùng máy Windows làm bastion.
    var ssh = managedHost("j")
    ssh.jumpHostID = w.id
    await #expect(throws: HostRepositoryError.self) { try await repo.insert(ssh) }
}

// MARK: - Lọc (hàm thuần)

@Test func windowsHostsFilteredFromSSHLists() {
    let w = windows()
    let s = managedHost()
    let imp = importedHost()
    #expect(HostPresentation.sshHosts([w, s, imp]).map(\.id) == [s.id, imp.id])
    #expect(HostPresentation.windowsHosts([w, s, imp]).map(\.id) == [w.id])
    #expect(HostPresentation.addressText(w) == "10.0.0.5:3389")
    #expect(HostPresentation.addressText(windows(host: "::1")) == "[::1]:3389")
}

@Test func windowsConnectionRows() {
    let w = windows(user: "CORP\\a") {
        $0.rdpGateway = "gw"
        $0.rdpMultiMonitor = true
    }
    let rows = HostPresentation.connectionRows(w, jumpHostName: nil)
    #expect(rows.map(\.label) == ["Địa chỉ", "Port", "User", "Gateway", "Hiển thị"])
    #expect(rows.last?.value == "Toàn màn hình, nhiều màn hình")
}

@Test func draftBuildsWindowsProfile() {
    var d = HostDraft()
    d.setKind(.windowsRDP)
    #expect(d.portText == "3389")
    d.displayName = "  Win  "
    d.hostName = " 10.0.0.5 "
    d.rdpUsername = " u "
    d.rdpDomain = " "
    let h = d.profile(basedOn: nil)
    #expect(h.kind == .windowsRDP && h.hostName == "10.0.0.5" && h.rdpUsername == "u")
    #expect(h.rdpDomain == nil && h.user == "" && h.port == 3389)
    #expect(d.errors(basedOn: nil).isEmpty)
    d.setKind(.ssh)
    #expect(d.portText == "22")
}

@Test func duplicatingWindowsHostHasNoCredential() {
    var w = windows()
    w.credentialReference = "ref"
    let copy = w.duplicated(existingNames: ["Win"])
    #expect(copy.kind == .windowsRDP && copy.credentialReference == nil)
    #expect(copy.displayName == "Win (bản sao)")
}

// MARK: - Launcher

@Test func launcherWritesSecureFileAndOpens() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let fake = FakeWindowsApp()
    let dir = t.url.appendingPathComponent("rdp")
    let launcher = WindowsAppLauncher(directory: dir, handler: fake)
    let h = windows("Máy A")
    #expect(await launcher.launch(h) == .requested)
    let file = dir.appendingPathComponent(h.id.uuidString.lowercased())
        .appendingPathComponent("Máy A.rdp")
    #expect(fake.opened.first?.file == file)
    #expect(perms(dir) == 0o700)
    #expect(perms(file.deletingLastPathComponent()) == 0o700)
    #expect(perms(file) == 0o600)
    #expect(try String(contentsOf: file, encoding: .utf8) == RDPFileRenderer.render(h))
    // Mở lần nữa: ghi đè, không lỗi.
    #expect(await launcher.launch(h) == .requested)
}

@Test func launcherAppUnavailableAndFailure() async {
    let t = HostTempDir()
    defer { t.cleanup() }
    let fake = FakeWindowsApp()
    fake.app = nil
    let launcher = WindowsAppLauncher(directory: t.url.appendingPathComponent("rdp"), handler: fake)
    #expect(await launcher.launch(windows()) == .appUnavailable)
    #expect(fake.opened.isEmpty)
    fake.app = URL(fileURLWithPath: "/x")
    fake.accept = false
    if case .failed = await launcher.launch(windows()) {} else { Issue.record("cần .failed") }
    // Host không hợp lệ -> không ghi file, không mở.
    fake.accept = true
    fake.opened = []
    if case .failed = await launcher.launch(windows(user: "a\nb")) {} else { Issue.record("cần .failed") }
    #expect(fake.opened.isEmpty)
}

@Test func fileNameSanitizing() {
    let s = WindowsAppLauncher.sanitizedFileName
    #expect(s("Web/Prod: a\\b") == "Web-Prod- a-b")
    #expect(s("a\nb\u{7}c") == "abc")
    #expect(s("   ") == "Windows")
    #expect(s("") == "Windows")
    #expect(s("..") == "Windows")
    #expect(s("  .hidden  ") == "hidden")
    #expect(s(String(repeating: "x", count: 200)).count == 80)
    #expect(s("a*b?c\"d<e>f|g") == "a-b-c-d-e-f-g")
    #expect(!s("../../etc/passwd").contains("/"))
}

@Test func renamingHostRemovesOldFile() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let launcher = WindowsAppLauncher(
        directory: t.url.appendingPathComponent("rdp"), handler: FakeWindowsApp())
    var h = windows("Cũ")
    _ = await launcher.launch(h)
    let old = launcher.fileURL(hostID: h.id, displayName: "Cũ")
    #expect(FileManager.default.fileExists(atPath: old.path))
    h.displayName = "Mới"
    _ = await launcher.launch(h)
    let new = launcher.fileURL(hostID: h.id, displayName: "Mới")
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: new.path))
}

@Test func deletingHostRemovesOnlyItsDirectory() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let rdpDir = t.url.appendingPathComponent("rdp")
    let launcher = WindowsAppLauncher(directory: rdpDir, handler: FakeWindowsApp())
    let service = ConnectionService(
        repository: HostRepository(database: try Database(url: paths.databaseURL)),
        appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(
            tabConfigsDirectory: t.url.appendingPathComponent("tabs"),
            handler: SystemWarpURLHandler()),
        rdpLauncher: launcher, now: { Date(timeIntervalSince1970: 5) })
    let a = windows("A")
    let b = windows("B", host: "10.0.0.6")
    try await service.add(a)
    try await service.add(b)
    #expect(await service.openInWindowsApp(a) == .requested)
    #expect(await service.openInWindowsApp(b) == .requested)
    #expect(
        try await service.repository.host(id: a.id)?.lastLaunchRequestedAt
            == Date(timeIntervalSince1970: 5))
    try await service.delete(id: a.id)
    #expect(!FileManager.default.fileExists(atPath: launcher.hostDirectory(hostID: a.id).path))
    #expect(FileManager.default.fileExists(atPath: launcher.fileURL(hostID: b.id, displayName: "B").path))
    // SSH config không có khối cho host Windows.
    let cfg = try String(contentsOf: paths.sshConfigURL, encoding: .utf8)
    #expect(!cfg.contains("Host "))
}

@Test func deleteDoesNotFollowSymlinkedHostDirectory() throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let rdpDir = t.url.appendingPathComponent("rdp")
    try FileManager.default.createDirectory(at: rdpDir, withIntermediateDirectories: true)
    let victim = t.url.appendingPathComponent("victim")
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: victim.appendingPathComponent("keep.txt"))
    let launcher = WindowsAppLauncher(directory: rdpDir, handler: FakeWindowsApp())
    let id = UUID()
    try FileManager.default.createSymbolicLink(
        at: launcher.hostDirectory(hostID: id), withDestinationURL: victim)
    try launcher.removeFile(hostID: id)
    #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.txt").path))
    #expect(
        (try? FileManager.default.destinationOfSymbolicLink(
            atPath: launcher.hostDirectory(hostID: id).path)) == nil)
}

@Test func windowsHostRefusesWarpAndSSHOperations() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let service = ConnectionService(
        repository: HostRepository(database: try Database(url: paths.databaseURL)),
        appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(
            tabConfigsDirectory: t.url.appendingPathComponent("tabs"),
            handler: SystemWarpURLHandler()),
        rdpLauncher: WindowsAppLauncher(
            directory: t.url.appendingPathComponent("rdp"), handler: FakeWindowsApp()))
    let w = windows()
    try await service.add(w)
    if case .failed = await service.openInWarp(w) {} else { Issue.record("cần .failed") }
    await #expect(throws: ConnectionServiceError.self) { try await service.sshArguments(for: w) }
    await #expect(throws: ConnectionServiceError.self) {
        try await service.useKey(hostID: w.id, privateKeyPath: "/k")
    }
}
