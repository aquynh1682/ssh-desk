import Foundation
import Testing

@testable import SSHDeskCore

private final class FakePasteboard: SecretPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private(set) var string: String?
    private(set) var types: [String] = []
    var changeCount: Int { lock.withLock { count } }
    @discardableResult func clearContents() -> Int {
        lock.withLock {
            count += 1
            string = nil
            types = []
            return count
        }
    }
    func write(string: String, markerTypes: [String]) -> Int {
        lock.withLock {
            count += 1
            self.string = string
            types = markerTypes
            return count
        }
    }
    /// Người dùng tự copy thứ khác.
    func userCopies(_ s: String) { _ = write(string: s, markerTypes: []) }
}

private final class FakeTimer: @unchecked Sendable {
    private let lock = NSLock()
    var delays: [TimeInterval] = []
    var actions: [() -> Void] = []
    var cancelled = 0
    var scheduler: SecretClipboard.Scheduler {
        { [self] delay, action in
            lock.withLock {
                delays.append(delay)
                actions.append(action)
            }
            return { [self] in lock.withLock { cancelled += 1 } }
        }
    }
    func fireLast() { actions.last?() }
}

@Test func clipboardWritesStringWithConcealedAndTransientTypes() {
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let c = SecretClipboard(pasteboard: pb, scheduler: timer.scheduler)
    c.copy("s3cret")
    #expect(pb.string == "s3cret")
    #expect(pb.types.contains("org.nspasteboard.ConcealedType"))
    #expect(pb.types.contains("org.nspasteboard.TransientType"))
    #expect(timer.delays == [30])
}

@Test func clipboardClearsOnTimerWhenStillOwned() {
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let c = SecretClipboard(pasteboard: pb, scheduler: timer.scheduler)
    c.copy("s3cret")
    timer.fireLast()
    #expect(pb.string == nil)
}

@Test func clipboardKeepsUserContentAfterTimer() {
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let c = SecretClipboard(pasteboard: pb, scheduler: timer.scheduler)
    c.copy("s3cret")
    pb.userCopies("của người dùng")
    timer.fireLast()
    #expect(pb.string == "của người dùng")
    c.clearNowIfOwned()
    #expect(pb.string == "của người dùng")
}

@Test func clipboardClearsOnQuitAndCancelsTimer() {
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let c = SecretClipboard(pasteboard: pb, scheduler: timer.scheduler)
    c.copy("s3cret")
    c.clearNowIfOwned()
    #expect(pb.string == nil)
    #expect(timer.cancelled == 1)
}

@Test func clipboardNewCopyCancelsOldTimerAndStaleTimerIsHarmless() {
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let c = SecretClipboard(pasteboard: pb, scheduler: timer.scheduler)
    c.copy("one")
    c.copy("two")
    #expect(pb.string == "two")
    #expect(timer.cancelled == 1)
    timer.actions[0]()  // hẹn giờ cũ lỡ chạy: không được xoá "two"
    #expect(pb.string == "two")
    timer.actions[1]()
    #expect(pb.string == nil)
}

// MARK: - ConnectionService

private final class OpenApp: WindowsAppHandler, @unchecked Sendable {
    var accept = true
    var available = true
    func windowsAppURL() -> URL? { available ? URL(fileURLWithPath: "/Applications/Windows App.app") : nil }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { accept }
}

private struct Rig {
    let t: HostTempDir
    let service: ConnectionService
    let store: InMemoryCredentialStore
    let pb: FakePasteboard
    let timer: FakeTimer
    let app: OpenApp
    let paths: AppPaths
}

private func rig(store: any CredentialStore = InMemoryCredentialStore()) throws -> Rig {
    let t = HostTempDir()
    let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let pb = FakePasteboard()
    let timer = FakeTimer()
    let app = OpenApp()
    let service = ConnectionService(
        repository: HostRepository(database: try Database(url: paths.databaseURL)),
        appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(
            tabConfigsDirectory: t.url.appendingPathComponent("tabs"),
            handler: SystemWarpURLHandler()),
        rdpLauncher: WindowsAppLauncher(directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: app),
        credentials: store,
        secretClipboard: SecretClipboard(pasteboard: pb, scheduler: timer.scheduler))
    return Rig(
        t: t, service: service, store: (store as? InMemoryCredentialStore) ?? InMemoryCredentialStore(),
        pb: pb, timer: timer, app: app, paths: paths)
}

private func win(_ name: String = "Win") -> HostProfile {
    HostProfile(displayName: name, kind: .windowsRDP, rdpUsername: "CORP\\a", hostName: "10.0.0.5", port: 3389)
}

