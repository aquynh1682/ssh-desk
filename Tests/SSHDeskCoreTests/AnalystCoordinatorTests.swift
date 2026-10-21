import Foundation
import Testing

@testable import SSHDeskCore

final class FakeProvider: AnalystSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var executors: [UUID: any RemoteCommandExecuting]
    private var errors: [UUID: any Error]
    private var _finished = 0
    private var _requested: [UUID] = []
    var delay: Duration?

    init(executors: [UUID: any RemoteCommandExecuting], errors: [UUID: any Error] = [:]) {
        self.executors = executors
        self.errors = errors
    }

    var finished: Int {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    var requested: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return _requested
    }

    func executor(for host: HostProfile) async throws -> any RemoteCommandExecuting {
        lock.withLock { _requested.append(host.id) }
        if let delay { try await Task.sleep(for: delay) }
        if let e = errors[host.id] { throw e }
        guard let ex = executors[host.id] else { throw SessionConnectError.failed("không có") }
        return ex
    }

    func finish() async {
        lock.withLock { _finished += 1 }
    }
}

struct AnalystCoordinatorTests {
    typealias F = AnalystFixtures

    static func host(_ id: UUID, _ name: String, ip: String) -> HostProfile {
        HostProfile(
            id: id, displayName: name, project: "Payment", environment: .uat, hostName: ip, user: "u")
    }

    static let fe = host(F.fe, "fe-01", ip: "10.0.0.1")
    static let be = host(F.be, "be-01", ip: "10.0.0.2")
    static let api = host(F.api, "api-01", ip: "10.0.0.3")

    static func ipAddr(_ ip: String) -> String {
        "1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever\n"
            + "2: eth0    inet \(ip)/24 brd 10.0.0.255 scope global eth0\\       valid_lft forever\n"
    }

    static let feSockets = "ESTAB 0 0 10.0.0.1:40001 10.0.0.2:8080 users:((\"nginx\",pid=11,fd=9))\n"
    static let beSockets =
        "LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"java\",pid=20,fd=4))\n"
        + "ESTAB 0 0 10.0.0.2:41000 10.0.0.3:9000\n"
    static let apiSockets = "LISTEN 0 128 *:9000 *:*\n"

    static func exec(
        sockets: String, ip: String, probe: RemoteCommandResult = ok()
    ) -> FakeExecutor {
        FakeExecutor { cmd in
            switch cmd {
            case .sockets, .socketsNoProcess: return ok(sockets)
            case .addresses: return ok(ipAddr(ip))
            case .probeBash, .probeNc: return probe
            default: return ok()
            }
        }
    }

    func repo() throws -> (AnalystRunRepository, HostTempDir) {
        let t = HostTempDir()
        return (AnalystRunRepository(database: try Database(url: t.dbURL)), t)
    }

