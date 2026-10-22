import AppKit
import Foundation

/// Mặt phẳng tối thiểu của pasteboard để test bằng bản giả (ADR-018).
public protocol SecretPasteboard: Sendable {
    var changeCount: Int { get }
    /// Xoá toàn bộ nội dung; trả `changeCount` mới.
    @discardableResult func clearContents() -> Int
    /// Thay nội dung bằng một item gồm `.string` + các kiểu đánh dấu (dữ liệu rỗng); trả `changeCount` mới.
    func write(string: String, markerTypes: [String]) -> Int
}

/// NSPasteboard.general. NSPasteboard dùng được từ thread nền.
public struct SystemSecretPasteboard: SecretPasteboard, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public var changeCount: Int { pasteboard.changeCount }

    @discardableResult public func clearContents() -> Int { pasteboard.clearContents() }

    public func write(string: String, markerTypes: [String]) -> Int {
        pasteboard.clearContents()
        let types = [NSPasteboard.PasteboardType.string] + markerTypes.map { .init($0) }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(string, forType: .string)
        for t in markerTypes { pasteboard.setData(Data(), forType: .init(t)) }
        return pasteboard.changeCount
    }
}

/// Đặt bí mật lên clipboard, đánh dấu ẩn với trình quản lý clipboard và tự xoá sau hạn — chỉ khi
/// clipboard vẫn là giá trị app đặt (so `changeCount`). Không lưu, không log nội dung bí mật.
public final class SecretClipboard: @unchecked Sendable {
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"

    /// Hẹn giờ: nhận số giây + hành động, trả hàm huỷ hẹn.
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> @Sendable () -> Void

    private let pasteboard: any SecretPasteboard
    private let schedule: Scheduler
    private let lock = NSLock()
    private var ownedChangeCount: Int?
    private var cancelTimer: (@Sendable () -> Void)?

    public init(
        pasteboard: any SecretPasteboard = SystemSecretPasteboard(),
        scheduler: @escaping Scheduler = SecretClipboard.dispatchScheduler
    ) {
        self.pasteboard = pasteboard
        self.schedule = scheduler
    }

    public static let dispatchScheduler: Scheduler = { delay, action in
        nonisolated(unsafe) let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// Copy `secret`; xoá clipboard cũ do app đặt (nếu còn) trước. Tự xoá sau `clearAfter` giây.
    public func copy(_ secret: String, clearAfter: TimeInterval = 30) {
        lock.lock()
        defer { lock.unlock() }
        clearIfOwnedLocked()
        cancelTimer?()
        let count = pasteboard.write(
            string: secret, markerTypes: [Self.concealedType, Self.transientType])
        ownedChangeCount = count
        cancelTimer = schedule(clearAfter) { [weak self] in self?.timerFired(count) }
    }

    /// Gọi khi thoát app: xoá ngay nếu clipboard vẫn là giá trị app đặt.
    public func clearNowIfOwned() {
        lock.lock()
        defer { lock.unlock() }
        cancelTimer?()
        cancelTimer = nil
        clearIfOwnedLocked()
    }

    private func timerFired(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard ownedChangeCount == count else { return }
        cancelTimer = nil
        clearIfOwnedLocked()
    }

    private func clearIfOwnedLocked() {
        guard let owned = ownedChangeCount else { return }
        ownedChangeCount = nil
        if pasteboard.changeCount == owned { pasteboard.clearContents() }
    }
}
