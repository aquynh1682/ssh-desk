import Foundation

/// Nơi lấy phiên để chạy lệnh Monitor (thật: `PooledMonitorSessions`; test: giả).
public protocol MonitorSessionProviding: Sendable {
    /// Ném `SessionConnectError` khi không mở được; `CancellationError` khi bị huỷ.
    func executor(for host: HostProfile) async throws -> any MonitorCommandExecuting
    /// Đóng các phiên do provider tự mở (không đụng phiên của màn Truyền file/Analyst).
    func finish() async
}

/// Provider thật: tái dùng phiên đang sống trong `SessionPool`, chưa có thì tự mở qua `SessionConnector`
/// (đăng ký vào pool với owner `.monitor`).
public actor PooledMonitorSessions: MonitorSessionProviding {
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

    public func executor(for host: HostProfile) async throws -> any MonitorCommandExecuting {
        if let live = await pool.liveSession(for: host.id) {
            return RemoteCommandRunner(session: live)
        }
        let handler = onPrompt
        let session = try await connector.connect(host: host) { kind, respond in
            handler(host, kind, respond)
        }
        if Task.isCancelled {
            await session.close()
            throw CancellationError()
        }
        await pool.register(hostID: host.id, session: session, owner: .monitor)
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

public enum MonitorHostStatus: Sendable, Equatable {
    case connecting
    case ok
    /// Lý do ngắn gọn, đã làm sạch.
    case failed(String)
    /// Không phải Linux hoặc thiếu `/proc`.
    case unsupported
}

public struct MonitorHostState: Sendable, Equatable {
    public var hostID: UUID
    public var status: MonitorHostStatus
    /// Giữ mẫu cuối cả khi lỗi (hiển thị mờ).
    public var snapshot: MonitorSnapshot?
    public var cpuHistory = MonitorHistory()
    public var memoryHistory = MonitorHistory()

    public init(hostID: UUID, status: MonitorHostStatus) {
        self.hostID = hostID
        self.status = status
    }
}

/// Vòng làm mới Monitor (ADR-019). Mỗi host độc lập, ≤ 4 host song song, vòng trước chưa xong thì bỏ lượt.
/// Host kết nối thất bại hoặc không hỗ trợ KHÔNG bị tự thử lại (tránh khoá tài khoản vì sai password lặp);
/// người dùng bấm thử lại (`retry`) hoặc Dừng/Tiếp tục.
public actor MonitorCoordinator {
    public static let maxParallel = 4

    private let sessions: any MonitorSessionProviding
    private let now: @Sendable () -> Date
    private let onUpdate: @Sendable (MonitorHostState) -> Void

    private var hosts: [HostProfile] = []
    private var interval: TimeInterval = 5
    private var generation = 0
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var roundTask: Task<Void, Never>?
    private var roundRunning = false

    private var executors: [UUID: any MonitorCommandExecuting] = [:]
    private var previousCPU: [UUID: CPUCounters] = [:]
    private var blocked: Set<UUID> = []
    public private(set) var states: [UUID: MonitorHostState] = [:]

    public init(
        sessions: any MonitorSessionProviding, now: @escaping @Sendable () -> Date = { Date() },
        onUpdate: @escaping @Sendable (MonitorHostState) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.now = now
        self.onUpdate = onUpdate
    }

    public var isRunning: Bool { running }

    // MARK: - Điều khiển

    /// Bắt đầu theo dõi (xoá trạng thái cũ). Vòng đầu chạy ngay.
    public func start(hosts: [HostProfile], interval: TimeInterval) {
        cancelTasks()
        generation += 1
        self.hosts = hosts.filter { $0.sshAlias != nil }
        self.interval = max(1, interval)
        executors = [:]
        previousCPU = [:]
        blocked = []
        states = [:]
        roundRunning = false
        running = true
        startLoop()
    }

    /// Đổi chu kỳ mà không đóng phiên hay xoá lịch sử.
    public func setInterval(_ newInterval: TimeInterval) {
        interval = max(1, newInterval)
        guard running else { return }
        loopTask?.cancel()
        startLoop()
    }

    /// Dừng vòng và đóng các phiên do Monitor tự mở. Trạng thái cuối vẫn đọc được.
    public func stop() async {
        generation += 1
        running = false
        cancelTasks()
        roundRunning = false
        executors = [:]
        await sessions.finish()
    }

    /// Thử lại một host đã lỗi kết nối/không hỗ trợ.
    public func retry(hostID: UUID) {
        guard running, blocked.remove(hostID) != nil else { return }
        executors[hostID] = nil
        if !roundRunning { launchRound() }
    }

    private func cancelTasks() {
        loopTask?.cancel()
        roundTask?.cancel()
        loopTask = nil
        roundTask = nil
    }

    private func startLoop() {
        let seconds = interval
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.launchRoundIfIdle()
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    private func launchRoundIfIdle() {
        guard running, !roundRunning else { return }
        launchRound()
    }

    private func launchRound() {
        roundRunning = true
        let gen = generation
        roundTask = Task { [weak self] in
            await self?.runRound(generation: gen)
            await self?.roundFinished(generation: gen)
        }
    }

    private func roundFinished(generation gen: Int) {
        if gen == generation { roundRunning = false }
    }

    /// Chạy đúng một vòng nếu không có vòng nào đang chạy (cho test). Trả false nếu bỏ lượt.
    @discardableResult
    func refreshRound() async -> Bool {
        guard running, !roundRunning else { return false }
        roundRunning = true
        let gen = generation
        await runRound(generation: gen)
        roundFinished(generation: gen)
        return true
    }

    // MARK: - Một vòng

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

    private func setStatus(_ id: UUID, _ status: MonitorHostStatus, generation gen: Int) {
        var s = states[id] ?? MonitorHostState(hostID: id, status: status)
        s.status = status
        publish(s, generation: gen)
    }

    private func refreshHost(_ host: HostProfile, generation gen: Int) async {
        guard gen == generation else { return }
        let executor: any MonitorCommandExecuting
        if let existing = executors[host.id] {
            executor = existing
        } else {
            setStatus(host.id, .connecting, generation: gen)
            do {
                executor = try await sessions.executor(for: host)
            } catch is CancellationError {
                return
            } catch let e as SessionConnectError {
                blocked.insert(host.id)
                setStatus(host.id, .failed(Self.clean(e.message)), generation: gen)
                return
            } catch {
                blocked.insert(host.id)
                setStatus(host.id, .failed(Self.clean(String(describing: error))), generation: gen)
                return
            }
            guard gen == generation else { return }
            executors[host.id] = executor
        }

        let procResult: RemoteCommandResult
        do {
            procResult = try await executor.execute(.procFiles)
        } catch RemoteCommandError.toolMissing {
            blocked.insert(host.id)
            setStatus(host.id, .unsupported, generation: gen)
            return
        } catch RemoteCommandError.sessionLost {
            executors[host.id] = nil
            setStatus(host.id, .failed("Mất phiên SSH"), generation: gen)
            return
        } catch RemoteCommandError.connectionFailed(let m) {
            setStatus(host.id, .failed(m.isEmpty ? "Lỗi kênh SSH" : Self.clean(m)), generation: gen)
            return
        } catch is CancellationError {
            return
        } catch {
            setStatus(host.id, .failed(Self.clean(String(describing: error))), generation: gen)
            return
        }
        if procResult.timedOut {
            setStatus(host.id, .failed("Hết thời gian chờ"), generation: gen)
            return
        }
        if procResult.exitStatus != 0 {
            if procResult.exitStatus == 127 || procResult.stderr.contains("No such file") {
                blocked.insert(host.id)
                setStatus(host.id, .unsupported, generation: gen)
            } else {
                setStatus(host.id, .failed("Lệnh thoát với mã \(procResult.exitStatus)"), generation: gen)
            }
            return
        }
        let proc = MonitorParser.parseProc(procResult.stdout)
        guard proc.cpu != nil || proc.memory != nil else {
            blocked.insert(host.id)
            setStatus(host.id, .unsupported, generation: gen)
            return
        }

        // Số nhân và đĩa chỉ là phụ: lỗi thì bỏ qua phần đó.
        var cores: Int?
        if let r = try? await executor.execute(.cpuCount), r.exitStatus == 0, !r.timedOut {
            cores = MonitorParser.parseCPUCount(r.stdout)
        }
        var disks: [DiskUsage] = []
        if let r = try? await executor.execute(.diskUsage), r.exitStatus == 0, !r.timedOut {
            disks = MonitorParser.parseDf(r.stdout)
        }
        guard gen == generation else { return }

        let snapshot = MonitorSnapshot.make(
            proc: proc, cores: cores, disks: disks, previousCPU: previousCPU[host.id], at: now())
        if let cpu = proc.cpu { previousCPU[host.id] = cpu }
        var state = states[host.id] ?? MonitorHostState(hostID: host.id, status: .ok)
        state.status = .ok
        state.snapshot = snapshot
        if let p = snapshot.cpuPercent { state.cpuHistory.append(p) }
        if let p = snapshot.memoryPercent { state.memoryHistory.append(p) }
        publish(state, generation: gen)
    }

    /// Lý do lỗi: bỏ ký tự điều khiển, cắt 200 ký tự.
    static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String.UnicodeScalarView(scalars).prefix(200))
    }
}
