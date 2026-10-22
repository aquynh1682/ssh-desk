import Foundation

/// Nơi lấy phiên để chạy lệnh trên từng server (thật: `PooledAnalystSessions`; test: giả).
public protocol AnalystSessionProviding: Sendable {
    /// Ném `SessionConnectError` khi không mở được; `CancellationError` khi bị huỷ.
    func executor(for host: HostProfile) async throws -> any RemoteCommandExecuting
    /// Đóng các phiên do provider tự mở (không đụng phiên của màn Truyền file).
    func finish() async
}

/// Provider thật: tái dùng phiên đang sống trong `SessionPool` (vd tab Truyền file cùng host), chưa có thì
/// tự mở qua `SessionConnector` (đăng ký vào pool với owner `.analyst`).
public actor PooledAnalystSessions: AnalystSessionProviding {
    public typealias PromptHandler =
        @Sendable (HostProfile, PromptKind, @escaping SessionConnector.Respond) -> Void

    private let pool: SessionPool
    private let connector: SessionConnector
    private let onPrompt: PromptHandler
    private var opened: [(UUID, RemoteSession)] = []

    public init(pool: SessionPool, connector: SessionConnector, onPrompt: @escaping PromptHandler) {
        self.pool = pool
        self.connector = connector
        self.onPrompt = onPrompt
    }

    public func executor(for host: HostProfile) async throws -> any RemoteCommandExecuting {
        if let live = await pool.liveSession(for: host.id) {
            return RemoteCommandRunner(session: live)
        }
        let handler = onPrompt
        let session = try await connector.connect(host: host) { kind, respond in
            handler(host, kind, respond)
        }
        await pool.register(hostID: host.id, session: session, owner: .analyst)
        opened.append((host.id, session))
        return RemoteCommandRunner(session: session)
    }

    public func finish() async {
        let list = opened
        opened = []
        for (id, s) in list {
            await pool.unregister(hostID: id, session: s)
            await s.close()
        }
    }
}

public enum AnalystProgress: Sendable, Equatable {
    case connecting(host: String, index: Int, total: Int)
    case collecting(done: Int, total: Int, host: String)
    case testing(done: Int, total: Int)
    case saving
}

/// Kết quả bước thu thập: giữ các executor để bước thử dùng lại.
public struct AnalystCollection: Sendable {
    public var folderName: String
    public var startedAt: Date
    public var hosts: [HostProfile]
    public var topology: Topology
    public var warnings: [AnalystWarning]
    var executors: [UUID: any RemoteCommandExecuting]
}

