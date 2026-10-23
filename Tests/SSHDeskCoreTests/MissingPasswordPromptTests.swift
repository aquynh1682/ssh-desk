import Foundation
import Testing

@testable import SSHDeskCore

// ADR-029: bảng quyết định có hiện sheet hỏi mật khẩu không.

private final class StatusStore: CredentialStore, @unchecked Sendable {
    var statuses: [String: CredentialStatus] = [:]
    func save(ref: String, password: String) throws { statuses[ref] = .present }
    func read(ref: String) -> String? { statuses[ref] == .present ? "x" : nil }
    func delete(ref: String) throws { statuses[ref] = nil }
    func exists(ref: String) -> Bool { statuses[ref] == .present }
    func status(ref: String) -> CredentialStatus { statuses[ref] ?? .missing }
}

private func ssh(
    auth: HostAuthMethod = .interactive, jump: UUID? = nil, hold: Bool = false, ref: String? = nil,
    setID: UUID? = nil, kind: HostKind = .ssh, imported: Bool = false
) -> HostProfile {
    if imported {
        return HostProfile(
            displayName: "legacy", connectionMode: .existingSSHConfigAlias, authMethod: auth,
            sshConfigPath: "/Users/me/.ssh/config", sshConfigAlias: "legacy")
    }
    if kind == .windowsRDP {
        return HostProfile(
            displayName: "win", kind: .windowsRDP, rdpUsername: "admin", hostName: "win.example.com",
            user: "", authMethod: auth, credentialReference: ref, credentialSetID: setID,
            autofillHold: hold)
    }
    return HostProfile(
        displayName: "web", hostName: "web.example.com", user: "deploy", authMethod: auth, jumpHostID: jump,
        credentialReference: ref, credentialSetID: setID, autofillHold: hold)
}

private func decide(
    _ host: HostProfile, settings: AppSettings = .default, store: StatusStore = StatusStore(),
    set: CredentialSet? = nil
) -> MissingPasswordPrompt.Decision {
    let resolved = CredentialResolution.resolve(host: host, set: set, settingsDefaultAgent: nil)
    return MissingPasswordPrompt.decide(host: host, resolved: resolved, settings: settings, store: store)
}

@Suite struct MissingPasswordPromptTests {
    @Test func plainInteractiveSSHHostWithoutPasswordAsks() {
        #expect(decide(ssh()) == .ssh)
    }

    @Test func settingsDefaultPromptIsOn() {
        #expect(AppSettings.default.promptMissingPassword)
    }

    @Test func tableOfBlockingConditions() {
        var off = AppSettings.default
        off.promptMissingPassword = false
        #expect(decide(ssh(), settings: off) == .none)
        var noAutofill = AppSettings.default
        noAutofill.autofillEnabled = false
        #expect(decide(ssh(), settings: noAutofill) == .none)
        #expect(decide(ssh(jump: UUID())) == .none)
        #expect(decide(ssh(hold: true)) == .none)
        #expect(decide(ssh(auth: .agent)) == .none)
        #expect(decide(ssh(auth: .keyFile)) == .none)
        #expect(decide(ssh(imported: true)) == .none)
    }

    @Test func savedPasswordSkipsPromptButMissingOrUndecryptableAsks() {
        let store = StatusStore()
        let h = ssh(ref: "r1")
        // Ref có nhưng item không có (xoá tay) → hỏi.
        #expect(decide(h, store: store) == .ssh)
        store.statuses["r1"] = .present
        #expect(decide(h, store: store) == .none)
        // Không giải mã được (khoá SE mất) → hỏi lại.
        store.statuses["r1"] = .undecryptable
        #expect(decide(h, store: store) == .ssh)
    }

    @Test func setPasswordCounts() {
        let set = CredentialSet(name: "prod")
        let store = StatusStore()
        let h = ssh(setID: set.id)
        #expect(decide(h, store: store, set: set) == .ssh)
        store.statuses[set.passwordReference] = .present
        #expect(decide(h, store: store, set: set) == .none)
        store.statuses[set.passwordReference] = .undecryptable
        #expect(decide(h, store: store, set: set) == .ssh)
    }

