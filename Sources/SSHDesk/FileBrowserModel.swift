import AppKit
import Foundation
import Observation
import SSHDeskCore
import UniformTypeIdentifiers

/// Nội dung thả vào một khung.
enum DroppedContent: Sendable {
    case payload(BrowserDragPayload)
    /// File kéo từ Finder (chỉ đường dẫn, không đọc nội dung).
    case files([String])
}

extension UTType {
    /// Kiểu kéo thả nội bộ (khai báo trong Info.plist của .app).
    static let browserItems = UTType(
        exportedAs: BrowserDragPayload.typeIdentifier, conformingTo: .data)
}

/// Trạng thái toàn màn "Truyền file": khung local, các tab remote, hộp thoại, điều phối kéo thả.
/// Quyết định (kế hoạch trùng tên, PROD, đích, refresh...) nằm trong SSHDeskCore; ở đây chỉ nối UI với service.
@MainActor @Observable
final class FileBrowserModel {
    weak var app: AppModel?
    let credentials: any CredentialStore
    let local: LocalPaneModel
    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: UUID?
    var dialog: BrowserDialog?
    /// Nguồn của lượt kéo đang diễn ra (để không hiện vùng thả trên chính khung nguồn).
    var dragOrigin: BrowserDragPayload.Origin?
    private var socketDirectory: SocketDirectory?
    private var mouseMonitor: Any?

