import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - effectiveCredentialReference / hold

@Test func effectiveReferencePrefersOwnThenSetThenNil() {
    let setID = UUID()
    var h = managedHost()
    #expect(h.effectiveCredentialReference == nil)
    h.credentialSetID = setID
    #expect(h.effectiveCredentialReference == "set-\(setID.uuidString.lowercased())")
    h.credentialReference = "own-ref"
    #expect(h.effectiveCredentialReference == "own-ref")
    // Ref riêng rỗng coi như không có.
    h.credentialReference = ""
    #expect(h.effectiveCredentialReference == "set-\(setID.uuidString.lowercased())")
    #expect(CredentialSet.passphraseReference(for: setID) == "setkey-\(setID.uuidString.lowercased())")
}

@Test func holdBlocksAutofillReferenceButNotDisplayReference() {
    var h = managedHost()
    h.credentialReference = "own"
    #expect(h.autofillCredentialReference == "own")
    h.autofillHold = true
    #expect(h.autofillCredentialReference == nil)
    #expect(h.effectiveCredentialReference == "own")
}

// MARK: - CredentialResolution

private func keySet(
    id: UUID = UUID(), user: String? = nil, file: String? = "/keys/team_ed25519", agent: String? = nil
) -> CredentialSet {
    CredentialSet(id: id, name: "Team", user: user, identityFile: file, identityAgent: agent)
}

@Test func resolutionSetWithOnlyKey() {
    let set = keySet()
    let h = HostProfile(
        displayName: "a", hostName: "a.example.com", user: "deploy", authMethod: .keyFile,
        credentialSetID: set.id)
    let r = CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: nil)
    #expect(r.user == "deploy")
    #expect(r.identityFile == "/keys/team_ed25519")
    #expect(r.passphraseKeyPath == "/keys/team_ed25519")
    #expect(r.passphraseRef == "setkey-\(set.id.uuidString.lowercased())")
    #expect(r.passwordRef == "set-\(set.id.uuidString.lowercased())")
    #expect(r.identityAgent == nil)
}

@Test func resolutionHostOverridesSetFieldByField() {
    let set = keySet(user: "setuser", agent: "~/set.sock")
    var h = HostProfile(
        displayName: "a", hostName: "a.example.com", user: "hostuser", authMethod: .keyFile,
        identityFile: "/keys/own", identityAgent: "SSH_AUTH_SOCK", credentialReference: "own-ref",
        credentialSetID: set.id)
    var r = CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: "~/default.sock")
    #expect(r.user == "hostuser")
    #expect(r.identityFile == "/keys/own")
    #expect(r.identityAgent == "SSH_AUTH_SOCK")
    #expect(r.passwordRef == "own-ref")
    // Key riêng của host: passphrase của bộ KHÔNG áp dụng.
    #expect(r.passphraseRef == nil && r.passphraseKeyPath == nil)

    // Host không đặt gì: lấy của bộ.
    h.user = ""
    h.identityFile = nil
    h.identityAgent = nil
    h.credentialReference = nil
    r = CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: "~/default.sock")
    #expect(r.user == "setuser")
    #expect(r.identityFile == "/keys/team_ed25519")
    #expect(r.identityAgent == "~/set.sock")
    #expect(r.passphraseRef != nil)
}

@Test func resolutionAgentOrderHostThenSetThenSettings() {
    let set = keySet(file: nil, agent: "~/set.sock")
    var h = HostProfile(
        displayName: "a", hostName: "h", user: "u", identityAgent: "~/host.sock", credentialSetID: set.id)
    #expect(CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: "~/d").identityAgent == "~/host.sock")
    h.identityAgent = nil
    #expect(CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: "~/d").identityAgent == "~/set.sock")
    #expect(CredentialResolution.resolve(host: h, set: nil, settingsDefaultAgent: "~/d").identityAgent == "~/d")
    // Chuỗi trắng ở tầng nào cũng coi như không đặt.
    h.identityAgent = "  "
    let blankSet = CredentialSet(id: set.id, name: "x")
    #expect(CredentialResolution.resolve(host: h, set: blankSet, settingsDefaultAgent: nil).identityAgent == nil)
}

