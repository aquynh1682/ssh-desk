import Foundation
import Testing

@testable import SSHDeskCore

private final class SetWarp: WarpURLHandler, @unchecked Sendable {
    func isWarpAvailable() -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
}

private final class SetPasteboard: SecretPasteboard, @unchecked Sendable {
    private(set) var string: String?
    private(set) var changeCount = 0
    @discardableResult func clearContents() -> Int {
        changeCount += 1
        string = nil
        return changeCount
    }
    func write(string: String, markerTypes: [String]) -> Int {
        self.string = string
        changeCount += 1
        return changeCount
    }
}

private struct SetStubWindowsApp: WindowsAppHandler {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

private struct SetRig {
    let dir = HostTempDir()
    let store = InMemoryCredentialStore()
    let settings: SettingsStore
    let pasteboard = SetPasteboard()
    let paths: AppPaths
    let repo: HostRepository
    let service: ConnectionService
    let helper = URL(fileURLWithPath: "/Applications/SSH Desk.app/Contents/MacOS/sshdesk-askpass")

    init(_ initial: AppSettings = .default) throws {
        settings = SettingsStore(initial)
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: SetWarp()),
            rdpLauncher: WindowsAppLauncher(
                directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: SetStubWindowsApp()),
            credentials: store, secretClipboard: SecretClipboard(pasteboard: pasteboard, scheduler: { _, _ in {} }),
            askpassHelper: helper, settings: settings)
    }

    func hostWithSet(
        _ set: CredentialSet, name: String = "h", hostName: String = "h.example.com",
        auth: HostAuthMethod = .interactive
    ) async throws -> HostProfile {
        var h = managedHost(name, hostName: hostName)
        h.authMethod = auth
        h.credentialSetID = set.id
        try await service.add(h)
        return h
    }
}

// MARK: - Lệnh Warp / askpass

@Test func warpCommandUsesSetPasswordRefWithoutSecrets() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(CredentialSet(name: "Team"), password: "Set-Pw-Zq9")
    let h = try await r.hostWithSet(set)
    let (cmd, notice) = try await r.service.warpSSHCommand(for: h)
    #expect(notice == nil)
    #expect(cmd.contains("SSHDESK_HOST_REF='set-\(set.id.uuidString.lowercased())'"))
    #expect(!cmd.contains("Set-Pw-Zq9"))
    #expect(!cmd.contains("SSHDESK_KEY_REF"))
    // Mật khẩu riêng ưu tiên hơn bộ.
    let own = try await r.service.savePassword(hostID: h.id, password: "own-pw")
    let (cmd2, _) = try await r.service.warpSSHCommand(for: own)
    #expect(cmd2.contains("SSHDESK_HOST_REF='\(own.credentialReference ?? "?")'"))
    #expect(!cmd2.contains("set-\(set.id.uuidString.lowercased())"))
    // Xoá mật khẩu riêng → quay về bộ.
    let cleared = try await r.service.clearPassword(hostID: h.id)
    let (cmd3, _) = try await r.service.warpSSHCommand(for: cleared)
    #expect(cmd3.contains("set-\(set.id.uuidString.lowercased())"))
}

