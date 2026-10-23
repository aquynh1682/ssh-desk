import Foundation
import Testing

@testable import SSHDeskCore

// ADR-029/030: kiểm tra đăng nhập TRƯỚC khi lưu; lưu theo lựa chọn; không ghi đè bộ khi sai.

private final class StubVerifier: PasswordVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(hostID: UUID, password: String)] = []
    var results: [String: PasswordVerification] = [:]
    var fallback: PasswordVerification = .ok

    func verify(host: HostProfile, password: String) async -> PasswordVerification {
        lock.withLock { calls.append((host.id, password)) }
        return results[password] ?? fallback
    }
    var passwords: [String] { lock.withLock { calls.map(\.password) } }
}

/// Kho đếm số lần `save` để chứng minh "không tích lưu / sai" thì không ghi gì.
private final class CountingStore: CredentialStore, @unchecked Sendable {
    let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private(set) var saves: [String] = []
    func save(ref: String, password: String) throws {
        lock.withLock { saves.append(ref) }
        try inner.save(ref: ref, password: password)
    }
    func read(ref: String) -> String? { inner.read(ref: ref) }
    func delete(ref: String) throws { try inner.delete(ref: ref) }
    func exists(ref: String) -> Bool { inner.exists(ref: ref) }
}

private struct Rig {
    let dir = HostTempDir()
    let store = CountingStore()
    let verifier = StubVerifier()
    let repo: HostRepository
    let service: ConnectionService
    let entry: PasswordEntryService

    init() throws {
        let paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs")),
            credentials: store)
        entry = PasswordEntryService(connection: service, verifier: verifier, credentials: store)
    }

    func addHost(_ name: String = "web", hostName: String = "web.example.com") async throws -> HostProfile {
        var h = managedHost(name, hostName: hostName)
        h.authMethod = .interactive
        try await service.add(h)
        return h
    }

    func addSet(_ name: String = "prod", password: String? = "set-pw") async throws -> CredentialSet {
        try await service.createCredentialSet(CredentialSet(name: name), password: password)
    }
}