    @Test func holdOnResolvedAlsoBlocks() {
        let host = ssh()
        var resolved = CredentialResolution.resolve(host: host, set: nil, settingsDefaultAgent: nil)
        resolved.autofillHold = true
        #expect(
            MissingPasswordPrompt.decide(
                host: host, resolved: resolved, settings: .default, store: StatusStore()) == .none)
    }

    @Test func nilResolvedFallsBackToHostFields() {
        let store = StatusStore()
        store.statuses["r1"] = .present
        #expect(
            MissingPasswordPrompt.decide(
                host: ssh(ref: "r1"), resolved: nil, settings: .default, store: store) == .none)
        #expect(
            MissingPasswordPrompt.decide(host: ssh(), resolved: nil, settings: .default, store: store)
                == .ssh)
    }

    @Test func windowsHostsGetTheirOwnDecision() {
        #expect(decide(ssh(kind: .windowsRDP)) == .windows)
        // Windows chọn "Nhập trong Windows App" (authMethod .agent) → không hỏi.
        #expect(decide(ssh(auth: .agent, kind: .windowsRDP)) == .none)
        let store = StatusStore()
        store.statuses["w"] = .present
        #expect(decide(ssh(ref: "w", kind: .windowsRDP), store: store) == .none)
        var off = AppSettings.default
        off.promptMissingPassword = false
        #expect(decide(ssh(kind: .windowsRDP), settings: off) == .none)
        var noAutofill = AppSettings.default
        noAutofill.autofillEnabled = false
        #expect(decide(ssh(kind: .windowsRDP), settings: noAutofill) == .none)
        #expect(decide(ssh(hold: true, kind: .windowsRDP)) == .none)
    }

    @Test func settingRoundTripsAndBadValueFallsBackToOn() {
        var s = AppSettings.default
        s.promptMissingPassword = false
        #expect(s.values["security.prompt_missing_password"] == "0")
        #expect(!AppSettings(values: s.values).promptMissingPassword)
        #expect(AppSettings(values: ["security.prompt_missing_password": "???"]).promptMissingPassword)
        #expect(AppSettings(values: [:]).promptMissingPassword)
    }
}

// MARK: - Kho tạm trong bộ nhớ (ADR-029 "không tích lưu")

@Suite struct EphemeralPasswordVaultTests {
    @Test func adjustedHostGetsEphemeralRefAndAutofillReadsFromOverlay() throws {
        let vault = EphemeralPasswordVault()
        let real = InMemoryCredentialStore()
        let overlay = EphemeralOverlayCredentialStore(base: real, vault: vault)
        let h = ssh()
        // Chưa có trong vault: host không đổi.
        #expect(vault.adjusted(h) == h)
        vault.retain(host: h, password: "tmp-pw", owner: "tab-1")
        let adjusted = vault.adjusted(h)
        let ref = try #require(adjusted.autofillCredentialReference)
        #expect(ref == EphemeralPasswordVault.reference(for: h.id))
        #expect(overlay.read(ref: ref) == "tmp-pw")
        #expect(overlay.status(ref: ref) == .present && overlay.exists(ref: ref))
        // Chính sách tự điền áp dụng bình thường lên bản đã chỉnh.
        #expect(
            PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@web.example.com's password: ", host: adjusted, alreadyFilled: false))
        // Bản gốc không bị đổi; kho thật không có gì.
        #expect(h.credentialReference == nil)
        #expect(real.description.contains("count: 0"))
    }

    @Test func ephemeralRefsNeverWriteThroughToRealStore() {
        let vault = EphemeralPasswordVault()
        let real = InMemoryCredentialStore()
        let overlay = EphemeralOverlayCredentialStore(base: real, vault: vault)
        let ref = EphemeralPasswordVault.reference(for: UUID())
        #expect(throws: CredentialStoreError.invalidReference) { try overlay.save(ref: ref, password: "x") }
        #expect(real.description.contains("count: 0"))
        // Ref thường vẫn đi tới kho thật.
        try? overlay.save(ref: "r1", password: "real")
        #expect(real.read(ref: "r1") == "real" && overlay.read(ref: "r1") == "real")
    }

    @Test func releaseByLastOwnerClearsPassword() {
        let vault = EphemeralPasswordVault()
        let h = ssh()
        let id = h.id
        vault.retain(host: h, password: "pw", owner: "a")
        vault.retain(host: h, password: "pw", owner: "b")
        vault.release(hostID: id, owner: "a")
        #expect(vault.has(hostID: id))
        vault.release(hostID: id, owner: "b")
        #expect(!vault.has(hostID: id))
        let overlay = EphemeralOverlayCredentialStore(base: InMemoryCredentialStore(), vault: vault)
        #expect(overlay.read(ref: EphemeralPasswordVault.reference(for: id)) == nil)
    }

