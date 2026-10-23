import Foundation
import Testing

@testable import SSHDeskCore

/// Executor giả: trả đầu ra theo script, đếm số lần gọi. Mỗi lần gọi `.procFiles` tăng bộ đếm CPU.
actor FakeMonitorExecutor: MonitorCommandExecuting {
    enum Mode: Sendable {
        case ok
        case unsupported
        case sessionLost
        case timedOut
    }

    var mode: Mode
    var delay: Duration?
    private(set) var calls: [MonitorCommand] = []
    private var n: UInt64 = 0

    init(mode: Mode = .ok, delay: Duration? = nil) {
        self.mode = mode
        self.delay = delay
    }

    func setMode(_ m: Mode) { mode = m }

    func execute(_ command: MonitorCommand) async throws -> RemoteCommandResult {
        calls.append(command)
        if let delay { try await Task.sleep(for: delay) }
        switch mode {
        case .sessionLost: throw RemoteCommandError.sessionLost
        case .timedOut: return RemoteCommandResult(exitStatus: 0, stdout: "", stderr: "", timedOut: true)
        case .unsupported:
            return RemoteCommandResult(
                exitStatus: 1, stdout: "", stderr: "cat: /proc/stat: No such file or directory")
        case .ok: break
        }
        switch command {
        case .procFiles:
            n += 1
            // mỗi lần: +1000 tổng, +500 idle → 50%
            let text = """
                cpu  \(500 * n) 0 0 \(500 * n) 0 0 0 0 0 0
                cpu0 1 0 0 1 0 0 0 0 0 0
                MemTotal: 1000 kB
                MemAvailable: 250 kB
                SwapTotal: 0 kB
                SwapFree: 0 kB
                0.10 0.20 0.30 1/100 5
                1000.50 2000.00

                """
            return RemoteCommandResult(exitStatus: 0, stdout: text, stderr: "")
        case .cpuCount: return RemoteCommandResult(exitStatus: 0, stdout: "2\n", stderr: "")
        case .diskUsage:
            return RemoteCommandResult(
                exitStatus: 0,
                stdout:
                    "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 1000 500 500 50% /\n",
                stderr: "")
        }
    }

    var procCalls: Int { calls.filter { $0 == .procFiles }.count }
}

final class FakeMonitorProvider: MonitorSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var executors: [UUID: any MonitorCommandExecuting]
    private var errors: [UUID: any Error]
    private var _finished = 0
    private var _requested: [UUID] = []
    private var _active = 0
    private var _maxActive = 0
    var connectDelay: Duration?

    init(executors: [UUID: any MonitorCommandExecuting], errors: [UUID: any Error] = [:]) {
        self.executors = executors
        self.errors = errors
    }

    var finished: Int { lock.withLock { _finished } }
    var requested: [UUID] { lock.withLock { _requested } }
    var maxActive: Int { lock.withLock { _maxActive } }

    func executor(for host: HostProfile) async throws -> any MonitorCommandExecuting {
        lock.withLock {
            _requested.append(host.id)
            _active += 1
            _maxActive = max(_maxActive, _active)
        }
        defer { lock.withLock { _active -= 1 } }
        if let connectDelay { try await Task.sleep(for: connectDelay) }
        if let e = errors[host.id] { throw e }
        guard let ex = executors[host.id] else { throw SessionConnectError.failed("không có") }
        return ex
    }

    func finish() async { lock.withLock { _finished += 1 } }
}

final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MonitorHostState] = []
    func add(_ s: MonitorHostState) { lock.withLock { items.append(s) } }
    var all: [MonitorHostState] { lock.withLock { items } }
}

struct MonitorCoordinatorTests {
    static func host(_ name: String, env: HostEnvironment = .dev) -> HostProfile {
        HostProfile(displayName: name, project: "P", environment: env, hostName: "\(name).example.com", user: "u")
    }

    @Test func okHostsComputeCPUFromSecondRound() async {
        let h = Self.host("a")
        let ex = FakeMonitorExecutor()
        let provider = FakeMonitorProvider(executors: [h.id: ex])
        let log = UpdateLog()
        let c = MonitorCoordinator(sessions: provider, onUpdate: { log.add($0) })
        await c.start(hosts: [h], interval: 3600)
        // vòng tự chạy bởi start; đợi nó xong rồi gọi thêm
        try? await Task.sleep(for: .milliseconds(1200))
        var s = await c.states[h.id]
        #expect(s?.status == .ok)
        #expect(s?.snapshot?.cpuPercent == nil)  // lần đầu
        #expect(s?.snapshot?.memoryPercent == 75)
        #expect(s?.snapshot?.cores == 2)
        #expect(s?.snapshot?.disks.first?.mount == "/")
        #expect(await c.refreshRound())
        s = await c.states[h.id]
        #expect(s?.snapshot?.cpuPercent == 50)
        #expect(s?.cpuHistory.values == [50])
        #expect(s?.memoryHistory.values.count == 2)
        #expect(log.all.first?.status == .connecting)
        await c.stop()
        #expect(provider.finished == 1)
    }