@Suite struct PasswordEntryServiceTests {
    @Test func thisHostOnlyVerifiesThenSavesOwnPassword() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let result = await r.entry.save(hostID: h.id, password: "pw1", choice: .thisHostOnly)
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        let ref = try #require(saved.credentialReference)
        #expect(r.store.read(ref: ref) == "pw1")
        #expect(r.verifier.passwords == ["pw1"])
        #expect(saved.credentialSetID == nil)
    }

    @Test func wrongPasswordSavesNothing() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        r.verifier.results["bad"] = .wrongPassword
        #expect(await r.entry.save(hostID: h.id, password: "bad", choice: .thisHostOnly) == .wrongPassword)
        #expect(r.store.saves.isEmpty)
        #expect(try await r.repo.host(id: h.id)?.credentialReference == nil)
    }

    @Test func blockedAndUnverifiableResultsSaveNothingAndAreDistinguished() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        for blocked in [
            PasswordVerification.hostKeyUnconfirmed, .hostKeyChanged, .otherPrompt("Verification code:"),
        ] {
            r.verifier.fallback = blocked
            #expect(
                await r.entry.save(hostID: h.id, password: "p", choice: .thisHostOnly) == .blocked(blocked))
        }
        for loose in [PasswordVerification.timeout, .networkError("Connection refused")] {
            r.verifier.fallback = loose
            #expect(
                await r.entry.save(hostID: h.id, password: "p", choice: .thisHostOnly) == .unverifiable(loose))
        }
        #expect(r.store.saves.isEmpty)
    }

    @Test func saveAnywayAfterUnverifiableSavesWithoutCallingVerifier() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let result = await r.entry.saveWithoutVerifying(hostID: h.id, password: "pw", choice: .thisHostOnly)
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(r.store.read(ref: try #require(saved.credentialReference)) == "pw")
        #expect(r.verifier.passwords.isEmpty)
    }

    @Test func existingSetVerifiesWithSetPasswordAndAssigns() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let set = try await r.addSet()
        let saves = r.store.saves.count
        let result = await r.entry.save(hostID: h.id, password: "ignored", choice: .existingSet(set.id))
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(saved.credentialSetID == set.id)
        #expect(r.verifier.passwords == ["set-pw"], "kiểm bằng password của bộ, không dùng chuỗi đã gõ")
        #expect(r.store.saves.count == saves, "không ghi password nào mới")
        #expect(saved.autofillHold == false)
    }

    @Test func existingSetWrongDoesNotOverwriteSetAndReportsAffectedHosts() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let other = try await r.addHost("other", hostName: "other.example.com")
        let set = try await r.addSet()
        _ = try await r.service.assignCredentialSet(setID: set.id, to: [other.id])
        r.verifier.results["set-pw"] = .wrongPassword
        let saves = r.store.saves.count
        let result = await r.entry.save(hostID: h.id, password: "typed", choice: .existingSet(set.id))
        #expect(result == .setPasswordWrong(setID: set.id, setName: "prod", affectedHosts: 2))
        #expect(r.store.read(ref: set.passwordReference) == "set-pw")
        #expect(r.store.saves.count == saves)
        #expect(try await r.repo.host(id: h.id)?.credentialSetID == nil)
    }

    @Test func updateSetPasswordVerifiesNewPasswordThenOverwritesAndAssigns() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let set = try await r.addSet()
        r.verifier.results["bad-new"] = .wrongPassword
        #expect(
            await r.entry.updateSetPassword(hostID: h.id, setID: set.id, newPassword: "bad-new")
                == .wrongPassword)
        #expect(r.store.read(ref: set.passwordReference) == "set-pw", "sai thì giữ nguyên bộ")
        let result = await r.entry.updateSetPassword(hostID: h.id, setID: set.id, newPassword: "new-pw")
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(saved.credentialSetID == set.id)
        #expect(r.store.read(ref: set.passwordReference) == "new-pw")
    }

    @Test func existingSetWithoutPasswordIsRejectedBeforeAnyConnection() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let set = try await r.addSet("empty", password: nil)
        let result = await r.entry.save(hostID: h.id, password: "x", choice: .existingSet(set.id))
        guard case .invalid = result else {
            Issue.record("\(result)")
            return
        }
        #expect(r.verifier.passwords.isEmpty)
    }

    @Test func newSetCreatesSetStoresPasswordAndAssigns() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let result = await r.entry.save(hostID: h.id, password: "pw-new", choice: .newSet(name: "  Staging  "))
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        let setID = try #require(saved.credentialSetID)
        let set = try #require(try await r.repo.credentialSet(id: setID))
        #expect(set.name == "Staging")
        #expect(r.store.read(ref: set.passwordReference) == "pw-new")
        #expect(saved.credentialReference == nil, "mật khẩu nằm ở bộ, không phải riêng")
        #expect(r.verifier.passwords == ["pw-new"])
    }

    @Test func newSetWrongPasswordCreatesNoSet() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        r.verifier.fallback = .wrongPassword
        #expect(
            await r.entry.save(hostID: h.id, password: "bad", choice: .newSet(name: "S")) == .wrongPassword)
        #expect(try await r.repo.credentialSets().isEmpty)
        #expect(r.store.saves.isEmpty)
    }

    @Test func newSetNameRulesAreCheckedBeforeConnecting() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        _ = try await r.addSet("Prod")
        for name in ["", "   ", "prod", "PROD", "bad\nname"] {
            let result = await r.entry.save(hostID: h.id, password: "pw", choice: .newSet(name: name))
            guard case .invalid = result else {
                Issue.record("\(name): \(result)")
                return
            }
        }
        #expect(r.verifier.passwords.isEmpty)
    }

    @Test func choosingSetClearsBrokenOwnPasswordThatWouldOverrideIt() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        var h = try await r.addHost()
        h.credentialReference = "dead-ref"  // item không còn trong kho
        _ = try await r.repo.update(h)
        let set = try await r.addSet()
        let result = await r.entry.save(hostID: h.id, password: "x", choice: .existingSet(set.id))
        guard case .saved(let saved) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(saved.credentialReference == nil && saved.credentialSetID == set.id)
        #expect(saved.effectiveCredentialReference == set.passwordReference)
    }

    @Test func emptyPasswordIsRejected() async throws {
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let result = await r.entry.save(hostID: h.id, password: "", choice: .thisHostOnly)
        guard case .invalid = result else {
            Issue.record("\(result)")
            return
        }
        #expect(r.verifier.passwords.isEmpty)
    }

    @Test func vaultPathNoSaveNeverTouchesStore() async throws {
        // "Không tích lưu": password chỉ vào vault; kho thật và DB không đổi.
        let r = try Rig()
        defer { r.dir.cleanup() }
        let h = try await r.addHost()
        let vault = EphemeralPasswordVault()
        vault.retain(host: h, password: "only-memory", owner: "monitor")
        #expect(r.store.saves.isEmpty)
        #expect(try await r.repo.host(id: h.id)?.credentialReference == nil)
        vault.releaseAll(owner: "monitor")
        #expect(!vault.has(hostID: h.id))
    }
}