@Test func warpCommandHoldAutofillOffJumpAllFallBackToPlainEvenWithSet() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(
        CredentialSet(name: "Team", identityFile: "/keys/t"), password: "pw", passphrase: "pp")
    let h = try await r.hostWithSet(set, auth: .keyFile)
    // Bình thường: có cả password và passphrase.
    var (cmd, _) = try await r.service.warpSSHCommand(for: h)
    #expect(
        cmd.contains("SSHDESK_HOST_REF=") && cmd.contains("SSHDESK_KEY_REF='setkey-\(set.id.uuidString.lowercased())'"))
    #expect(cmd.contains("SSHDESK_KEY_PATH='/keys/t'"))
    #expect(!cmd.contains("'pp'") && !cmd.contains("'pw'"))

    // Hold: ssh thường, có thông báo.
    try await r.repo.setAutofillHold(ids: [h.id], reason: "Bộ đăng nhập Team được gán từ file")
    var plain = try await r.service.warpSSHCommand(for: h)
    #expect(!plain.command.contains("SSH_ASKPASS") && !plain.command.contains("SSHDESK_"))
    #expect(plain.notice != nil)
    try await r.service.confirmAutofillHold(hostID: h.id)
    (cmd, _) = try await r.service.warpSSHCommand(for: h)
    #expect(cmd.contains("SSHDESK_HOST_REF="))

    // Tắt tự điền.
    var s = AppSettings()
    s.autofillEnabled = false
    r.settings.update(s)
    plain = try await r.service.warpSSHCommand(for: h)
    #expect(!plain.command.contains("SSHDESK_"))
    r.settings.update(.default)

    // Bastion.
    var jumped = managedHost("j", hostName: "j.example.com", jump: h.id)
    jumped.credentialSetID = set.id
    jumped.authMethod = .keyFile
    try await r.service.add(jumped)
    plain = try await r.service.warpSSHCommand(for: jumped)
    #expect(!plain.command.contains("SSHDESK_"))
    #expect(plain.notice != nil)
}

@Test func setPassphraseOnlyWhenKeyComesFromSet() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(
        CredentialSet(name: "Key"), passphrase: "pp")
    var set2 = set
    set2.identityFile = "/keys/set"
    try await r.service.updateCredentialSet(set2)
    // Host có key riêng → passphrase của bộ không áp dụng.
    var own = managedHost("own", hostName: "own.example.com")
    own.authMethod = .keyFile
    own.identityFile = "/keys/own"
    own.credentialSetID = set.id
    try await r.service.add(own)
    let (cmdOwn, _) = try await r.service.warpSSHCommand(for: own)
    #expect(!cmdOwn.contains("SSHDESK_KEY_REF"))
    // Host lấy key từ bộ.
    var fromSet = managedHost("fs", hostName: "fs.example.com")
    fromSet.authMethod = .keyFile
    fromSet.credentialSetID = set.id
    try await r.service.add(fromSet)
    let (cmd, _) = try await r.service.warpSSHCommand(for: fromSet)
    #expect(cmd.contains("SSHDESK_KEY_PATH='/keys/set'"))
    // Config có IdentityFile của bộ cho host thứ hai, của riêng cho host thứ nhất.
    let config = try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)
    #expect(config.contains("\"/keys/set\"") && config.contains("\"/keys/own\""))
    #expect(!config.contains("pp"))
}

// MARK: - Vòng đời bộ

@Test func deleteSetClearsKeychainUnlinksHostsAndRegeneratesConfig() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(
        CredentialSet(name: "Team", identityFile: "/keys/t"), password: "pw", passphrase: "pp")
    let h = try await r.hostWithSet(set, auth: .keyFile)
    #expect(try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8).contains("/keys/t"))
    #expect(r.store.exists(ref: set.passwordReference) && r.store.exists(ref: set.passphraseReference))
    let affected = try await r.service.deleteCredentialSet(id: set.id)
    #expect(affected == [h.id])
    #expect(!r.store.exists(ref: set.passwordReference) && !r.store.exists(ref: set.passphraseReference))
    #expect(try await r.repo.host(id: h.id)?.credentialSetID == nil)
    #expect(!(try String(contentsOf: r.paths.sshConfigURL, encoding: .utf8)).contains("/keys/t"))
}

@Test func changingSetPasswordAppliesToAllHostsSameRef() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(CredentialSet(name: "Team"), password: "old")
    let a = try await r.hostWithSet(set, name: "a", hostName: "a.example.com")
    let b = try await r.hostWithSet(set, name: "b", hostName: "b.example.com")
    try await r.service.saveSetPassword(setID: set.id, password: "new")
    for h in [a, b] {
        let stored = try #require(try await r.repo.host(id: h.id))
        #expect(r.store.read(ref: try #require(stored.effectiveCredentialReference)) == "new")
        #expect(stored.credentialReference == nil)  // không lưu ref riêng trong DB
    }
}

