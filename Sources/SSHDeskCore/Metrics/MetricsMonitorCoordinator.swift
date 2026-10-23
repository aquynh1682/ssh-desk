import Foundation

public enum MetricsClientFactory {
    public static func make(
        source: MetricsSource, credentials: (any CredentialStore)?,
        transport: any MetricsTransport = URLSessionMetricsTransport()
    ) -> any MetricsSnapshotProviding {
        switch source.kind {
        case .prometheus:
            return PrometheusClient(source: source, credentials: credentials, transport: transport)
        case .zabbix:
            return ZabbixClient(source: source, credentials: credentials, transport: transport)
        }
    }
}

/// Vòng làm mới Monitor từ nguồn số liệu (ADR-028). KHÔNG mở SSH, KHÔNG chạy lệnh trên server.
/// Mỗi host độc lập, ≤ 4 song song; vòng trước chưa xong thì bỏ lượt. 401/403 -> dừng thử lại host đó
/// cho tới khi người dùng bấm "Thử lại" (tránh khoá tài khoản do sai token lặp lại).
public actor MetricsMonitorCoordinator {
    public static let maxParallel = 4
    public static let intervalChoices = [15, 30, 60]
    public static let defaultInterval = 30

    private let provider: any MetricsSnapshotProviding
    private let now: @Sendable () -> Date
    private let onUpdate: @Sendable (MonitorHostState) -> Void

    private var hosts: [HostProfile] = []
    private var interval: TimeInterval = TimeInterval(defaultInterval)
    private var generation = 0
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var roundRunning = false
    private var blocked: Set<UUID> = []
    public private(set) var states: [UUID: MonitorHostState] = [:]

    public init(
        provider: any MetricsSnapshotProviding, now: @escaping @Sendable () -> Date = { Date() },
        onUpdate: @escaping @Sendable (MonitorHostState) -> Void = { _ in }
    ) {
        self.provider = provider
        self.now = now
        self.onUpdate = onUpdate
    }

    public var isRunning: Bool { running }

    public static func normalizedInterval(_ seconds: Int) -> Int {
        intervalChoices.contains(seconds) ? seconds : defaultInterval
    }

    public func start(hosts: [HostProfile], interval: TimeInterval) {
        loopTask?.cancel()
        generation += 1
        self.hosts = hosts.filter { $0.kind == .ssh }
        self.interval = max(1, interval)
        blocked = []
        states = [:]
        roundRunning = false
        running = true
        startLoop()
    }

    public func setInterval(_ newInterval: TimeInterval) {
        interval = max(1, newInterval)
        guard running else { return }
        loopTask?.cancel()
        startLoop()
    }

    public func stop() {
        generation += 1
        running = false
        loopTask?.cancel()
        loopTask = nil
        roundRunning = false
    }

    public func retry(hostID: UUID) {
        guard running, blocked.remove(hostID) != nil else { return }
        if !roundRunning { Task { await self.refreshRoundIfIdle() } }
    }

    private func startLoop() {
        let seconds = interval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshRoundIfIdle()
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    /// Chạy đúng một vòng nếu không có vòng nào đang chạy. Trả false nếu bỏ lượt.
    @discardableResult
    func refreshRoundIfIdle() async -> Bool {
        guard running, !roundRunning else { return false }
        roundRunning = true
        let gen = generation
        await runRound(generation: gen)
        if gen == generation { roundRunning = false }
        return true
    }

    private func runRound(generation gen: Int) async {
        let targets = hosts.filter { !blocked.contains($0.id) }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let host = targets[next]
                next += 1
                group.addTask { [self] in await refreshHost(host, generation: gen) }
            }
            while next < min(Self.maxParallel, targets.count) { launch() }
            while await group.next() != nil {
                if next < targets.count, !Task.isCancelled { launch() }
            }
        }
    }

    private func publish(_ state: MonitorHostState, generation gen: Int) {
        guard gen == generation else { return }
        states[state.hostID] = state
        onUpdate(state)
    }

    private func refreshHost(_ host: HostProfile, generation gen: Int) async {
        guard gen == generation else { return }
        var state = states[host.id] ?? MonitorHostState(hostID: host.id, status: .connecting)
        if state.snapshot == nil {
            state.status = .connecting
            publish(state, generation: gen)
        }
        do {
            let snapshot = try await provider.snapshot(for: host, at: now())
            guard gen == generation else { return }
            state.status = .ok
            state.snapshot = snapshot
            if let p = snapshot.cpuPercent { state.cpuHistory.append(p) }
            if let p = snapshot.memoryPercent { state.memoryHistory.append(p) }
            publish(state, generation: gen)
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            if case MetricsError.unauthorized = error { blocked.insert(host.id) }
            if case MetricsError.secretMissing = error { blocked.insert(host.id) }
            state.status = .failed(Self.message(error))
            publish(state, generation: gen)
        }
    }

    /// Chỉ thông điệp đã biết của `MetricsError`/`MetricsSourceError`; lỗi lạ -> câu chung (không in error thô).
    static func message(_ error: Error) -> String {
        if let e = error as? MetricsError, let d = e.errorDescription { return d }
        if let e = error as? MetricsSourceError, let d = e.errorDescription { return d }
        return "Không đọc được số liệu."
    }
}
