import Darwin
import Foundation

/// IPv4/IPv6 literal đã validate bằng `inet_pton` (ADR-016). Lưu dạng chuẩn hoá (IPv6 nén, thường;
/// `::ffff:a.b.c.d` quy về IPv4). Không bao giờ chứa ký tự ngoài `[0-9a-fA-F:.]` nên an toàn để ghép vào lệnh.
public struct IPLiteral: Hashable, Sendable, CustomStringConvertible {
    public enum Version: Sendable { case v4, v6 }

    public let version: Version
    /// Dạng chuẩn hoá.
    public let address: String
    let bytes: [UInt8]

    public var description: String { address }

    public init?(_ raw: String) {
        // Kiểm tra byte trước: `withCString` cắt tại NUL nên "1.2.3.4\0evil" sẽ lọt nếu bỏ qua bước này.
        let utf8 = Array(raw.utf8)
        guard !utf8.isEmpty, utf8.count <= 45 else { return nil }
        let allowed = Set("0123456789abcdefABCDEF:.".utf8)
        guard utf8.allSatisfy({ allowed.contains($0) }) else { return nil }

        if !raw.contains(":") {
            var a = in_addr()
            guard inet_pton(AF_INET, raw, &a) == 1 else { return nil }
            let b = withUnsafeBytes(of: &a) { Array($0) }
            self.init(v4Bytes: b)
        } else {
            var a = in6_addr()
            guard inet_pton(AF_INET6, raw, &a) == 1 else { return nil }
            let b = withUnsafeBytes(of: &a) { Array($0) }
            let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
            if mapped {
                self.init(v4Bytes: Array(b[12..<16]))
            } else {
                var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var copy = a
                guard inet_ntop(AF_INET6, &copy, &out, socklen_t(out.count)) != nil else { return nil }
                self.init(v6Bytes: b, address: String(cString: out))
            }
        }
    }

    private init(v6Bytes b: [UInt8], address: String) {
        version = .v6
        self.address = address
        bytes = b
    }

    private init?(v4Bytes b: [UInt8]) {
        guard b.count == 4 else { return nil }
        version = .v4
        address = b.map(String.init).joined(separator: ".")
        bytes = b
    }

    public var isLoopback: Bool {
        switch version {
        case .v4: return bytes[0] == 127
        case .v6: return bytes == [UInt8](repeating: 0, count: 15) + [1]
        }
    }

    public var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }

    public var isLinkLocal: Bool {
        switch version {
        case .v4: return bytes[0] == 169 && bytes[1] == 254
        case .v6: return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        }
    }
}

/// Cổng TCP 1–65535.
public struct Port: Hashable, Sendable, CustomStringConvertible {
    public let value: Int
    public var description: String { String(value) }

    public init?(_ value: Int) {
        guard (1...65535).contains(value) else { return nil }
        self.value = value
    }

    /// Chỉ chữ số ASCII, tối đa 5 ký tự.
    public init?(_ text: String) {
        let u = Array(text.utf8)
        guard !u.isEmpty, u.count <= 5, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
            let v = Int(text)
        else { return nil }
        self.init(v)
    }
}

/// Whitelist lệnh Project Analyst (ADR-016). Chuỗi lệnh đến từ hằng số; chỉ `IPLiteral` và `Port`
/// (đã validate ở kiểu) được ghép vào.
public enum AnalystCommand: Sendable, Equatable {
    case sockets
    case socketsNoProcess
    case addresses
    case hostnameIPs
    case hostname
    case probeBash(IPLiteral, Port)
    case probeNc(IPLiteral, Port)

    /// Chuỗi gửi cho shell remote. `nil` nếu không hỗ trợ: probe bash chỉ cho IPv4 (hỗ trợ IPv6 trong
    /// `/dev/tcp` chưa được xác minh trên mọi bản bash → IPv6 chỉ probe bằng `nc -6`).
    public var commandString: String? {
        switch self {
        case .sockets: return "ss -Htanp"
        case .socketsNoProcess: return "ss -Htan"
        case .addresses: return "ip -o addr show"
        case .hostnameIPs: return "hostname -I"
        case .hostname: return "hostname"
        case .probeBash(let ip, let port):
            guard ip.version == .v4 else { return nil }
            return "timeout 3 bash -c '</dev/tcp/\(ip.address)/\(port.value)'"
        case .probeNc(let ip, let port):
            let family = ip.version == .v6 ? "-6 " : ""
            return "nc -z -w3 \(family)\(ip.address) \(port.value)"
        }
    }

    /// Tên công cụ chính (để báo "thiếu công cụ").
    public var primaryTool: String {
        switch self {
        case .sockets, .socketsNoProcess: return "ss"
        case .addresses: return "ip"
        case .hostnameIPs, .hostname: return "hostname"
        case .probeBash: return "timeout"
        case .probeNc: return "nc"
        }
    }
}
