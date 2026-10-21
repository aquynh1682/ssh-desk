import Foundation
import Testing

@testable import SSHDeskCore

@Suite struct HostRepositoryTests {
    private func makeRepo(_ t: HostTempDir) throws -> HostRepository {
        HostRepository(database: try Database(url: t.dbURL))
    }

    @Test func crudAndPersistenceAcrossReopen() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        var h = managedHost("Web", project: "Alpha", tags: ["x", "y"])
        h.createdAt = Date(timeIntervalSince1970: 1000)
        h.updatedAt = Date(timeIntervalSince1970: 2000)
        h.environment = .prod
        h.notes = "ghi chú"
        h.authMethod = .keyFile
        h.identityFile = "/Users/me/.ssh/k"
        h.credentialReference = "keychain:abc"
        h.remoteBookmarks = [RemoteBookmark(name: "logs", path: "/var/log")]
        h.defaultLocalDirectory = "/tmp"
        h.defaultRemoteDirectory = "/srv"
        h.lastLaunchRequestedAt = Date(timeIntervalSince1970: 1234)
        do {
            let repo = try makeRepo(t)
            try await repo.insert(h)
            #expect(try await repo.host(id: h.id) == h)
            #expect(try await repo.all().count == 1)
        }
        let repo = try makeRepo(t)
        #expect(try await repo.host(id: h.id) == h)

        h.displayName = "Web 2"
        h.createdAt = Date(timeIntervalSince1970: 5)  // phải bị bỏ qua
        let saved = try await repo.update(h)
        #expect(saved.updatedAt > saved.createdAt)
        #expect(saved.createdAt != Date(timeIntervalSince1970: 5))
        #expect(try await repo.host(id: h.id)?.displayName == "Web 2")

