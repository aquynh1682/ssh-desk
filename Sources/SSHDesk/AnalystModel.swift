import AppKit
import Foundation
import Observation
import SSHDeskCore
import UniformTypeIdentifiers

enum AnalystTab: String, CaseIterable {
    case servers, map, results, history
}

enum AnalystSelection: Equatable {
    case node(UUID)
    case flow(Flow)
}

/// Yêu cầu xác nhận trước khi chạy (có server PROD).
struct AnalystProdConfirm: Identifiable {
    let id = UUID()
    let message: String
    let prodNames: [String]
}

/// Prompt xác thực đang chờ của một server khi Analyst mở phiên.
struct AnalystPendingPrompt {
    let id = UUID()
    let host: HostProfile
    let kind: PromptKind
    let respond: SessionConnector.Respond
}

/// Trạng thái màn Project Analyst. Quyết định (nhãn, màu, tóm tắt, bố trí) nằm trong SSHDeskCore.
@MainActor @Observable
final class AnalystModel {
    weak var app: AppModel?

    private(set) var folder: String?
    var tab: AnalystTab = .map
    var mode: AnalystMapMode = .tests
    var selection: AnalystSelection?
    /// Thư mục đang mở rộng ở cây PROJECTS (chỉ nhớ trong phiên).
    var expanded: Set<String> = []

    /// Lần chạy đang hiển thị (mới chạy, mới nhất đã lưu, hoặc lần lịch sử đang xem).
    private(set) var current: StoredAnalystRun?
    /// Đang xem một lần chạy cũ (chỉ đọc).
    private(set) var viewingHistory = false
    private(set) var history: [AnalystRunSummary] = []
    private var latestByFolder: [String: StoredAnalystRun] = [:]

    private(set) var progress: AnalystProgress?
    private(set) var retesting: Flow?
    var prodConfirm: AnalystProdConfirm?
    var pendingDelete: AnalystRunSummary?
    private(set) var pendingPrompt: AnalystPendingPrompt?
    private var runTask: Task<Void, Never>?
    private var coordinator: AnalystCoordinator?

    init(app: AppModel) { self.app = app }

    var isRunning: Bool { runTask != nil }

    // MARK: - Dữ liệu

    var hosts: [HostProfile] {
        guard let folder, let app else { return [] }
        return HostPresentation.sortedByName(
            app.hosts.filter { $0.project == folder }, ascending: true)
    }

    func host(_ id: UUID) -> HostProfile? { app?.hosts.first { $0.id == id } }

    /// Máy có tab Truyền file đang kết nối: Analyst dùng ngay, không cần xác thực lại.
    func isLive(_ id: UUID) -> Bool {
        app?.browser?.tabs.contains { $0.hostID == id && $0.state == .connected } ?? false
    }

    var readyCount: Int { hosts.filter { isLive($0.id) }.count }

    var emptyState: AnalystEmptyState {
        AnalystPresentation.emptyState(hostCount: hosts.count, run: current)
    }

    // MARK: - Chọn thư mục

    func select(_ name: String) {
        app?.sidebar = .analyst
        guard folder != name else { return }
        guard !isRunning else {
            app?.showToast("Đang chạy kiểm tra — hãy đợi hoặc huỷ trước khi đổi thư mục")
            return
        }
        folder = name
        expanded.insert(name)
        selection = nil
        viewingHistory = false
        current = latestByFolder[name]
        history = []
        Task { await refreshHistory(loadLatestIfNeeded: true) }
    }

    /// Thư mục bị xoá/đổi tên: bỏ chọn (khi không đang chạy).
    func foldersChanged() {
        guard let f = folder, !isRunning, !(app?.folders.contains(f) ?? false),
            !(app?.hosts.contains { $0.project == f } ?? false)
        else { return }
        folder = nil
        current = nil
        history = []
        selection = nil
        viewingHistory = false
        if app?.sidebar == .analyst { enter() }
    }

    /// Mở màn: nếu chưa chọn thư mục thì lấy thư mục đầu tiên có máy chủ.
    func enter() {
        guard folder == nil || !(app?.folders.contains(folder ?? "") ?? false) else { return }
        if let first = app?.folderCounts.first { select(first.name) }
    }

