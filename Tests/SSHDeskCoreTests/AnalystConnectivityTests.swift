import Foundation
import Testing

@testable import SSHDeskCore

/// Runner giả: trả kết quả theo lệnh, ghi lại các lệnh đã gọi.
final class FakeExecutor: RemoteCommandExecuting, @unchecked Sendable {
    typealias Handler = @Sendable (AnalystCommand) throws -> RemoteCommandResult
    private let lock = NSLock()
    private var _calls: [String] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    private func record(_ c: AnalystCommand) {
        lock.lock()
        _calls.append(c.commandString ?? "?")
        lock.unlock()
    }

    func execute(_ command: AnalystCommand) async throws -> RemoteCommandResult {
        record(command)
        return try handler(command)
    }
}

func ok(_ out: String = "") -> RemoteCommandResult { RemoteCommandResult(exitStatus: 0, stdout: out, stderr: "") }
func fail(_ code: Int32, _ err: String = "") -> RemoteCommandResult {
    RemoteCommandResult(exitStatus: code, stdout: "", stderr: err)
}

struct AnalystConnectivityTests {
    typealias F = AnalystFixtures

    static let listenDb = "LISTEN 0 244 0.0.0.0:5432 0.0.0.0:* users:((\"postgres\",pid=812,fd=5))\n"

    /// Một cạnh api-01 -> db-01:5432.
    static func flow() -> TopologyFlow {
        TopologyBuilder.build(F.mockup()).flows.first { $0.flow.port == 5432 }!
    }

    static func tester(
        source: @escaping FakeExecutor.Handler, dest: FakeExecutor? = nil
    ) -> (ConnectivityTester, FakeExecutor, FakeExecutor) {
        let src = FakeExecutor(source)
        let dst = dest ?? FakeExecutor { _ in ok(listenDb) }
        return (ConnectivityTester(executors: [F.api: src, F.db: dst]), src, dst)
    }

