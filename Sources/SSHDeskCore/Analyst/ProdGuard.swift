import Foundation

/// Một server sẽ bị chạy lệnh trong lần quét.
public struct ProdGuardServer: Sendable {
    public var hostID: UUID
    public var displayName: String
    public var environment: HostEnvironment
    public var commands: [AnalystCommand]

    public init(
        hostID: UUID, displayName: String, environment: HostEnvironment, commands: [AnalystCommand]
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.environment = environment
        self.commands = commands
    }
}

public struct ProdGuardEntry: Sendable, Equatable {
    public var hostID: UUID
    public var displayName: String
    public var environment: HostEnvironment
    /// Chuỗi lệnh CHÍNH XÁC sẽ gửi (đã bỏ lệnh không hỗ trợ).
    public var commandStrings: [String]
}

public struct ProdGuardPrompt: Sendable, Equatable {
    /// Có ít nhất một server PROD → phải hỏi xác nhận mỗi lần.
    public var requiresConfirmation: Bool
    public var entries: [ProdGuardEntry]
    public var prodNames: [String]

    /// Văn bản mô tả cho hộp xác nhận.
    public var message: String {
        var lines = [
            "Project có server PROD: \(prodNames.joined(separator: ", ")). Sẽ chạy các lệnh chỉ-xem sau:"
        ]
        for e in entries {
            lines.append("")
            lines.append("\(e.displayName) [\(e.environment.rawValue)]")
            for c in e.commandStrings { lines.append("  \(c)") }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ProdGuard {
    /// Lệnh thu thập (kể cả dự phòng) chạy trên MỌI server của project.
    public static let collectionCommands: [AnalystCommand] = [
        .sockets, .socketsNoProcess, .addresses, .hostnameIPs, .hostname,
    ]

    public static func prompt(for servers: [ProdGuardServer]) -> ProdGuardPrompt {
        let entries = servers.map {
            ProdGuardEntry(
                hostID: $0.hostID, displayName: $0.displayName, environment: $0.environment,
                commandStrings: $0.commands.compactMap(\.commandString))
        }
        let prod = servers.filter { $0.environment == .prod }.map(\.displayName)
        return ProdGuardPrompt(
            requiresConfirmation: !prod.isEmpty, entries: entries, prodNames: prod)
    }
}