        try await repo.delete(id: h.id)
        #expect(try await repo.host(id: h.id) == nil)
        await #expect(throws: HostRepositoryError.notFound(h.id)) { try await repo.delete(id: h.id) }
        await #expect(throws: HostRepositoryError.notFound(h.id)) { try await repo.update(h) }
    }

    @Test func duplicateAndInvalidInsert() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let h = managedHost()
        try await repo.insert(h)
        await #expect(throws: HostRepositoryError.duplicateID(h.id)) { try await repo.insert(h) }
        var bad = managedHost()
        bad.displayName = ""
        await #expect(throws: HostValidationError.emptyDisplayName) { try await repo.insert(bad) }
        #expect(try await repo.all().count == 1)
    }

    @Test func favoritesProjectsAndLaunch() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let a = managedHost("a", project: "P1")
        let b = managedHost("b", project: "P2")
        let c = managedHost("c", project: "P1")
        for h in [a, b, c] { try await repo.insert(h) }
        try await repo.setFavorite(id: b.id, true)
        #expect(try await repo.favorites().map(\.id) == [b.id])
        try await repo.setFavorite(id: b.id, false)
        #expect(try await repo.favorites().isEmpty)
        #expect(try await repo.folders() == ["P1", "P2"])
        let d = Date(timeIntervalSince1970: 999)
        try await repo.markLaunchRequested(id: a.id, at: d)
        #expect(try await repo.host(id: a.id)?.lastLaunchRequestedAt == d)
        await #expect(throws: HostRepositoryError.self) {
            try await repo.markLaunchRequested(id: UUID(), at: d)
        }
    }

    @Test func searchTreatsInputLiterally() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let pct = managedHost("100% done", hostName: "p.example.com")
        let und = managedHost("a_b", hostName: "u.example.com")
        let plain = managedHost("axb", hostName: "x.example.com", user: "Admin", tags: ["Prod-DB"])
        let quote = managedHost("it's", hostName: "q.example.com", project: "Dự Án Việt")
        for h in [pct, und, plain, quote] { try await repo.insert(h) }

        #expect(try await repo.search("%").map(\.id) == [pct.id])
        #expect(try await repo.search("_").map(\.id) == [und.id])
        #expect(try await repo.search("a_b").map(\.id) == [und.id])
        #expect(try await repo.search("'").map(\.id) == [quote.id])
        #expect(try await repo.search("ADMIN").map(\.id) == [plain.id])
        #expect(try await repo.search("prod-db").map(\.id) == [plain.id])
        #expect(try await repo.search("x.EXAMPLE").map(\.id) == [plain.id])
        #expect(try await repo.search("dự án").map(\.id) == [quote.id])
        #expect(try await repo.search("DỰ ÁN VIỆT").map(\.id) == [quote.id])
        #expect(try await repo.search("").count == 4)
        #expect(try await repo.search("nope").isEmpty)

        #expect(try await repo.search("\"; DROP TABLE hosts;--").isEmpty)
        #expect(try await repo.search("'; DROP TABLE hosts;--").isEmpty)
        #expect(try await repo.all().count == 4)
        // Chèn tên độc hại: lưu nguyên văn, bảng vẫn còn.
        let evil = managedHost("\"; DROP TABLE hosts;--")
        try await repo.insert(evil)
        #expect(try await repo.host(id: evil.id)?.displayName == "\"; DROP TABLE hosts;--")
        #expect(try await repo.search("drop table").map(\.id) == [evil.id])
    }

    @Test func deleteReferencedJumpHostRejected() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let bastion = managedHost("bastion", hostName: "b.example.com")
        let target = managedHost("target", jump: bastion.id)
        try await repo.insert(bastion)
        try await repo.insert(target)
        await #expect(throws: HostRepositoryError.referencedAsJumpHost([target.id])) {
            try await repo.delete(id: bastion.id)
        }
        #expect(try await repo.host(id: bastion.id) != nil)
        try await repo.delete(id: target.id)
        try await repo.delete(id: bastion.id)
        #expect(try await repo.all().isEmpty)
    }

    @Test func jumpHostMustExistAndNotCycle() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let ghost = UUID()
        await #expect(throws: HostRepositoryError.jumpHostNotFound(ghost)) {
            try await repo.insert(managedHost(jump: ghost))
        }
        let a = managedHost("a", hostName: "a.example.com")
        let b = managedHost("b", hostName: "b.example.com", jump: a.id)
        try await repo.insert(a)
        try await repo.insert(b)
        var a2 = a
        a2.jumpHostID = b.id  // A→B→A
        await #expect(throws: HostRepositoryError.self) { try await repo.update(a2) }
        do {
            try await repo.update(a2)
        } catch let HostRepositoryError.jumpCycle(path) {
            #expect(path.first == a.id && path.last == a.id)
        }
        #expect(try await repo.host(id: a.id)?.jumpHostID == nil)
        var selfJump = a
        selfJump.jumpHostID = a.id
        await #expect(throws: HostValidationError.selfJump) { try await repo.update(selfJump) }
        // Chuỗi dài A→B→C→A
        let c = managedHost("c", hostName: "c.example.com", jump: b.id)
        try await repo.insert(c)
        a2.jumpHostID = c.id
        await #expect(throws: HostRepositoryError.self) { try await repo.update(a2) }
    }

    @Test func sshSpecsAndAliases() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)

        let bastion = managedHost("bastion", hostName: "b.example.com", user: "jump")
        var viaManaged = managedHost("app", hostName: "10.0.0.5", jump: bastion.id)
        viaManaged.authMethod = .keyFile
        viaManaged.identityFile = "/Users/me/.ssh/k"
        viaManaged.port = 2222
        let imported = importedHost("old", alias: "bastion-u")
        // Managed đi qua bastion là alias imported: chèn imported rồi trỏ jump vào nó.
        let viaImported = managedHost("db", hostName: "10.0.0.9", jump: imported.id)
        for h in [bastion, viaManaged, imported, viaImported] { try await repo.insert(h) }

        let specs = try await repo.sshSpecs()
        let byAlias = Dictionary(uniqueKeysWithValues: specs.map { ($0.alias, $0) })
        #expect(specs.count == 3)  // imported không sinh Host block
        #expect(byAlias["sshdesk-\(imported.id.uuidString.lowercased())"] == nil)

        let b = try #require(byAlias["sshdesk-\(bastion.id.uuidString.lowercased())"])
        #expect(b.jumpAlias == nil && b.identityFile == nil && b.user == "jump" && b.port == 22)

        let m = try #require(byAlias["sshdesk-\(viaManaged.id.uuidString.lowercased())"])
        #expect(m.jumpAlias == "sshdesk-\(bastion.id.uuidString.lowercased())")
        #expect(m.identityFile == "/Users/me/.ssh/k" && m.port == 2222 && m.hostName == "10.0.0.5")

        let i = try #require(byAlias["sshdesk-\(viaImported.id.uuidString.lowercased())"])
        #expect(i.jumpAlias == "bastion-u")

        #expect(repo.sshAlias(for: bastion) == "sshdesk-\(bastion.id.uuidString.lowercased())")
        #expect(repo.sshAlias(for: imported) == "bastion-u")

        let rendered = try SSHConfigWriter.render(hosts: specs, userConfigPath: nil)
        #expect(rendered.contains("ProxyJump bastion-u"))
        #expect(rendered.contains("Host sshdesk-\(bastion.id.uuidString.lowercased())"))
        #expect(!rendered.contains("Host bastion-u"))
    }

    @Test func agentAuthDropsIdentityFileInSpec() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        var h = managedHost()
        h.authMethod = .agent
        h.identityFile = "/Users/me/.ssh/leftover"
        try await repo.insert(h)
        #expect(try await repo.sshSpecs().first?.identityFile == nil)
    }
}
