import Foundation

/// Một dòng của `sshdesk list`. Cố ý KHÔNG có credentialReference, ghi chú, đường dẫn key (ADR-025).
public struct CLIHostEntry: Equatable, Sendable, Encodable {
    public let id: String
    public let name: String
    public let alias: String?
    public let folder: String?
    public let environment: String
    public let kind: String
    public let hostName: String
    public let port: Int
    public let user: String

    public init(_ h: HostProfile) {
        id = h.id.uuidString.lowercased()
        name = h.displayName
        alias = h.connectionMode == .existingSSHConfigAlias ? h.sshConfigAlias : nil
        folder = h.project.isEmpty ? nil : h.project
        environment = h.environment.rawValue
        kind = h.kind.rawValue
        hostName = h.hostName
        port = h.port
        user = h.user
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, alias, folder, environment, kind, hostName, port, user
    }

    /// Luôn ghi đủ khoá (alias/folder không có -> null) để script không phải đoán.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(alias, forKey: .alias)
        try c.encode(folder, forKey: .folder)
        try c.encode(environment, forKey: .environment)
        try c.encode(kind, forKey: .kind)
        try c.encode(hostName, forKey: .hostName)
        try c.encode(port, forKey: .port)
        try c.encode(user, forKey: .user)
    }
}

public enum CLIHostList {
    /// Lọc theo thư mục (không phân biệt hoa thường/dấu) rồi giữ thứ tự đầu vào.
    public static func entries(_ hosts: [HostProfile], folder: String?) -> [CLIHostEntry] {
        hosts.filter { h in
            guard let folder else { return true }
            return HostFolders.sameFolder(h.project, folder)
        }.map(CLIHostEntry.init)
    }

    public static func json(_ entries: [CLIHostEntry]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try enc.encode(entries), as: UTF8.self)
    }

    /// Bảng gọn; ký tự điều khiển trong tên bị bỏ để không bơm escape vào terminal.
    public static func table(_ entries: [CLIHostEntry]) -> String {
        guard !entries.isEmpty else { return "(không có máy chủ nào)" }
        let header = ["TÊN", "MÔI TRƯỜNG", "THƯ MỤC", "KẾT NỐI", "ID"]
        var rows: [[String]] = [header]
        for e in entries {
            let target: String
            if let a = e.alias, e.hostName.isEmpty {
                target = a
            } else {
                target = (e.user.isEmpty ? "" : e.user + "@") + e.hostName + (e.port == 22 ? "" : ":\(e.port)")
            }
            rows.append([e.name, e.environment, e.folder ?? "-", target, e.id].map(HostResolver.printable))
        }
        let widths = (0..<header.count).map { c in rows.map { $0[c].count }.max() ?? 0 }
        return rows.map { row in
            zip(row, widths).enumerated().map { i, pair in
                i == row.count - 1 ? pair.0 : pair.0.padding(toLength: pair.1, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}
