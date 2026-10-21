import Foundation

public struct ProcessRef: Hashable, Sendable {
    public var name: String
    public var pid: Int
    public init(name: String, pid: Int) {
        self.name = name
        self.pid = pid
    }
}

public enum SocketState: Hashable, Sendable {
    case listen, established, synSent, synRecv, finWait1, finWait2, timeWait, closeWait, lastAck, closing
    case unconnected
    case other(String)

    public init(_ text: String) {
        switch text.uppercased() {
        case "LISTEN": self = .listen
        case "ESTAB": self = .established
        case "SYN-SENT": self = .synSent
        case "SYN-RECV": self = .synRecv
        case "FIN-WAIT-1": self = .finWait1
        case "FIN-WAIT-2": self = .finWait2
        case "TIME-WAIT": self = .timeWait
        case "CLOSE-WAIT": self = .closeWait
        case "LAST-ACK": self = .lastAck
        case "CLOSING": self = .closing
        case "UNCONN": self = .unconnected
        default: self = .other(text)
        }
    }
}

/// Một đầu của socket. `ip == nil` khi là wildcard (`*`, `0.0.0.0`, `::`).
public struct SocketEndpoint: Hashable, Sendable {
    public var ip: IPLiteral?
    public var isWildcard: Bool
    /// `nil` khi ss in `*` (peer của socket LISTEN).
    public var port: Int?

    public init(ip: IPLiteral?, isWildcard: Bool, port: Int?) {
        self.ip = ip
        self.isWildcard = isWildcard
        self.port = port
    }

    public var hostDisplay: String {
        if isWildcard { return ip?.address ?? "*" }
        return ip?.address ?? "?"
    }
}

public struct SocketRecord: Hashable, Sendable {
    public var state: SocketState
    public var local: SocketEndpoint
    public var peer: SocketEndpoint
    /// `nil` = cột Process vắng (không đủ quyền / không dùng `-p`).
    public var processes: [ProcessRef]?

    public init(
        state: SocketState, local: SocketEndpoint, peer: SocketEndpoint, processes: [ProcessRef]? = nil
    ) {
        self.state = state
        self.local = local
        self.peer = peer
        self.processes = processes
    }
}

public struct SocketTableResult: Sendable, Equatable {
    public var records: [SocketRecord]
    public var unparsed: Int
}

/// Parse `ss -H -t -a -n [-p]` (iproute2): `State Recv-Q Send-Q Local:Port Peer:Port [Process]`.
public enum SocketTableParser {
    public static func parse(_ text: String) -> SocketTableResult {
        var records: [SocketRecord] = []
        var unparsed = 0
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let r = parseLine(trimmed) { records.append(r) } else { unparsed += 1 }
        }
        return SocketTableResult(records: records, unparsed: unparsed)
    }

    static func parseLine(_ line: String) -> SocketRecord? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 5, Int(fields[1]) != nil, Int(fields[2]) != nil,
            let local = parseEndpoint(fields[3]), let peer = parseEndpoint(fields[4])
        else { return nil }
        let rest = fields.dropFirst(5).joined(separator: " ")
        return SocketRecord(
            state: SocketState(fields[0]), local: local, peer: peer, processes: parseProcesses(rest))
    }

    /// `[::1]:22`, `*:22`, `0.0.0.0:5432`, `127.0.0.53%lo:53`, `[::ffff:10.0.0.1]:80`,
    /// và dạng không ngoặc của iproute2 cũ (`:::22`, `::1:22`).
    static func parseEndpoint(_ text: String) -> SocketEndpoint? {
        var host: String
        var portText: String
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            portText = String(after.dropFirst())
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = String(text[..<colon])
            portText = String(text[text.index(after: colon)...])
        }
        var port: Int?
        if portText == "*" {
            port = nil
        } else {
            guard let p = Int(portText), (0...65535).contains(p) else { return nil }
            port = p
        }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        if host == "*" { return SocketEndpoint(ip: nil, isWildcard: true, port: port) }
        guard let ip = IPLiteral(host) else { return nil }
        return SocketEndpoint(ip: ip, isWildcard: ip.isUnspecified, port: port)
    }

    /// `users:(("postgres",pid=812,fd=5),("x",pid=3,fd=4))`. Không có `users:` → `nil`.
    static func parseProcesses(_ text: String) -> [ProcessRef]? {
        guard let start = text.range(of: "users:(") else { return nil }
        var refs: [ProcessRef] = []
        var rest = text[start.upperBound...]
        while let open = rest.range(of: "(\"") {
            let afterOpen = rest[open.upperBound...]
            guard let sep = afterOpen.range(of: "\",pid=") else { break }
            let name = String(afterOpen[..<sep.lowerBound])
            let digits = afterOpen[sep.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
            if let pid = Int(digits) { refs.append(ProcessRef(name: name, pid: pid)) }
            rest = afterOpen[sep.upperBound...]
        }
        return refs.isEmpty ? nil : refs
    }
}