    @Test func fullRunCollectsTestsAndSaves() async throws {
        let (r, t) = try repo()
        defer { t.cleanup() }
        let provider = FakeProvider(executors: [
            F.fe: Self.exec(sockets: Self.feSockets, ip: "10.0.0.1"),
            F.be: Self.exec(sockets: Self.beSockets, ip: "10.0.0.2"),
            F.api: Self.exec(sockets: Self.apiSockets, ip: "10.0.0.3"),
        ])
        let c = AnalystCoordinator(sessions: provider, repository: r)
        let progress = ProgressLog()
        let run = try await c.run(
            folder: "Payment", hosts: [Self.fe, Self.be, Self.api]
        ) { progress.add($0) }
        #expect(run.topology.flows.count == 2)
        #expect(run.results.count == 2)
        #expect(AnalystPresentation.summary(run.results) == "2 thông · 0 lỗi")
        #expect(run.status == .completed && run.warnings.isEmpty)
        #expect(provider.finished == 1)
        let saved = try await r.list(folder: "Payment")
        #expect(saved.count == 1 && saved[0].passed == 2)
        let events = progress.events
        #expect(events.contains { if case .connecting(_, 3, 3) = $0 { true } else { false } })
        #expect(
            events.contains(
                .collecting(
                    done: 3, total: 3,
                    host: events.compactMap { if case .collecting(3, 3, let h) = $0 { h } else { nil } }.first ?? "")))
        #expect(events.contains(.testing(done: 2, total: 2)))
        #expect(events.last == .saving)
    }

    @Test func sessionFailureIsWarningAndOthersContinue() async throws {
        let provider = FakeProvider(
            executors: [
                F.fe: Self.exec(sockets: Self.feSockets, ip: "10.0.0.1"),
                F.be: Self.exec(sockets: Self.beSockets, ip: "10.0.0.2"),
            ], errors: [F.api: SessionConnectError.failed("Permission denied")])
        let c = AnalystCoordinator(sessions: provider, repository: nil)
        let run = try await c.run(folder: "Payment", hosts: [Self.fe, Self.be, Self.api])
        let w = try #require(run.warnings.first { $0.kind == .sessionFailed })
        #expect(w.hostID == F.api && w.detail == "Permission denied")
        #expect(run.status == .partial)
        #expect(run.topology.node(F.api)?.collected == false)
        // be -> api:9000 vẫn tạo cạnh (đích chưa xác minh), fe -> be vẫn thử được
        #expect(run.topology.flows.count == 2)
        #expect(run.results.count == 2)
        #expect(run.topology.flows.first { $0.flow.destination == F.api }?.destinationVerified == false)
    }

    @Test func missingToolAndLostSessionBecomeWarnings() async throws {
        let noSs = FakeExecutor { cmd in
            switch cmd {
            case .sockets, .socketsNoProcess: throw RemoteCommandError.toolMissing("ss")
            case .addresses: return ok(Self.ipAddr("10.0.0.2"))
            default: return ok()
            }
        }
        let lost = FakeExecutor { _ in throw RemoteCommandError.sessionLost }
        let provider = FakeProvider(executors: [
            F.fe: Self.exec(sockets: Self.feSockets, ip: "10.0.0.1"), F.be: noSs, F.api: lost,
        ])
        let c = AnalystCoordinator(sessions: provider, repository: nil)
        let run = try await c.run(folder: "P", hosts: [Self.fe, Self.be, Self.api])
        #expect(run.warnings.contains { $0.kind == .toolMissing && $0.hostID == F.be && $0.detail == "ss" })
        #expect(run.warnings.contains { $0.kind == .sessionLost && $0.hostID == F.api })
        #expect(run.warnings.filter { $0.hostID == F.api }.count == 1)
        #expect(run.topology.node(F.be)?.collected == false)
        #expect(run.warnings.first { $0.kind == .toolMissing }?.text.contains("thiếu công cụ ss") == true)
    }

    @Test func ssFallsBackToNoProcessVariant() async throws {
        let ex = FakeExecutor { cmd in
            switch cmd {
            case .sockets: return fail(1, "ss: invalid option -- 'p'")
            case .socketsNoProcess: return ok(Self.apiSockets)
            case .addresses: return ok(Self.ipAddr("10.0.0.3"))
            default: return ok()
            }
        }
        let c = AnalystCoordinator(sessions: FakeProvider(executors: [F.api: ex]), repository: nil)
        let run = try await c.run(folder: "P", hosts: [Self.api])
        #expect(run.topology.node(F.api)?.collected == true)
        #expect(ex.calls == ["ss -Htanp", "ss -Htan", "ip -o addr show"])
    }

    @Test func hostWithoutAliasIsSkipped() async throws {
        let bad = HostProfile(
            displayName: "legacy", connectionMode: .existingSSHConfigAlias, sshConfigPath: "/x",
            sshConfigAlias: nil)
        let provider = FakeProvider(executors: [:])
        let c = AnalystCoordinator(sessions: provider, repository: nil)
        let run = try await c.run(folder: "P", hosts: [bad])
        #expect(run.warnings.first?.kind == .noAlias)
        #expect(provider.requested.isEmpty)
    }

    @Test func collectionOnlyRunsWhitelistedReadCommands() async throws {
        let ex = Self.exec(sockets: Self.feSockets, ip: "10.0.0.1")
        let c = AnalystCoordinator(sessions: FakeProvider(executors: [F.fe: ex]), repository: nil)
        _ = try await c.run(folder: "P", hosts: [Self.fe])
        #expect(Set(ex.calls) == ["ss -Htanp", "ip -o addr show"])
        #expect(!AnalystCoordinator.collectionCommands.contains(.hostname))
    }

    @Test func cancelStopsWithoutSaving() async throws {
        let (r, t) = try repo()
        defer { t.cleanup() }
        let provider = FakeProvider(executors: [
            F.fe: Self.exec(sockets: Self.feSockets, ip: "10.0.0.1")
        ])
        provider.delay = .seconds(30)
        let c = AnalystCoordinator(sessions: provider, repository: r)
        let task = Task { try await c.run(folder: "P", hosts: [Self.fe]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("phải ném CancellationError")
        } catch is CancellationError {}
        #expect(try await r.list(folder: "P").isEmpty)
        #expect(provider.finished == 1)
    }

    @Test func collectionRunsAtMostFourInParallel() async throws {
        let counter = Concurrency()
        let ids = (0..<9).map { _ in UUID() }
        var execs: [UUID: any RemoteCommandExecuting] = [:]
        var hosts: [HostProfile] = []
        for (i, id) in ids.enumerated() {
            execs[id] = SlowExecutor(counter: counter, ip: "10.0.1.\(i + 1)")
            hosts.append(Self.host(id, "h\(i)", ip: "10.0.1.\(i + 1)"))
        }
        let c = AnalystCoordinator(sessions: FakeProvider(executors: execs), repository: nil)
        _ = try await c.collect(folder: "P", hosts: hosts)
        let peak = await counter.peak
        #expect(peak <= 4 && peak >= 2)
    }

    @Test func retestProbesOnlyThatFlow() async throws {
        let api = FakeExecutor { cmd in
            if case .probeBash = cmd { return fail(124) }
            return ok()
        }
        let db = FakeExecutor { _ in ok("LISTEN 0 244 0.0.0.0:5432 0.0.0.0:*\n") }
        let provider = FakeProvider(executors: [F.api: api, F.db: db])
        let c = AnalystCoordinator(sessions: provider, repository: nil)
        let tf = AnalystConnectivityTests.flow()
        let r = try await c.retest(
            flow: tf, source: Self.host(F.api, "api-01", ip: "10.0.0.3"),
            destination: Self.host(F.db, "db-01", ip: "10.0.0.4"))
        #expect(r.outcome == .failed(.timeout) && r.flow == tf.flow)
        #expect(api.calls == ["timeout 3 bash -c '</dev/tcp/10.0.0.4/5432'"])
    }

    @Test func retestWithoutSourceSessionIsUntestable() async throws {
        let provider = FakeProvider(executors: [:], errors: [F.api: SessionConnectError.failed("x")])
        let c = AnalystCoordinator(sessions: provider, repository: nil)
        let r = try await c.retest(
            flow: AnalystConnectivityTests.flow(), source: Self.host(F.api, "api-01", ip: "10.0.0.3"),
            destination: Self.host(F.db, "db-01", ip: "10.0.0.4"))
        #expect(r.outcome == .untestable(.noExecutor))
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _e: [AnalystProgress] = []
    func add(_ p: AnalystProgress) {
        lock.lock()
        _e.append(p)
        lock.unlock()
    }
    var events: [AnalystProgress] {
        lock.lock()
        defer { lock.unlock() }
        return _e
    }
}

actor Concurrency {
    private var current = 0
    private(set) var peak = 0
    func enter() {
        current += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}

struct SlowExecutor: RemoteCommandExecuting {
    let counter: Concurrency
    let ip: String
    func execute(_ command: AnalystCommand) async throws -> RemoteCommandResult {
        switch command {
        case .sockets:
            await counter.enter()
            try? await Task.sleep(for: .milliseconds(60))
            await counter.leave()
            return ok("LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n")
        case .addresses: return ok(AnalystCoordinatorTests.ipAddr(ip))
        default: return ok()
        }
    }
}

struct SessionPoolTests {
    @Test func registerLookupAndIdentityUnregister() async {
        let pool = SessionPool()
        let id = UUID()
        let a = RemoteSession(alias: "a", configPath: "/c", controlPath: "/tmp/sshdesk-test-none-\(id)")
        let b = RemoteSession(alias: "a", configPath: "/c", controlPath: "/tmp/sshdesk-test-none-\(id)")
        await pool.register(hostID: id, session: a, owner: .browser)
        #expect(await pool.owner(of: id) == .browser)
        await pool.unregister(hostID: id, session: b)  // phiên khác: không gỡ
        #expect(await pool.owner(of: id) == .browser)
        await pool.unregister(hostID: id, session: a)
        #expect(await pool.owner(of: id) == nil)
    }

    @Test func deadSessionIsDroppedOnLookup() async {
        let pool = SessionPool()
        let id = UUID()
        // Không có master nào trên socket này: `ssh -O check` thất bại → coi là chết.
        let s = RemoteSession(
            alias: "none", configPath: "/dev/null", controlPath: "/tmp/sshdesk-test-none-\(id)")
        await pool.register(hostID: id, session: s, owner: .analyst)
        #expect(await pool.liveSession(for: id) == nil)
        #expect(await pool.owner(of: id) == nil)
    }

    @Test func connectorRejectsHostWithoutAlias() async {
        let connector = SessionConnector(
            configPath: "/dev/null", credentials: InMemoryCredentialStore(), helper: nil)
        let bad = HostProfile(
            displayName: "x", connectionMode: .existingSSHConfigAlias, sshConfigPath: "/x",
            sshConfigAlias: nil)
        await #expect(throws: SessionConnectError.noAlias) {
            _ = try await connector.connect(host: bad) { _, _ in }
        }
    }
}
