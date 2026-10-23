import AppKit
import Foundation
import Observation
import SSHDeskCore

enum SidebarItem: Hashable {
    case all
    case favorites
    case recent
    case environment(HostEnvironment)
    case folder(String)
    case uncategorized
    case transfers
    case analyst
    case monitor
    case keys
    case settings

    var isHostSection: Bool {
        switch self {
        case .transfers, .analyst, .monitor, .keys, .settings: return false
        default: return true
        }
    }
}

enum FormTarget: Identifiable {
    case new
    case edit(HostProfile)
    /// Nhân bản: `source` là host gốc, `copy` là bản nháp đã điền sẵn (chưa lưu).
    case duplicate(source: HostProfile, copy: HostProfile)
    var id: String {
        switch self {
        case .new: return "new"
        case .duplicate(_, let copy): return "dup-" + copy.id.uuidString
        case .edit(let h): return h.id.uuidString
        }
    }
}

/// Hộp thoại thao tác thư mục (hiện ở thanh bên).
enum FolderDialog: Identifiable {
    case create
    case rename(String)
    case confirmDelete(String)
    /// Đổi tên trùng thư mục khác: hỏi gộp hay huỷ.
    case confirmMerge(from: String, to: String)

    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let n): return "rename:\(n)"
        case .confirmDelete(let n): return "delete:\(n)"
        case .confirmMerge(let f, let t): return "merge:\(f)>\(t)"
        }
    }
}

struct DatabaseFailure {
    let path: String
    let folder: URL
    let message: String
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Banner không chặn: dùng cho Warp không khả dụng (kèm nút Copy lệnh SSH).
struct Banner: Equatable {
    let text: String
    let copyHostID: UUID?
    /// Hiện nút mở trang tải Windows App trên App Store.
    var showsAppStoreLink = false
}

@MainActor @Observable
final class AppModel {
    enum Phase {
        case loading
        case ready
        case failed(DatabaseFailure)
    }

    var phase: Phase = .loading
    var hosts: [HostProfile] = []
    /// Mọi thư mục (kể cả rỗng), đã sắp theo tên.
    var folders: [String] = []
    /// Bộ đăng nhập dùng chung (ADR-030) + số host đang dùng mỗi bộ.
    private(set) var credentialSets: [CredentialSet] = []
    private(set) var credentialSetUsage: [UUID: Int] = [:]
    var folderDialog: FolderDialog?
    /// Sheet "Gán bộ đăng nhập…" cho cả thư mục (ADR-030).
    var assignSetTarget: AssignSetTarget?
    /// Nhóm đang thu gọn trong bảng "Tất cả máy chủ" (khoá = tên thư mục, "" = Chưa phân loại). Chỉ nhớ trong phiên.
    var collapsedGroups: Set<String> = []
    var selection: UUID?
    /// Lọc danh sách tới đúng các máy này (nút "Xem" sau khi tự thêm từ nguồn, ADR-026b). nil = không lọc.
    var focusHostIDs: Set<UUID>?
    var sidebar: SidebarItem = .all
    var searchText = ""
    /// Bộ lọc môi trường của Menu ở cột giữa (độc lập với mục "MÔI TRƯỜNG" ở sidebar).
    var environmentFilter: HostEnvironment?
    var sortAscending = true
    /// Tăng mỗi lần người dùng bấm ⌘K / ⌘F; MainView theo dõi để focus ô tìm.
    var searchFocusTick = 0
    var alert: AppAlert?
    var toast: String?
    var banner: Banner?
    var form: FormTarget?
    var showImport = false
    var pendingDelete: HostProfile?
    var transferSheet: TransferSheetTarget?
    /// Mọi job đã biết (đang chạy + lịch sử). Cập nhật từ `TransferManager.events` trên MainActor.
    var jobs: [TransferJob] = []
    var prompts = AuthPromptQueue()
    /// Mọi local port forward đã lưu (ADR-011).
    private(set) var forwards: [PortForward] = []
    var forwardForm: ForwardFormTarget?
    /// File xuất/nhập đã đọc, đang xem trước (ADR-020).
    var exchangePreview: ExchangePreview?

