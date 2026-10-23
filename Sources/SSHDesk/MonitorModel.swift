import Foundation
import Observation
import SSHDeskCore

/// Prompt xác thực đang chờ của một server khi Monitor mở phiên.
struct MonitorPendingPrompt {
    let id = UUID()
    let host: HostProfile
    let kind: PromptKind
    let respond: SessionConnector.Respond
}

/// Trạng thái màn Monitor (ADR-019). Vòng làm mới chỉ chạy khi màn đang hiện; quyết định nằm ở Core.
@MainActor @Observable
final class MonitorModel {
    static let intervals = [5, 10, 30]

    weak var app: AppModel?

    private(set) var folder: String?
    var expanded: Set<String> = []
    var intervalSeconds = 5
    /// Chu kỳ khi dùng nguồn metrics (15/30/60 giây, ADR-028).
    var metricsIntervalSeconds = MetricsMonitorCoordinator.defaultInterval
    /// Mọi nguồn số liệu đã cấu hình (nạp lại mỗi lần màn hiện).
    private(set) var metricSourceList: [MetricsSource] = []
    /// Nguồn của thư mục đang chọn; nil = đo qua SSH (mặc định).
    private(set) var activeSource: MetricsSource?
    private var metricsCoordinator: MetricsMonitorCoordinator?
    private(set) var isRunning = false
    private(set) var states: [UUID: MonitorHostState] = [:]
    var prodConfirm: AnalystProdConfirm?
    private(set) var pendingPrompts: [MonitorPendingPrompt] = []
    private var coordinator: MonitorCoordinator?
    private var token = UUID()

    init(app: AppModel) { self.app = app }

    var hosts: [HostProfile] {
        guard let folder, let app else { return [] }
        return HostPresentation.sortedByName(
            HostPresentation.sshHosts(app.hosts).filter { $0.project == folder }, ascending: true)
    }

    /// Đang đọc từ Prometheus/Zabbix (không mở SSH).
    var usesMetricsSource: Bool { activeSource != nil }

    var intervalChoices: [Int] {
        usesMetricsSource ? MetricsMonitorCoordinator.intervalChoices : Self.intervals
    }

    var currentInterval: Int { usesMetricsSource ? metricsIntervalSeconds : intervalSeconds }

    /// Nạp danh sách nguồn + nguồn gán cho thư mục hiện tại (đọc DB nhỏ, đồng bộ).
    func reloadSources() {
        guard let repo = app?.metricSources?.repository else {
            metricSourceList = []
            activeSource = nil
            return
        }
        metricSourceList = (try? repo.all()) ?? []
        if let folder, let id = try? repo.assignedSourceID(folder: folder) {
            activeSource = metricSourceList.first { $0.id == id }
        } else {
            activeSource = nil
        }
    }

    /// Chọn nguồn cho thư mục (nil = SSH). Dừng vòng hiện tại rồi chạy lại với nguồn mới.
    func setSource(_ id: UUID?) {
        guard let folder, let repo = app?.metricSources?.repository else { return }
        stop()
        do { try repo.assign(folder: folder, sourceID: id) } catch {
            app?.show(error, title: "Không lưu được nguồn số liệu")
        }
        states = [:]
        reloadSources()
        requestStart()
    }

    // MARK: - Chọn thư mục

    func select(_ name: String) {
        app?.sidebar = .monitor
        guard folder != name else { return }
        stop()
        folder = name
        expanded.insert(name)
        states = [:]
        reloadSources()
        requestStart()
    }

    func foldersChanged() {
        guard let f = folder, !(app?.folders.contains(f) ?? false),
            !(app?.hosts.contains { $0.project == f } ?? false)
        else { return }
        stop()
        folder = nil
        states = [:]
        if app?.sidebar == .monitor { enter() }
    }

    /// Màn hiện ra: chọn thư mục đầu tiên nếu chưa có, rồi bắt đầu theo dõi.
    func enter() {
        if folder == nil || !(app?.folders.contains(folder ?? "") ?? false) {
            if let first = app?.folderCounts.first { select(first.name) }
            return
        }
        reloadSources()
        if !isRunning { requestStart() }
    }

    /// Màn ẩn đi: dừng và đóng phiên tự mở.
    func leave() {
        prodConfirm = nil
        stop()
    }

    // MARK: - Điều khiển

    /// PROD thì hỏi xác nhận trước khi chạy lệnh trên server.
    func requestStart() {
        guard !isRunning, !hosts.isEmpty else { return }
        // Nguồn metrics không chạy lệnh nào trên server -> không cần xác nhận PROD (ADR-028).
        if let source = activeSource {
            startMetrics(source: source)
            return
        }
        if hosts.contains(where: { $0.environment == .prod }) {
            let prodNames = hosts.filter { $0.environment == .prod }.map(\.displayName)
            prodConfirm = AnalystProdConfirm(
                message: MonitorProdGuard.message(hosts: hosts, intervalSeconds: intervalSeconds),
                prodNames: prodNames)
            return
        }
        start()
    }

    func confirmProd() {
        prodConfirm = nil
        start()
    }

