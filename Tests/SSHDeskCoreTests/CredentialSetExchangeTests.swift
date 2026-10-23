import CredentialBackend
import Foundation
import Testing

@testable import SSHDeskCore

@Test func exportCarriesOnlySetNameNeverPathRefOrSecret() throws {
    let set = CredentialSet(name: "Team A", user: "ops", identityFile: "/keys/secret-path", identityAgent: "~/a.sock")
    var h = managedHost()
    h.credentialSetID = set.id
    h.credentialReference = "own-ref-123"
    let data = try HostExchange.export(
        hosts: [h], forwards: [], folders: [], needsReauth: [h.id], setNames: [set.id: set.name])
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"credentialSet\" : \"Team A\""))
    #expect(!text.contains("secret-path") && !text.contains("a.sock"))
    #expect(!text.contains("own-ref-123") && !text.contains("set-\(set.id.uuidString.lowercased())"))
    #expect(!text.contains("setkey-"))
}

@Test func importAssignsSetCreatesEmptyOneAndHoldsAutofill() async throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let repo = HostRepository(database: try Database(url: dir.dbURL))
    let set = CredentialSet(name: "Team A")
    var h = managedHost()
    h.authMethod = .interactive
    h.credentialSetID = set.id
    let data = try HostExchange.export(
        hosts: [h], forwards: [], folders: [], setNames: [set.id: set.name])
    let file = try HostExchange.decode(data)
    let plan = HostExchange.plan(
        file: file, existingHosts: [], existingFolders: [], existingForwards: [], existingSetNames: [])
    #expect(plan.setsToCreate == ["Team A"])
    let newID = try #require(plan.hosts.first?.id)
    #expect(plan.hostsNeedingHold == [newID])
    #expect(plan.entries.first?.warnings.contains { $0.contains("Team A") } == true)
    try await repo.applyImport(plan)
    let stored = try #require(try await repo.host(id: newID))
    #expect(stored.autofillHold)
    #expect(stored.autofillHoldReason == "Bộ đăng nhập Team A được gán từ file")
    #expect(stored.credentialReference == nil)
    let sets = try await repo.credentialSets()
    #expect(sets.count == 1 && stored.credentialSetID == sets[0].id)
    #expect(sets[0].identityFile == nil && sets[0].identityAgent == nil)
    #expect(stored.autofillCredentialReference == nil)
    // Nhập lần hai với tên khác hoa thường: dùng lại bộ, không tạo bộ trùng.
    var file2 = file
    file2 = try HostExchange.decode(
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Team A", with: "TEAM a").utf8))
    let plan2 = HostExchange.plan(
        file: file2, existingHosts: [stored], existingFolders: [], existingForwards: [],
        existingSetNames: ["Team A"], duplicates: .copy)
    #expect(plan2.setsToCreate.isEmpty)
    try await repo.applyImport(plan2)
    #expect(try await repo.credentialSets().count == 1)
}

@Test func importRejectsBadSetNameAndSkipsAgentHosts() throws {
    var h = managedHost()
    h.credentialSetID = UUID()
    let data = try HostExchange.export(
        hosts: [h], forwards: [], folders: [], setNames: [h.credentialSetID!: "bad\u{7}name"])
    let plan = HostExchange.plan(
        file: try HostExchange.decode(data), existingHosts: [], existingFolders: [], existingForwards: [])
    // Ký tự điều khiển trong tên bộ → máy bị từ chối ở bước kiểm tra trường một dòng.
    #expect(plan.invalidCount == 1 && plan.importCount == 0)
    // Máy xác thực agent: bộ bị bỏ qua kèm cảnh báo.
    var agentHost = managedHost()
    agentHost.authMethod = .agent
    let json = try HostExchange.export(hosts: [agentHost], forwards: [], folders: [])
    let patched = String(decoding: json, as: UTF8.self).replacingOccurrences(
        of: "\"connectionMode\"", with: "\"credentialSet\" : \"X\",\n    \"connectionMode\"")
    let p2 = HostExchange.plan(
        file: try HostExchange.decode(Data(patched.utf8)), existingHosts: [], existingFolders: [], existingForwards: [])
    #expect(p2.setAssignments.isEmpty && p2.hostsNeedingHold.isEmpty)
}

// MARK: - ADR-004b: một backend duy nhất

private func sourcesRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")
}

private func swiftFiles(under root: URL) -> [URL] {
    let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    return (en?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
}

@Test func secItemAppearsOnlyInSharedKeychainBackend() throws {
    let files = swiftFiles(under: sourcesRoot())
    #expect(files.count > 50)
    var offenders: [String] = []
    for f in files where !f.path.contains("/Sources/CredentialBackend/") {
        let text = try String(contentsOf: f, encoding: .utf8)
        if text.contains("SecItem") || text.contains("kSecClass") { offenders.append(f.path) }
    }
    #expect(offenders.isEmpty, "\(offenders)")
    let helper = try String(
        contentsOf: sourcesRoot().appendingPathComponent("sshdesk-askpass/main.swift"), encoding: .utf8)
    #expect(helper.contains("import CredentialBackend") && helper.contains("KeychainBackend("))
}

/// Chỉ file được liệt kê mới được đọc `credentialReference` thô; chỗ khác phải qua
/// `effectiveCredentialReference` / `autofillCredentialReference` / `CredentialResolution`.
@Test func rawCredentialReferenceReadsOnlyInAllowedFiles() throws {
    let allowed: Set<String> = [
        "HostProfile.swift", "HostRepository.swift", "CredentialResolution.swift", "ConnectionService.swift",
        "HostDraft.swift", "HostExchange.swift", "AskpassDecision.swift", "CLIHostList.swift",
        "AppModel.swift", "CredentialSetViews.swift",  // UI chỉ kiểm có mật khẩu riêng để hiển thị
    ]
    var offenders: [String] = []
    for f in swiftFiles(under: sourcesRoot()) where !allowed.contains(f.lastPathComponent) {
        if try String(contentsOf: f, encoding: .utf8).contains("credentialReference") {
            offenders.append(f.lastPathComponent)
        }
    }
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test func keychainStoreAndBackendShareSameItems() throws {
    #expect(KeychainBackend.defaultService == CredentialConstants.service)
    let service = "local.sshdesk.tests.\(UUID().uuidString)"
    let ref = "set-\(UUID().uuidString.lowercased())"
    let store = KeychainCredentialStore(service: service)
    do { try store.save(ref: ref, password: "shared-1") } catch {
        print("BỎ QUA: không ghi được Keychain trong môi trường test.")
        return
    }
    defer { try? store.delete(ref: ref) }
    // Helper askpass đọc bằng cùng backend.
    #expect(KeychainBackend(service: service).read(account: ref) == "shared-1")
    #expect(store.status(ref: ref) == .present)
    try store.delete(ref: ref)
    #expect(store.status(ref: ref) == .missing)
}
