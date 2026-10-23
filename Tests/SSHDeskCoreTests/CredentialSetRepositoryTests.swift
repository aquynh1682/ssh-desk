import Foundation
import Testing

@testable import SSHDeskCore

private struct RepoEnv {
    let dir = HostTempDir()
    let db: Database
    let repo: HostRepository
    init() throws {
        db = try Database(url: dir.dbURL)
        repo = HostRepository(database: db)
    }
}

// MARK: - Migration v9

@Test func migrationV9UpgradesV8AndKeepsHosts() async throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    #expect(Database.currentSchemaVersion >= 9)
    do {
        let old = try Database(url: dir.dbURL, migrations: Array(Database.migrations.prefix(8)))
        #expect(try old.schemaVersion() == 8)
        let id = UUID().uuidString
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
    #expect(hosts.count == 1)
    #expect(hosts[0].credentialSetID == nil)
    #expect(hosts[0].autofillHold == false)
    #expect(hosts[0].autofillHoldReason == nil)
    #expect(try await repo.credentialSets().isEmpty)
}

// MARK: - CRUD bộ đăng nhập

@Test func setCrudNameUniquenessCaseInsensitive() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let a = try await env.repo.createCredentialSet(CredentialSet(name: "  Team A "))
    #expect(a.name == "Team A")
    await #expect(throws: CredentialSetError.duplicateName("Team A")) {
        try await env.repo.createCredentialSet(CredentialSet(name: "team a"))
    }
    let b = try await env.repo.createCredentialSet(CredentialSet(name: "Team B", user: "ops", identityFile: "/k/b"))
    // Đổi tên sang tên của bộ khác (khác hoa thường) bị từ chối; đổi hoa thường tên của chính nó thì được.
    var renamed = b
    renamed.name = "TEAM a"
    await #expect(throws: CredentialSetError.duplicateName("Team A")) {
        try await env.repo.updateCredentialSet(renamed)
    }
    renamed.name = "TEAM B"
    let saved = try await env.repo.updateCredentialSet(renamed)
    #expect(saved.name == "TEAM B" && abs(saved.createdAt.timeIntervalSince(b.createdAt)) < 0.001)
    #expect(try await env.repo.credentialSets().map(\.name) == ["Team A", "TEAM B"])
    await #expect(throws: CredentialSetError.notFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
        try await env.repo.updateCredentialSet(
            CredentialSet(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "zz"))
    }
    // Dữ liệu sai bị chặn trước khi chạm DB.
    await #expect(throws: CredentialSetError.invalidIdentityFile) {
        try await env.repo.createCredentialSet(CredentialSet(name: "bad", identityFile: "/k\nProxyCommand x"))
    }
    #expect(try await env.repo.credentialSets().count == 2)
}

@Test func deleteSetUnlinksHostsInOneTransactionAndKeepsHosts() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let set = try await env.repo.createCredentialSet(CredentialSet(name: "S"))
    var h1 = managedHost("h1", hostName: "a.example.com")
    h1.credentialSetID = set.id
    var h2 = managedHost("h2", hostName: "b.example.com")
    h2.credentialSetID = set.id
    let h3 = managedHost("h3", hostName: "c.example.com")
    for h in [h1, h2, h3] { try await env.repo.insert(h) }
    #expect(try await env.repo.credentialSetUsage()[set.id] == 2)
    let affected = try await env.repo.deleteCredentialSet(id: set.id)
    #expect(Set(affected) == [h1.id, h2.id])
    #expect(try await env.repo.all().count == 3)
    #expect(try await env.repo.all().allSatisfy { $0.credentialSetID == nil })
    #expect(try await env.repo.credentialSets().isEmpty)
    await #expect(throws: CredentialSetError.notFound(set.id)) { try await env.repo.deleteCredentialSet(id: set.id) }
}

@Test func hostWithMissingSetIsRejected() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    var h = managedHost()
    let ghost = UUID()
    h.credentialSetID = ghost
    await #expect(throws: CredentialSetError.notFound(ghost)) { try await env.repo.insert(h) }
}

@Test func assignSetManuallyDoesNotHoldAndGatesImportedHosts() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let set = try await env.repo.createCredentialSet(CredentialSet(name: "S"))
    let h = managedHost()
    let imp = importedHost()
    try await env.repo.insert(h)
    try await env.repo.insert(imp)
    let n = try await env.repo.assignCredentialSet(setID: set.id, to: [h.id, imp.id])
    #expect(n == 1)  // host imported bị bỏ qua
    let after = try #require(try await env.repo.host(id: h.id))
    #expect(after.credentialSetID == set.id && !after.autofillHold)
    #expect(try await env.repo.host(id: imp.id)?.credentialSetID == nil)
    // Gỡ.
    #expect(try await env.repo.assignCredentialSet(setID: nil, to: [h.id]) == 1)
    #expect(try await env.repo.host(id: h.id)?.credentialSetID == nil)
}

