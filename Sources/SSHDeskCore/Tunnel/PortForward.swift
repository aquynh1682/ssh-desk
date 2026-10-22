import Darwin
import Foundation

public enum PortForwardError: Error, Equatable {
    /// Cổng local phải trong 1024–65535.
    case invalidLocalPort(Int)
    case invalidRemotePort(Int)
    case invalidRemoteHost(String)
    case invalidName
    /// Cổng local đã được một forward khác của app dùng (`usedBy` = id forward đó).
    case localPortTaken(port: Int, usedBy: UUID)
    case hostNotFound(UUID)
    /// Máy Windows không có forward.
    case hostNotSupported(UUID)
    case notFound(UUID)
}

/// Một local forward đã lưu: `127.0.0.1:localPort` → `remoteHost:remotePort` (phía server). ADR-011.
public struct PortForward: Codable, Sendable, Identifiable, Equatable {
    public static let defaultRemoteHost = "localhost"
    public static let minLocalPort = 1024
    public static let maxNameLength = 100
    public static let maxRemoteHostLength = 253

    public var id: UUID
    public var hostID: UUID
    public var name: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(), hostID: UUID, name: String = "", localPort: Int,
        remoteHost: String = PortForward.defaultRemoteHost, remotePort: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.createdAt = createdAt
    }

    /// Địa chỉ người dùng nối vào, vd `127.0.0.1:5432`.
    public var localAddress: String { "127.0.0.1:\(localPort)" }

    /// Mô tả ngắn `127.0.0.1:5432 → db.internal:5432`.
    public var summary: String { "\(localAddress) → \(remoteHost):\(remotePort)" }

    /// Bản đã chuẩn hoá (trim, remoteHost rỗng → `localhost`) và đã kiểm tra. Ném `PortForwardError`.
    public func validated() throws -> PortForward {
        var f = self
        f.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        f.remoteHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.remoteHost.isEmpty { f.remoteHost = Self.defaultRemoteHost }
        if f.name.count > Self.maxNameLength
            || f.name.unicodeScalars.contains(where: Self.isControl)
        {
            throw PortForwardError.invalidName
        }
        guard (Self.minLocalPort...65535).contains(f.localPort) else {
            throw PortForwardError.invalidLocalPort(f.localPort)
        }
        guard (1...65535).contains(f.remotePort) else {
            throw PortForwardError.invalidRemotePort(f.remotePort)
        }
        guard Self.isValidRemoteHost(f.remoteHost) else {
            throw PortForwardError.invalidRemoteHost(f.remoteHost)
        }
        return f
    }

    /// Hostname / IPv4 (`[A-Za-z0-9._-]`, không bắt đầu hay kết thúc bằng `.`/`-`), hoặc IPv6 literal
    /// BẮT BUỘC nằm trong `[ ]`. Cấm khoảng trắng, ký tự điều khiển, `:` ngoài `[ ]`, `,` `/` `@` `%`...
    /// (các ký tự này có thể làm lệch cú pháp `-L bind:port:host:port`).
    public static func isValidRemoteHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= maxRemoteHostLength else { return false }
        if host.unicodeScalars.contains(where: { isControl($0) || $0.properties.isWhitespace }) {
            return false
        }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), host.count > 2 else { return false }
            let inner = String(host.dropFirst().dropLast())
            guard inner.contains(":"), !inner.contains("%") else { return false }
            var addr = in6_addr()
            return inet_pton(AF_INET6, inner, &addr) == 1
        }
        return host.range(
            of: #"^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value)
            || s.value == 0x2028 || s.value == 0x2029
    }
}