    @Test func releaseAllOwnerLeavesOthers() {
        let vault = EphemeralPasswordVault()
        let ha = ssh()
        let hb = ssh()
        let a = ha.id
        let b = hb.id
        vault.retain(host: ha, password: "1", owner: "monitor")
        vault.retain(host: hb, password: "2", owner: "monitor")
        vault.retain(host: hb, password: "2", owner: "tab")
        vault.releaseAll(owner: "monitor")
        #expect(!vault.has(hostID: a) && vault.has(hostID: b))
    }

    @Test func ephemeralOverridesSetButDescriptionNeverShowsPassword() {
        let vault = EphemeralPasswordVault()
        let set = CredentialSet(name: "s")
        var h = ssh(setID: set.id)
        h.credentialReference = nil
        vault.retain(host: h, password: "SECRET-IN-VAULT", owner: "x")
        #expect(vault.adjusted(h).effectiveCredentialReference == EphemeralPasswordVault.reference(for: h.id))
        #expect(!"\(vault)".contains("SECRET-IN-VAULT"))
    }

    @Test func hostWithEphemeralReferenceCannotBeValidatedForStorage() {
        let vault = EphemeralPasswordVault()
        let h = ssh()
        vault.retain(host: h, password: "pw", owner: "x")
        #expect(throws: HostValidationError.ephemeralReference) { try vault.adjusted(h).validate() }
        #expect(throws: Never.self) { try h.validate() }
    }

    @Test func repositoryRefusesToPersistAdjustedHost() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let repo = HostRepository(database: try Database(url: dir.dbURL))
        let h = ssh()
        try await repo.insert(h)
        let vault = EphemeralPasswordVault()
        vault.retain(host: h, password: "pw", owner: "x")
        await #expect(throws: HostValidationError.ephemeralReference) {
            _ = try await repo.update(vault.adjusted(h))
        }
        #expect(try await repo.host(id: h.id)?.credentialReference == nil)
    }

    @Test func changedTargetDropsTemporaryEntry() {
        let vault = EphemeralPasswordVault()
        let h = ssh()
        vault.retain(host: h, password: "pw", owner: "x")
        var moved = h
        moved.hostName = "evil.example.com"
        #expect(vault.adjusted(moved) == moved)
        moved = h
        moved.user = "root"
        #expect(vault.adjusted(moved) == moved)
        moved = h
        moved.port = 2222
        #expect(vault.adjusted(moved) == moved)
        #expect(vault.adjusted(h).credentialReference != nil)
    }

    @Test func shareKeepsEntryUntilLastOwnerReleases() {
        let vault = EphemeralPasswordVault()
        let h = ssh()
        vault.share(hostID: h.id, owner: "none")
        #expect(!vault.has(hostID: h.id))
        vault.retain(host: h, password: "pw", owner: "a")
        vault.share(hostID: h.id, owner: "b")
        vault.share(hostID: h.id, owner: "c")
        vault.release(hostID: h.id, owner: "a")
        vault.release(hostID: h.id, owner: "b")
        #expect(vault.has(hostID: h.id))
        vault.release(hostID: h.id, owner: "c")
        #expect(!vault.has(hostID: h.id))
    }

    @Test func disabledAutofillGateHidesVaultPassword() {
        let vault = EphemeralPasswordVault()
        let h = ssh()
        vault.retain(host: h, password: "pw", owner: "x")
        let overlay = EphemeralOverlayCredentialStore(base: InMemoryCredentialStore(), vault: vault)
        let off = AutofillGatedCredentialStore(base: overlay) { false }
        let on = AutofillGatedCredentialStore(base: overlay) { true }
        let ref = EphemeralPasswordVault.reference(for: h.id)
        #expect(off.read(ref: ref) == nil)
        #expect(on.read(ref: ref) == "pw")
    }

    @Test func holdBlocksAutofillEvenWithVaultPassword() {
        let vault = EphemeralPasswordVault()
        var h = ssh()
        h.autofillHold = true
        vault.retain(host: h, password: "pw", owner: "x")
        let adjusted = vault.adjusted(h)
        #expect(adjusted.autofillCredentialReference == nil)
        #expect(
            !PasswordAutofillPolicy.shouldAutofill(
                promptText: "deploy@web.example.com's password: ", host: adjusted, alreadyFilled: false))
    }

    @Test func verifyPrefixRefsCannotBeStored() {
        var h = ssh()
        h.credentialReference = "verify-abc"
        #expect(throws: HostValidationError.ephemeralReference) { try h.validate() }
    }
}
