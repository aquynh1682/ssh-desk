import Foundation

public struct Evidence: Sendable, Equatable {
    public var title: String
    public var detail: String
    /// Trích từ output thô của server (đã làm sạch/cắt ngắn). Báo cáo xuất ra KHÔNG gồm bằng chứng `raw`.
    public var raw: Bool

    public init(title: String, detail: String, raw: Bool = false) {
        self.title = title
        self.detail = detail
        self.raw = raw
    }
}

public enum ProbeFailure: Sendable, Equatable {
    case timeout
    case refused
    case other(String)
}

public enum UntestableReason: Sendable, Equatable {
    case toolMissing(String)
    case sessionLost
    case connectionFailed(String)
    case noExecutor
    case noDestinationIP
}

public enum ProbeOutcome: Sendable, Equatable {
    /// Thời gian xấp xỉ (ms), đo cục bộ.
    case passed(milliseconds: Int)
    case failed(ProbeFailure)
    case untestable(UntestableReason)
}

public enum DestinationCheck: Sendable, Equatable {
    case listening(bind: String, processes: [ProcessRef]?)
    case notListening
    case unknown
}

public struct FlowTestResult: Sendable, Equatable {
    public var flow: Flow
    public var outcome: ProbeOutcome
    public var destinationCheck: DestinationCheck
    public var evidence: [Evidence]
    /// Luôn "Chưa xác nhận" khi probe không đạt: app không suy đoán nguyên nhân (ADR-016).
    public var cause: String?

    public static let unconfirmedCause = "Chưa xác nhận"
}