@Test func assignKeyFileHostNeedsSetWithKey() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let empty = try await env.repo.createCredentialSet(CredentialSet(name: "Empty"))
    let withKey = try await env.repo.createCredentialSet(CredentialSet(name: "Key", identityFile: "/k/a"))
    var h = managedHost()
    h.authMethod = .keyFile
    h.identityFile = "/k/own"
    try await env.repo.insert(h)
    // Host có key riêng nên gán bộ rỗng vẫn hợp lệ.
    #expect(try await env.repo.assignCredentialSet(setID: empty.id, to: [h.id]) == 1)
    var h2 = managedHost("k2", hostName: "k2.example.com")
    h2.authMethod = .keyFile
    h2.credentialSetID = withKey.id
    try await env.repo.insert(h2)  // key lấy từ bộ
    await #expect(throws: HostValidationError.identityFileRequired) {
        try await env.repo.assignCredentialSet(setID: empty.id, to: [h2.id])
    }
    #expect(try await env.repo.host(id: h2.id)?.credentialSetID == withKey.id)
}

// MARK: - Hold

@Test func updateNeverClearsHoldOnlyConfirmDoes() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.repo.insert(h)
    try await env.repo.setAutofillHold(ids: [h.id], reason: "Địa chỉ đổi: a → b")
    var stored = try #require(try await env.repo.host(id: h.id))
    #expect(stored.autofillHold && stored.autofillHoldReason == "Địa chỉ đổi: a → b")
    // Form cũ (hold = false) lưu lại: hold vẫn còn.
    var stale = stored
    stale.autofillHold = false
    stale.autofillHoldReason = nil
    stale.hostName = "other.example.com"
    try await env.repo.update(stale)
    stored = try #require(try await env.repo.host(id: h.id))
    #expect(stored.autofillHold && stored.hostName == "other.example.com")
    try await env.repo.confirmAutofillHold(id: h.id)
    stored = try #require(try await env.repo.host(id: h.id))
    #expect(!stored.autofillHold && stored.autofillHoldReason == nil)
}

// MARK: - SSH config

private func specs(_ env: RepoEnv, agent: String? = nil) async throws -> [SSHHostSpec] {
    try await env.repo.sshSpecs(defaultIdentityAgent: agent)
}

@Test func sshSpecsTakeKeyAgentUserFromSet() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let set = try await env.repo.createCredentialSet(
        CredentialSet(name: "S", identityFile: "/keys/team", identityAgent: "~/set.sock"))
    var h = managedHost()
    h.authMethod = .keyFile
    h.credentialSetID = set.id
    try await env.repo.insert(h)
    var s = try #require(try await specs(env, agent: "~/default.sock").first)
    #expect(s.identityFile == "/keys/team")
    #expect(s.identityAgent == "~/set.sock")
    let text = try SSHConfigWriter.render(hosts: [s], userConfigPath: nil)
    #expect(text.contains("    IdentityFile \"/keys/team\""))
    #expect(text.contains("    IdentitiesOnly yes"))
    #expect(text.contains("    IdentityAgent \"~/set.sock\""))
    // Đổi key của bộ → mọi host nhận giá trị mới.
    var edit = set
    edit.identityFile = "/keys/new"
    try await env.repo.updateCredentialSet(edit)
    s = try #require(try await specs(env).first)
    #expect(s.identityFile == "/keys/new")
    // Host ghi đè bằng key riêng.
    var stored = try #require(try await env.repo.host(id: h.id))
    stored.identityFile = "/keys/own"
    try await env.repo.update(stored)
    #expect(try await specs(env).first?.identityFile == "/keys/own")
}

@Test func writerQuotesSetPathsAndRejectsInjection() throws {
    let spec = SSHHostSpec(
        alias: "sshdesk-a", hostName: "h.example.com", user: "u",
        identityFile: "/keys/a \"q\" \\b", identityAgent: "/tmp/a\"b.sock")
    let text = try SSHConfigWriter.render(hosts: [spec], userConfigPath: nil)
    #expect(text.contains(#"IdentityFile "/keys/a \"q\" \\b""#))
    #expect(text.contains(#"IdentityAgent "/tmp/a\"b.sock""#))
    for bad in ["/k\nProxyCommand evil", "/k\rProxyCommand evil", "/k\u{0}", "/k\u{7}"] {
        var s = spec
        s.identityFile = bad
        #expect(throws: SSHConfigError.self) { try SSHConfigWriter.render(hosts: [s], userConfigPath: nil) }
    }
    var s = spec
    s.identityAgent = "/a\nProxyCommand evil"
    #expect(throws: SSHConfigError.self) { try SSHConfigWriter.render(hosts: [s], userConfigPath: nil) }
}

@Test func tamperedSetRowCannotInjectDirectiveIntoConfig() async throws {
    let env = try RepoEnv()
    defer { env.dir.cleanup() }
    let set = try await env.repo.createCredentialSet(CredentialSet(name: "S", identityFile: "/keys/a"))
    var h = managedHost()
    h.credentialSetID = set.id
    h.authMethod = .keyFile
    try await env.repo.insert(h)
    // DB bị sửa trực tiếp (bỏ qua validator của repository): lúc sinh config vẫn bị chặn.
    try env.db.execute(
        "UPDATE credential_sets SET identity_file = ? WHERE id = ?",
        [.text("/k\nProxyCommand evil"), .text(set.id.uuidString)])
    let tampered = try await env.repo.sshSpecs()
    #expect(throws: SSHConfigError.self) { try SSHConfigWriter.render(hosts: tampered, userConfigPath: nil) }
}
