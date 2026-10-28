import Foundation
import Testing

@testable import SSHDeskCore

// ADR-018b: tự gõ mật khẩu vào Windows App.

private let winApp = WindowsPasswordAutotype.windowsAppBundleID

private func secure(pid: Int32 = 42, length: Int? = 0) -> WindowsUISnapshot {
    WindowsUISnapshot(
        frontmostBundleID: winApp, frontmostPID: pid, focusedSubrole: "AXSecureTextField", fieldLength: length)
}

private let plainField = WindowsUISnapshot(
    frontmostBundleID: winApp, frontmostPID: 42, focusedSubrole: "AXTextField", fieldLength: 0)
private let otherAppSecure = WindowsUISnapshot(
    frontmostBundleID: "com.apple.Safari", frontmostPID: 7, focusedSubrole: "AXSecureTextField", fieldLength: 0)

// MARK: - Quyết định thuần

@Test func decideTable() {
    typealias A = WindowsPasswordAutotype
    func input(
        host: Bool = true, autofill: Bool = true, autotype: Bool = true, trusted: Bool = true,
        _ snap: WindowsUISnapshot = WindowsUISnapshot(), waited: TimeInterval = 0,
        phase: A.Input.Phase = .waiting
    ) -> A.Input {
        A.Input(
            isWindowsHost: host, autofillEnabled: autofill, autotypeEnabled: autotype,
            accessibilityTrusted: trusted, snapshot: snap, waited: waited, phase: phase)
    }
    // Không áp dụng: không gõ, không copy.
    #expect(A.decide(input(host: false, secure())) == .abort(.notWindowsHost))
    #expect(A.decide(input(autofill: false, secure())) == .abort(.autofillDisabled))
    // Cài đặt tắt / thiếu quyền: clipboard.
    #expect(A.decide(input(autotype: false, secure())) == .fallbackClipboard(.autotypeDisabled))
    #expect(A.decide(input(trusted: false, secure())) == .fallbackClipboard(.noPermission))
    // Đủ điều kiện.
    #expect(A.decide(input(secure())) == .type(pid: 42))
    #expect(A.decide(input(secure(length: nil))) == .type(pid: 42))  // không đọc được độ dài: chấp nhận
    // Thiếu từng điều kiện: chờ.
    #expect(A.decide(input(otherAppSecure)) == .wait)
    #expect(A.decide(input(plainField)) == .wait)
    #expect(A.decide(input(secure(length: 3))) == .wait)  // ô không rỗng
    #expect(A.decide(input(WindowsUISnapshot(frontmostBundleID: winApp, focusedSubrole: "AXSecureTextField"))) == .wait)
    #expect(A.decide(input()) == .wait)
    // Hết giờ.
    #expect(A.decide(input(plainField, waited: 29.9)) == .wait)
    #expect(A.decide(input(plainField, waited: 30)) == .fallbackClipboard(.timedOut))
    #expect(A.decide(input(secure(length: 2), waited: 31)) == .fallbackClipboard(.timedOut))
    #expect(A.decide(input(secure(), waited: 31)) == .type(pid: 42))  // đủ điều kiện thì gõ, không timeout
    // Đang gõ: chỉ tiếp tục đúng pid đã khoá, ô không cần rỗng.
    #expect(A.decide(input(secure(length: 5), phase: .typing(pid: 42))) == .type(pid: 42))
    #expect(A.decide(input(secure(pid: 43), phase: .typing(pid: 42))) == .abort(.focusChanged))
    #expect(A.decide(input(plainField, phase: .typing(pid: 42))) == .abort(.focusChanged))
    #expect(A.decide(input(otherAppSecure, phase: .typing(pid: 42))) == .abort(.focusChanged))
    #expect(A.decide(input(trusted: false, secure(), phase: .typing(pid: 42))) == .abort(.permissionLost))
    #expect(A.decide(input(host: false, secure(), phase: .typing(pid: 42))) == .abort(.notWindowsHost))
}