    func refreshHistory(loadLatestIfNeeded: Bool = false) async {
        guard let folder, let repo = app?.analystRepository else { return }
        do {
            let list = try await repo.list(folder: folder)
            guard self.folder == folder else { return }
            history = list
            if loadLatestIfNeeded, current == nil, let first = list.first,
                let run = try await repo.load(id: first.id), self.folder == folder
            {
                current = run
                latestByFolder[folder] = run
            }
        } catch { app?.show(error, title: "Không đọc được lịch sử Project Analyst") }
    }

    // MARK: - Chạy

    /// Bấm "Chạy kiểm tra": PROD thì hỏi xác nhận trước.
    func requestRun() {
        guard !isRunning, let app, !hosts.isEmpty else { return }
        let servers = hosts.map {
            ProdGuardServer(
                hostID: $0.id, displayName: $0.displayName, environment: $0.environment,
                commands: AnalystCoordinator.collectionCommands)
        }
        let prompt = ProdGuard.prompt(for: servers)
        guard prompt.requiresConfirmation else {
            startRun()
            return
        }
        let probe =
            "\nSau đó, với mỗi kết nối phát hiện, trên server NGUỒN chạy:\n"
            + "  timeout 3 bash -c '</dev/tcp/<IP đích>/<cổng>'\n"
            + "  (dự phòng nếu thiếu bash/timeout) nc -z -w3 <IP đích> <cổng>"
        prodConfirm = AnalystProdConfirm(
            message: prompt.message + "\n" + probe, prodNames: prompt.prodNames)
        _ = app
    }

    func confirmProd() {
        prodConfirm = nil
        startRun()
    }