    private func start() {
        guard let app, !isRunning else { return }
        let hosts = self.hosts
        guard !hosts.isEmpty else { return }
        let myToken = UUID()
        token = myToken
        states = [:]
        isRunning = true
        let vault = app.ephemeralVault
        let connector = SessionConnector(
            configPath: app.paths.sshConfigURL.path, credentials: app.autofillCredentials,
            helper: ControllingTTYHelper.defaultURL(), hostAdjuster: { vault.adjusted($0) })
        let provider = PooledMonitorSessions(pool: app.sessionPool, connector: connector) {
            [weak self] host, kind, respond in
            Task { @MainActor in
                guard self?.token == myToken else { return }
                self?.pendingPrompts.append(
                    MonitorPendingPrompt(host: host, kind: kind, respond: respond))
            }
        }
        let coord = MonitorCoordinator(
            sessions: provider,
            onUpdate: { [weak self] state in
                Task { @MainActor in self?.apply(state, token: myToken) }
            })
        coordinator = coord
        let seconds = TimeInterval(intervalSeconds)
        Task {
            do { try await app.service?.regenerateSSHConfig() } catch {
                app.show(error, title: "Không ghi được SSH config")
                if token == myToken { stop() }
                return
            }
            guard token == myToken, isRunning else { return }
            // ADR-029/019: máy chưa lưu mật khẩu -> hỏi TUẦN TỰ (không bật nhiều sheet); huỷ = bỏ qua máy đó.
            let (runnable, skipped) = await app.preparePasswords(for: hosts, owner: Self.passwordOwner)
            guard token == myToken, isRunning else {
                app.ephemeralVault.releaseAll(owner: Self.passwordOwner)
                return
            }
            for host in skipped {
                states[host.id] = MonitorHostState(
                    hostID: host.id, status: .failed("Bỏ qua — chưa nhập mật khẩu"))
            }
            guard !runnable.isEmpty else {
                stop()
                return
            }
            await coord.start(hosts: runnable, interval: seconds)
        }
    }

    private func startMetrics(source: MetricsSource) {
        guard let app, !isRunning else { return }
        let hosts = self.hosts
        guard !hosts.isEmpty else { return }
        let myToken = UUID()
        token = myToken
        states = [:]
        isRunning = true
        let provider = MetricsClientFactory.make(source: source, credentials: app.credentials)
        let coord = MetricsMonitorCoordinator(
            provider: provider,
            onUpdate: { [weak self] state in
                Task { @MainActor in self?.apply(state, token: myToken) }
            })
        metricsCoordinator = coord
        let seconds = TimeInterval(metricsIntervalSeconds)
        Task { await coord.start(hosts: hosts, interval: seconds) }
    }

    private func apply(_ state: MonitorHostState, token t: UUID) {
        guard t == token else { return }
        states[state.hostID] = state
        if state.status != .connecting {
            pendingPrompts.removeAll { $0.host.id == state.hostID }
        }
    }

    /// Dừng vòng và đóng phiên Monitor tự mở. Trạng thái cuối vẫn hiển thị.
    func stop() {
        guard isRunning || coordinator != nil || metricsCoordinator != nil else { return }
        isRunning = false
        pendingPrompts = []
        token = UUID()
        let metrics = metricsCoordinator
        metricsCoordinator = nil
        Task { await metrics?.stop() }
        let coord = coordinator
        coordinator = nil
        // Mật khẩu không tích lưu bỏ cùng phiên Monitor (ADR-029).
        let vault = app?.ephemeralVault
        Task {
            await coord?.stop()
            vault?.releaseAll(owner: Self.passwordOwner)
        }
    }

    private static let passwordOwner = "monitor"

    /// Chu kỳ mặc định từ Cài đặt (ADR-021); đang chạy thì áp dụng luôn.
    func applyDefaultInterval(_ seconds: Int) { setInterval(seconds) }

    func setInterval(_ seconds: Int) {
        if usesMetricsSource {
            guard MetricsMonitorCoordinator.intervalChoices.contains(seconds) else { return }
            metricsIntervalSeconds = seconds
            let metrics = metricsCoordinator
            if isRunning { Task { await metrics?.setInterval(TimeInterval(seconds)) } }
            return
        }
        guard Self.intervals.contains(seconds) else { return }
        intervalSeconds = seconds
        let coord = coordinator
        if isRunning { Task { await coord?.setInterval(TimeInterval(seconds)) } }
    }

    func retry(_ hostID: UUID) {
        let coord = coordinator
        let metrics = metricsCoordinator
        Task {
            await coord?.retry(hostID: hostID)
            await metrics?.retry(hostID: hostID)
        }
    }

    /// Thoát app: dừng và đóng phiên (chờ xong).
    func shutdown() async {
        isRunning = false
        pendingPrompts = []
        token = UUID()
        let coord = coordinator
        coordinator = nil
        let metrics = metricsCoordinator
        metricsCoordinator = nil
        await metrics?.stop()
        await coord?.stop()
        app?.ephemeralVault.releaseAll(owner: Self.passwordOwner)
    }

    // MARK: - Prompt xác thực

    var activePrompt: ActivePrompt? {
        guard let p = pendingPrompts.first else { return nil }
        return ActivePrompt(
            id: "monitor-" + p.id.uuidString, kind: p.kind,
            context: "\(p.host.displayName) · \(BrowserTabPresentation.identity(p.host)) (Monitor)",
            waiting: pendingPrompts.count - 1, cancelTitle: "Dừng Monitor",
            send: { [weak self] text, secret in self?.answer(p, text: text, secret: secret) },
            cancel: { [weak self] in self?.stop() })
    }

    private func answer(_ p: MonitorPendingPrompt, text: String, secret: Bool) {
        pendingPrompts.removeAll { $0.id == p.id }
        let respond = p.respond
        Task { await respond(text, secret) }
    }
}