// MARK: - Chia đoạn / ký tự gõ được

@Test func chunksRespectLimitAndNeverSplitSurrogates() {
    #expect(WindowsPasswordAutotype.chunks(of: "").isEmpty)
    #expect(WindowsPasswordAutotype.chunks(of: "abc") == ["abc"])
    let long = String(repeating: "a", count: 45)
    #expect(WindowsPasswordAutotype.chunks(of: long).map { $0.utf16.count } == [20, 20, 5])
    // 19 ký tự + emoji (2 unit) không vừa đoạn đầu -> sang đoạn sau.
    let boundary = String(repeating: "a", count: 19) + "😀" + "b"
    let parts = WindowsPasswordAutotype.chunks(of: boundary)
    #expect(parts == [String(repeating: "a", count: 19), "😀b"])
    // Đúng 20 unit: 18 ký tự + emoji.
    let exact = String(repeating: "a", count: 18) + "😀" + "z"
    #expect(WindowsPasswordAutotype.chunks(of: exact) == [String(repeating: "a", count: 18) + "😀", "z"])
    // Tính chất: ghép lại bằng bản gốc, mỗi đoạn ≤ 20 unit và không có surrogate mồ côi.
    let mixed = String((0..<200).map { i -> Character in i % 7 == 0 ? "😀" : (i % 3 == 0 ? "é" : "x") })
    let chunks = WindowsPasswordAutotype.chunks(of: mixed)
    #expect(chunks.joined() == mixed)
    for chunk in chunks {
        #expect(chunk.utf16.count <= 20)
        #expect(String(decoding: Array(chunk.utf16), as: UTF16.self) == chunk)
        #expect(!chunk.unicodeScalars.contains(where: { $0.value == 0xFFFD }))
    }
    // Giới hạn nhỏ bất thường vẫn chứa được scalar 2 unit.
    #expect(WindowsPasswordAutotype.chunks(of: "😀😀", maxUnits: 1) == ["😀", "😀"])
}

@Test func typableRejectsEmptyAndControlCharacters() {
    #expect(WindowsPasswordAutotype.isTypable("p@ss é 密码 😀"))
    #expect(!WindowsPasswordAutotype.isTypable(""))
    #expect(!WindowsPasswordAutotype.isTypable("a\tb"))
    #expect(!WindowsPasswordAutotype.isTypable("a\nb"))
    #expect(!WindowsPasswordAutotype.isTypable("a\u{7F}"))
    #expect(!WindowsPasswordAutotype.isTypable("a\u{85}"))
}

// MARK: - Orchestrator với probe giả

private final class ScriptedProbe: WindowsAutotypeProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Bool
    private let script: [WindowsUISnapshot]
    private var calls = 0
    private var requests = 0
    init(_ script: [WindowsUISnapshot], trusted: Bool = true) {
        self.script = script
        self.trusted = trusted
    }
    var snapshotCalls: Int { lock.withLock { calls } }
    var trustRequests: Int { lock.withLock { requests } }
    func isTrusted() -> Bool { lock.withLock { trusted } }
    func requestTrust() { lock.withLock { requests += 1 } }
    /// Mỗi lần gọi lấy phần tử kế tiếp; hết thì lặp lại phần tử cuối.
    func snapshot() -> WindowsUISnapshot {
        lock.withLock { () -> WindowsUISnapshot in
            defer { calls += 1 }
            guard !script.isEmpty else { return WindowsUISnapshot() }
            return script[min(calls, script.count - 1)]
        }
    }
}

