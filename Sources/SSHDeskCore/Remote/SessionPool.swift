import Foundation

/// Sổ đăng ký các `RemoteSession` đang sống, theo hostID (socket cũng theo hostID nên một host chỉ có
/// một master). Màn Truyền file đăng ký phiên của tab; Project Analyst tái dùng phiên đó thay vì mở
/// master thứ hai (ADR-013/016).
public actor SessionPool {
    public enum Owner: Sendable, Equatable {
        /// Tab của màn Truyền file: do tab đóng.
        case browser
        /// Phiên do Project Analyst tự mở: Analyst đóng khi xong.
        case analyst
    }

    private struct Entry {
        let session: RemoteSession
        let owner: Owner
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    public func register(hostID: UUID, session: RemoteSession, owner: Owner) {
        entries[hostID] = Entry(session: session, owner: owner)
    }

    /// Chỉ gỡ nếu đúng phiên đã đăng ký (phiên cũ muộn không gỡ nhầm phiên mới).
    public func unregister(hostID: UUID, session: RemoteSession) {
        if let e = entries[hostID], e.session === session { entries[hostID] = nil }
    }

    public func owner(of hostID: UUID) -> Owner? { entries[hostID]?.owner }

    /// Phiên còn sống của host (kiểm tra `-O check`); phiên chết bị gỡ khỏi sổ.
    public func liveSession(for hostID: UUID) async -> RemoteSession? {
        guard let e = entries[hostID] else { return nil }
        if await e.session.checkAlive() { return e.session }
        if let now = entries[hostID], now.session === e.session { entries[hostID] = nil }
        return nil
    }

    public func registeredHostIDs() -> Set<UUID> { Set(entries.keys) }
}