@Test func createSetRollsBackWhenKeychainUnavailable() async throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let repo = HostRepository(database: try Database(url: paths.databaseURL))
    let noKeychain = ConnectionService(
        repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil, launcher: WarpLauncher())
    await #expect(throws: ConnectionServiceError.credentialsUnavailable) {
        try await noKeychain.createCredentialSet(CredentialSet(name: "x"), password: "pw")
    }
    #expect(try await repo.credentialSets().isEmpty)
}

@Test func clearAllPasswordsAlsoClearsSetItemsButKeepsSetsAndAssignments() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(
        CredentialSet(name: "Team", identityFile: "/keys/t"), password: "pw", passphrase: "pp")
    let h = try await r.hostWithSet(set)
    let own = try await r.service.savePassword(hostID: h.id, password: "own")
    #expect(try await r.service.savedPasswordCount() == 3)
    let result = try await r.service.clearAllPasswords()
    #expect(result.removed == 1 && result.setItemsRemoved == 2 && result.failed == 0 && result.setItemsFailed == 0)
    #expect(!r.store.exists(ref: own.credentialReference ?? "?"))
    #expect(!r.store.exists(ref: set.passwordReference) && !r.store.exists(ref: set.passphraseReference))
    #expect(try await r.repo.credentialSets().count == 1)
    #expect(try await r.repo.host(id: h.id)?.credentialSetID == set.id)
    #expect(try await r.service.savedPasswordCount() == 0)
}

// MARK: - Windows clipboard

@Test func windowsClipboardUsesSetPasswordAndRespectsHold() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(CredentialSet(name: "Win"), password: "Win-Pw-1")
    var w = HostProfile(displayName: "win", kind: .windowsRDP, hostName: "win.example.com", port: 3389)
    w.authMethod = .interactive
    w.credentialSetID = set.id
    try await r.service.add(w)
    #expect(await r.service.copyStoredWindowsPassword(w) == .copied)
    #expect(r.pasteboard.string == "Win-Pw-1")
    r.pasteboard.clearContents()
    try await r.repo.setAutofillHold(ids: [w.id], reason: "Bộ đăng nhập Win được gán từ file")
    #expect(await r.service.copyStoredWindowsPassword(w) == .held)
    #expect(r.pasteboard.string == nil)
    try await r.repo.confirmAutofillHold(id: w.id)
    #expect(await r.service.copyStoredWindowsPassword(w) == .copied)
}

// MARK: - Key mất

@Test func missingKeyFileWarnsWithoutReadingContent() async throws {
    let r = try SetRig()
    defer { r.dir.cleanup() }
    let set = try await r.service.createCredentialSet(CredentialSet(name: "K", identityFile: "/keys/gone"))
    let h = try await r.hostWithSet(set, auth: .keyFile)
    #expect(await r.service.missingKeyFile(for: h, exists: { _ in false }) == "/keys/gone")
    #expect(await r.service.missingKeyFile(for: h, exists: { _ in true }) == nil)
}

// MARK: - Tự điền (policy)

private func policyHost(set: CredentialSet?, user: String = "deploy", hostName: String = "web.example.com")
    -> HostProfile
{
    HostProfile(
        displayName: "web", hostName: hostName, user: user, authMethod: .interactive,
        credentialSetID: set?.id)
}

@Test func policyReadsSetPasswordButStillNeedsMatchingPrompt() {
    let set = CredentialSet(name: "S")
    let h = policyHost(set: set)
    #expect(
        PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@web.example.com's password: ", host: h, alreadyFilled: false))
    #expect(
        PasswordAutofillPolicy.shouldAutofill(
            promptText: "(deploy@web.example.com) Password: ", host: h, alreadyFilled: false))
    // Prompt không khớp user@host của chính host → không điền dù bộ có password.
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "root@bastion.example.com's password: ", host: h, alreadyFilled: false))
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@other.example.com's password: ", host: h, alreadyFilled: false))
    #expect(!PasswordAutofillPolicy.shouldAutofill(promptText: "Password: ", host: h, alreadyFilled: false))
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@web.example.com's password: ", host: h, alreadyFilled: true))
    // Không bộ, không ref riêng → không điền.
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@web.example.com's password: ", host: policyHost(set: nil), alreadyFilled: false))
    // Bastion và hold chặn.
    var jumped = h
    jumped.jumpHostID = UUID()
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@web.example.com's password: ", host: jumped, alreadyFilled: false))
    var held = h
    held.autofillHold = true
    #expect(
        !PasswordAutofillPolicy.shouldAutofill(
            promptText: "deploy@web.example.com's password: ", host: held, alreadyFilled: false))
}