private final class RecordingTyper: WindowsKeyTyper, @unchecked Sendable {
    private let lock = NSLock()
    private var chunkLog: [(String, Int32)] = []
    private var returns: [Int32] = []
    var failFromChunk: Int?
    var typedChunks: [String] { lock.withLock { chunkLog.map(\.0) } }
    var pids: [Int32] { lock.withLock { chunkLog.map(\.1) } }
    var returnPIDs: [Int32] { lock.withLock { returns } }
    func type(_ chunk: String, toPID pid: Int32) -> Bool {
        lock.withLock { () -> Bool in
            if let limit = self.failFromChunk, chunkLog.count >= limit { return false }
            chunkLog.append((chunk, pid))
            return true
        }
    }
    func pressReturn(toPID pid: Int32) -> Bool {
        lock.withLock {
            returns.append(pid)
            return true
        }
    }
}

private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var log: [TimeInterval] = []
    var sleeps: [TimeInterval] { lock.withLock { log } }
    var clock: WindowsPasswordAutotyper.Clock { { [self] in lock.withLock { now } } }
    var sleep: WindowsPasswordAutotyper.Sleep {
        { [self] seconds in
            lock.withLock {
                now += seconds
                log.append(seconds)
            }
        }
    }
}

private func makeAutotyper(
    _ probe: ScriptedProbe, _ typer: RecordingTyper, _ time: FakeTime = FakeTime()
) -> WindowsPasswordAutotyper {
    WindowsPasswordAutotyper(probe: probe, typer: typer, sleep: time.sleep, clock: time.clock)
}

private let longPassword = String(repeating: "k", count: 45)

@Test func autotypeWaitsForSecureFieldThenTypesInChunksAndPressesReturn() async {
    let probe = ScriptedProbe([otherAppSecure, plainField, secure()])
    let typer = RecordingTyper()
    let time = FakeTime()
    let outcome = await makeAutotyper(probe, typer, time).run(
        password: longPassword, autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .typed)
    #expect(typer.typedChunks.map { $0.utf16.count } == [20, 20, 5])
    #expect(typer.typedChunks.joined() == longPassword)
    #expect(typer.pids == [42, 42, 42] && typer.returnPIDs == [42])
    #expect(probe.trustRequests == 0)
    #expect(Array(time.sleeps.prefix(2)) == [0.3, 0.3])  // chờ ~300 ms giữa các lần kiểm
}

@Test func noAccessibilityPermissionAsksOnceAndFallsBackToClipboard() async {
    let probe = ScriptedProbe([secure()], trusted: false)
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "pw", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .fallbackClipboard(.noPermission))
    #expect(probe.trustRequests == 1)
    #expect(typer.typedChunks.isEmpty && typer.returnPIDs.isEmpty)
    #expect(outcome.message(clearSeconds: 30)?.contains("Trợ năng") == true)
}

@Test func timeoutFallsBackToClipboardAfterThirtySeconds() async {
    let probe = ScriptedProbe([plainField])
    let typer = RecordingTyper()
    let time = FakeTime()
    let outcome = await makeAutotyper(probe, typer, time).run(
        password: "pw", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .fallbackClipboard(.timedOut))
    #expect((99...101).contains(time.sleeps.count))
    #expect(typer.typedChunks.isEmpty)
    #expect(probe.trustRequests == 0)
}

@Test func nonEmptyFieldIsNeverTypedInto() async {
    let probe = ScriptedProbe([secure(length: 4)])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "pw", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .fallbackClipboard(.timedOut))
    #expect(typer.typedChunks.isEmpty)
}

@Test func focusChangeMidTypingAbortsWithoutClipboardFallback() async {
    // Lần kiểm: 0 chờ -> secure; 1 trước đoạn 1 -> secure; 2 trước đoạn 2 -> đổi sang app khác.
    let probe = ScriptedProbe([secure(), secure(), otherAppSecure])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: longPassword, autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .aborted(.focusChanged))
    #expect(typer.typedChunks.count == 1)
    #expect(typer.returnPIDs.isEmpty)
    let message = outcome.message(clearSeconds: 30) ?? ""
    #expect(message.contains("xoá ô mật khẩu") && !message.contains("clipboard"))
}