    let paths: AppPaths
    private(set) var service: ConnectionService?
    /// Repository host/bộ đăng nhập (cùng DB với `service`).
    private(set) var hostRepository: HostRepository?
    private(set) var transfers: TransferManager?
    /// Màn "Truyền file": khung local, tab remote, kéo thả. Tạo khi dữ liệu đã sẵn sàng.
    private(set) var browser: FileBrowserModel?
    /// Keychain thật; ACL tin cậy cả helper `sshdesk-askpass` (nếu tìm thấy trong bundle).
    let credentials: any CredentialStore
    private let sealedStore: SecureEnclaveCredentialStore
    /// Kho bí mật dành cho MỌI chỗ tự điền (PTY, tunnel, phiên SFTP, cài key): trả nil khi cài đặt tắt tự điền.
    let autofillCredentials: any CredentialStore
    /// Mật khẩu chỉ trong bộ nhớ cho phiên/job không tích "Lưu" (ADR-029); bỏ khi phiên đóng.
    let ephemeralVault = EphemeralPasswordVault()
    /// Hàng đợi sheet "Nhập mật khẩu" (mỗi lúc một sheet, ADR-019/029).
    let passwordPrompts = PasswordPromptCenter()
    /// Luồng "kiểm tra đăng nhập rồi lưu" (ADR-029); có sau khi dữ liệu nạp xong.
    private(set) var passwordEntry: PasswordEntryService?
    /// Bản cài đặt dùng chung với các service Core (ADR-021).
    let settingsStore = SettingsStore()
    /// Cài đặt hiện hành cho UI (đổi qua `updateSettings`).
    private(set) var settings = AppSettings.default
    private var settingsRepository: SettingsRepository?
    /// Clipboard giữ mật khẩu Windows tạm thời (ADR-018); xoá khi thoát app.
    let secretClipboard = SecretClipboard()
    /// Màn "SSH Keys": liệt kê, tạo, cài key (ADR-014).
    @ObservationIgnored lazy var keys = KeysModel(app: self)
    /// Sổ phiên SSH đang sống, dùng chung giữa màn Truyền file và Project Analyst (một master/host).
    let sessionPool = SessionPool()
    /// Màn "Project Analyst" (ADR-016).
    @ObservationIgnored lazy var analyst = AnalystModel(app: self)
    /// Nguồn máy chủ đồng bộ một chiều: Excel/CSV, JSON, Ansible (ADR-026).
    @ObservationIgnored lazy var inventory = InventoryModel(app: self)
    /// Màn "Monitor" tài nguyên server (ADR-019).
    @ObservationIgnored lazy var monitor = MonitorModel(app: self)
    private(set) var analystRepository: AnalystRunRepository?
    /// Nguồn số liệu Prometheus/Zabbix (ADR-028).
    private(set) var metricSources: MetricSourceService?
    private(set) var forwardRepository: PortForwardRepository?
    /// Các tunnel `ssh -N -L` (ADR-011).
    @ObservationIgnored lazy var tunnels = TunnelsModel(app: self)
    private var transferRepository: TransferRepository?
    private var eventsTask: Task<Void, Never>?
    /// URL `sshdesk://` đến trước khi dữ liệu nạp xong (hoặc đang xử lý URL khác) — xếp hàng (ADR-025).
    var pendingURLs: [URL] = []
    var isHandlingURLs = false
    private var toastTask: Task<Void, Never>?

    /// Dùng chung cho `AppDelegate` (hỏi khi thoát).
    static let shared = AppModel()

    init(paths: AppPaths = .default) {
        self.paths = paths
        let store = SecureEnclaveCredentialStore(
            trustedApplicationPaths: AskpassHelper.defaultURL().map { [$0.path] } ?? [])
        credentials = store
        sealedStore = store
        let settingsStore = self.settingsStore
        autofillCredentials = AutofillGatedCredentialStore(
            base: EphemeralOverlayCredentialStore(base: store, vault: ephemeralVault)
        ) {
            settingsStore.current.autofillEnabled
        }
    }

    // MARK: - Khởi động

    func start() async {
        guard case .loading = phase else { return }
        do {
            try paths.prepareDirectories()
            // Database(url:) từ chối file hỏng/schema mới hơn và không ghi đè.
            let db = try Database(url: paths.databaseURL)
            let repo = HostRepository(database: db)
            let settingsRepo = SettingsRepository(database: db)
            settingsRepository = settingsRepo
            let loaded = settingsRepo.load()
            settingsStore.update(loaded)
            settings = loaded
            // Migration một lần Keychain plaintext -> Secure Enclave (ADR-004c), xong trước khi hiện danh sách.
            let metricRepo = MetricSourceRepository(database: db)
            await CredentialMigration.runIfNeeded(
                store: sealedStore, repository: repo, settings: settingsRepo, metricSources: metricRepo)
            let metricService = MetricSourceService(repository: metricRepo, credentials: credentials)
            metricSources = metricService
            let service = ConnectionService(
                repository: repo, appConfigURL: paths.sshConfigURL,
                userConfigPath: nil, launcher: WarpLauncher(),
                credentials: credentials, secretClipboard: secretClipboard,
                askpassHelper: AskpassHelper.defaultURL(), settings: settingsStore,
                metricSources: metricService)
            self.service = service
            hostRepository = repo
            passwordEntry = PasswordEntryService(
                connection: service,
                verifier: PasswordVerifier(
                    configPath: paths.sshConfigURL.path, helper: ControllingTTYHelper.defaultURL()),
                credentials: credentials)
            analystRepository = AnalystRunRepository(
                database: db, retention: loaded.analystRetention)
            monitor.applyDefaultInterval(loaded.monitorIntervalSeconds)
            let forwardRepo = PortForwardRepository(database: db)
            forwardRepository = forwardRepo
            try await service.regenerateSSHConfig()
            hosts = try await repo.all()
            folders = try await repo.folders()
            credentialSets = try await repo.credentialSets()
            credentialSetUsage = try await repo.credentialSetUsage()
            forwards = try await forwardRepo.all()
            try await startTransfers(database: db, hosts: repo)
            browser = FileBrowserModel(app: self, credentials: autofillCredentials)
            phase = .ready
            drainPendingURLs()
            // Phát hiện file nguồn đổi (mtime + SHA-256); chỉ báo, không tự áp dụng.
            Task { await inventory.checkChanges() }
        } catch {
            phase = .failed(
                DatabaseFailure(
                    path: paths.databaseURL.path, folder: paths.baseDirectory,
                    message: Self.message(for: error)))
        }
    }

