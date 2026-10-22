import Foundation

/// Whitelist lệnh Monitor (ADR-019). Chuỗi lệnh là hằng số, không ghép input nào từ người dùng/server.
/// Chỉ-xem, không sudo.
public enum MonitorCommand: Sendable, Equatable, CaseIterable {
    /// `/proc/stat` + `/proc/meminfo` + `/proc/loadavg` + `/proc/uptime` trong một lần gọi.
    case procFiles
    case cpuCount
    case diskUsage

    public var commandString: String {
        switch self {
        case .procFiles: return "cat /proc/stat /proc/meminfo /proc/loadavg /proc/uptime"
        case .cpuCount: return "nproc"
        case .diskUsage: return "df -P -k"
        }
    }

    public var primaryTool: String {
        switch self {
        case .procFiles: return "cat"
        case .cpuCount: return "nproc"
        case .diskUsage: return "df"
        }
    }

    /// Các chuỗi lệnh thật sự gửi đi (cho hộp xác nhận PROD).
    public static var allCommandStrings: [String] { allCases.map(\.commandString) }
}

/// Nơi thực thi lệnh Monitor (thật: `RemoteCommandRunner`; test: giả). API chỉ nhận enum whitelist.
public protocol MonitorCommandExecuting: Sendable {
    func execute(_ command: MonitorCommand) async throws -> RemoteCommandResult
}

extension RemoteCommandRunner: MonitorCommandExecuting {
    public func execute(_ command: MonitorCommand) async throws -> RemoteCommandResult {
        try await executeRaw(command.commandString, toolHint: command.primaryTool)
    }
}