    @Test func passedViaBash() async {
        let (t, src, _) = Self.tester { _ in ok() }
        let r = await t.run(flows: [Self.flow()])
        guard case .passed(let ms) = r[0].outcome else {
            Issue.record("không passed")
            return
        }
        #expect(ms >= 0)
        #expect(src.calls == ["timeout 3 bash -c '</dev/tcp/10.0.0.4/5432'"])
        #expect(r[0].cause == nil)
        #expect(
            r[0].destinationCheck == .listening(bind: "0.0.0.0", processes: [ProcessRef(name: "postgres", pid: 812)]))
        #expect(r[0].evidence.contains { $0.detail.contains("xấp xỉ") })
    }

    @Test func timeoutFromExit124() async {
        let (t, _, _) = Self.tester { _ in fail(124) }
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .failed(.timeout))
        #expect(r[0].cause == "Chưa xác nhận")
    }

    @Test func refusedFromBashMessage() async {
        let (t, src, _) = Self.tester { _ in
            fail(1, "bash: connect: Connection refused\nbash: /dev/tcp/10.0.0.4/5432: Connection refused")
        }
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .failed(.refused))
        #expect(src.calls.count == 1)  // không fallback khi đã biết rõ
    }

    @Test func fallsBackToNcWhenBashToolMissing() async {
        let (t, src, _) = Self.tester { cmd in
            if case .probeBash = cmd { throw RemoteCommandError.toolMissing("bash") }
            return ok()
        }
        let r = await t.run(flows: [Self.flow()])
        guard case .passed = r[0].outcome else {
            Issue.record("không passed")
            return
        }
        #expect(src.calls.last == "nc -z -w3 10.0.0.4 5432")
    }

    @Test func ncExitOneIsNotGuessed() async {
        let (t, _, _) = Self.tester { cmd in
            if case .probeBash = cmd { throw RemoteCommandError.toolMissing("timeout") }
            return fail(1)
        }
        let r = await t.run(flows: [Self.flow()])
        guard case .failed(.other(let m)) = r[0].outcome else {
            Issue.record("không failed.other")
            return
        }
        #expect(m.contains("không phân biệt"))
    }

    @Test func ncRefusedByMessage() async {
        let (t, _, _) = Self.tester { cmd in
            if case .probeBash = cmd { throw RemoteCommandError.toolMissing("bash") }
            return fail(1, "nc: connect to 10.0.0.4 port 5432 (tcp) failed: Connection refused")
        }
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .failed(.refused))
    }

    @Test func toolMissingEverywhere() async {
        let (t, _, _) = Self.tester { cmd in
            switch cmd {
            case .probeBash: throw RemoteCommandError.toolMissing("bash")
            default: throw RemoteCommandError.toolMissing("nc")
            }
        }
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .untestable(.toolMissing("nc")))
        #expect(r[0].cause == nil)
    }

    @Test func sessionLost() async {
        let (t, src, _) = Self.tester { _ in throw RemoteCommandError.sessionLost }
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .untestable(.sessionLost))
        #expect(src.calls.count == 1)  // không thử tiếp khi mất phiên
    }

    @Test func missingExecutorIsUntestable() async {
        let t = ConnectivityTester(executors: [:])
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].outcome == .untestable(.noExecutor))
        #expect(r[0].destinationCheck == .unknown)
    }

    @Test func destinationNotListening() async {
        let dst = FakeExecutor { _ in ok("LISTEN 0 1 0.0.0.0:22 0.0.0.0:*\n") }
        let (t, _, _) = Self.tester(source: { _ in fail(124) }, dest: dst)
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].destinationCheck == .notListening)
        #expect(r[0].outcome == .failed(.timeout))
    }

    @Test func destinationFallsBackToSocketsWithoutProcess() async {
        let dst = FakeExecutor { cmd in
            if case .sockets = cmd { return fail(1, "Cannot open netlink socket") }
            return ok("LISTEN 0 1 0.0.0.0:5432 0.0.0.0:*\n")
        }
        let (t, _, _) = Self.tester(source: { _ in ok() }, dest: dst)
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].destinationCheck == .listening(bind: "0.0.0.0", processes: nil))
        #expect(dst.calls == ["ss -Htanp", "ss -Htan"])
    }

    @Test func destinationUnknownWhenUnreadable() async {
        let dst = FakeExecutor { _ in throw RemoteCommandError.sessionLost }
        let (t, _, _) = Self.tester(source: { _ in ok() }, dest: dst)
        let r = await t.run(flows: [Self.flow()])
        #expect(r[0].destinationCheck == .unknown)
    }

    @Test func localTimeoutIsNotReportedAsServerTimeout() async {
        let (t, _, _) = Self.tester { _ in
            RemoteCommandResult(exitStatus: 15, stdout: "", stderr: "", timedOut: true)
        }
        let r = await t.run(flows: [Self.flow()])
        guard case .failed(.other) = r[0].outcome else {
            Issue.record("phải là other")
            return
        }
    }

    @Test func ipv6UsesNcOnly() async {
        let f = TopologyFlow(
            flow: Flow(source: F.api, destination: F.db, port: 443), observedConnections: 1,
            destinationIPs: [IPLiteral("fd00::2")!], sourceProcesses: [], destinationListen: nil,
            destinationVerified: false)
        let (t, src, _) = Self.tester { _ in ok() }
        _ = await t.run(flows: [f])
        #expect(src.calls == ["nc -z -w3 -6 fd00::2 443"])
    }

    @Test func parallelismIsBoundedAndOrderPreserved() async {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var current = 0
            var peak = 0
            func enter() {
                lock.lock()
                current += 1
                peak = max(peak, current)
                lock.unlock()
            }
            func leave() {
                lock.lock()
                current -= 1
                lock.unlock()
            }
        }
        let counter = Counter()
        struct Slow: RemoteCommandExecuting {
            let counter: Counter
            func execute(_ command: AnalystCommand) async throws -> RemoteCommandResult {
                if case .probeBash = command {
                    counter.enter()
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    counter.leave()
                }
                return RemoteCommandResult(exitStatus: 0, stdout: "", stderr: "")
            }
        }
        let base = Self.flow()
        let flows = (1...12).map { i -> TopologyFlow in
            var f = base
            f.flow.port = 1000 + i
            return f
        }
        let t = ConnectivityTester(
            executors: [F.api: Slow(counter: counter), F.db: Slow(counter: counter)], maxParallel: 99)
        let r = await t.run(flows: flows)
        #expect(r.map(\.flow.port) == flows.map(\.flow.port))
        #expect(counter.peak <= 4)
        #expect(counter.peak >= 2)
    }
}