    private func startTransfers(database: Database, hosts repo: HostRepository) async throws {
        let repository = TransferRepository(
            database: database, retention: settings.transferHistoryLimit)
        let manager = TransferManager(
            repository: repository, hosts: repo, concurrency: settings.transferConcurrency,
            controllingTTYHelper: ControllingTTYHelper.defaultURL(),
            credentials: autofillCredentials,
            hostAdjuster: { [vault = ephemeralVault] host in vault.adjusted(host) })
        transferRepository = repository
        transfers = manager
        // Job dở dang của lần chạy trước → "Bị gián đoạn" (hiện trong lịch sử).
        _ = try await manager.recoverInterrupted()
        jobs = try await repository.history(limit: nil)
        eventsTask = Task { [weak self] in
            for await event in manager.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: TransferEvent) {
        switch event {
        case .jobUpdated(let job), .jobFinished(let job):
            if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[i] = job
            } else {
                jobs.insert(job, at: 0)
            }
            prompts.reconcile(job)
            if case .jobFinished = event {
                ephemeralVault.release(hostID: job.hostID, owner: "job-" + job.id.uuidString)
                browser?.jobFinished(job)
            }
        case .authPrompt(let id, let kind):
            prompts.enqueue(jobID: id, kind: kind)
        }
    }

    var hasActiveTransfers: Bool { jobs.contains { !$0.state.isTerminal } }

    func revealDataFolder() {
        NSWorkspace.shared.open(paths.baseDirectory)
    }

    // MARK: - Dữ liệu hiển thị

    var folderCounts: [HostFolders.FolderCount] {
        HostFolders.counts(hosts, emptyFolders: folders)
    }

    var uncategorizedCount: Int { HostFolders.uncategorizedCount(hosts) }

    /// Có chia nhóm theo thư mục trong bảng không (chỉ ở "Tất cả máy chủ", không lọc/tìm).
    var isGroupedTable: Bool {
        sidebar == .all && environmentFilter == nil
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var tableGroups: [HostGroup] {
        HostFolders.group(visibleHosts, emptyFolders: folders)
    }

    /// Host điều hướng được bằng ↑/↓ (bỏ qua host trong nhóm đang thu gọn).
    var navigableHosts: [HostProfile] {
        guard isGroupedTable else { return visibleHosts }
        return tableGroups.filter { !collapsedGroups.contains($0.name) }.flatMap(\.hosts)
    }

    func toggleGroup(_ name: String) {
        if collapsedGroups.contains(name) { collapsedGroups.remove(name) } else { collapsedGroups.insert(name) }
    }

    /// Dùng đúng cách viết của thư mục đã có nếu trùng tên (không phân biệt hoa thường/dấu).
    func canonicalFolder(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return folders.first { HostFolders.sameFolder($0, t) } ?? t
    }

    /// Môi trường đang lọc: ưu tiên mục sidebar, nếu không thì Menu lọc.
    var effectiveEnvironment: HostEnvironment? {
        if case .environment(let e) = sidebar { return e }
        return environmentFilter
    }

    var visibleHosts: [HostProfile] {
        var list = hosts
        if let ids = focusHostIDs { list = list.filter { ids.contains($0.id) } }
        var byRecency = false
        switch sidebar {
        case .all, .environment: break
        case .favorites: list = list.filter(\.isFavorite)
        case .recent:
            list = HostPresentation.recent(list)
            byRecency = true
        case .folder(let p): list = list.filter { $0.project == p }
        case .uncategorized: list = list.filter { $0.project.isEmpty }
        case .transfers, .analyst, .monitor, .keys, .settings: break
        }
        list = HostPresentation.filter(list, environment: effectiveEnvironment)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            func hit(_ s: String) -> Bool { s.range(of: q, options: opts) != nil }
            list = list.filter {
                hit($0.displayName) || hit($0.hostName) || hit($0.user) || hit($0.project)
                    || hit($0.rdpUsername) || hit($0.sshConfigAlias ?? "") || $0.tags.contains(where: hit)
            }
        }
        return byRecency ? list : HostPresentation.sortedByName(list, ascending: sortAscending)
    }

    var columnTitle: String {
        switch sidebar {
        case .all, .environment, .transfers, .analyst, .monitor, .keys, .settings: return "Máy chủ"
        case .favorites: return "Yêu thích"
        case .recent: return "Gần đây"
        case .folder(let p): return p
        case .uncategorized: return HostFolders.uncategorizedTitle
        }
    }

    /// Chọn môi trường ở Menu lọc. Đang ở mục môi trường của sidebar thì quay về "Tất cả".
    func setEnvironmentFilter(_ env: HostEnvironment?) {
        if case .environment = sidebar { sidebar = .all }
        environmentFilter = env
    }

    var selectedHost: HostProfile? {
        guard let selection else { return nil }
        return hosts.first { $0.id == selection }
    }