/// Probe TCP từ server nguồn tới IP của đích (ADR-016). Thời gian đo ở máy này quanh lệnh probe,
/// nên là số XẤP XỈ: gồm cả overhead SSH qua master, không phải RTT mạng thuần.
public actor ConnectivityTester {
    public static let defaultMaxParallel = 4

    private let executors: [UUID: any RemoteCommandExecuting]
    private let maxParallel: Int
    private let probeTimeout: ProbeTimeout

    public init(
        executors: [UUID: any RemoteCommandExecuting], maxParallel: Int = defaultMaxParallel,
        probeTimeout: ProbeTimeout = .default
    ) {
        self.probeTimeout = probeTimeout
        self.executors = executors
        self.maxParallel = max(1, min(maxParallel, Self.defaultMaxParallel))
    }

    /// `progress(đã xong, tổng)` được gọi sau mỗi cạnh. Task bị huỷ thì không khởi chạy thêm cạnh mới;
    /// kết quả trả về chỉ gồm các cạnh đã chạy.
    public func run(
        flows: [TopologyFlow], progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [FlowTestResult] {
        let executors = self.executors
        // Kiểm tra LISTEN của đích: mỗi (đích, cổng) một lần, tuần tự.
        var checks: [Flow: DestinationCheck] = [:]
        var socketCache: [UUID: [SocketRecord]?] = [:]
        for tf in flows {
            if Task.isCancelled { return [] }
            let dest = tf.flow.destination
            if socketCache[dest] == nil {
                socketCache[dest] = await Self.fetchSockets(executors[dest])
            }
            checks[tf.flow] = Self.destinationCheck(
                records: socketCache[dest] ?? nil, flow: tf)
        }

        var results = [FlowTestResult?](repeating: nil, count: flows.count)
        let limit = maxParallel
        let timeout = probeTimeout
        await withTaskGroup(of: (Int, FlowTestResult).self) { group in
            var next = 0
            var inFlight = 0
            func launch(_ i: Int) {
                let tf = flows[i]
                let check = checks[tf.flow] ?? .unknown
                group.addTask {
                    (i, await Self.test(tf, check: check, executor: executors[tf.flow.source], timeout: timeout))
                }
            }
            while next < flows.count, inFlight < limit {
                launch(next)
                next += 1
                inFlight += 1
            }
            var done = 0
            while let (i, r) = await group.next() {
                results[i] = r
                done += 1
                progress?(done, flows.count)
                if next < flows.count, !Task.isCancelled {
                    launch(next)
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    // MARK: - Kiểm tra đích

    static func fetchSockets(_ executor: (any RemoteCommandExecuting)?) async -> [SocketRecord]? {
        guard let executor else { return nil }
        for cmd in [AnalystCommand.sockets, .socketsNoProcess] {
            guard let r = try? await executor.execute(cmd), r.exitStatus == 0, !r.timedOut else {
                continue
            }
            return SocketTableParser.parse(r.stdout).records
        }
        return nil
    }

    static func destinationCheck(records: [SocketRecord]?, flow: TopologyFlow) -> DestinationCheck {
        guard let records else { return .unknown }
        let hit = records.first { rec in
            rec.state == .listen && rec.local.port == flow.flow.port
                && (rec.local.isWildcard || flow.destinationIPs.contains { $0 == rec.local.ip })
        }
        guard let hit else { return .notListening }
        return .listening(bind: hit.local.hostDisplay, processes: hit.processes)
    }

    // MARK: - Probe

    static func test(
        _ tf: TopologyFlow, check: DestinationCheck, executor: (any RemoteCommandExecuting)?,
        timeout: ProbeTimeout = .default
    ) async -> FlowTestResult {
        func make(_ outcome: ProbeOutcome, _ evidence: [Evidence]) -> FlowTestResult {
            var ev = evidence
            switch check {
            case .listening(let bind, let procs):
                let p = procs.map { " (" + $0.map { "\($0.name)/\($0.pid)" }.joined(separator: ", ") + ")" }
                ev.append(
                    Evidence(
                        title: "Đích đang LISTEN",
                        detail: "cổng \(tf.flow.port) bind \(bind)" + (p ?? "")))
            case .notListening:
                ev.append(
                    Evidence(
                        title: "Đích không thấy LISTEN",
                        detail: "cổng \(tf.flow.port) không có socket LISTEN khớp lúc kiểm tra"))
            case .unknown:
                ev.append(
                    Evidence(title: "Chưa kiểm tra được đích", detail: "không đọc được bảng socket của đích"))
            }
            var failed = false
            if case .failed = outcome { failed = true }
            return FlowTestResult(
                flow: tf.flow, outcome: outcome, destinationCheck: check, evidence: ev,
                cause: failed ? FlowTestResult.unconfirmedCause : nil)
        }

        guard let executor else {
            return make(.untestable(.noExecutor), [])
        }
        guard let ip = tf.destinationIPs.first, let port = Port(tf.flow.port) else {
            return make(.untestable(.noDestinationIP), [])
        }
        var evidence = [
            Evidence(title: "Đích thử", detail: "\(ip.address):\(port.value)")
        ]

        // 1) bash /dev/tcp (chỉ IPv4)
        var bashNote: String?
        if ip.version == .v4 {
            let step = await attempt(.probeBash(ip, port, timeout: timeout), executor)
            switch step.kind {
            case .error(let e):
                switch e {
                case .toolMissing(let name):
                    evidence.append(Evidence(title: "Thiếu công cụ", detail: name))
                default:
                    return make(.untestable(reason(for: e)), evidence)
                }
            case .result(let r):
                evidence.append(contentsOf: timing("bash /dev/tcp", r, step.ms))
                if r.timedOut {
                    return make(.failed(.other("ssh không phản hồi trong thời gian chờ cục bộ")), evidence)
                }
                if r.exitStatus == 0 { return make(.passed(milliseconds: step.ms), evidence) }
                if r.exitStatus == 124 { return make(.failed(.timeout), evidence) }
                let err = r.stderr.lowercased()
                if err.contains("connection refused") { return make(.failed(.refused), evidence) }
                if err.contains("no route to host") || err.contains("network is unreachable") {
                    let msg = err.contains("no route to host") ? "No route to host" : "Network is unreachable"
                    return make(.failed(.other(msg)), evidence)
                }
                bashNote = "bash thoát mã \(r.exitStatus)"
            }
        }

        // 2) nc
        let step = await attempt(.probeNc(ip, port, timeout: timeout), executor)
        switch step.kind {
        case .error(let e):
            if case .toolMissing(let name) = e {
                evidence.append(Evidence(title: "Thiếu công cụ", detail: name))
                if let bashNote {
                    return make(.failed(.other("\(bashNote); nc không có")), evidence)
                }
                return make(.untestable(.toolMissing(name)), evidence)
            }
            return make(.untestable(reason(for: e)), evidence)
        case .result(let r):
            evidence.append(contentsOf: timing("nc -z", r, step.ms))
            if r.timedOut {
                return make(.failed(.other("ssh không phản hồi trong thời gian chờ cục bộ")), evidence)
            }
            if r.exitStatus == 0 { return make(.passed(milliseconds: step.ms), evidence) }
            let err = r.stderr.lowercased()
            if err.contains("refused") { return make(.failed(.refused), evidence) }
            if err.contains("timed out") || err.contains("timeout") {
                return make(.failed(.timeout), evidence)
            }
            if r.exitStatus == 1 {
                // nc -z không in lý do khi không có -v: không phân biệt được timeout và refused → không đoán.
                return make(
                    .failed(.other("nc thoát mã 1 (không phân biệt được timeout hay bị từ chối)")),
                    evidence)
            }
            return make(.failed(.other("nc thoát mã \(r.exitStatus)")), evidence)
        }
    }

    private struct Step {
        enum Kind {
            case result(RemoteCommandResult)
            case error(RemoteCommandError)
        }
        var kind: Kind
        var ms: Int
    }

    private static func attempt(_ cmd: AnalystCommand, _ executor: any RemoteCommandExecuting) async -> Step {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let r = try await executor.execute(cmd)
            return Step(kind: .result(r), ms: millis(clock.now - start))
        } catch let e as RemoteCommandError {
            return Step(kind: .error(e), ms: millis(clock.now - start))
        } catch {
            return Step(
                kind: .error(.connectionFailed(String(describing: error))),
                ms: millis(clock.now - start))
        }
    }

    private static func millis(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }

    private static func reason(for e: RemoteCommandError) -> UntestableReason {
        switch e {
        case .toolMissing(let n): return .toolMissing(n)
        case .sessionLost: return .sessionLost
        case .connectionFailed(let m): return .connectionFailed(m)
        case .unsupportedCommand: return .toolMissing("probe")
        case .spawnFailed(let m): return .connectionFailed(m)
        }
    }

    private static func timing(_ name: String, _ r: RemoteCommandResult, _ ms: Int) -> [Evidence] {
        var ev = [
            Evidence(
                title: "Phép thử \(name)",
                detail: "mã thoát \(r.exitStatus); \(ms) ms (xấp xỉ, đo cục bộ, gồm overhead SSH qua master)")
        ]
        let line = firstLine(r.stderr)
        if !line.isEmpty { ev.append(Evidence(title: "stderr", detail: line, raw: true)) }
        return ev
    }

    private static func firstLine(_ s: String) -> String {
        RemoteCommandRunner.firstLine(s)
    }
}