@Test func focusChangeJustBeforeReturnDoesNotPressReturn() async {
    // 1 đoạn: lần 0 chờ, lần 1 trước đoạn, lần 2 trước Return.
    let probe = ScriptedProbe([secure(), secure(), plainField])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "short", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .aborted(.focusChanged))
    #expect(typer.typedChunks == ["short"] && typer.returnPIDs.isEmpty)
}

@Test func differentPidMidTypingAborts() async {
    let probe = ScriptedProbe([secure(pid: 42), secure(pid: 42), secure(pid: 99)])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: longPassword, autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .aborted(.focusChanged))
    #expect(typer.pids == [42])
}

@Test func disabledAutotypeNeitherProbesNorTypes() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "pw", autofillEnabled: true, autotypeEnabled: false)
    #expect(outcome == .fallbackClipboard(.autotypeDisabled))
    #expect(probe.snapshotCalls == 0 && probe.trustRequests == 0 && typer.typedChunks.isEmpty)
}

@Test func autofillOffAndSSHHostNeverTypeOrCopy() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let autotyper = makeAutotyper(probe, typer)
    let off = await autotyper.run(password: "pw", autofillEnabled: false, autotypeEnabled: true)
    #expect(off == .aborted(.autofillDisabled))
    let ssh = await autotyper.run(
        password: "pw", isWindowsHost: false, autofillEnabled: true, autotypeEnabled: true)
    #expect(ssh == .aborted(.notWindowsHost))
    #expect(probe.snapshotCalls == 0 && typer.typedChunks.isEmpty && typer.returnPIDs.isEmpty)
    #expect(off.message(clearSeconds: 30) == nil && ssh.message(clearSeconds: 30) == nil)
}

@Test func passwordWithControlCharactersFallsBackWithoutTyping() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "ab\tcd", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .fallbackClipboard(.unsupportedCharacters))
    #expect(typer.typedChunks.isEmpty && probe.snapshotCalls == 0)
}

@Test func sendFailureAbortsWithoutReturn() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    typer.failFromChunk = 1
    let outcome = await makeAutotyper(probe, typer).run(
        password: longPassword, autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .aborted(.sendFailed))
    #expect(typer.typedChunks.count == 1 && typer.returnPIDs.isEmpty)
}

@Test func cancelledWhileWaitingTypesNothing() async {
    let probe = ScriptedProbe([plainField])
    let typer = RecordingTyper()
    let autotyper = WindowsPasswordAutotyper(
        probe: probe, typer: typer, sleep: { _ in throw CancellationError() }, clock: { 0 })
    let outcome = await autotyper.run(password: "pw", autofillEnabled: true, autotypeEnabled: true)
    #expect(outcome == .cancelled)
    #expect(outcome.message(clearSeconds: 30) == nil)
    #expect(typer.typedChunks.isEmpty)
}

@Test func cancelledTaskStopsBeforeTyping() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let autotyper = makeAutotyper(probe, typer)
    let task = Task { () -> WindowsAutotypeOutcome in
        try? await Task.sleep(nanoseconds: 200_000_000)  // bị huỷ ngay, trả về sớm
        return await autotyper.run(password: "pw", autofillEnabled: true, autotypeEnabled: true)
    }
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(typer.typedChunks.isEmpty)
}

// MARK: - Nối vào ConnectionService

private final class AutotypeOpenApp: WindowsAppHandler, @unchecked Sendable {
    func windowsAppURL() -> URL? { URL(fileURLWithPath: "/Applications/Windows App.app") }
    func open(file: URL, withApplicationAt app: URL) async -> Bool { true }
}

private final class AutotypePasteboard: SecretPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var value: String?
    var string: String? { lock.withLock { value } }
    var changeCount: Int { lock.withLock { count } }
    @discardableResult func clearContents() -> Int {
        lock.withLock {
            count += 1
            value = nil
            return count
        }
    }
    func write(string: String, markerTypes: [String]) -> Int {
        lock.withLock {
            count += 1
            value = string
            return count
        }
    }
}