    func name(of id: UUID?) -> String? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }?.displayName
    }

    // MARK: - Thao tác

    func reload() async {
        guard let service else { return }
        do {
            hosts = try await service.repository.all()
            folders = try await service.repository.folders()
            credentialSets = try await service.repository.credentialSets()
            credentialSetUsage = try await service.repository.credentialSetUsage()
            await inventory.refreshData()
            forwards = try await forwardRepository?.all() ?? []
            if case .folder(let f) = sidebar, !folders.contains(f) { sidebar = .all }
            browser?.hostsChanged(hosts)
            analyst.foldersChanged()
            monitor.foldersChanged()
            if let s = selection, !hosts.contains(where: { $0.id == s }) { selection = nil }
        } catch { show(error, title: "Không đọc được dữ liệu") }
    }

    /// Trả true nếu lưu thành công (form đóng).
    /// `password`: nếu có thì ghi vào Keychain sau khi lưu hồ sơ (chuỗi này không được giữ lại ở đâu cả).
    func save(
        _ host: HostProfile, isNew: Bool, password: String? = nil, copyPasswordFrom: UUID? = nil
    ) async -> Bool {
        guard let service else { return false }
        do {
            if isNew { try await service.add(host) } else { try await service.update(host) }
            if password == nil, let copyPasswordFrom {
                do { try await service.copyPassword(from: copyPasswordFrom, to: host.id) } catch {
                    show(error, title: "Đã lưu hồ sơ nhưng không sao chép được mật khẩu")
                }
            }
            if let password, !password.isEmpty {
                do { try await service.savePassword(hostID: host.id, password: password) } catch {
                    show(error, title: "Đã lưu hồ sơ nhưng không lưu được mật khẩu vào Keychain")
                }
            }
            await reload()
            selection = host.id
            return true
        } catch {
            show(error, title: "Không lưu được hồ sơ")
            return false
        }
    }

    /// Xoá mật khẩu đã lưu của host; trả hồ sơ đã cập nhật.
    func clearPassword(hostID: UUID) async -> HostProfile? {
        guard let service else { return nil }
        do {
            let updated = try await service.clearPassword(hostID: hostID)
            await reload()
            showToast("Đã xoá mật khẩu đã lưu")
            return updated
        } catch {
            show(error, title: "Không xoá được mật khẩu")
            return nil
        }
    }

    /// Mở form nhân bản (chưa tạo gì; Keychain chỉ được chạm khi bấm Lưu).
    func beginDuplicate(_ host: HostProfile) {
        let copy = host.duplicated(existingNames: hosts.map(\.displayName))
        form = .duplicate(source: host, copy: copy)
    }

    /// Có password hiệu lực đã lưu không (riêng hoặc từ bộ đăng nhập). Chỉ để hiển thị.
    func hasStoredPassword(_ host: HostProfile) -> Bool {
        guard let ref = host.effectiveCredentialReference else { return false }
        return credentials.exists(ref: ref)
    }

    /// Mật khẩu hiệu lực đã lưu nhưng không giải mã được (khoá SE mất/đổi máy) → cần nhập lại (ADR-004c).
    func needsReauth(_ host: HostProfile) -> Bool {
        guard let ref = host.effectiveCredentialReference else { return false }
        return credentials.status(ref: ref) == .undecryptable
    }

    /// Bộ đăng nhập có password/passphrase không giải mã được.
    func setNeedsReauth(_ id: UUID) -> Bool {
        [CredentialSet.passwordReference(for: id), CredentialSet.passphraseReference(for: id)]
            .contains { credentials.status(ref: $0) == .undecryptable }
    }

    /// Host có mật khẩu RIÊNG trong Keychain (form dùng để xoá/giữ mật khẩu riêng).
    func hasOwnPassword(_ host: HostProfile) -> Bool {
        guard let ref = host.credentialReference, !ref.isEmpty else { return false }
        return credentials.exists(ref: ref)
    }

    /// Nguồn thông tin đăng nhập hiệu lực của UI/service Core (bộ đăng nhập, ADR-030).
    var credentialResolver: CredentialResolver? {
        let store = settingsStore
        return hostRepository?.credentialResolver { store.current.defaultIdentityAgent }
    }

    func credentialSet(id: UUID?) -> CredentialSet? {
        guard let id else { return nil }
        return credentialSets.first { $0.id == id }
    }

    func setHasPassword(_ id: UUID) -> Bool { credentials.exists(ref: CredentialSet.passwordReference(for: id)) }
    func setHasPassphrase(_ id: UUID) -> Bool { credentials.exists(ref: CredentialSet.passphraseReference(for: id)) }

    func toggleFavorite(_ host: HostProfile) async {
        guard let service else { return }
        do {
            try await service.repository.setFavorite(id: host.id, !host.isFavorite)
            await reload()
        } catch { show(error, title: "Không đổi được yêu thích") }
    }

    func confirmDelete() async {
        guard let host = pendingDelete, let service else { return }
        pendingDelete = nil
        do {
            await tunnels.stopTunnels(hostID: host.id)
            try await service.delete(id: host.id)
            if selection == host.id { selection = nil }
            await reload()
        } catch HostRepositoryError.referencedAsJumpHost(let ids) {
            let names = ids.compactMap { name(of: $0) }.joined(separator: ", ")
            alert = AppAlert(
                title: "Không xoá được “\(host.displayName)”",
                message: "Máy này đang là bastion của: \(names). Hãy đổi bastion của các máy đó trước.")
            await reload()
        } catch {
            show(error, title: "Không xoá được hồ sơ")
            await reload()
        }
    }

    // MARK: - Thư mục

    func createFolder(_ rawName: String) async -> Bool {
        guard let service else { return false }
        do {
            let name = try await service.repository.createFolder(rawName)
            await reload()
            sidebar = .folder(name)
            return true
        } catch {
            show(error, title: "Không tạo được thư mục")
            return false
        }
    }

    /// Trả true nếu xong (hoặc đã chuyển sang hỏi gộp); false nếu lỗi.
    func renameFolder(_ old: String, to rawName: String, merge: Bool = false) async -> Bool {
        guard let service else { return false }
        do {
            let name = try await service.repository.renameFolder(from: old, to: rawName, merge: merge)
            if sidebar == .folder(old) { sidebar = .folder(name) }
            await reload()
            return true
        } catch HostRepositoryError.folderNameExists(let existing) {
            folderDialog = .confirmMerge(from: old, to: existing)
            return true
        } catch {
            show(error, title: "Không đổi được tên thư mục")
            return false
        }
    }

    func deleteFolder(_ name: String) async {
        guard let service else { return }
        do {
            let n = try await service.repository.deleteFolder(name)
            if sidebar == .folder(name) { sidebar = .all }
            await reload()
            showToast(n > 0 ? "Đã xoá thư mục; \(n) máy chủ về “Chưa phân loại”" : "Đã xoá thư mục")
        } catch { show(error, title: "Không xoá được thư mục") }
    }

    /// `folder == nil`: bỏ thư mục (Chưa phân loại).
    func moveHosts(_ ids: [UUID], toFolder folder: String?) async {
        guard let service, !ids.isEmpty else { return }
        do {
            try await service.repository.moveHosts(ids: ids, toFolder: folder)
            await reload()
            showToast(folder.map { "Đã chuyển vào “\($0)”" } ?? "Đã chuyển về “Chưa phân loại”")
        } catch { show(error, title: "Không chuyển được máy chủ") }
    }

    func openInWarp(_ original: HostProfile, newWindow: Bool = false) async {
        guard let service else { return }
        // ADR-029: máy chưa lưu mật khẩu -> sheet hỏi (sau xác nhận PROD của đường URL/CLI, vì xác nhận nằm ở người gọi).
        let answer = await requestMissingPassword(for: original, purpose: .warp, owner: nil)
        if case .cancelled = answer { return }
        let host = hosts.first(where: { $0.id == original.id }) ?? original
        banner = nil
        let report = await service.openInWarpReport(host, newWindow: newWindow)
        switch report.result {
        case .requested:
            showToast(
                report.notice
                    ?? (hasStoredPassword(host)
                        ? "Đã yêu cầu Warp mở phiên — đăng nhập bằng mật khẩu đã lưu"
                        : "Đã yêu cầu Warp mở phiên — đăng nhập diễn ra trong Warp"))
            await reload()
        case .warpUnavailable:
            banner = Banner(
                text: "Không tìm thấy Warp trên máy này. Bạn có thể copy lệnh SSH và chạy trong terminal khác.",
                copyHostID: host.id)
        case .failed(let reason):
            alert = AppAlert(title: "Không mở được Warp", message: reason)
        }
    }

    /// Mở máy theo loại: Windows -> Windows App, còn lại -> Warp.
    func open(_ host: HostProfile) async {
        if host.kind == .windowsRDP { await openInWindowsApp(host) } else { await openInWarp(host) }
    }

    func openInWindowsApp(_ original: HostProfile) async {
        guard let service else { return }
        let answer = await requestMissingPassword(for: original, purpose: .windows, owner: nil)
        if case .cancelled = answer { return }
        let host = hosts.first(where: { $0.id == original.id }) ?? original
        banner = nil
        let report = await service.openInWindowsAppReport(host)
        switch report.result {
        case .requested:
            // Không tích lưu (ADR-029/018): copy MỘT lần, tự xoá; password không được lưu ở đâu.
            if case .windowsCopy(let password) = answer {
                secretClipboard.copy(password, clearAfter: TimeInterval(settings.clipboardClearSeconds))
                showToast(passwordCopiedToast)
                await reload()
                return
            }
            switch report.passwordCopy {
            case .none: showToast("Đã yêu cầu Windows App mở kết nối — nhập mật khẩu trong Windows App")
            case .copied: showToast(passwordCopiedToast)
            case .disabled:
                showToast("Đã mở Windows App — đang tắt tự điền mật khẩu (Cài đặt), nhập mật khẩu trong Windows App")
            case .held:
                showToast(
                    "Đã mở Windows App — đang tạm tắt tự điền cho máy này (chờ bạn xác nhận), nhập mật khẩu trong Windows App"
                )
            case .failed(let why): showToast("Đã mở Windows App nhưng không copy được mật khẩu: \(why)")
            }
            await reload()
        case .appUnavailable:
            banner = Banner(text: "Chưa cài Windows App.", copyHostID: nil, showsAppStoreLink: true)
        case .failed(let reason):
            alert = AppAlert(title: "Không mở được Windows App", message: reason)
        }
    }

    var passwordCopiedToast: String {
        "Đã copy mật khẩu — dán (⌘V) vào Windows App. Tự xoá sau \(settings.clipboardClearSeconds) giây."
    }

    /// Menu "Copy mật khẩu" của máy Windows có mật khẩu lưu.
    func copyWindowsPassword(_ host: HostProfile) async {
        guard let service else { return }
        switch await service.copyStoredWindowsPassword(host) {
        case .none: showToast("Máy này chưa lưu mật khẩu")
        case .copied: showToast("Đã copy mật khẩu. Tự xoá sau \(settings.clipboardClearSeconds) giây.")
        case .disabled: showToast("Đang tắt tự điền mật khẩu đã lưu (Cài đặt) nên không copy.")
        case .held: showToast("Máy này đang tạm tắt tự điền — mở chi tiết máy và bấm “Xác nhận” trước.")
        case .failed(let why): showToast("Không copy được mật khẩu: \(why)")
        }
    }

    func openWindowsAppStore() {
        NSWorkspace.shared.open(SystemWindowsAppHandler.appStoreURL)
    }

    /// Ghi file .rdp rồi hiện trong Finder.
    func revealRDPFile(_ host: HostProfile) async {
        guard let service else { return }
        do {
            let url = try await service.prepareRDPFile(for: host)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { show(error, title: "Không tạo được file .rdp") }
    }

    /// Copy một giá trị hiển thị (địa chỉ, port...). Chỉ dùng cho dữ liệu không bí mật.
    func copyValue(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast("Đã copy \(label)")
    }

    func copySSHCommand(_ host: HostProfile) async {
        guard let service else { return }
        do {
            let cmd = try await service.copyableSSHCommand(for: host)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            showToast("Đã copy lệnh SSH (không chứa mật khẩu)")
        } catch { show(error, title: "Không tạo được lệnh SSH") }
    }

    func importSelected(_ candidates: [ImportCandidate], sourcePath: String) async -> Bool {
        guard let service else { return false }
        do {
            let outcome = try await service.importAliases(candidates, sourcePath: sourcePath)
            await reload()
            var text = "Đã import \(outcome.imported.count) máy chủ"
            if !outcome.skippedAliases.isEmpty {
                text += "; bỏ qua \(outcome.skippedAliases.count) alias đã import"
            }
            showToast(text)
            return true
        } catch {
            show(error, title: "Không import được")
            await reload()
            return false
        }
    }

    // MARK: - Truyền file

    private var configPath: String { paths.sshConfigURL.path }

    /// Trả true nếu job đã vào hàng đợi (sheet đóng).
    func startDownload(_ form: DownloadForm, host: HostProfile) async -> Bool {
        do { return try await enqueue(form.makeJob(host: host, configPath: configPath), host: host) } catch {
            show(error, title: "Không bắt đầu được tải về")
            return false
        }
    }

    func startUpload(_ form: UploadForm, host: HostProfile) async -> Bool {
        do { return try await enqueue(form.makeJob(host: host, configPath: configPath), host: host) } catch {
            show(error, title: "Không bắt đầu được tải lên")
            return false
        }
    }

    private func enqueue(_ job: TransferJob, host: HostProfile) async throws -> Bool {
        guard let transfers else { return false }
        // ADR-029: máy chưa lưu mật khẩu -> hỏi (sheet lồng trong sheet Tải về/Tải lên). Huỷ = sheet vẫn mở.
        let owner = "job-" + job.id.uuidString
        guard await preparePasswordForSession(host, owner: owner, presenter: .transferSheet) else {
            return false
        }
        do {
            // Config có thể cũ so với hồ sơ: sinh lại trước khi scp đọc.
            try await service?.regenerateSSHConfig()
            try await transfers.enqueue(job)
        } catch {
            ephemeralVault.release(hostID: host.id, owner: owner)
            throw error
        }
        sidebar = .transfers
        return true
    }

    /// Job tạo từ màn Truyền file: dùng lại master của tab (`controlPath`). Không chuyển màn.
    /// Trả số job đã vào hàng đợi; lỗi giữa chừng → ném lỗi (các job trước đó vẫn đã xếp hàng).
    func enqueueBrowserJobs(_ jobs: [TransferJob], controlPath: String) async throws -> Int {
        guard let transfers else { return 0 }
        try await service?.regenerateSSHConfig()
        var queued = 0
        for job in jobs {
            try await transfers.enqueue(job, controlPath: controlPath)
            queued += 1
        }
        return queued
    }

    func cancel(_ job: TransferJob) async { await cancelJob(id: job.id) }

    func cancelJob(id: UUID) async {
        do { try await transfers?.cancel(jobID: id) } catch {
            show(error, title: "Không huỷ được tác vụ")
        }
    }

    func retry(_ job: TransferJob) async {
        do {
            try await service?.regenerateSSHConfig()
            try await transfers?.retry(jobID: job.id)
            sidebar = .transfers
        } catch { show(error, title: "Không thử lại được") }
    }

    /// Gửi câu trả lời cho prompt. Caller đã xoá giá trị khỏi state; ở đây chỉ chuyển tiếp, không lưu/log.
    func respond(jobID: UUID, text: String, isSecret: Bool) {
        prompts.remove(jobID: jobID)
        guard let transfers else { return }
        Task {
            do { try await transfers.respond(jobID: jobID, text: text, isSecret: isSecret) } catch {
                show(error, title: "Không gửi được câu trả lời")
            }
        }
    }

    func clearHistory() async {
        do {
            _ = try await transferRepository?.clearHistory()
            jobs = jobs.filter { !$0.state.isTerminal }
        } catch { show(error, title: "Không xoá được lịch sử") }
    }

    var hasOpenSessions: Bool {
        (browser?.hasOpenSessions ?? false) || analyst.isRunning || tunnels.activeCount > 0
    }

    /// Dùng khi thoát: đóng mọi master của tab duyệt file (`ssh -O exit`), sau khi job đã xử lý xong.
    func closeAllSessions() async {
        await tunnels.shutdown()
        await analyst.shutdown()
        await monitor.shutdown()
        await browser?.closeAll()
    }

    /// Dùng khi thoát: huỷ job đang chạy rồi dừng manager.
    func shutdownTransfers(cancelRunning: Bool) async {
        await transfers?.shutdown(cancelRunning: cancelRunning)
    }

    // MARK: - Phím tắt & vòng đời (ADR-022)

    /// Mục sidebar ứng với ⌘1…⌘6 (theo thứ tự trên sidebar).
    static let shortcutSections: [(title: String, item: SidebarItem)] = [
        ("Tất cả máy chủ", .all), ("Yêu thích", .favorites), ("Truyền file", .transfers),
        ("Gần đây", .recent), ("Project Analyst", .analyst), ("Monitor", .monitor),
    ]

    var hasSelectedHost: Bool { isReadyForCommands && selectedHost != nil && sidebar.isHostSection }

    private var isReadyForCommands: Bool {
        if case .ready = phase { return form == nil && pendingDelete == nil }
        return false
    }

    func openSelected() {
        guard hasSelectedHost, let host = selectedHost else { return }
        Task { await open(host) }
    }

    func editSelected() {
        guard hasSelectedHost, let host = selectedHost else { return }
        form = .edit(host)
    }

    func duplicateSelected() {
        guard hasSelectedHost, let host = selectedHost else { return }
        beginDuplicate(host)
    }

    /// Luôn đi qua hộp xác nhận (`pendingDelete`).
    func deleteSelected() {
        guard hasSelectedHost, let host = selectedHost else { return }
        pendingDelete = host
    }

    /// Việc đang chạy, để hỏi trước khi thoát.
    var quitActivity: QuitActivity {
        QuitActivity(
            transfers: jobs.filter { !$0.state.isTerminal }.count, tunnels: tunnels.activeCount,
            monitorRunning: monitor.isRunning, analystRunning: analyst.isRunning,
            keyTaskRunning: keys.isBusy)
    }

    // MARK: - Cài đặt (ADR-021)

    /// Đổi một hay nhiều cài đặt: chuẩn hoá, lưu SQLite, rồi áp dụng ngay vào các service đang chạy.
    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.normalized
        guard next != settings else { return }
        let old = settings
        do { next = try settingsRepository?.save(next) ?? next } catch {
            show(error, title: "Không lưu được cài đặt")
            return
        }
        settings = next
        settingsStore.update(next)
        if next.transferConcurrency != old.transferConcurrency {
            let n = next.transferConcurrency
            Task { await transfers?.setConcurrency(n) }
        }
        if next.transferHistoryLimit != old.transferHistoryLimit {
            let n = next.transferHistoryLimit
            Task {
                await transferRepository?.setRetention(n)
                if let list = try? await transferRepository?.history() { jobs = list }
            }
        }
        if next.analystRetention != old.analystRetention {
            let n = next.analystRetention
            Task { await analystRepository?.setRetention(n) }
        }
        if next.monitorIntervalSeconds != old.monitorIntervalSeconds {
            monitor.applyDefaultInterval(next.monitorIntervalSeconds)
        }
        if next.userSSHConfigPath != old.userSSHConfigPath
            || next.defaultIdentityAgent != old.defaultIdentityAgent
        {
            Task {
                do { try await service?.regenerateSSHConfig() } catch {
                    show(error, title: "Không sinh lại được SSH config")
                }
            }
        }
    }

    /// Đường dẫn config người dùng đang được Include (nil = không có).
    var effectiveUserConfigPath: String? { settings.effectiveUserConfigPath() }

    /// Số host đang lưu mật khẩu (cho hộp xác nhận "Xoá mọi mật khẩu đã lưu").
    func savedPasswordCount() async -> Int {
        (try? await service?.savedPasswordCount()) ?? 0
    }

    func clearAllPasswords() async {
        guard let service else { return }
        do {
            let r = try await service.clearAllPasswords()
            await reload()
            let removed = r.removed + r.setItemsRemoved + r.metricsItemsRemoved
            let failed = r.failed + r.setItemsFailed + r.metricsItemsFailed
            if failed > 0 {
                alert = AppAlert(
                    title: "Xoá mật khẩu chưa hoàn tất",
                    message:
                        "Đã xoá \(removed) mật khẩu; \(failed) mục không xoá được (Keychain từ chối). Thử lại sau."
                )
            } else {
                showToast("Đã xoá \(removed) mật khẩu đã lưu")
            }
        } catch { show(error, title: "Không xoá được mật khẩu") }
    }

    func revealSSHConfigFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.sshConfigURL])
    }

    // MARK: - Thông báo

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func show(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: Self.message(for: error))
    }

    static func message(for error: Error) -> String {
        switch error {
        case DatabaseError.corrupt(let s):
            return "File dữ liệu bị hỏng hoặc không phải SQLite (\(s)). App không tạo file mới đè lên."
        case DatabaseError.newerSchema(let found, let supported):
            return
                "File dữ liệu thuộc phiên bản mới hơn (schema \(found), app hiểu tới \(supported)). Hãy dùng bản app mới hơn."
        case DatabaseError.cannotCreate(let s): return "Không tạo/đọc được file dữ liệu: \(s)"
        case DatabaseError.sqlite(_, let m): return "Lỗi cơ sở dữ liệu: \(m)"
        case HostRepositoryError.notFound: return "Không tìm thấy hồ sơ (có thể đã bị xoá)."
        case HostRepositoryError.duplicateID: return "Hồ sơ này đã tồn tại."
        case HostRepositoryError.jumpHostNotFound: return "Bastion đã chọn không còn tồn tại."
        case HostRepositoryError.jumpCycle: return "Chuỗi bastion tạo thành vòng lặp."
        case FolderNameError.empty: return "Tên thư mục không được để trống."
        case FolderNameError.tooLong:
            return "Tên thư mục tối đa \(HostFolders.maxNameLength) ký tự."
        case FolderNameError.controlCharacters: return "Tên thư mục chứa ký tự điều khiển."
        case HostRepositoryError.folderNameExists: return "Đã có thư mục trùng tên."
        case let e as PortForwardError: return Self.message(for: e)
        case let e as HostExchangeError: return e.description
        case let e as SpreadsheetError: return e.description
        case let e as InventoryError: return e.description
        case let e as InventoryTemplateError: return e.description
        case let e as ColumnMappingError: return e.description
        case HostRepositoryError.referencedAsJumpHost:
            return "Máy này đang là bastion của máy khác."
        case ConnectionServiceError.missingAlias: return "Hồ sơ thiếu alias SSH."
        case ConnectionServiceError.importedHostReadOnly:
            return "Máy chủ import từ SSH config: app không sửa cấu hình của máy này."
        case ConnectionServiceError.notSSHHost: return "Thao tác này chỉ dành cho máy Linux/SSH."
        case ConnectionServiceError.notWindowsHost: return "Đây không phải máy Windows."
        case let e as WindowsAppLauncherError: return "Lỗi ghi file .rdp: \(e)"
        case let e as RDPRenderError: return "Không sinh được file .rdp: \(e)"
        case ConnectionServiceError.hostNotFound: return "Không tìm thấy hồ sơ (có thể đã bị xoá)."
        case let e as SSHKeyError: return e.description
        case KeyTaskError.spawnFailed(let s): return "Không chạy được tiến trình: \(s)"
        case PTYProcessError.helperNotFound:
            return "Không tìm thấy helper sshdesk-ctty (cần build đầy đủ app)."
        case let e as TransferFormError: return e.issues.map(\.message).joined(separator: "\n")
        case TransferManagerError.hostNotFound: return "Máy chủ không còn tồn tại."
        case TransferManagerError.hostChanged:
            return "Alias SSH của máy đã thay đổi kể từ khi tạo tác vụ; hãy tạo tác vụ mới."
        case TransferManagerError.localSourceMissing(let p): return "Không thấy nguồn local: \(p)"
        case TransferManagerError.symlinksNotSupported(let l):
            return "Nguồn chứa symbolic link, chưa được hỗ trợ: "
                + l.prefix(TransferFormLimits.symlinkDisplay).joined(separator: ", ")
        case TransferManagerError.localConflict(let p): return "Đích đã tồn tại: \(p)"
        case TransferManagerError.jobNotFound: return "Không tìm thấy tác vụ."
        case TransferManagerError.notAwaitingInput: return "Tác vụ không còn chờ nhập."
        case TransferManagerError.notCancellable: return "Tác vụ không huỷ được ở trạng thái này."
        case let e as ScpBuildError: return "Đường dẫn không hợp lệ: \(e)"
        case let e as HostValidationError: return HostDraft.describe(e).1
        case let e as SSHConfigError: return "Cấu hình SSH không hợp lệ: \(e)"
        case let e as WarpLauncherError: return "Lỗi file cấu hình Warp: \(e)"
        default: return error.localizedDescription
        }
    }

    static func message(for e: PortForwardError) -> String {
        switch e {
        case .invalidLocalPort(let p):
            return "Cổng local \(p) không hợp lệ: phải từ \(PortForward.minLocalPort) đến 65535."
        case .invalidRemotePort(let p): return "Cổng đích \(p) không hợp lệ: phải từ 1 đến 65535."
        case .invalidRemoteHost:
            return
                "Máy đích không hợp lệ: dùng tên máy/IPv4 (chữ, số, '.', '-', '_') hoặc IPv6 trong [ ]; không có khoảng trắng hay dấu ':'."
        case .invalidName: return "Tên forward chứa ký tự điều khiển hoặc dài quá \(PortForward.maxNameLength) ký tự."
        case .localPortTaken(let port, _): return "Cổng local \(port) đã được một forward khác của app dùng."
        case .hostNotFound: return "Không tìm thấy máy chủ (có thể đã bị xoá)."
        case .hostNotSupported: return "Máy Windows không có port forward."
        case .notFound: return "Không tìm thấy forward (có thể đã bị xoá)."
        }
    }

    // MARK: - Port forward

    /// Trả true nếu lưu được (form đóng).
    func saveForward(_ forward: PortForward, isNew: Bool) async -> Bool {
        guard let repo = forwardRepository else { return false }
        do {
            if isNew { try await repo.add(forward) } else { try await repo.update(forward) }
            forwards = try await repo.all()
            return true
        } catch {
            show(error, title: "Không lưu được port forward")
            return false
        }
    }

    func deleteForward(_ forward: PortForward) async {
        guard let repo = forwardRepository else { return }
        do {
            await tunnels.manager.stop(forwardID: forward.id)
            try await repo.delete(id: forward.id)
            forwards = try await repo.all()
        } catch { show(error, title: "Không xoá được port forward") }
    }

    func forwards(for hostID: UUID) -> [PortForward] {
        forwards.filter { $0.hostID == hostID }.sorted { $0.localPort < $1.localPort }
    }
}