@Test func openWindowsCopiesStoredPasswordExactlyOnce() async throws {
    let r = try rig()
    defer { r.t.cleanup() }
    let w = win()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw-1")
    let report = await r.service.openInWindowsAppReport(try #require(try await r.service.repository.host(id: w.id)))
    #expect(report.result == .requested)
    #expect(report.passwordCopy == .copied)
    #expect(r.pb.string == "pw-1")
    #expect(r.timer.delays == [30])
    #expect(r.store.reads == 1)
}

@Test func openWindowsWithoutPasswordOrWhenNotRequestedDoesNotCopy() async throws {
    let r = try rig()
    defer { r.t.cleanup() }
    let w = win()
    try await r.service.add(w)
    #expect(await r.service.openInWindowsAppReport(w).passwordCopy == .none)
    try await r.service.savePassword(hostID: w.id, password: "pw")
    r.app.accept = false
    let failed = await r.service.openInWindowsAppReport(w)
    #expect(failed.result != .requested)
    #expect(failed.passwordCopy == .none)
    r.app.accept = true
    r.app.available = false
    #expect(await r.service.openInWindowsAppReport(w).passwordCopy == .none)
    #expect(r.pb.string == nil)
    #expect(r.store.reads == 0)
}

@Test func sshHostNeverCopiesPassword() async throws {
    let r = try rig()
    defer { r.t.cleanup() }
    var h = HostProfile(displayName: "S", hostName: "h.example.com", user: "u")
    h.authMethod = .interactive
    try await r.service.add(h)
    try await r.service.savePassword(hostID: h.id, password: "ssh-pw")
    let stored = try #require(try await r.service.repository.host(id: h.id))
    let report = await r.service.openInWindowsAppReport(stored)
    #expect(report.passwordCopy == .none)
    if case .failed = report.result {} else { Issue.record("cần .failed") }
    if case .failed = await r.service.copyStoredWindowsPassword(stored) {} else { Issue.record("cần .failed") }
    #expect(r.pb.string == nil)
    #expect(r.store.reads == 0)
}

private struct FailingReadStore: CredentialStore {
    func save(ref: String, password: String) throws {}
    func read(ref: String) -> String? { nil }
    func delete(ref: String) throws {}
    func exists(ref: String) -> Bool { true }
}

@Test func keychainReadFailureStillOpensAndReportsError() async throws {
    let r = try rig(store: FailingReadStore())
    defer { r.t.cleanup() }
    var w = win()
    w.credentialReference = "ref-1"
    try await r.service.add(w)
    let report = await r.service.openInWindowsAppReport(w)
    #expect(report.result == .requested)
    if case .failed = report.passwordCopy {} else { Issue.record("cần .failed") }
    #expect(r.pb.string == nil)
}

@Test func windowsDuplicateCopiesPasswordAndDeleteRemovesItem() async throws {
    let r = try rig()
    defer { r.t.cleanup() }
    let w = win()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw")
    let source = try #require(try await r.service.repository.host(id: w.id))
    let copy = source.duplicated(existingNames: [source.displayName])
    try await r.service.add(copy)
    let saved = try #require(try await r.service.copyPassword(from: w.id, to: copy.id))
    #expect(saved.credentialReference != nil && saved.credentialReference != source.credentialReference)
    #expect(r.store.read(ref: try #require(saved.credentialReference)) == "pw")
    try await r.service.delete(id: copy.id)
    #expect(!r.store.exists(ref: try #require(saved.credentialReference)))
    #expect(r.store.exists(ref: try #require(source.credentialReference)))
}

@Test func passwordNeverInRdpFileOrDatabase() async throws {
    let r = try rig()
    defer { r.t.cleanup() }
    let w = win()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "UniquePw-9137")
    #expect(await r.service.openInWindowsApp(w) == .requested)
    let base = r.paths.baseDirectory
    let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    for f in files where !f.hasDirectoryPath {
        let data = (try? Data(contentsOf: f)) ?? Data()
        #expect(String(decoding: data, as: UTF8.self).contains("UniquePw-9137") == false, "\(f.lastPathComponent)")
    }
    let out = try RDPFileRenderer.render(w)
    #expect(!out.contains("UniquePw"))
}

// MARK: - Draft

@Test func windowsDraftPasswordValidationAndMapping() {
    var d = HostDraft()
    d.displayName = "W"
    d.hostName = "10.0.0.5"
    d.setKind(.windowsRDP)
    #expect(d.authChoice == .prompt)
    #expect(d.errors(basedOn: nil).isEmpty)
    d.authChoice = .password
    #expect(d.errors(basedOn: nil)[.password] == "Nhập mật khẩu.")
    #expect(d.errors(basedOn: nil, passwordEntered: true).isEmpty)
    #expect(d.errors(basedOn: nil, hasSavedPassword: true).isEmpty)
    #expect(d.profile(basedOn: nil).authMethod == .interactive)
    d.authChoice = .prompt
    #expect(d.profile(basedOn: nil).authMethod == .agent)
}

@Test func switchingKindKeepsPasswordChoiceAndOtherwiseConfirmsRemoval() {
    var d = HostDraft()
    d.authChoice = .password
    d.setKind(.windowsRDP)
    #expect(d.authChoice == .password)
    #expect(!d.removesStoredPassword(hasSavedPassword: true))
    d.setKind(.ssh)
    #expect(d.authChoice == .password)
    #expect(!d.removesStoredPassword(hasSavedPassword: true))
    d.authChoice = .agent
    d.setKind(.windowsRDP)
    #expect(d.authChoice == .prompt)
    #expect(d.removesStoredPassword(hasSavedPassword: true))
    var host = win()
    host.credentialReference = "r"
    #expect(HostDraft(host: host, hasSavedPassword: true).authChoice == .password)
    #expect(HostDraft(host: host, hasSavedPassword: false).authChoice == .prompt)
}

@Test func windowsConnectionRowShowsAuth() {
    var host = win()
    let saved = HostPresentation.connectionRows(host, jumpHostName: nil, hasSavedPassword: true)
    #expect(saved.first { $0.label == "Xác thực" }?.value == "Mật khẩu đã lưu")
    host.credentialReference = nil
    let none = HostPresentation.connectionRows(host, jumpHostName: nil)
    #expect(none.first { $0.label == "Xác thực" }?.value == "Nhập trong Windows App")
}