    private func startRun() {
        guard let app, let folder, !isRunning else { return }
        let hosts = self.hosts
        guard !hosts.isEmpty else { return }
        viewingHistory = false
        selection = nil
        progress = nil
        let provider = makeProvider(app: app)
        let coord = AnalystCoordinator(sessions: provider, repository: app.analystRepository)
        coordinator = coord
        let sink: @Sendable (AnalystProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.progress = p }
        }
        runTask = Task { [weak self] in
            defer {
                self?.runTask = nil
                self?.progress = nil
                self?.pendingPrompt = nil
                self?.coordinator = nil
            }
            do {
                try await app.service?.regenerateSSHConfig()
                let run = try await coord.run(folder: folder, hosts: hosts, progress: sink)
                guard let self else { return }
                self.latestByFolder[folder] = run
                if self.folder == folder {
                    self.current = run
                    self.tab = run.topology.flows.isEmpty ? self.tab : .map
                    await self.refreshHistory()
                }
                app.showToast(
                    "Xong: " + AnalystPresentation.summary(run.results)
                        + (run.warnings.isEmpty ? "" : " · \(run.warnings.count) cảnh báo"))
            } catch is CancellationError {
                app.showToast("Đã huỷ kiểm tra")
            } catch {
                app.show(error, title: "Không chạy được Project Analyst")
            }
        }
    }

    func cancelRun() {
        runTask?.cancel()
        pendingPrompt = nil
    }

    /// Thoát app: huỷ lần chạy và đóng phiên Analyst tự mở.
    func shutdown() async {
        runTask?.cancel()
        await coordinator?.finish()
    }

    private func makeProvider(app: AppModel) -> PooledAnalystSessions {
        let connector = SessionConnector(
            configPath: app.paths.sshConfigURL.path, credentials: app.credentials,
            helper: ControllingTTYHelper.defaultURL())
        return PooledAnalystSessions(pool: app.sessionPool, connector: connector) {
            [weak self] host, kind, respond in
            Task { @MainActor in
                self?.pendingPrompt = AnalystPendingPrompt(host: host, kind: kind, respond: respond)
            }
        }
    }

    // MARK: - Prompt xác thực

    var activePrompt: ActivePrompt? {
        guard let p = pendingPrompt else { return nil }
        return ActivePrompt(
            id: "analyst-" + p.id.uuidString, kind: p.kind,
            context: "\(p.host.displayName) · \(BrowserTabPresentation.identity(p.host)) (Project Analyst)",
            waiting: 0, cancelTitle: "Huỷ kiểm tra",
            send: { [weak self] text, secret in self?.answer(p, text: text, secret: secret) },
            cancel: { [weak self] in self?.cancelRun() })
    }

    private func answer(_ p: AnalystPendingPrompt, text: String, secret: Bool) {
        if pendingPrompt?.id == p.id { pendingPrompt = nil }
        let respond = p.respond
        Task { await respond(text, secret) }
    }

    // MARK: - Thử lại một cạnh

    func retest(_ flow: Flow) {
        guard let app, !isRunning, !viewingHistory, let run = current,
            let tf = run.topology.flows.first(where: { $0.flow == flow }),
            let source = host(flow.source), let dest = host(flow.destination)
        else { return }
        let provider = makeProvider(app: app)
        let coord = AnalystCoordinator(sessions: provider, repository: nil)
        coordinator = coord
        retesting = flow
        runTask = Task { [weak self] in
            defer {
                self?.runTask = nil
                self?.retesting = nil
                self?.pendingPrompt = nil
                self?.coordinator = nil
            }
            do {
                try await app.service?.regenerateSSHConfig()
                let result = try await coord.retest(flow: tf, source: source, destination: dest)
                guard let self, var updated = self.current, updated.id == run.id else { return }
                if let i = updated.results.firstIndex(where: { $0.flow == flow }) {
                    updated.results[i] = result
                } else {
                    updated.results.append(result)
                }
                self.current = updated
                self.latestByFolder[updated.folderName] = updated
                // Cập nhật bản đã lưu (cùng id) để lịch sử khớp với kết quả đang xem.
                if let repo = app.analystRepository {
                    try? await repo.delete(id: updated.id)
                    try? await repo.save(updated)
                    await self.refreshHistory()
                }
            } catch is CancellationError {
            } catch { app.show(error, title: "Không thử lại được kết nối") }
        }
    }

    func openWarp(_ id: UUID) {
        guard let h = host(id) else { return }
        Task { await app?.openInWarp(h) }
    }

    // MARK: - Lịch sử

    func view(_ summary: AnalystRunSummary) {
        guard !isRunning, let repo = app?.analystRepository else { return }
        Task {
            do {
                guard let run = try await repo.load(id: summary.id) else {
                    await refreshHistory()
                    return
                }
                current = run
                viewingHistory = (history.first?.id != run.id)
                selection = nil
                tab = .map
            } catch { app?.show(error, title: "Không đọc được lần chạy") }
        }
    }

    func backToLatest() {
        viewingHistory = false
        selection = nil
        if let folder, let first = history.first, let repo = app?.analystRepository {
            Task {
                if let run = try? await repo.load(id: first.id) {
                    current = run
                    latestByFolder[folder] = run
                }
            }
        }
    }

    func confirmDelete() {
        guard let s = pendingDelete, let repo = app?.analystRepository else { return }
        pendingDelete = nil
        Task {
            do {
                try await repo.delete(id: s.id)
                if current?.id == s.id {
                    current = nil
                    viewingHistory = false
                    if let folder { latestByFolder[folder] = nil }
                    selection = nil
                }
                await refreshHistory(loadLatestIfNeeded: true)
            } catch { app?.show(error, title: "Không xoá được lần chạy") }
        }
    }

    // MARK: - Thêm máy chủ vào thư mục

    func add(_ hostIDs: [UUID]) {
        guard let folder, !hostIDs.isEmpty else { return }
        Task { await app?.moveHosts(hostIDs, toFolder: folder) }
    }

    // MARK: - Xuất báo cáo

    func export(_ format: AnalystPresentation.ExportFormat) {
        guard let run = current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AnalystPresentation.exportFileName(
            folder: run.folderName, date: run.startedAt, format: format)
        panel.allowedContentTypes =
            format == .markdown
            ? [UTType(filenameExtension: "md") ?? .plainText] : [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text =
            format == .markdown ? AnalystReport.markdown(run.run) : AnalystReport.csv(run.run)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            app?.showToast("Đã xuất báo cáo")
        } catch { app?.show(error, title: "Không ghi được báo cáo") }
    }
}