/// Điều phối một lần chạy Project Analyst cho một thư mục: mở phiên → thu thập (song song ≤ 4) →
/// dựng topology → thử kết nối → lưu. Server mất phiên/thiếu công cụ chỉ ghi cảnh báo.
public actor AnalystCoordinator {
    public static let maxParallel = 4

    /// Lệnh thu thập thật sự có thể chạy (không gồm `hostname`: kết quả không được dùng).
    public static let collectionCommands: [AnalystCommand] = ProdGuard.collectionCommands.filter {
        $0 != .hostname
    }

    private let sessions: any AnalystSessionProviding
    private let repository: AnalystRunRepository?
    private let now: @Sendable () -> Date
    private let probeTimeout: ProbeTimeout

    public init(
        sessions: any AnalystSessionProviding, repository: AnalystRunRepository?,
        probeTimeout: ProbeTimeout = .default, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.probeTimeout = probeTimeout
        self.sessions = sessions
        self.repository = repository
        self.now = now
    }

    // MARK: - Chạy đủ

    /// Thu thập + thử + lưu. Huỷ → ném `CancellationError` (không lưu). Luôn đóng phiên tự mở khi xong.
    public func run(
        folder: String, hosts: [HostProfile], progress: (@Sendable (AnalystProgress) -> Void)? = nil
    ) async throws -> StoredAnalystRun {
        do {
            let collection = try await collect(folder: folder, hosts: hosts, progress: progress)
            let results = try await test(collection, progress: progress)
            progress?(.saving)
            let run = Self.makeRun(collection, results: results, finishedAt: now())
            if let repository { try await repository.save(run) }
            await sessions.finish()
            return run
        } catch {
            await sessions.finish()
            throw error
        }
    }

    public static func makeRun(
        _ c: AnalystCollection, results: [FlowTestResult], finishedAt: Date
    ) -> StoredAnalystRun {
        StoredAnalystRun(
            folderName: c.folderName, startedAt: c.startedAt, finishedAt: finishedAt,
            status: c.warnings.isEmpty ? .completed : .partial, warnings: c.warnings,
            topology: c.topology, results: results)
    }

    // MARK: - Thu thập

    public func collect(
        folder: String, hosts: [HostProfile], progress: (@Sendable (AnalystProgress) -> Void)? = nil
    ) async throws -> AnalystCollection {
        let started = now()
        var warnings: [AnalystWarning] = []
        var executors: [UUID: any RemoteCommandExecuting] = [:]

        for (i, host) in hosts.enumerated() {
            try Task.checkCancellation()
            guard host.sshAlias != nil else {
                warnings.append(AnalystWarning(kind: .noAlias, hostID: host.id, hostName: host.displayName))
                continue
            }
            progress?(.connecting(host: host.displayName, index: i + 1, total: hosts.count))
            do {
                executors[host.id] = try await sessions.executor(for: host)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as SessionConnectError {
                warnings.append(
                    AnalystWarning(
                        kind: .sessionFailed, hostID: host.id, hostName: host.displayName,
                        detail: e.message))
            } catch {
                warnings.append(
                    AnalystWarning(
                        kind: .sessionFailed, hostID: host.id, hostName: host.displayName,
                        detail: String(describing: error)))
            }
        }
        try Task.checkCancellation()

        // Thu thập song song ≤ 4.
        let targets = hosts.filter { executors[$0.id] != nil }
        var collected: [UUID: Collected] = [:]
        var done = 0
        await withTaskGroup(of: (UUID, Collected).self) { group in
            var next = 0
            func launch() {
                let host = targets[next]
                let exec = executors[host.id]!
                next += 1
                group.addTask { (host.id, await Self.collectServer(host: host, executor: exec)) }
            }
            while next < min(Self.maxParallel, targets.count) { launch() }
            while let (id, c) = await group.next() {
                collected[id] = c
                done += 1
                let name = hosts.first { $0.id == id }?.displayName ?? ""
                progress?(.collecting(done: done, total: targets.count, host: name))
                if next < targets.count, !Task.isCancelled { launch() }
            }
        }
        try Task.checkCancellation()

        var snapshots: [ServerSnapshot] = []
        for host in hosts {
            let c = collected[host.id]
            snapshots.append(
                ServerSnapshot(
                    hostID: host.id, displayName: host.displayName, hostName: host.hostName,
                    addresses: c?.addresses, sockets: c?.sockets))
            warnings.append(
                contentsOf: c?.warnings.map {
                    var w = $0
                    w.hostName = host.displayName
                    w.hostID = host.id
                    return w
                } ?? [])
        }
        let topology = TopologyBuilder.build(snapshots)
        for w in topology.warnings {
            if case .duplicateIP(let ip, _) = w {
                warnings.append(AnalystWarning(kind: .duplicateIP, detail: ip))
            }
        }
        return AnalystCollection(
            folderName: folder, startedAt: started, hosts: hosts, topology: topology,
            warnings: warnings, executors: executors)
    }

    struct Collected: Sendable {
        var sockets: [SocketRecord]?
        var addresses: [InterfaceAddress]?
        var warnings: [AnalystWarning]
    }

    enum Fetch {
        case ok(String)
        case failed(AnalystWarning.Kind, String)
    }

    /// Thử lần lượt các lệnh; công cụ thiếu thì không thử lệnh dự phòng cùng công cụ.
    static func fetch(_ commands: [AnalystCommand], _ executor: any RemoteCommandExecuting) async -> Fetch {
        var last: Fetch = .failed(.collectFailed, "")
        var missing = Set<String>()
        for cmd in commands {
            if missing.contains(cmd.primaryTool) { continue }
            do {
                let r = try await executor.execute(cmd)
                if r.exitStatus == 0, !r.timedOut { return .ok(r.stdout) }
                last = .failed(.collectFailed, "")
            } catch RemoteCommandError.sessionLost {
                return .failed(.sessionLost, "")
            } catch RemoteCommandError.toolMissing(let t) {
                missing.insert(cmd.primaryTool)
                last = .failed(.toolMissing, t)
            } catch {
                last = .failed(.collectFailed, "")
            }
        }
        return last
    }

    static func collectServer(host: HostProfile, executor: any RemoteCommandExecuting) async -> Collected {
        var out = Collected(sockets: nil, addresses: nil, warnings: [])
        switch await fetch([.sockets, .socketsNoProcess], executor) {
        case .ok(let text):
            let parsed = SocketTableParser.parse(text)
            out.sockets = parsed.records
            if parsed.unparsed > 0 {
                out.warnings.append(AnalystWarning(kind: .unparsedLines, detail: String(parsed.unparsed)))
            }
        case .failed(let kind, let detail):
            out.warnings.append(AnalystWarning(kind: kind, detail: detail))
            if kind == .sessionLost { return out }
        }
        switch await fetch([.addresses, .hostnameIPs], executor) {
        case .ok(let text):
            let a = AddressParser.parseIPAddr(text)
            out.addresses = a.addresses.isEmpty ? AddressParser.parseHostnameIPs(text).addresses : a.addresses
        case .failed(let kind, _):
            if kind == .sessionLost {
                if !out.warnings.contains(where: { $0.kind == .sessionLost }) {
                    out.warnings.append(AnalystWarning(kind: .sessionLost))
                }
            } else if IPLiteral(host.hostName) == nil {
                out.warnings.append(AnalystWarning(kind: .addressesMissing))
            }
        }
        return out
    }

    // MARK: - Thử

    /// Thử mọi cạnh của topology. Huỷ → ném `CancellationError`.
    public func test(
        _ c: AnalystCollection, progress: (@Sendable (AnalystProgress) -> Void)? = nil
    ) async throws -> [FlowTestResult] {
        let flows = c.topology.flows
        if flows.isEmpty { return [] }
        let tester = ConnectivityTester(executors: c.executors, probeTimeout: probeTimeout)
        let results = await tester.run(flows: flows) { done, total in
            progress?(.testing(done: done, total: total))
        }
        try Task.checkCancellation()
        return results
    }

    /// Thử lại đúng một cạnh (mở lại phiên nếu cần). Gọi `finish()` của provider khi xong.
    public func retest(
        flow: TopologyFlow, source: HostProfile, destination: HostProfile
    ) async throws -> FlowTestResult {
        defer { Task { [sessions] in await sessions.finish() } }
        var executors: [UUID: any RemoteCommandExecuting] = [:]
        for host in [source, destination] {
            do { executors[host.id] = try await sessions.executor(for: host) } catch is CancellationError {
                throw CancellationError()
            } catch {
                if host.id == source.id {
                    return FlowTestResult(
                        flow: flow.flow, outcome: .untestable(.noExecutor), destinationCheck: .unknown,
                        evidence: [
                            Evidence(title: "Không mở được phiên", detail: "máy nguồn \(host.displayName)")
                        ], cause: nil)
                }
            }
        }
        let tester = ConnectivityTester(executors: executors, probeTimeout: probeTimeout)
        let r = await tester.run(flows: [flow])
        try Task.checkCancellation()
        return r.first
            ?? FlowTestResult(
                flow: flow.flow, outcome: .untestable(.noExecutor), destinationCheck: .unknown,
                evidence: [], cause: nil)
    }

    /// Đóng phiên tự mở (dùng khi huỷ/thoát).
    public func finish() async { await sessions.finish() }
}