@Test func resolutionIgnoresForeignSetAndAuthMethodRules() {
    let set = keySet()
    // Bộ không phải của host (id lệch) → bỏ qua hoàn toàn.
    var h = HostProfile(displayName: "a", hostName: "h", user: "u", authMethod: .keyFile, credentialSetID: UUID())
    var r = CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: nil)
    #expect(r.identityFile == nil && r.passwordRef == nil && r.passphraseRef == nil)
    // Host không có bộ nhưng có key riêng ở auth khác .keyFile: key riêng không được dùng (như trước ADR-030).
    h = HostProfile(displayName: "a", hostName: "h", user: "u", authMethod: .interactive, identityFile: "/x")
    r = CredentialResolution.resolve(host: h, set: nil, settingsDefaultAgent: nil)
    #expect(r.identityFile == nil)
    // `~` trong key của bộ được mở rộng cho path passphrase.
    let tilde = keySet(file: "~/k")
    h = HostProfile(displayName: "a", hostName: "h", user: "u", authMethod: .keyFile, credentialSetID: tilde.id)
    r = CredentialResolution.resolve(host: h, set: tilde, settingsDefaultAgent: nil, home: "/Users/me")
    #expect(r.passphraseKeyPath == "/Users/me/k")
}

@Test func resolutionCarriesHoldAndGatesAutofillRefs() {
    let set = keySet()
    var h = HostProfile(
        displayName: "a", hostName: "h", user: "u", authMethod: .keyFile, credentialSetID: set.id)
    h.autofillHold = true
    let r = CredentialResolution.resolve(host: h, set: set, settingsDefaultAgent: nil)
    #expect(r.autofillHold)
    #expect(r.autofillPasswordRef == nil)
    #expect(r.autofillPassphrase == nil)
    #expect(r.passwordRef != nil)  // vẫn biết ref để hiển thị
}

@Test func passwordSourceLabels() {
    let set = CredentialSet(name: "Team")
    var h = managedHost()
    #expect(CredentialResolution.passwordSource(host: h, set: nil) == .none)
    h.credentialReference = "own"
    #expect(CredentialResolution.passwordSource(host: h, set: nil) == .own)
    h.credentialSetID = set.id
    #expect(CredentialResolution.passwordSource(host: h, set: set) == .ownOverridesSet(name: "Team"))
    #expect(PasswordSource.ownOverridesSet(name: "Team").label == "Mật khẩu riêng (ưu tiên hơn bộ Team)")
    h.credentialReference = nil
    #expect(CredentialResolution.passwordSource(host: h, set: set).label == "Bộ đăng nhập: Team")
}

// MARK: - Validate bộ đăng nhập

@Test func setNameRules() throws {
    #expect(try CredentialSet.normalizedName("  Team A  ") == "Team A")
    #expect(throws: CredentialSetError.invalidName) { try CredentialSet.normalizedName("   ") }
    #expect(throws: CredentialSetError.invalidName) { try CredentialSet.normalizedName("") }
    #expect(throws: CredentialSetError.invalidName) { try CredentialSet.normalizedName("a\nb") }
    #expect(throws: CredentialSetError.invalidName) { try CredentialSet.normalizedName("a\u{7}b") }
    #expect(throws: CredentialSetError.invalidName) { try CredentialSet.normalizedName("a\tb") }
    #expect(try CredentialSet.normalizedName(String(repeating: "x", count: 100)).count == 100)
    #expect(throws: CredentialSetError.invalidName) {
        try CredentialSet.normalizedName(String(repeating: "x", count: 101))
    }
}