    init(app: AppModel, credentials: any CredentialStore) {
        self.app = app
        self.credentials = credentials
        local = LocalPaneModel(startDirectory: app.settings.resolvedLocalDirectory())
        // Bắt đầu một thao tác chuột mới thì xoá nguồn kéo cũ (kéo bị huỷ giữa chừng không có callback).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in self?.dragOrigin = nil }
            return event
        }
    }

    var configPath: String { app?.paths.sshConfigURL.path ?? "" }
    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabID } }
    var sessionCount: Int { BrowserTabPresentation.sessionCount(tabs.map(\.state)) }
    var hasOpenSessions: Bool { !tabs.isEmpty }

    /// Phiên của tab được chia sẻ với Project Analyst qua `SessionPool` (không mở master thứ hai).
    func registerSession(_ session: RemoteSession, hostID: UUID) async {
        await app?.sessionPool.register(hostID: hostID, session: session, owner: .browser)
    }

    func unregisterSession(_ session: RemoteSession, hostID: UUID) async {
        await app?.sessionPool.unregister(hostID: hostID, session: session)
    }

    func prepareConfig() async throws {
        try await app?.service?.regenerateSSHConfig()
    }

    func apply(_ outcome: DialogOutcome) {
        switch outcome {
        case .done: dialog = nil
        case .next(let next): dialog = next
        case .error(let message): dialog = .error("Có lỗi", message)
        }
    }

    // MARK: - Tab

    func openTab(_ host: HostProfile) async {
        if let existing = tabs.first(where: { $0.hostID == host.id }) {
            selectedTabID = existing.id
            return
        }
        guard HostPicker.isSelectable(host) else {
            dialog = .error("Không mở được “\(host.displayName)”", "Hồ sơ thiếu alias SSH.")
            return
        }
        switch await app?.sessionPool.owner(of: host.id) {
        case .analyst:
            dialog = .error(
                "Không mở được “\(host.displayName)”",
                "Project Analyst đang dùng kết nối của máy này. Hãy thử lại sau khi lần chạy kết thúc.")
            return
        case .monitor:
            dialog = .error(
                "Không mở được “\(host.displayName)”",
                "Monitor đang dùng kết nối của máy này. Hãy dừng Monitor hoặc rời màn Monitor rồi thử lại.")
            return
        case .browser, nil:
            break
        }
        do {
            if socketDirectory == nil { socketDirectory = try SocketDirectory.ensure() }
        } catch {
            dialog = .error("Không tạo được thư mục socket", BrowserErrorText.message(for: error))
            return
        }
        guard let dir = socketDirectory else { return }
        let tab = BrowserTab(host: host, owner: self, socketDirectory: dir)
        tabs.append(tab)
        selectedTabID = tab.id
        let wanted = host.defaultLocalDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.hasPrefix("/"), FileManager.default.fileExists(atPath: wanted) {
            await local.go(.visit(wanted))
        }
        await tab.start()
    }

    /// Nút × của tab: còn job của host này đang chạy thì hỏi trước (scp dùng master của tab sẽ đứt).
    func requestClose(_ tab: BrowserTab) {
        let running = TransferPresentation.active(app?.jobs ?? []).filter { $0.hostID == tab.hostID }
        guard !running.isEmpty else {
            Task { await closeTab(tab) }
            return
        }
        dialog = .confirm(
            ConfirmDialog(
                title: "Đóng tab “\(tab.title)”?",
                message:
                    "Còn \(running.count) tác vụ truyền file của máy này đang chạy hoặc đang chờ. Đóng tab sẽ ngắt kết nối dùng chung và các tác vụ đó có thể thất bại.",
                confirmTitle: "Đóng tab", destructive: true
            ) { [weak self] in
                await self?.closeTab(tab)
                return .done
            })
    }

    func closeTab(_ tab: BrowserTab) async {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: i)
        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
        await tab.close()
    }

    /// Thoát app: đóng mọi master (ssh -O exit).
    func closeAll() async {
        let all = tabs
        tabs = []
        selectedTabID = nil
        for tab in all { await tab.close() }
    }

    func hostsChanged(_ hosts: [HostProfile]) {
        for tab in tabs {
            if let h = hosts.first(where: { $0.id == tab.hostID }) { tab.updateHost(h) }
        }
    }

    /// Job của app vừa kết thúc: làm mới khung đích nếu đang xem đúng thư mục đó.
    func jobFinished(_ job: TransferJob) {
        for tab in tabs
        where BrowserRefreshRule.shouldRefreshRemote(
            job: job, hostID: tab.hostID, currentPath: tab.path)
        {
            Task { await tab.refresh() }
        }
        if BrowserRefreshRule.shouldRefreshLocal(job: job, currentDirectory: local.path) {
            Task { await local.refresh() }
        }
    }

    // MARK: - Kéo thả

    func shouldShowDropOverlay(onRemote tab: BrowserTab, targeted: Bool) -> Bool {
        guard targeted, tab.isBrowsable else { return false }
        return dragOrigin != .remote(hostID: tab.hostID)
    }

    func shouldShowDropOverlay(onLocal targeted: Bool) -> Bool {
        targeted && dragOrigin != .local
    }

    func beginDrag(_ origin: BrowserDragPayload.Origin) { dragOrigin = origin }

    /// Tạo `NSItemProvider` nội bộ (chỉ trong process của app) cho các dòng kéo.
    func provider(for items: [BatchItem], origin: BrowserDragPayload.Origin) -> NSItemProvider {
        beginDrag(origin)
        let provider = NSItemProvider()
        if let data = BrowserDragPayload(origin: origin, items: items).encoded() {
            provider.registerDataRepresentation(
                forTypeIdentifier: BrowserDragPayload.typeIdentifier, visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }

    /// Đọc dữ liệu thả: payload nội bộ hoặc đường dẫn file từ Finder. Không đọc nội dung file.
    static func decode(_ providers: [NSItemProvider]) async -> DroppedContent? {
        var files: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(BrowserDragPayload.typeIdentifier) {
                let data: Data? = await withCheckedContinuation { cont in
                    provider.loadDataRepresentation(
                        forTypeIdentifier: BrowserDragPayload.typeIdentifier
                    ) { data, _ in cont.resume(returning: data) }
                }
                if let data, let payload = BrowserDragPayload.decode(data) {
                    return .payload(payload)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let data: Data? = await withCheckedContinuation { cont in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
                        data, _ in cont.resume(returning: data)
                    }
                }
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    files.append(url.path)
                }
            }
        }
        return files.isEmpty ? nil : .files(files)
    }

    func handleDrop(_ providers: [NSItemProvider], onRemote tab: BrowserTab) {
        dragOrigin = nil
        Task {
            guard let content = await Self.decode(providers) else { return }
            await dropOnRemote(tab, content)
        }
    }

    func handleDropOnLocal(_ providers: [NSItemProvider]) {
        dragOrigin = nil
        Task {
            guard let content = await Self.decode(providers) else { return }
            await dropOnLocal(content)
        }
    }

    func dropOnRemote(_ tab: BrowserTab, _ content: DroppedContent) async {
        let paths: [String]
        switch content {
        case .payload(let p):
            if case .remote = p.origin { return }  // thả vào chính khung nguồn: không làm gì
            paths = p.items.map(\.path)
        case .files(let f): paths = f
        }
        await startUpload(paths: paths, to: tab)
    }

    func dropOnLocal(_ content: DroppedContent) async {
        guard case .payload(let p) = content, case .remote(let hostID) = p.origin else { return }
        guard let tab = tabs.first(where: { $0.hostID == hostID }) else {
            dialog = .error("Không tải về được", "Tab của máy chủ này đã đóng.")
            return
        }
        await startDownload(items: p.items, from: tab)
    }

    // MARK: - Upload

    /// Menu "Tải lên": các dòng đang chọn ở khung local → thư mục remote hiện tại.
    func uploadSelectedLocal(to tab: BrowserTab) async {
        await startUpload(paths: local.selectedRows.filter(\.isSupported).map(\.id), to: tab)
    }

    func startUpload(paths: [String], to tab: BrowserTab) async {
        guard tab.isBrowsable, !tab.path.isEmpty else {
            dialog = .error(
                "Chưa tải lên được", "“\(tab.title)” chưa kết nối. Đợi kết nối xong hoặc bấm Kết nối lại.")
            return
        }
        guard !paths.isEmpty else { return }
        let inspected = await Task.detached { BrowserTransferPlanner.inspectLocalSources(paths) }.value
        let remoteNames: Set<String>
        do {
            let listing = try await tab.files.list(tab.path)  // listing mới nhất (không nguyên tử, có race)
            remoteNames = Set(listing.entries.map(\.name))
        } catch {
            tab.noteFailure(error)
            dialog = .error("Không kiểm tra được thư mục đích", BrowserErrorText.message(for: error))
            return
        }
        let plan = BrowserTransferPlanner.planUpload(
            items: inspected.items, remoteDirectory: tab.path, remoteNames: remoteNames)
        var notes = inspected.rejections.map(\.message)
        notes += plan.unsupported.map { "“\($0)”: tên chứa ký tự điều khiển, không hỗ trợ." }
        let proceed: @MainActor () -> DialogOutcome = { [weak self] in
            self?.continueUpload(plan, to: tab) ?? .done
        }
        if notes.isEmpty {
            apply(proceed())
        } else if plan.isEmpty {
            dialog = .notice(
                NoticeDialog(
                    title: "Không có mục nào tải lên được",
                    message: "Các mục sau bị từ chối:", items: notes))
        } else {
            dialog = .notice(
                NoticeDialog(
                    title: "Một số mục bị bỏ qua",
                    message: "Các mục sau bị từ chối, phần còn lại vẫn tiếp tục:", items: notes,
                    then: proceed))
        }
    }

    private func continueUpload(_ plan: TransferBatchPlan, to tab: BrowserTab) -> DialogOutcome {
        guard plan.hasConflicts else { return finishUpload(plan, .overwriteAll, to: tab) }
        let hasDirectory = plan.items.contains { $0.kind == .directory && plan.conflicts.contains($0.name) }
        return .next(
            .conflicts(
                ConflictDialog(
                    title: "\(plan.conflicts.count) mục đã có trên \(tab.title) trong \(plan.destinationDirectory)",
                    names: plan.conflicts,
                    note: "scp không kiểm tra nguyên tử: kiểm tra dựa trên danh sách vừa tải."
                        + (hasDirectory
                            ? " Thư mục trùng tên sẽ được gộp vào (file trùng bị ghi đè, file khác giữ nguyên)."
                            : ""),
                    allowAutoRename: false,
                    choose: { [weak self] choice in
                        guard let self, let choice else { return .done }
                        return self.finishUpload(plan, choice, to: tab)
                    })))
    }

    private func finishUpload(
        _ plan: TransferBatchPlan, _ choice: BatchConflictChoice, to tab: BrowserTab
    ) -> DialogOutcome {
        let planned = BrowserTransferPlanner.uploadJobs(plan, choice: choice)
        guard !planned.isEmpty else {
            app?.showToast("Không có mục nào để tải lên")
            return .done
        }
        let host = tab.host
        let enqueue: @MainActor () async -> DialogOutcome = { [weak self] in
            guard let self else { return .done }
            return await self.enqueue(planned, host: host, tab: tab)
        }
        guard BrowserSafety.requiresUploadConfirmation(host) else {
            Task { apply(await enqueue()) }
            return .done
        }
        let names = planned.map { BrowserPath.lastComponent($0.source) }
        return .next(
            .confirm(
                ConfirmDialog(
                    title: BrowserSafety.uploadConfirmationTitle(host),
                    message: "\(planned.count) mục → \(tab.path)",
                    emphasis: "Đây là máy PRODUCTION — kiểm tra kỹ đích trước khi tải lên.",
                    items: names, confirmTitle: "Tải lên", action: enqueue)))
    }

    // MARK: - Download

    /// Menu "Tải về": các dòng remote đang chọn → thư mục local hiện tại.
    func downloadSelected(from tab: BrowserTab) async {
        let items = tab.selectedRows.filter(\.isSupported).map(BatchItem.init(row:))
        await startDownload(items: items, from: tab)
    }

    func startDownload(items: [BatchItem], from tab: BrowserTab) async {
        let destination = local.path
        let plan = BrowserTransferPlanner.planDownload(items: items, localDirectory: destination)
        let notes = plan.unsupported.map { "“\($0)”: tên chứa ký tự điều khiển, không hỗ trợ." }
        let proceed: @MainActor () -> DialogOutcome = { [weak self] in
            self?.continueDownload(plan, from: tab) ?? .done
        }
        if plan.isEmpty {
            if !notes.isEmpty {
                dialog = .notice(NoticeDialog(title: "Không có mục nào tải về được", message: "", items: notes))
            }
        } else if notes.isEmpty {
            apply(proceed())
        } else {
            dialog = .notice(
                NoticeDialog(
                    title: "Một số mục bị bỏ qua", message: "Các mục sau không hỗ trợ:", items: notes,
                    then: proceed))
        }
    }

    private func continueDownload(_ plan: TransferBatchPlan, from tab: BrowserTab) -> DialogOutcome {
        guard plan.hasConflicts else { return finishDownload(plan, .overwriteAll, from: tab) }
        return .next(
            .conflicts(
                ConflictDialog(
                    title:
                        "\(plan.conflicts.count) mục đã có trong \(BrowserPath.display(plan.destinationDirectory, home: local.home))",
                    names: plan.conflicts, note: nil, allowAutoRename: true,
                    choose: { [weak self] choice in
                        guard let self, let choice else { return .done }
                        return self.finishDownload(plan, choice, from: tab)
                    })))
    }

    private func finishDownload(
        _ plan: TransferBatchPlan, _ choice: BatchConflictChoice, from tab: BrowserTab
    ) -> DialogOutcome {
        let planned = BrowserTransferPlanner.downloadJobs(plan, choice: choice)
        guard !planned.isEmpty else {
            app?.showToast("Không có mục nào để tải về")
            return .done
        }
        let host = tab.host
        Task { apply(await enqueue(planned, host: host, tab: tab)) }
        return .done
    }

    private func enqueue(_ planned: [PlannedTransfer], host: HostProfile, tab: BrowserTab) async
        -> DialogOutcome
    {
        guard let app else { return .done }
        do {
            let jobs = try BrowserTransferPlanner.makeJobs(planned, host: host, configPath: configPath)
            let queued = try await app.enqueueBrowserJobs(jobs, controlPath: tab.session.controlPath)
            app.showToast("Đã thêm \(queued) tác vụ vào hàng đợi")
            return .done
        } catch {
            return .next(.error("Không tạo được tác vụ", AppModel.message(for: error)))
        }
    }

    // MARK: - Thao tác remote

    func promptNewRemoteFolder(_ tab: BrowserTab) {
        dialog = .nameInput(
            NameInputDialog(
                title: "Thư mục mới trên \(tab.title)", message: tab.path, initial: "Thư mục mới",
                confirmTitle: "Tạo"
            ) { name in
                if let issue = EntryNameRules.validate(name) { return .error(issue.message) }
                do {
                    try await tab.makeFolder(named: name)
                    return .done
                } catch { return .error(BrowserErrorText.message(for: error)) }
            })
    }

    func promptRenameRemote(_ tab: BrowserTab, _ row: BrowserRow) {
        guard row.isSupported else { return }
        dialog = .nameInput(
            NameInputDialog(
                title: "Đổi tên “\(row.name)”", message: nil, initial: row.name, confirmTitle: "Đổi tên"
            ) { [weak self] newName in
                if let issue = EntryNameRules.validate(newName) { return .error(issue.message) }
                if newName == row.name { return .done }
                do {
                    try await tab.rename(row, to: newName, overwrite: false)
                    return .done
                } catch RemoteFileError.destinationExists {
                    guard let self else { return .done }
                    return .next(self.overwriteRenameDialog(tab, row, newName))
                } catch { return .error(BrowserErrorText.message(for: error)) }
            })
    }

    private func overwriteRenameDialog(_ tab: BrowserTab, _ row: BrowserRow, _ newName: String)
        -> BrowserDialog
    {
        .confirm(
            ConfirmDialog(
                title: "“\(newName)” đã tồn tại. Ghi đè?",
                message: "Đổi tên “\(row.name)” thành “\(newName)” sẽ thay thế mục cùng tên trên \(tab.title).",
                confirmTitle: "Ghi đè", destructive: true
            ) {
                do {
                    try await tab.rename(row, to: newName, overwrite: true)
                    return .done
                } catch { return .next(.error("Không đổi tên được", BrowserErrorText.message(for: error))) }
            })
    }

    func confirmDeleteRemote(_ tab: BrowserTab, _ row: BrowserRow) {
        guard row.isSupported else { return }
        if row.isDirectory {
            let op = DeleteOperation(tab: tab, row: row)
            dialog = .delete(op)
            return
        }
        let prod = tab.host.environment == .prod
        dialog = .confirm(
            ConfirmDialog(
                title: "Xoá “\(row.name)”?",
                message:
                    "Xoá vĩnh viễn trên \(tab.title) (\(row.id)). Không có Thùng rác; quyền theo user SSH, không dùng sudo.",
                emphasis: prod ? "Đây là máy PRODUCTION." : nil, confirmTitle: "Xoá", destructive: true
            ) {
                do {
                    try await tab.removeFile(row)
                    return .done
                } catch { return .next(.error("Không xoá được", BrowserErrorText.message(for: error))) }
            })
    }

    // MARK: - Thao tác local

    func promptNewLocalFolder() {
        dialog = .nameInput(
            NameInputDialog(
                title: "Thư mục mới", message: BrowserPath.display(local.path, home: local.home),
                initial: "Thư mục mới", confirmTitle: "Tạo"
            ) { [weak self] name in
                if let issue = EntryNameRules.validate(name) { return .error(issue.message) }
                do {
                    try self?.local.makeFolder(named: name)
                    await self?.local.refresh()
                    return .done
                } catch { return .error(BrowserErrorText.message(for: error)) }
            })
    }

    func promptRenameLocal(_ row: BrowserRow) {
        guard row.isSupported else { return }
        dialog = .nameInput(
            NameInputDialog(
                title: "Đổi tên “\(row.name)”", message: "Không ghi đè mục đã có.", initial: row.name,
                confirmTitle: "Đổi tên"
            ) { [weak self] newName in
                if let issue = EntryNameRules.validate(newName) { return .error(issue.message) }
                if newName == row.name { return .done }
                do {
                    try self?.local.rename(row, to: newName)
                    await self?.local.refresh()
                    return .done
                } catch { return .error(BrowserErrorText.message(for: error)) }
            })
    }

    func confirmTrash(_ rows: [BrowserRow]) {
        let targets = rows.filter(\.isSupported)
        guard !targets.isEmpty else { return }
        dialog = .confirm(
            ConfirmDialog(
                title: targets.count == 1
                    ? "Chuyển “\(targets[0].name)” vào Thùng rác?"
                    : "Chuyển \(targets.count) mục vào Thùng rác?",
                message: "Có thể khôi phục từ Thùng rác.", items: targets.map(\.name),
                confirmTitle: "Chuyển vào Thùng rác", destructive: true
            ) { [weak self] in
                do {
                    try self?.local.trash(targets)
                    await self?.local.refresh()
                    return .done
                } catch {
                    await self?.local.refresh()
                    return .next(.error("Không chuyển được vào Thùng rác", BrowserErrorText.message(for: error)))
                }
            })
    }
}
