import Foundation

/// Trạng thái kết nối của một tab (một host = một master).
public enum BrowserTabState: Equatable, Sendable {
    case connecting
    /// Master đang chờ người dùng/Keychain trả lời prompt.
    case awaitingAuth
    case connected
    /// Mất kết nối hoặc không kết nối được; chuỗi là lý do đã làm sạch.
    case disconnected(String)
}

public enum BrowserTabEvent: Sendable, Equatable {
    case session(SessionEvent)
    /// Đã trả lời prompt (người dùng hoặc tự điền).
    case answered
    case reconnecting
    case startFailed(String)
    /// Một thao tác file báo `RemoteFileError.sessionLost`.
    case sessionLost
}

public enum BrowserTabReducer {
    public static func reduce(_ state: BrowserTabState, _ event: BrowserTabEvent) -> BrowserTabState {
        switch (state, event) {
        case (.connecting, .session(.authPrompt)), (.awaitingAuth, .session(.authPrompt)):
            return .awaitingAuth
        case (.awaitingAuth, .answered):
            return .connecting
        case (.connecting, .session(.connected)), (.awaitingAuth, .session(.connected)):
            return .connected
        case (.disconnected, .session(.disconnected)), (.disconnected, .sessionLost),
            (.disconnected, .startFailed):
            return state  // giữ lý do đầu tiên
        case (_, .session(.disconnected(let reason))):
            return .disconnected(reason)
        case (_, .startFailed(let reason)):
            return .disconnected(reason)
        case (.connected, .sessionLost), (.connecting, .sessionLost), (.awaitingAuth, .sessionLost):
            return .disconnected("Mất kết nối tới máy chủ.")
        case (.disconnected, .reconnecting):
            return .connecting
        default:
            return state
        }
    }
}

public enum BrowserTabPresentation {
    public enum Dot: Sendable, Equatable { case green, yellow, red }

    public static func dot(_ state: BrowserTabState) -> Dot {
        switch state {
        case .connected: return .green
        case .connecting, .awaitingAuth: return .yellow
        case .disconnected: return .red
        }
    }

    public static func statusText(_ state: BrowserTabState) -> String {
        switch state {
        case .connected: return "Đã kết nối SFTP"
        case .connecting: return "Đang kết nối…"
        case .awaitingAuth: return "Chờ xác thực…"
        case .disconnected: return "Mất kết nối"
        }
    }

    /// Lý do kèm theo khi mất kết nối (hiển thị nhỏ).
    public static func detail(_ state: BrowserTabState) -> String? {
        if case .disconnected(let reason) = state, !reason.isEmpty { return reason }
        return nil
    }

    public static func canReconnect(_ state: BrowserTabState) -> Bool {
        if case .disconnected = state { return true }
        return false
    }

    public static func isBrowsable(_ state: BrowserTabState) -> Bool { state == .connected }

    /// `user@host` (managed) hoặc alias (imported).
    public static func identity(_ host: HostProfile) -> String {
        switch host.connectionMode {
        case .managed: return "\(host.user)@\(host.hostName)"
        case .existingSSHConfigAlias: return host.sshConfigAlias ?? host.displayName
        }
    }

    public static func sessionCount(_ states: [BrowserTabState]) -> Int {
        states.filter { $0 == .connected }.count
    }

    public static func sessionsText(_ count: Int) -> String { "\(count) phiên đang kết nối" }
}

public struct HostPickerGroup: Equatable, Sendable {
    public let environment: HostEnvironment
    public let hosts: [HostProfile]
}

/// Popover chọn host để mở tab: nhóm theo môi trường (PROD trước), tìm theo tên/host/user/alias.
public enum HostPicker {
    public static func groups(_ hosts: [HostProfile], query: String) -> [HostPickerGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func hit(_ s: String) -> Bool {
            q.isEmpty || s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let matching = hosts.filter {
            hit($0.displayName) || hit($0.hostName) || hit($0.user) || hit($0.sshConfigAlias ?? "")
                || hit($0.project)
        }
        return HostPresentation.environmentOrder.compactMap { env in
            let list = HostPresentation.sortedByName(
                matching.filter { $0.environment == env }, ascending: true)
            return list.isEmpty ? nil : HostPickerGroup(environment: env, hosts: list)
        }
    }

    /// Host thiếu alias SSH thì không mở được.
    public static func isSelectable(_ host: HostProfile) -> Bool { host.sshAlias != nil }
}
