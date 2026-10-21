import Foundation
import Testing

@testable import SSHDeskCore

private final class FakeWarp: WarpURLHandler, @unchecked Sendable {
    var available = true
    var accept = true
    var opened: [URL] = []
    func isWarpAvailable() -> Bool { available }
    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return accept
    }
}

private struct Env {
    let dir = HostTempDir()
    let warp = FakeWarp()
    let paths: AppPaths
    let service: ConnectionService
    let repo: HostRepository
    var tabDir: URL { dir.url.appendingPathComponent("tabs") }

    init(userConfig: String? = nil, now: Date = Date(timeIntervalSince1970: 1_000_000)) throws {
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: userConfig,
            launcher: WarpLauncher(
                tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: warp),
            now: { now })
    }
}

@Test func appPathsLayoutAndPermissions() throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    #expect(env.paths.databaseURL.lastPathComponent == "sshdesk.sqlite")
    #expect(env.paths.sshConfigURL.path.hasSuffix("SSHDesk/ssh/config"))
    let attrs = try FileManager.default.attributesOfItem(atPath: env.paths.baseDirectory.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o700)
}

@Test func addRegeneratesConfigAndDeleteRegeneratesAgain() async throws {
    let env = try Env(userConfig: "/Users/me/.ssh/config")
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    let text = try String(contentsOf: env.paths.sshConfigURL, encoding: .utf8)
    #expect(text.contains("Host sshdesk-\(h.id.uuidString.lowercased())"))
    #expect(text.contains("Include"))
    try await env.service.delete(id: h.id)
    let after = try String(contentsOf: env.paths.sshConfigURL, encoding: .utf8)
    #expect(!after.contains("sshdesk-\(h.id.uuidString.lowercased())"))
}

@Test func noUserConfigMeansNoInclude() async throws {
    let env = try Env(userConfig: nil)
    defer { env.dir.cleanup() }
    try await env.service.add(managedHost())
    let text = try String(contentsOf: env.paths.sshConfigURL, encoding: .utf8)
    #expect(!text.contains("Include"))
}

@Test func copyableCommandMatchesExactForm() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    let cmd = try await env.service.copyableSSHCommand(for: h)
    #expect(
        cmd
            == "'/usr/bin/ssh' '-F' '\(env.paths.sshConfigURL.path)' 'sshdesk-\(h.id.uuidString.lowercased())'"
    )
    let args = try await env.service.sshArguments(for: h)
    #expect(args == ["-F", env.paths.sshConfigURL.path, "sshdesk-\(h.id.uuidString.lowercased())"])
}

@Test func hostileDisplayNameNeverReachesCommand() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    var h = managedHost()
    h.displayName = "x'; rm -rf / `id` $(whoami)\n[[panes]]"
    try await env.service.add(h)
    let cmd = try await env.service.copyableSSHCommand(for: h)
    #expect(!cmd.contains("rm -rf"))
    let result = await env.service.openInWarp(h)
    #expect(result == .requested)
    let toml = try String(
        contentsOf: env.tabDir.appendingPathComponent("sshdesk_\(h.id.uuidString.lowercased()).toml"),
        encoding: .utf8)
    let commandLines = toml.split(separator: "\n").filter { $0.hasPrefix("commands") }
    #expect(commandLines.count == 1)
    #expect(!commandLines[0].contains("rm -rf"))
}

@Test func openInWarpMarksLaunchOnlyWhenRequested() async throws {
    let env = try Env(now: Date(timeIntervalSince1970: 5000))
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)

    env.warp.available = false
    #expect(await env.service.openInWarp(h) == .warpUnavailable)
    #expect(try await env.repo.host(id: h.id)?.lastLaunchRequestedAt == nil)

    env.warp.available = true
    env.warp.accept = false
    if case .failed = await env.service.openInWarp(h) {} else { Issue.record("cần .failed") }
    #expect(try await env.repo.host(id: h.id)?.lastLaunchRequestedAt == nil)

    env.warp.accept = true
    #expect(await env.service.openInWarp(h) == .requested)
    #expect(
        try await env.repo.host(id: h.id)?.lastLaunchRequestedAt
            == Date(timeIntervalSince1970: 5000))
    #expect(env.warp.opened.last?.absoluteString == "warp://tab_config/sshdesk_\(h.id.uuidString.lowercased())")
}

@Test func openInWarpRejectsInvalidHost() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    var h = managedHost()
    h.hostName = "bad host\nProxyCommand x"
    if case .failed = await env.service.openInWarp(h) {} else { Issue.record("cần .failed") }
    #expect(env.warp.opened.isEmpty)
}

