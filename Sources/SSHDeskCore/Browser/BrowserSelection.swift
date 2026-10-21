import Foundation

/// Chọn nhiều dòng kiểu Finder: click thường, ⌘-click (thêm/bớt), ⇧-click (dải từ mốc).
public struct BrowserSelection: Equatable, Sendable {
    public enum Modifier: Sendable { case none, command, shift }

    public private(set) var selected: Set<String> = []
    public private(set) var anchor: String?

    public init() {}

    public mutating func click(_ id: String, modifier: Modifier, order: [String]) {
        switch modifier {
        case .none:
            selected = [id]
            anchor = id
        case .command:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        case .shift:
            guard let a = anchor, let i = order.firstIndex(of: id),
                let j = order.firstIndex(of: a)
            else {
                selected = [id]
                anchor = id
                return
            }
            selected = Set(order[min(i, j)...max(i, j)])
        }
    }

    public mutating func clear() {
        selected = []
        anchor = nil
    }

    public mutating func selectAll(_ order: [String]) {
        selected = Set(order)
        anchor = order.first
    }

    /// Bỏ các id không còn tồn tại (sau khi làm mới / đổi thư mục).
    public mutating func retain(_ valid: Set<String>) {
        selected.formIntersection(valid)
        if let a = anchor, !valid.contains(a) { anchor = selected.first }
    }

    /// Các id sẽ được kéo khi bắt đầu kéo từ `id`: dòng đã chọn → cả vùng chọn (theo thứ tự hiển thị),
    /// ngược lại chỉ dòng đó.
    public func dragIDs(from id: String, order: [String]) -> [String] {
        guard selected.contains(id) else { return [id] }
        return order.filter { selected.contains($0) }
    }
}

/// Lịch sử lùi/tiến. Hai bước: hỏi đích (`backTarget`), tải xong mới `commit…` (tải lỗi thì không đổi).
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    public init(start: String) { current = start }

    public var backTarget: String? { backStack.last }
    public var forwardTarget: String? { forwardStack.last }
    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Đi tới thư mục mới (xoá nhánh tiến). Cùng thư mục hiện tại → không đổi.
    public mutating func commitVisit(_ path: String) {
        guard path != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = path
    }

    public mutating func commitBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(current)
        current = target
    }

    public mutating func commitForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(current)
        current = target
    }
}