@Test func policyNeverAutofillsPassphraseOverPTY() {
    let set = CredentialSet(name: "S", identityFile: "/keys/team")
    var h = policyHost(set: set)
    h.authMethod = .keyFile
    for text in ["Enter passphrase for key '/keys/team': ", "Enter passphrase for key '/keys/other': "] {
        #expect(!PasswordAutofillPolicy.shouldAutofill(prompt: .passphrase(text), host: h, alreadyFilled: false))
        #expect(!PasswordAutofillPolicy.shouldAutofill(promptText: text, host: h, alreadyFilled: false))
    }
}

// MARK: - Askpass

@Test func askpassPassphraseDecisionTable() {
    let parent = "/usr/bin/ssh"
    func decide(
        _ prompt: String, keyRef: String? = "setkey-1", keyPath: String? = "/keys/team",
        parent: String? = parent, claimed: Bool = true, hostRef: String? = "set-1"
    ) -> AskpassAction {
        AskpassDecision.decide(
            prompt: prompt, promptType: nil, hostRef: hostRef, keyRef: keyRef, keyPath: keyPath,
            parentPath: parent, claimUse: { claimed }, claimKeyUse: { claimed })
    }
    let good = "Enter passphrase for key '/keys/team': "
    #expect(decide(good) == .answerPassphraseFromKeychain(ref: "setkey-1"))
    #expect(decide(good, claimed: false) == .askTTY(echo: false))
    #expect(decide(good, keyRef: nil) == .askTTY(echo: false))
    #expect(decide(good, keyRef: "") == .askTTY(echo: false))
    #expect(decide(good, keyPath: nil) == .askTTY(echo: false))
    #expect(decide(good, keyPath: "/keys/other") == .askTTY(echo: false))
    #expect(decide(good, parent: "/bin/sh") == .askTTY(echo: false))
    #expect(decide(good, parent: nil) == .askTTY(echo: false))
    // OpenSSH >= 8.4 thêm "(user@host) " vào MỌI prompt kbd-int do server gửi → không bao giờ trả passphrase.
    for fake in [
        "(deploy@web) Enter passphrase for key '/keys/team': ",
        " (deploy@web) Enter passphrase for key '/keys/team': ",
        "x Enter passphrase for key '/keys/team': ",
        "Enter passphrase for key '/keys/team': extra",
    ] {
        #expect(decide(fake) == .askTTY(echo: false), "\(fake)")
    }
    // ssh-keygen / passphrase khác.
    #expect(decide("Enter passphrase (empty for no passphrase): ") == .askTTY(echo: false))
    // Prompt password của host vẫn như cũ, không lẫn với passphrase.
    #expect(decide("deploy@web's password: ") == .answerFromKeychain(ref: "set-1"))
    #expect(decide("deploy@web's password: ", hostRef: nil) == .askTTY(echo: false))
}