@Test func setPathAndAgentValidation() throws {
    for bad in ["/k\nProxyCommand evil", "/k\rx", "/k\u{0}x", "/k\u{1b}[0m", "relative/key", "~/key", "/k%h"] {
        #expect(throws: CredentialSetError.invalidIdentityFile, "\(bad.debugDescription)") {
            try CredentialSet(name: "n", identityFile: bad).validated()
        }
    }
    #expect(throws: CredentialSetError.self) {
        try CredentialSet(name: "n", identityAgent: "/a\nProxyCommand x").validated()
    }
    #expect(throws: CredentialSetError.self) { try CredentialSet(name: "n", identityAgent: "relative").validated() }
    #expect(throws: CredentialSetError.invalidUser("bad user")) {
        try CredentialSet(name: "n", user: "bad user").validated()
    }
    let ok = try CredentialSet(name: " n ", user: " ", identityFile: " /k ", identityAgent: "").validated()
    #expect(ok.name == "n" && ok.user == nil && ok.identityFile == "/k" && ok.identityAgent == nil)
}

@Test func setKindLabelCombinesParts() {
    var set = CredentialSet(name: "n")
    #expect(set.kindLabel(hasPassword: false) == "Trống")
    #expect(set.kindLabel(hasPassword: true) == "Password")
    set.identityFile = "/k"
    #expect(set.kindLabel(hasPassword: false) == "Key")
    #expect(set.kindLabel(hasPassword: true) == "Password + Key")
    set.identityAgent = "SSH_AUTH_SOCK"
    #expect(set.kindLabel(hasPassword: true) == "Password + Key + Agent")
    set.identityFile = nil
    #expect(set.kindLabel(hasPassword: false) == "Agent")
}

@Test func keyFileHostValidIfSetProvidesKey() throws {
    var h = HostProfile(displayName: "a", hostName: "h", user: "u", authMethod: .keyFile)
    #expect(throws: HostValidationError.identityFileRequired) { try h.validate() }
    #expect(throws: HostValidationError.identityFileRequired) {
        try h.validate(credentialSet: CredentialSet(name: "empty"))
    }
    try h.validate(credentialSet: CredentialSet(name: "k", identityFile: "/keys/a"))
    #expect(throws: HostValidationError.invalidIdentityFile) {
        try h.validate(credentialSet: CredentialSet(name: "k", identityFile: "relative"))
    }
    h.identityFile = "/own"
    try h.validate()
}

// MARK: - Passphrase prompt

@Test func passphrasePromptParsingAndTruncation() {
    let prompt = "Enter passphrase for key '/Users/me/k': "
    #expect(PassphrasePrompt.keyPath(in: prompt) == "/Users/me/k")
    #expect(PassphrasePrompt.matches(prompt: prompt, keyPath: "/Users/me/k"))
    #expect(!PassphrasePrompt.matches(prompt: prompt, keyPath: "/Users/me/other"))
    #expect(!PassphrasePrompt.matches(prompt: prompt, keyPath: "~/k"))
    // Dạng khác không nhận.
    #expect(PassphrasePrompt.keyPath(in: "(me@h) Enter passphrase for key '/k': ") == nil)
    #expect(PassphrasePrompt.keyPath(in: "Enter passphrase for /k:") == nil)
    #expect(PassphrasePrompt.keyPath(in: "Enter passphrase for key '/k':  x") == nil)
    #expect(PassphrasePrompt.keyPath(in: "enter passphrase for key '/k':") == nil)
    // ssh cắt path ở 100 byte (`%.100s`): so với phần đã cắt.
    let long = "/" + String(repeating: "d", count: 150) + "/key"
    let truncated = String(long.prefix(100))
    let cut = "Enter passphrase for key '\(truncated)': "
    #expect(PassphrasePrompt.matches(prompt: cut, keyPath: long))
    #expect(!PassphrasePrompt.matches(prompt: cut, keyPath: "/" + String(repeating: "e", count: 150)))
}
