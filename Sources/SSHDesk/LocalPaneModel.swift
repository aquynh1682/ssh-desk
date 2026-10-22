import AppKit
import Foundation
import Observation
import SSHDeskCore

/// Trạng thái khung trái "Local — Máy Mac này". Logic quyết định nằm trong SSHDeskCore
/// (`BrowserRows`, `BrowserPath`, `NavigationHistory`...), ở đây chỉ gom state cho SwiftUI.
@MainActor @Observable
final class LocalPaneModel {
    let home = NSHomeDirectory()
    private let service = LocalFileService()

    private(set) var history: NavigationHistory
    private(set) var allRows: [BrowserRow] = []
    private(set) var isLoading = false
    var selection = BrowserSelection()
    var sort = BrowserSort()
    var query = ""
    var showSearch = false
    var showHidden = false
    var pathText = ""
    var error: String?
    private var generation = 0

    /// `startDirectory`: thư mục local mặc định từ Cài đặt (ADR-021).
    init(startDirectory: String) {
        history = NavigationHistory(start: startDirectory)
        pathText = BrowserPath.display(startDirectory, home: NSHomeDirectory())
    }

    var path: String { history.current }
    var rows: [BrowserRow] {
        BrowserRows.arranged(allRows, query: query, sort: sort, showHidden: showHidden)
    }
    var selectedRows: [BrowserRow] { rows.filter { selection.selected.contains($0.id) } }

    // MARK: - Điều hướng

    enum Move {
        case visit(String)
        case back, forward, refresh
    }

    /// Tải thư mục đích; chỉ đổi lịch sử/đường dẫn khi tải thành công. Trả true nếu thành công.
    @discardableResult
    func go(_ move: Move) async -> Bool {
        let target: String
        switch move {
        case .visit(let p): target = p
        case .back:
            guard let t = history.backTarget else { return false }
            target = t
        case .forward:
            guard let t = history.forwardTarget else { return false }
            target = t
        case .refresh: target = history.current
        }
        generation += 1
        let g = generation
        isLoading = true
        let svc = service
        let result: Result<[LocalEntry], any Error> = await Task.detached {
            Result { try svc.list(target) }
        }.value
        guard g == generation else { return false }
        isLoading = false
        switch result {
        case .failure(let e):
            error = BrowserErrorText.message(for: e)
            pathText = BrowserPath.display(history.current, home: home)
            return false
        case .success(let entries):
            switch move {
            case .visit(let p): history.commitVisit(p)
            case .back: history.commitBack()
            case .forward: history.commitForward()
            case .refresh: break
            }
            allRows = entries.map(BrowserRow.init(local:))
            selection.retain(Set(allRows.map(\.id)))
            pathText = BrowserPath.display(history.current, home: home)
            error = nil
            return true
        }
    }

    func refresh() async { await go(.refresh) }

    func goUp() async {
        let parent = BrowserPath.parent(path)
        if parent != path { await go(.visit(parent)) }
    }

    /// Enter trong ô đường dẫn.
    func submitPathText() async {
        guard let resolved = BrowserPath.resolve(pathText, home: home) else {
            error = "Đường dẫn không hợp lệ."
            pathText = BrowserPath.display(path, home: home)
            return
        }
        if !(await go(.visit(resolved))) { pathText = BrowserPath.display(path, home: home) }
    }

    func open(_ row: BrowserRow) async {
        guard row.isSupported else { return }
        if row.isDirectory || row.isSymlink {
            // Symlink: thử vào như thư mục, lỗi thì báo.
            await go(.visit(row.id))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: row.id))
        }
    }

    // MARK: - Thao tác

    func makeFolder(named name: String) throws {
        try service.mkdir(in: path, name: name)
    }

    func rename(_ row: BrowserRow, to newName: String) throws {
        try service.rename(path: row.id, newName: newName)
    }

    func trash(_ rows: [BrowserRow]) throws {
        for row in rows { try service.moveToTrash(path: row.id) }
    }

    func reveal(_ rows: [BrowserRow]) {
        if rows.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: $0.id) })
        }
    }
}