@Test func deleteRemovesWarpConfig() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    _ = await env.service.openInWarp(h)
    let file = env.tabDir.appendingPathComponent("sshdesk_\(h.id.uuidString.lowercased()).toml")
    #expect(FileManager.default.fileExists(atPath: file.path))
    try await env.service.delete(id: h.id)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func deleteBastionInUseFailsAndKeepsEverything() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    let bastion = managedHost("bastion", hostName: "b.example.com")
    try await env.service.add(bastion)
    try await env.service.add(managedHost("app", jump: bastion.id))
    await #expect(throws: HostRepositoryError.self) { try await env.service.delete(id: bastion.id) }
    #expect(try await env.repo.host(id: bastion.id) != nil)
}

@Test func importSkipsDuplicates() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    let src = URL(fileURLWithPath: "/Users/me/.ssh/config")
    let cands = [
        ImportCandidate(alias: "web-u", sourceFile: src, line: 1),
        ImportCandidate(alias: "db", sourceFile: src, line: 5),
    ]
    let first = try await env.service.importAliases(cands, sourcePath: src.path)
    #expect(first.imported.count == 2)
    #expect(first.imported.allSatisfy { $0.displayName == $0.sshConfigAlias })
    #expect(first.imported.allSatisfy { $0.environment == .other && $0.project.isEmpty })
    let second = try await env.service.importAliases(cands, sourcePath: src.path)
    #expect(second.imported.isEmpty)
    #expect(second.skippedAliases == ["web-u", "db"])
    // Cùng alias nhưng file khác thì vẫn import.
    let third = try await env.service.importAliases(
        [cands[0]], sourcePath: "/Users/me/other/config")
    #expect(third.imported.count == 1)
    #expect(try await env.repo.all().count == 3)
}

@Test func importedHostUsesOriginalAlias() async throws {
    let env = try Env()
    defer { env.dir.cleanup() }
    let src = URL(fileURLWithPath: "/Users/me/.ssh/config")
    let out = try await env.service.importAliases(
        [ImportCandidate(alias: "web-u", sourceFile: src, line: 1)], sourcePath: src.path)
    let cmd = try await env.service.copyableSSHCommand(for: out.imported[0])
    #expect(cmd.hasSuffix("'web-u'"))
}

@Test func draftValidationAndTags() {
    var d = HostDraft()
    #expect(d.errors(basedOn: nil)[.displayName] != nil)
    d.displayName = "Web"
    d.hostName = "web.example.com"
    d.user = "deploy"
    d.portText = "abc"
    #expect(d.errors(basedOn: nil)[.port] != nil)
    d.portText = "2222"
    #expect(d.errors(basedOn: nil).isEmpty)
    d.hostName = "a\nProxyCommand x"
    #expect(d.errors(basedOn: nil)[.hostName] != nil)
    d.hostName = "ok.example.com"
    d.authMethod = .keyFile
    #expect(d.errors(basedOn: nil)[.identityFile] != nil)
    #expect(HostDraft.parseTags(" a, b ,,a,c ") == ["a", "b", "c"])
}

@Test func draftOnImportedOnlyChangesMetadata() {
    let base = importedHost("legacy", alias: "web-u")
    var d = HostDraft(host: base)
    d.displayName = "Mới"
    d.hostName = "evil.example.com"
    d.portText = "1"
    d.environment = .prod
    let p = d.profile(basedOn: base)
    #expect(p.displayName == "Mới" && p.environment == .prod)
    #expect(p.hostName == base.hostName && p.port == base.port)
    #expect(p.sshConfigAlias == "web-u" && p.connectionMode == .existingSSHConfigAlias)
    #expect(d.errors(basedOn: base).isEmpty)
}

@Test func draftAuthChoiceMappingAndPasswordValidation() {
    var d = HostDraft()
    d.displayName = "x"
    d.hostName = "h"
    d.user = "u"
    d.authChoice = .password
    #expect(d.profile(basedOn: nil).authMethod == .interactive)
    #expect(d.errors(basedOn: nil)[.password] == "Nhập mật khẩu.")
    #expect(d.errors(basedOn: nil, passwordEntered: true).isEmpty)
    #expect(d.errors(basedOn: nil, hasSavedPassword: true).isEmpty)
    d.authChoice = .prompt
    #expect(d.errors(basedOn: nil).isEmpty)
    #expect(d.profile(basedOn: nil).authMethod == .interactive)

    var h = HostProfile(displayName: "x")
    h.authMethod = .interactive
    #expect(HostDraft(host: h, hasSavedPassword: true).authChoice == .password)
    #expect(HostDraft(host: h, hasSavedPassword: false).authChoice == .prompt)
    var saved = HostDraft(host: h, hasSavedPassword: true)
    #expect(!saved.removesStoredPassword(hasSavedPassword: true))
    saved.authChoice = .agent
    #expect(saved.removesStoredPassword(hasSavedPassword: true))
    #expect(!saved.removesStoredPassword(hasSavedPassword: false))
}
