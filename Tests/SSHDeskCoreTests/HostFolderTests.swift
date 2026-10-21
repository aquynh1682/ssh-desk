import Foundation
import Testing

@testable import SSHDeskCore

struct HostFolderTests {
    @Test func normalizeRules() throws {
        #expect(try HostFolders.normalize("  Web  ") == "Web")
        #expect(throws: FolderNameError.empty) { try HostFolders.normalize("   ") }
        #expect(throws: FolderNameError.controlCharacters) { try HostFolders.normalize("a\u{07}b") }
        #expect(throws: FolderNameError.controlCharacters) { try HostFolders.normalize("a\tb") }
        #expect(throws: FolderNameError.tooLong) {
            try HostFolders.normalize(String(repeating: "x", count: 101))
        }
        #expect(try HostFolders.normalize(String(repeating: "x", count: 100)).count == 100)
    }

    @Test func countsAndGroups() {
        let hosts = [
            managedHost("a", project: "Zeta"), managedHost("b", project: "écho"),
            managedHost("c", project: "Zeta"), managedHost("d"),
        ]
        let counts = HostFolders.counts(hosts, emptyFolders: ["alpha"])
        #expect(counts.map(\.name) == ["alpha", "écho", "Zeta"])
        #expect(counts.map(\.count) == [0, 1, 2])
        #expect(HostFolders.uncategorizedCount(hosts) == 1)
        let groups = HostFolders.group(hosts, emptyFolders: ["alpha"])
        #expect(groups.map(\.title) == ["alpha", "écho", "Zeta", "Chưa phân loại"])
        #expect(groups[2].hosts.map(\.displayName) == ["a", "c"])
        #expect(HostFolders.group([managedHost("x", project: "P")]).count == 1)
    }

    @Test func dragPayloadRoundTripAndRejectsGarbage() {
        let ids = [UUID(), UUID()]
        #expect(HostFolders.parseDragPayload(HostFolders.dragPayload(ids)) == ids)
        #expect(HostFolders.parseDragPayload("hello") == nil)
        #expect(HostFolders.parseDragPayload("sshdesk-hosts:") == nil)
        #expect(HostFolders.parseDragPayload("sshdesk-hosts:\(UUID().uuidString),zzz") == nil)
    }

    private func repo() throws -> (HostRepository, HostTempDir) {
        let dir = HostTempDir()
        return (HostRepository(database: try Database(url: dir.dbURL)), dir)
    }

    @Test func emptyFolderPersistsAndListsWithHostFolders() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        try await r.insert(managedHost("a", project: "Beta"))
        #expect(try await r.createFolder("  Alpha ") == "Alpha")
        #expect(try await r.createFolder("alpha") == "Alpha")  // trùng → dùng lại
        #expect(try await r.folders() == ["Alpha", "Beta"])
        await #expect(throws: FolderNameError.empty) { try await r.createFolder(" ") }
    }

    @Test func renameMovesAllHostsAndEmptyFolder() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        let a = managedHost("a", project: "Old")
        let b = managedHost("b", project: "Old")
        let c = managedHost("c", project: "Other")
        for h in [a, b, c] { try await r.insert(h) }
        #expect(try await r.renameFolder(from: "Old", to: " New ") == "New")
        #expect(try await r.host(id: a.id)?.project == "New")
        #expect(try await r.host(id: b.id)?.project == "New")
        #expect(try await r.host(id: c.id)?.project == "Other")
        try await r.createFolder("Empty")
        try await r.renameFolder(from: "Empty", to: "Empty2")
        #expect(try await r.folders() == ["Empty2", "New", "Other"])
        // đổi hoa/thường của chính nó được phép
        #expect(try await r.renameFolder(from: "New", to: "new") == "new")
    }

    @Test func renameToExistingNeedsMerge() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        let a = managedHost("a", project: "One")
        let b = managedHost("b", project: "Hai")
        try await r.insert(a)
        try await r.insert(b)
        await #expect(throws: HostRepositoryError.folderNameExists("Hai")) {
            try await r.renameFolder(from: "One", to: "hai")
        }
        #expect(try await r.host(id: a.id)?.project == "One")  // không đổi gì
        #expect(try await r.renameFolder(from: "One", to: "hai", merge: true) == "Hai")
        #expect(try await r.host(id: a.id)?.project == "Hai")
        #expect(try await r.folders() == ["Hai"])
    }

    @Test func deleteFolderKeepsHosts() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        let a = managedHost("a", project: "X")
        try await r.insert(a)
        try await r.createFolder("Empty")
        #expect(try await r.deleteFolder("X") == 1)
        #expect(try await r.deleteFolder("Empty") == 0)
        #expect(try await r.host(id: a.id)?.project == "")
        #expect(try await r.folders().isEmpty)
    }

    @Test func moveHosts() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        let a = managedHost("a", project: "X")
        let b = managedHost("b")
        try await r.insert(a)
        try await r.insert(b)
        try await r.moveHosts(ids: [a.id, b.id], toFolder: "x")
        #expect(try await r.host(id: b.id)?.project == "X")  // dùng cách viết sẵn có
        try await r.moveHosts(ids: [a.id], toFolder: nil)
        #expect(try await r.host(id: a.id)?.project == "")
        // thư mục bị bỏ trống vẫn còn
        #expect(try await r.folders() == ["X"])
        let ghost = UUID()
        await #expect(throws: HostRepositoryError.notFound(ghost)) {
            try await r.moveHosts(ids: [ghost], toFolder: "X")
        }
    }

    @Test func folderSurvivesWhenLastHostEditedAway() async throws {
        let (r, dir) = try repo()
        defer { dir.cleanup() }
        var a = managedHost("a", project: "Keep")
        try await r.insert(a)
        a.project = "Else"
        try await r.update(a)
        #expect(try await r.folders() == ["Else", "Keep"])
    }
}