private final class OutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [WindowsAutotypeOutcome] = []
    var outcomes: [WindowsAutotypeOutcome] { lock.withLock { log } }
    var completion: @Sendable (WindowsAutotypeOutcome) -> Void {
        { [self] outcome in lock.withLock { log.append(outcome) } }
    }
    func waitForFirst() async -> WindowsAutotypeOutcome? {
        for _ in 0..<300 {
            if let first = outcomes.first { return first }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

private struct AutotypeRig {
    let t: HostTempDir
    let service: ConnectionService
    let store: InMemoryCredentialStore
    let pasteboard: AutotypePasteboard
    let settings: SettingsStore
}

private func autotypeRig(
    probe: ScriptedProbe, typer: RecordingTyper, settings initial: AppSettings = AppSettings(),
    time: FakeTime = FakeTime(), sleep: WindowsPasswordAutotyper.Sleep? = nil
) throws -> AutotypeRig {
    let t = HostTempDir()
    let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let pasteboard = AutotypePasteboard()
    let store = InMemoryCredentialStore()
    let settings = SettingsStore(initial)
    let autotyper = WindowsPasswordAutotyper(
        probe: probe, typer: typer, sleep: sleep ?? time.sleep, clock: time.clock)
    let service = ConnectionService(
        repository: HostRepository(database: try Database(url: paths.databaseURL)),
        appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(
            tabConfigsDirectory: t.url.appendingPathComponent("tabs"), handler: SystemWarpURLHandler()),
        rdpLauncher: WindowsAppLauncher(
            directory: paths.baseDirectory.appendingPathComponent("rdp"), handler: AutotypeOpenApp()),
        credentials: store,
        secretClipboard: SecretClipboard(pasteboard: pasteboard, scheduler: { _, _ in {} }),
        settings: settings, windowsAutotyper: autotyper)
    return AutotypeRig(t: t, service: service, store: store, pasteboard: pasteboard, settings: settings)
}

private func windowsHost() -> HostProfile {
    HostProfile(displayName: "Win", kind: .windowsRDP, rdpUsername: "CORP\\a", hostName: "10.0.0.5", port: 3389)
}

@Test func openWindowsAutotypesStoredPasswordAndDoesNotUseClipboard() async throws {
    let typer = RecordingTyper()
    let r = try autotypeRig(probe: ScriptedProbe([secure()]), typer: typer)
    defer { r.t.cleanup() }
    let w = windowsHost()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw-typed")
    let recorder = OutcomeRecorder()
    let report = await r.service.openInWindowsAppReport(w, autotypeCompletion: recorder.completion)
    #expect(report.result == .requested && report.passwordCopy == .autotyping)
    #expect(await recorder.waitForFirst() == .typed)
    #expect(typer.typedChunks.joined() == "pw-typed" && typer.returnPIDs == [42])
    #expect(r.pasteboard.string == nil)  // đã gõ thành công thì không dùng clipboard
    #expect(r.store.reads == 1)
}

@Test func openWindowsFallsBackToClipboardWithoutPermissionOrOnTimeout() async throws {
    // Không có quyền.
    let noPermission = try autotypeRig(
        probe: ScriptedProbe([secure()], trusted: false), typer: RecordingTyper())
    defer { noPermission.t.cleanup() }
    let w = windowsHost()
    try await noPermission.service.add(w)
    try await noPermission.service.savePassword(hostID: w.id, password: "pw-clip")
    let recorder = OutcomeRecorder()
    _ = await noPermission.service.openInWindowsAppReport(w, autotypeCompletion: recorder.completion)
    #expect(await recorder.waitForFirst() == .fallbackClipboard(.noPermission))
    #expect(noPermission.pasteboard.string == "pw-clip")

    // Hết giờ: đồng hồ giả chạy nhanh qua 30 giây.
    let timedOut = try autotypeRig(probe: ScriptedProbe([plainField]), typer: RecordingTyper())
    defer { timedOut.t.cleanup() }
    try await timedOut.service.add(w)
    try await timedOut.service.savePassword(hostID: w.id, password: "pw-late")
    let lateRecorder = OutcomeRecorder()
    _ = await timedOut.service.openInWindowsAppReport(w, autotypeCompletion: lateRecorder.completion)
    #expect(await lateRecorder.waitForFirst() == .fallbackClipboard(.timedOut))
    #expect(timedOut.pasteboard.string == "pw-late")
}

@Test func openWindowsWithAutotypeSettingOffCopiesImmediatelyWithoutProbing() async throws {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    var s = AppSettings()
    s.windowsAutotypePassword = false
    let r = try autotypeRig(probe: probe, typer: typer, settings: s)
    defer { r.t.cleanup() }
    let w = windowsHost()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw-off")
    let report = await r.service.openInWindowsAppReport(w)
    #expect(report.passwordCopy == .copied && r.pasteboard.string == "pw-off")
    #expect(probe.snapshotCalls == 0 && typer.typedChunks.isEmpty)
}

@Test func openWindowsWithAutofillOffNeitherTypesNorCopies() async throws {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    var s = AppSettings()
    s.autofillEnabled = false
    let r = try autotypeRig(probe: probe, typer: typer, settings: s)
    defer { r.t.cleanup() }
    let w = windowsHost()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw")
    let report = await r.service.openInWindowsAppReport(w)
    #expect(report.passwordCopy == .disabled)
    #expect(probe.snapshotCalls == 0 && typer.typedChunks.isEmpty && r.pasteboard.string == nil)
    #expect(r.store.reads == 0)
}

@Test func sshHostNeverAutotypes() async throws {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let r = try autotypeRig(probe: probe, typer: typer)
    defer { r.t.cleanup() }
    var h = HostProfile(displayName: "S", hostName: "h.example.com", user: "u")
    h.authMethod = .interactive
    try await r.service.add(h)
    try await r.service.savePassword(hostID: h.id, password: "ssh-pw")
    let stored = try #require(try await r.service.repository.host(id: h.id))
    let report = await r.service.openInWindowsAppReport(stored)
    if case .failed = report.result {} else { Issue.record("cần .failed") }
    #expect(report.passwordCopy == .none)
    #expect(probe.snapshotCalls == 0 && typer.typedChunks.isEmpty && r.pasteboard.string == nil)
    #expect(r.store.reads == 0)
}

@Test func openingAgainCancelsThePreviousWaitWithoutCopyingOrReporting() async throws {
    let probe = ScriptedProbe([plainField])  // không bao giờ thấy ô mật khẩu
    let r = try autotypeRig(
        probe: probe, typer: RecordingTyper(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    defer { r.t.cleanup() }
    let w = windowsHost()
    try await r.service.add(w)
    try await r.service.savePassword(hostID: w.id, password: "pw")
    let first = OutcomeRecorder()
    let second = OutcomeRecorder()
    let one = await r.service.openInWindowsAppReport(w, autotypeCompletion: first.completion)
    let two = await r.service.openInWindowsAppReport(w, autotypeCompletion: second.completion)
    #expect(one.passwordCopy == .autotyping && two.passwordCopy == .autotyping)
    try await Task.sleep(for: .milliseconds(150))
    #expect(first.outcomes.isEmpty && r.pasteboard.string == nil)
    await r.service.cancelAutotype()
    try await Task.sleep(for: .milliseconds(150))
    #expect(second.outcomes.isEmpty && r.pasteboard.string == nil)
}

@Test func enteredButUnsavedPasswordIsDeliveredThroughAutotypeToo() async throws {
    let typer = RecordingTyper()
    let r = try autotypeRig(probe: ScriptedProbe([secure()]), typer: typer)
    defer { r.t.cleanup() }
    let recorder = OutcomeRecorder()
    #expect(await r.service.deliverWindowsPassword("typed-once", completion: recorder.completion) == .autotyping)
    #expect(await recorder.waitForFirst() == .typed)
    #expect(typer.typedChunks.joined() == "typed-once" && r.pasteboard.string == nil)
    #expect(r.store.reads == 0)  // không đọc / không lưu Keychain
}

@Test func withoutAutotyperServiceKeepsClipboardBehaviour() async throws {
    let t = HostTempDir()
    defer { t.cleanup() }
    let paths = AppPaths(baseDirectory: t.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let pasteboard = AutotypePasteboard()
    let service = ConnectionService(
        repository: HostRepository(database: try Database(url: paths.databaseURL)),
        appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(
            tabConfigsDirectory: t.url.appendingPathComponent("tabs"), handler: SystemWarpURLHandler()),
        credentials: InMemoryCredentialStore(),
        secretClipboard: SecretClipboard(pasteboard: pasteboard, scheduler: { _, _ in {} }))
    #expect(await service.deliverWindowsPassword("pw") == .copied)
    #expect(pasteboard.string == "pw")
}

// MARK: - Tự điền bị tắt giữa chừng (QA)

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// true cho `allowed` lần gọi đầu, sau đó false.
    func allow(first allowed: Int) -> Bool {
        lock.withLock {
            count += 1
            return count <= allowed
        }
    }
}

private final class SleepHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func fire() { lock.withLock { action }?() }
}

@Test func autofillTurnedOffWhileWaitingStopsWithoutTyping() async {
    let probe = ScriptedProbe([plainField])
    let typer = RecordingTyper()
    let counter = CallCounter()
    let outcome = await makeAutotyper(probe, typer).run(
        password: "pw", autofillEnabled: true, autotypeEnabled: true,
        stillAllowed: { counter.allow(first: 2) })
    #expect(outcome == .aborted(.autofillDisabled))
    #expect(typer.typedChunks.isEmpty && typer.returnPIDs.isEmpty)
}

@Test func autofillTurnedOffMidTypingAbortsWithoutReturn() async {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    let counter = CallCounter()
    // Lần 1: vòng chờ; lần 2: trước đoạn 1; lần 3: trước đoạn 2 -> tắt.
    let outcome = await makeAutotyper(probe, typer).run(
        password: longPassword, autofillEnabled: true, autotypeEnabled: true,
        stillAllowed: { counter.allow(first: 2) })
    #expect(outcome == .aborted(.autofillDisabled))
    #expect(typer.typedChunks.count == 1 && typer.returnPIDs.isEmpty)
}

@Test func serviceStopsAndDoesNotCopyWhenAutofillTurnedOffDuringWait() async throws {
    let hook = SleepHook()
    let typer = RecordingTyper()
    let r = try autotypeRig(
        probe: ScriptedProbe([plainField]), typer: typer, sleep: { _ in hook.fire() })
    defer { r.t.cleanup() }
    let settings = r.settings
    hook.set {
        var off = AppSettings()
        off.autofillEnabled = false
        settings.update(off)
    }
    let recorder = OutcomeRecorder()
    #expect(await r.service.deliverWindowsPassword("pw-late", completion: recorder.completion) == .autotyping)
    #expect(await recorder.waitForFirst() == .aborted(.autofillDisabled))
    #expect(typer.typedChunks.isEmpty && r.pasteboard.string == nil)
}

@Test func enteredPasswordWithAutofillOffKeepsOldClipboardBehaviourAndNeverTypes() async throws {
    let probe = ScriptedProbe([secure()])
    let typer = RecordingTyper()
    var s = AppSettings()
    s.autofillEnabled = false
    let r = try autotypeRig(probe: probe, typer: typer, settings: s)
    defer { r.t.cleanup() }
    #expect(await r.service.deliverWindowsPassword("typed-by-hand") == .copied)
    #expect(r.pasteboard.string == "typed-by-hand")
    #expect(probe.snapshotCalls == 0 && typer.typedChunks.isEmpty)
}