@Test func askpassUsesSeparateClaimsForPasswordAndPassphrase() {
    var passwordClaims = 0
    var keyClaims = 0
    func ask(_ prompt: String) -> AskpassAction {
        AskpassDecision.decide(
            prompt: prompt, promptType: nil, hostRef: "set-1", keyRef: "setkey-1", keyPath: "/k",
            parentPath: "/usr/bin/ssh",
            claimUse: {
                passwordClaims += 1
                return passwordClaims == 1
            },
            claimKeyUse: {
                keyClaims += 1
                return keyClaims == 1
            })
    }
    #expect(ask("Enter passphrase for key '/k': ") == .answerPassphraseFromKeychain(ref: "setkey-1"))
    #expect(ask("u@h's password: ") == .answerFromKeychain(ref: "set-1"))
    #expect(ask("Enter passphrase for key '/k': ") == .askTTY(echo: false))
    #expect(ask("u@h's password: ") == .askTTY(echo: false))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
func askpassCommandWithKeyCarriesOnlyReferenceAndPath() throws {
    let cmd = try ZshQuoting.askpassSshCommand(
        helperPath: "/h/askpass", hostRef: "set-a", keyRef: "setkey-a", keyPath: "/Users/me/my key's",
        sshPath: "/usr/bin/ssh", configPath: "/c", alias: "sshdesk-x")
    #expect(cmd.contains("SSHDESK_HOST_REF='set-a'"))
    #expect(cmd.contains("SSHDESK_KEY_REF='setkey-a'"))
    #expect(cmd.contains("SSHDESK_KEY_PATH='/Users/me/my key'\\''s'"))
    // Chỉ passphrase, không password.
    let onlyKey = try ZshQuoting.askpassSshCommand(
        helperPath: "/h/askpass", hostRef: nil, keyRef: "setkey-a", keyPath: "/k", sshPath: "/usr/bin/ssh",
        configPath: "/c", alias: "a")
    #expect(!onlyKey.contains("SSHDESK_HOST_REF") && onlyKey.contains("SSHDESK_KEY_REF"))
    // Thiếu path → không đặt key env.
    let noPath = try ZshQuoting.askpassSshCommand(
        helperPath: "/h/askpass", hostRef: "r", keyRef: "setkey-a", keyPath: nil, sshPath: "/usr/bin/ssh",
        configPath: "/c", alias: "a")
    #expect(!noPath.contains("SSHDESK_KEY"))
}

@Test func deleteSetReportsKeychainFailureAfterDbDelete() async throws {
    struct StuckStore: CredentialStore {
        let base: InMemoryCredentialStore
        func save(ref: String, password: String) throws { try base.save(ref: ref, password: password) }
        func read(ref: String) -> String? { base.read(ref: ref) }
        func delete(ref: String) throws { throw CredentialStoreError.keychain(status: -25293) }
        func exists(ref: String) -> Bool { base.exists(ref: ref) }
    }
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let repo = HostRepository(database: try Database(url: paths.databaseURL))
    let store = StuckStore(base: InMemoryCredentialStore())
    let service = ConnectionService(
        repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil, launcher: WarpLauncher(),
        credentials: store)
    let set = try await service.createCredentialSet(CredentialSet(name: "T"), password: "pw", passphrase: "pp")
    await #expect(throws: ConnectionServiceError.setDeletedButKeychainFailed(count: 2)) {
        try await service.deleteCredentialSet(id: set.id)
    }
    #expect(try await repo.credentialSets().isEmpty)
}

@Test func editingSetThatDropsKeyListsAffectedKeyFileHosts() {
    let set = CredentialSet(name: "S", identityFile: "/k")
    var a = HostProfile(displayName: "a", hostName: "a", user: "u", authMethod: .keyFile, credentialSetID: set.id)
    var own = a
    own.id = UUID()
    own.identityFile = "/own"
    let pw = HostProfile(displayName: "p", hostName: "p", user: "u", authMethod: .interactive, credentialSetID: set.id)
    var after = set
    after.identityFile = nil
    #expect(CredentialSet.hostsLosingKey(hosts: [a, own, pw], before: set, after: after).map(\.id) == [a.id])
    #expect(CredentialSet.hostsLosingKey(hosts: [a], before: set, after: set).isEmpty)
    a.credentialSetID = nil
    #expect(CredentialSet.hostsLosingKey(hosts: [a], before: set, after: after).isEmpty)
}

@Test func connectionRowsShowEffectiveKeyFromSet() {
    let set = CredentialSet(name: "S", identityFile: "/keys/team_key")
    let h = HostProfile(displayName: "a", hostName: "a", user: "u", authMethod: .keyFile, credentialSetID: set.id)
    let rows = HostPresentation.connectionRows(h, jumpHostName: nil, credentialSet: set)
    #expect(rows.contains { $0.label == "Key" && $0.value == "team_key" })
    #expect(!HostPresentation.connectionRows(h, jumpHostName: nil).contains { $0.label == "Key" })
}
