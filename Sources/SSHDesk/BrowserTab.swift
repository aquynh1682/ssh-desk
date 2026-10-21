import AppKit
import Foundation
import Observation
import SSHDeskCore

/// Một tab của khung phải: một host = một master ControlMaster (`RemoteSession`) + thao tác file qua sftp.
/// Quyết định nằm trong SSHDeskCore (`BrowserTabReducer`, `PasswordAutofillPolicy`, `BrowserRows`...).
@MainActor @Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let hostID: UUID
    /// Bản chụp hồ sơ host; `FileBrowserModel.hostsChanged()` cập nhật khi hồ sơ đổi.
    private(set) var host: HostProfile
    private(set) var state: BrowserTabState = .connecting
    /// Prompt đang chờ người dùng (không tự điền được).
    private(set) var pendingPrompt: PromptKind?

    private(set) var history: NavigationHistory?
    private(set) var allRows: [BrowserRow] = []
    private(set) var unparsedLines = 0
    private(set) var isLoading = false
    var selection = BrowserSelection()
    var sort = BrowserSort()
    var query = ""
    var showSearch = false
    var pathText = ""
    var listError: String?
    private(set) var home = "/"

    private(set) var session: RemoteSession
    private(set) var files: RemoteFileService
    private unowned let owner: FileBrowserModel
    private let socketDirectory: SocketDirectory
    private var autofilled = false
    /// Chỉ `close()` phiên đã thực sự chạy master: `RemoteSession.close()` xoá file socket tại ControlPath,
    /// không được xoá socket của master khác (vd phiên chưa start vì `socketInUse`).
    private var sessionRan = false
    private var generation = 0
    private var eventsTask: Task<Void, Never>?

    init(host: HostProfile, owner: FileBrowserModel, socketDirectory: SocketDirectory) {
        self.host = host
        hostID = host.id
        self.owner = owner
        self.socketDirectory = socketDirectory
        let s = Self.makeSession(host: host, owner: owner, socketDirectory: socketDirectory)
        session = s
        files = RemoteFileService(session: s)
    }

    private static func makeSession(
        host: HostProfile, owner: FileBrowserModel, socketDirectory: SocketDirectory
    ) -> RemoteSession {
        RemoteSession(
            alias: host.sshAlias ?? "", configPath: owner.configPath, hostID: host.id,
            socketDirectory: socketDirectory, helper: ControllingTTYHelper.defaultURL())
    }

    // MARK: - Hiển thị

    var path: String { history?.current ?? "" }
    var rows: [BrowserRow] { BrowserRows.arranged(allRows, query: query, sort: sort) }
    var selectedRows: [BrowserRow] { rows.filter { selection.selected.contains($0.id) } }
    var isBrowsable: Bool { BrowserTabPresentation.isBrowsable(state) }
    var title: String { host.displayName }

    func updateHost(_ newHost: HostProfile) { host = newHost }

    // MARK: - Kết nối

    /// Khởi chạy master mới (lần đầu hoặc "Kết nối lại").
    func start() async {
        if case .disconnected = state { apply(.reconnecting) }
        eventsTask?.cancel()
        let s: RemoteSession
        if sessionRan {
            await session.close()  // phiên cũ: dọn master/socket rồi tạo phiên mới
            s = Self.makeSession(host: host, owner: owner, socketDirectory: socketDirectory)
            session = s
            files = RemoteFileService(session: s)
        } else {
            s = session
        }
        sessionRan = true
        pendingPrompt = nil
        autofilled = false
        listError = nil
        let events = s.events
        eventsTask = Task { [weak self] in
            for await event in events { self?.handle(event, from: s) }
        }
        do {
            try await owner.prepareConfig()
            try await s.start()
        } catch {
            sessionRan = false  // master chưa chạy: không được `close()` (sẽ xoá socket của master khác)
            apply(.startFailed(BrowserErrorText.message(for: error)))
        }
    }

    func close() async {
        eventsTask?.cancel()
        pendingPrompt = nil
        if sessionRan {
            await owner.unregisterSession(session, hostID: hostID)
            await session.close()
        }
    }

    private func apply(_ event: BrowserTabEvent) {
        state = BrowserTabReducer.reduce(state, event)
        if case .disconnected = state { pendingPrompt = nil }
    }

    private func handle(_ event: SessionEvent, from source: RemoteSession) {
        guard source === session else { return }  // sự kiện muộn của phiên cũ
        apply(.session(event))
        switch event {
        case .authPrompt(let kind):
            Task { await self.answer(kind, from: source) }
        case .connected:
            pendingPrompt = nil
            Task { await owner.registerSession(source, hostID: hostID) }
            Task { await self.loadInitialDirectory() }
        case .disconnected:
            Task { await owner.unregisterSession(source, hostID: hostID) }
        }
    }

    /// Tự điền password Keychain (một lần/phiên, theo `PasswordAutofillPolicy`) hoặc hiện thẻ prompt.
    private func answer(_ kind: PromptKind, from source: RemoteSession) async {
        if PasswordAutofillPolicy.shouldAutofill(prompt: kind, host: host, alreadyFilled: autofilled),
            let ref = host.credentialReference
        {
            autofilled = true
            let store = owner.credentials
            // Keychain có thể hỏi ACL: không đọc trên main thread.
            let password = await Task.detached { store.read(ref: ref) }.value
            guard source === session, state == .awaitingAuth else { return }
            if let password, !password.isEmpty {
                apply(.answered)
                await source.respond(text: password, isSecret: true)
                return
            }
        }
        pendingPrompt = kind
    }

    /// Trả lời prompt từ thẻ xác thực. Không lưu/log `text`.
    func respond(text: String, isSecret: Bool) {
        guard pendingPrompt != nil else { return }
        pendingPrompt = nil
        apply(.answered)
        let s = session
        Task { await s.respond(text: text, isSecret: isSecret) }
    }

    // MARK: - Duyệt

    private func loadInitialDirectory() async {
        do { home = try await files.home() } catch {
            noteFailure(error)
            return
        }
        let wanted = host.defaultRemoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, let resolved = BrowserPath.resolve(wanted, home: home) {
            if await load(.visit(resolved)) { return }
            owner.app?.showToast("Không mở được thư mục mặc định — dùng thư mục home")
        }
        await load(.visit(home))
    }

    enum Move {
        case visit(String)
        case back, forward, refresh
    }

    /// Liệt kê rồi mới đổi lịch sử/đường dẫn. Lỗi → giữ nguyên thư mục cũ và đặt `listError`.
    @discardableResult
    func load(_ move: Move) async -> Bool {
        let target: String
        switch move {
        case .visit(let p): target = p
        case .back:
            guard let t = history?.backTarget else { return false }
            target = t
        case .forward:
            guard let t = history?.forwardTarget else { return false }
            target = t
        case .refresh:
            guard let p = history?.current else { return false }
            target = p
        }
        guard isBrowsable else { return false }
        generation += 1
        let g = generation
        isLoading = true
        do {
            let listing = try await files.list(target)
            guard g == generation else { return false }
            isLoading = false
            switch move {
            case .visit(let p):
                if history == nil { history = NavigationHistory(start: p) } else { history?.commitVisit(p) }
            case .back: history?.commitBack()
            case .forward: history?.commitForward()
            case .refresh: break
            }
            allRows = listing.entries.map { BrowserRow(remote: $0, directory: target) }
            unparsedLines = listing.unparsedLines
            selection.retain(Set(allRows.map(\.id)))
            pathText = target
            listError = nil
            return true
        } catch {
            guard g == generation else { return false }
            isLoading = false
            noteFailure(error)
            pathText = path
            return false
        }
    }

    func refresh() async { await load(.refresh) }

    func goUp() async {
        let parent = BrowserPath.parent(path)
        if parent != path { await load(.visit(parent)) }
    }

    /// Enter trong ô đường dẫn.
    func submitPathText() async {
        guard let resolved = BrowserPath.resolve(pathText, home: home) else {
            listError = "Nhập đường dẫn tuyệt đối (hoặc bắt đầu bằng ~)."
            pathText = path
            return
        }
        await load(.visit(resolved))
    }

    /// Double-click: thư mục và symlink đều thử vào; symlink trỏ tới file thì báo lỗi.
    func open(_ row: BrowserRow) async {
        guard row.isSupported, row.isDirectory || row.isSymlink else { return }
        if !(await load(.visit(row.id))), row.isSymlink {
            owner.app?.showToast("Không vào được liên kết “\(row.name)” (có thể trỏ tới file)")
        }
    }

    /// Ghi nhận lỗi: mất kết nối → đổi trạng thái tab; còn lại hiện dòng lỗi ở khung.
    func noteFailure(_ error: Error) {
        if let e = error as? RemoteFileError, e == .sessionLost { apply(.sessionLost) }
        listError = BrowserErrorText.message(for: error)
    }

    // MARK: - Thao tác remote (sau đó làm mới)

    func makeFolder(named name: String) async throws {
        do { try await files.mkdir(BrowserPath.join(path, name)) } catch {
            noteFailure(error)
            throw error
        }
        await refresh()
    }

    /// `overwrite == false` mà đích tồn tại → ném `RemoteFileError.destinationExists`.
    func rename(_ row: BrowserRow, to newName: String, overwrite: Bool) async throws {
        do {
            try await files.rename(
                from: row.id, to: BrowserPath.join(path, newName), overwrite: overwrite)
        } catch let e as RemoteFileError {
            if e != .destinationExists(BrowserPath.join(path, newName)) { noteFailure(e) }
            throw e
        }
        await refresh()
    }

    func removeFile(_ row: BrowserRow) async throws {
        do { try await files.remove(file: row.id) } catch {
            noteFailure(error)
            throw error
        }
        await refresh()
    }

    func planDelete(_ row: BrowserRow) async throws -> RemoteDeletePlan {
        do { return try await files.planRecursiveDelete(row.id) } catch {
            noteFailure(error)
            throw error
        }
    }

    func executeDelete(
        _ plan: RemoteDeletePlan, progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws {
        do {
            try await files.executeRecursiveDelete(plan, progress: progress)
        } catch {
            if case RemoteFileError.deleteInterrupted(_, _, let message) = error,
                message == BrowserErrorText.remote(.sessionLost)
            {
                apply(.sessionLost)
            }
            await refresh()
            throw error
        }
        await refresh()
    }

    func copyPath(_ row: BrowserRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.id, forType: .string)
        owner.app?.showToast("Đã copy đường dẫn")
    }
}
