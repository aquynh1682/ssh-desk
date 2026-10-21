import Foundation
import Testing

@testable import SSHDeskCore

@Suite struct HostProfileTests {
    @Test func validManagedAndImportedPass() throws {
        try managedHost().validate()
        try importedHost().validate()
        var k = managedHost()
        k.authMethod = .keyFile
        k.identityFile = "/Users/me/.ssh/id_ed25519"
        try k.validate()
    }

    @Test func emptyDisplayName() {
        var h = managedHost()
        h.displayName = "   "
        #expect(throws: HostValidationError.emptyDisplayName) { try h.validate() }
    }

    @Test func managedFields() {
        var h = managedHost()
        h.hostName = ""
        #expect(throws: HostValidationError.invalidHostName("")) { try h.validate() }
        h.hostName = "a b"
        #expect(throws: HostValidationError.invalidHostName("a b")) { try h.validate() }
        h.hostName = "-oProxyCommand=x"
        #expect(throws: HostValidationError.invalidHostName("-oProxyCommand=x")) {
            try h.validate()
        }
        h = managedHost(user: "bad user")
        #expect(throws: HostValidationError.invalidUser("bad user")) { try h.validate() }
        h = managedHost(user: "u\nProxyCommand x")
        #expect(throws: HostValidationError.self) { try h.validate() }
        h = managedHost()
        h.port = 0
        #expect(throws: HostValidationError.invalidPort(0)) { try h.validate() }
        h.port = 70000
        #expect(throws: HostValidationError.invalidPort(70000)) { try h.validate() }
    }

    @Test func keyFileNeedsAbsoluteIdentity() {
        var h = managedHost()
        h.authMethod = .keyFile
        h.identityFile = nil
        #expect(throws: HostValidationError.identityFileRequired) { try h.validate() }
        h.identityFile = "~/.ssh/id"
        #expect(throws: HostValidationError.invalidIdentityFile) { try h.validate() }
        h.identityFile = "relative/key"
        #expect(throws: HostValidationError.invalidIdentityFile) { try h.validate() }
    }

    @Test func importedFields() {
        var h = importedHost()
        h.sshConfigAlias = "bad alias"
        #expect(throws: HostValidationError.invalidAlias("bad alias")) { try h.validate() }
        h.sshConfigAlias = nil
        #expect(throws: HostValidationError.invalidAlias("")) { try h.validate() }
        h = importedHost()
        h.sshConfigPath = "config"
        #expect(throws: HostValidationError.invalidSSHConfigPath) { try h.validate() }
        h.sshConfigPath = nil
        #expect(throws: HostValidationError.invalidSSHConfigPath) { try h.validate() }
        h = importedHost()
        h.jumpHostID = UUID()
        #expect(throws: HostValidationError.jumpHostNotAllowed) { try h.validate() }
    }

    @Test func nulRejectedInEveryFreeTextField() {
        let nul = "a\u{0}b"
        let cases: [(String, (inout HostProfile) -> Void)] = [
            ("displayName", { $0.displayName = nul }),
            ("project", { $0.project = nul }),
            ("notes", { $0.notes = nul }),
            ("tags", { $0.tags = [nul] }),
            ("remoteBookmarks.name", { $0.remoteBookmarks = [RemoteBookmark(name: nul, path: "/")] }),
            ("remoteBookmarks.path", { $0.remoteBookmarks = [RemoteBookmark(name: "n", path: nul)] }),
            ("defaultLocalDirectory", { $0.defaultLocalDirectory = nul }),
            ("defaultRemoteDirectory", { $0.defaultRemoteDirectory = nul }),
            ("credentialReference", { $0.credentialReference = nul }),
        ]
        for (field, mutate) in cases {
            var h = managedHost()
            mutate(&h)
            #expect(throws: HostValidationError.containsNUL(field: field)) { try h.validate() }
        }
    }

    @Test func selfJumpRejected() {
        var h = managedHost()
        h.jumpHostID = h.id
        #expect(throws: HostValidationError.selfJump) { try h.validate() }
    }

    @Test func codableRoundTrip() throws {
        var h = managedHost(tags: ["a"])
        h.remoteBookmarks = [RemoteBookmark(name: "logs", path: "/var/log")]
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(HostProfile.self, from: data) == h)
    }
}

@Suite struct HostDuplicateTests {
    @Test func copiesConfigAndResetsPerHostState() {
        var h = managedHost()
        h.isFavorite = true
        h.lastLaunchRequestedAt = Date(timeIntervalSince1970: 5)
        h.credentialReference = "ref-1"
        h.project = "Prod"
        h.environment = .prod
        h.tags = ["a", "b"]
        h.notes = "ghi chú"
        h.authMethod = .keyFile
        h.identityFile = "/Users/me/.ssh/k"
        h.jumpHostID = UUID()
        h.remoteBookmarks = [RemoteBookmark(name: "w", path: "/var/www")]
        h.defaultLocalDirectory = "/tmp"
        h.defaultRemoteDirectory = "/srv"
        let newID = UUID()
        let now = Date(timeIntervalSince1970: 99)
        let c = h.duplicated(newID: newID, now: now, existingNames: [h.displayName])
        #expect(c.id == newID && c.id != h.id)
        #expect(c.displayName == "\(h.displayName) (bản sao)")
        #expect(!c.isFavorite && c.lastLaunchRequestedAt == nil && c.credentialReference == nil)
        #expect(c.createdAt == now && c.updatedAt == now)
        var expected = h
        expected.id = newID
        expected.displayName = c.displayName
        expected.isFavorite = false
        expected.lastLaunchRequestedAt = nil
        expected.credentialReference = nil
        expected.createdAt = now
        expected.updatedAt = now
        #expect(c == expected)
    }

    @Test func importedKeepsAlias() {
        let c = importedHost().duplicated(existingNames: [])
        #expect(c.connectionMode == .existingSSHConfigAlias)
        #expect(c.sshConfigAlias == importedHost().sshConfigAlias)
    }

    @Test func nameSuffixIncrementsOnCollision() {
        let h = managedHost()
        let base = h.displayName
        let n1 = "\(base) (bản sao)"
        let n2 = "\(base) (bản sao 2)"
        #expect(h.duplicated(existingNames: [base, n1]).displayName == n2)
        #expect(h.duplicated(existingNames: [base, n1, n2]).displayName == "\(base) (bản sao 3)")
        #expect(h.duplicated(existingNames: [n1.uppercased()]).displayName == n2)
    }
}
