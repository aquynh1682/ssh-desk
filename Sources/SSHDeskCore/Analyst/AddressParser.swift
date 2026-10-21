import Foundation

public struct InterfaceAddress: Hashable, Sendable {
    public var interface: String
    public var ip: IPLiteral
    public var prefixLength: Int?
    public init(interface: String, ip: IPLiteral, prefixLength: Int?) {
        self.interface = interface
        self.ip = ip
        self.prefixLength = prefixLength
    }
}

public struct AddressParseResult: Sendable, Equatable {
    public var addresses: [InterfaceAddress]
    public var unparsed: Int

    /// IP dùng để ánh xạ IP → server: bỏ loopback, link-local, unspecified; khử trùng, giữ thứ tự.
    public var routableIPs: [IPLiteral] {
        var seen = Set<IPLiteral>()
        return addresses.map(\.ip).filter {
            !$0.isLoopback && !$0.isLinkLocal && !$0.isUnspecified && seen.insert($0).inserted
        }
    }
}

public enum AddressParser {
    /// `ip -o addr show`: `2: eth0    inet 10.0.0.5/24 brd ... scope global eth0\ valid_lft ...`.
    /// Chỉ lấy dòng `inet`/`inet6`; dòng khác (vd. `link/ether`) bỏ qua có kiểm soát nếu nhận ra, còn lại tính `unparsed`.
    public static func parseIPAddr(_ text: String) -> AddressParseResult {
        var out: [InterfaceAddress] = []
        var unparsed = 0
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if fields.isEmpty { continue }
            guard fields.count >= 4, fields[0].hasSuffix(":"), Int(fields[0].dropLast()) != nil else {
                unparsed += 1
                continue
            }
            let family = fields[2]
            if family == "link/ether" || family.hasPrefix("link/") { continue }
            guard family == "inet" || family == "inet6" else {
                unparsed += 1
                continue
            }
            let cidr = fields[3]
            let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
            guard let ip = IPLiteral(parts[0]) else {
                unparsed += 1
                continue
            }
            var iface = fields[1]
            if let at = iface.firstIndex(of: "@") { iface = String(iface[..<at]) }
            out.append(
                InterfaceAddress(
                    interface: iface, ip: ip, prefixLength: parts.count > 1 ? Int(parts[1]) : nil))
        }
        return AddressParseResult(addresses: out, unparsed: unparsed)
    }

    /// `hostname -I`: các IP cách nhau bằng khoảng trắng (có thể có khoảng trắng cuối dòng).
    public static func parseHostnameIPs(_ text: String) -> AddressParseResult {
        var out: [InterfaceAddress] = []
        var unparsed = 0
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if let ip = IPLiteral(String(token)) {
                out.append(InterfaceAddress(interface: "", ip: ip, prefixLength: nil))
            } else {
                unparsed += 1
            }
        }
        return AddressParseResult(addresses: out, unparsed: unparsed)
    }
}