    @Test func oneFailingHostDoesNotBlockOthers() async {
        let good = Self.host("good")
        let bad = Self.host("bad")
        let lost = Self.host("lost")
        let exGood = FakeMonitorExecutor()
        let provider = FakeMonitorProvider(
            executors: [good.id: exGood, lost.id: FakeMonitorExecutor(mode: .sessionLost)],
            errors: [bad.id: SessionConnectError.failed("Permission denied")])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [bad, good, lost], interval: 3600)
        try? await Task.sleep(for: .milliseconds(1200))
        let states = await c.states
        #expect(states[good.id]?.status == .ok)
        #expect(states[bad.id]?.status == .failed("Permission denied"))
        #expect(states[lost.id]?.status == .failed("Mất phiên SSH"))
        await c.stop()
    }

    /// Poll tối đa 5 giây tới khi điều kiện đúng.
    static func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func connectFailureIsNotRetriedAutomatically() async {
        let bad = Self.host("bad")
        let provider = FakeMonitorProvider(
            executors: [:], errors: [bad.id: SessionConnectError.failed("Permission denied")])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [bad], interval: 3600)
        #expect(await Self.waitUntil { provider.requested.count >= 1 })
        #expect(await c.refreshRound())
        #expect(await c.refreshRound())
        // Không thử lại tự động: chờ thêm một khoảng rồi kiểm số lần yêu cầu không tăng.
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(provider.requested.count == 1)
        await c.retry(hostID: bad.id)
        #expect(await Self.waitUntil { provider.requested.count >= 2 })
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(provider.requested.count == 2)
        await c.stop()
    }

    @Test func unsupportedHostIsReportedOnce() async {
        let h = Self.host("mac")
        let ex = FakeMonitorExecutor(mode: .unsupported)
        let provider = FakeMonitorProvider(executors: [h.id: ex])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [h], interval: 3600)
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(await c.states[h.id]?.status == .unsupported)
        _ = await c.refreshRound()
        #expect(await ex.procCalls == 1)
        await c.stop()
    }

    @Test func timeoutIsRetriedNextRound() async {
        let h = Self.host("slow")
        let ex = FakeMonitorExecutor(mode: .timedOut)
        let provider = FakeMonitorProvider(executors: [h.id: ex])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [h], interval: 3600)
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(await c.states[h.id]?.status == .failed("Hết thời gian chờ"))
        await ex.setMode(.ok)
        #expect(await c.refreshRound())
        #expect(await c.states[h.id]?.status == .ok)
        await c.stop()
    }

    @Test func overlappingRoundIsSkipped() async {
        let h = Self.host("slow")
        let ex = FakeMonitorExecutor(delay: .milliseconds(300))
        let provider = FakeMonitorProvider(executors: [h.id: ex])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [h], interval: 3600)
        try? await Task.sleep(for: .milliseconds(100))  // vòng đầu đang chạy
        #expect(await c.refreshRound() == false)
        await c.stop()
    }

    @Test func atMostFourHostsInParallel() async {
        let hosts = (0..<10).map { Self.host("h\($0)") }
        var execs: [UUID: any MonitorCommandExecuting] = [:]
        for h in hosts { execs[h.id] = FakeMonitorExecutor() }
        let provider = FakeMonitorProvider(executors: execs)
        provider.connectDelay = .milliseconds(100)
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: hosts, interval: 3600)
        try? await Task.sleep(for: .milliseconds(900))
        #expect(await c.states.count == 10)
        #expect(provider.maxActive <= 4)
        #expect(provider.maxActive > 1)
        await c.stop()
    }

    @Test func stopClosesSessionsAndIgnoresLateResults() async {
        let h = Self.host("slow")
        let provider = FakeMonitorProvider(executors: [h.id: FakeMonitorExecutor()])
        provider.connectDelay = .milliseconds(300)
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [h], interval: 3600)
        try? await Task.sleep(for: .milliseconds(50))
        await c.stop()
        #expect(provider.finished == 1)
        #expect(await c.isRunning == false)
        try? await Task.sleep(for: .milliseconds(400))
        // kết quả muộn không được ghi đè trạng thái sau khi dừng
        #expect(await c.states[h.id]?.status != .ok)
    }

    @Test func hostsWithoutAliasAreSkipped() async {
        var h = Self.host("noalias")
        h.connectionMode = .existingSSHConfigAlias
        h.sshConfigAlias = nil
        let provider = FakeMonitorProvider(executors: [:])
        let c = MonitorCoordinator(sessions: provider)
        await c.start(hosts: [h], interval: 3600)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.requested.isEmpty)
        await c.stop()
    }

    @Test func runnerArgvCarriesOnlyWhitelistedCommand() {
        let r = RemoteCommandRunner(
            alias: "a", configPath: "/c", controlPath: "/s", aliveCheck: { true })
        let argv = r.arguments(for: MonitorCommand.diskUsage.commandString)
        #expect(argv.last == "df -P -k")
        #expect(argv.contains("BatchMode=yes"))
        #expect(argv.contains("ControlMaster=no"))
    }
}
