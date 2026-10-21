import Foundation

/// Dữ liệu một server của project đưa vào `TopologyBuilder`.
public struct ServerSnapshot: Sendable {
    public var hostID: UUID
    public var displayName: String
    /// IP literal hoặc tên máy (chỉ IP literal được dùng để ánh xạ).
    public var hostName: String
    /// `nil` = không thu thập được.
    public var addresses: [InterfaceAddress]?
    /// `nil` = không thu thập được.
    public var sockets: [SocketRecord]?

    public init(
        hostID: UUID, displayName: String, hostName: String,
        addresses: [InterfaceAddress]? = nil, sockets: [SocketRecord]? = nil
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.hostName = hostName
        self.addresses = addresses
        self.sockets = sockets
    }
}

public struct ListenEntry: Hashable, Sendable {
    public var port: Int
    /// IP bind; `nil` nếu wildcard.
    public var bind: IPLiteral?
    public var isWildcard: Bool
    public var processes: [ProcessRef]?

    public var isLoopbackOnly: Bool { bind?.isLoopback ?? false }

    /// "0.0.0.0", "::", "127.0.0.1"...
    public var bindDisplay: String {
        if let bind { return bind.address }
        return "*"
    }

    /// Dạng hiển thị trong nút: "LISTEN :5432".
    public var label: String { "LISTEN :\(port)" }
}

public struct Flow: Hashable, Sendable {
    public var source: UUID
    public var destination: UUID
    public var port: Int
}

public struct TopologyFlow: Sendable, Equatable {
    public var flow: Flow
    /// Số kết nối ESTAB quan sát được (gộp trùng).
    public var observedConnections: Int
    /// IP đích mà nguồn đã thấy kết nối tới (theo thứ tự gặp).
    public var destinationIPs: [IPLiteral]
    public var sourceProcesses: [ProcessRef]
    /// `nil` nếu đích không thu thập được nên chưa xác minh LISTEN.
    public var destinationListen: ListenEntry?
    public var destinationVerified: Bool
}

public struct ServerNode: Sendable, Equatable {
    public var hostID: UUID
    public var displayName: String
    public var collected: Bool
    public var addresses: [IPLiteral]
    public var listening: [ListenEntry]
    /// Số kết nối ESTAB tới IP ngoài project (không tạo nút).
    public var externalConnections: Int
}

public enum TopologyWarning: Sendable, Equatable {
    /// Cùng một IP thuộc ≥ 2 server: không ánh xạ, không đoán.
    case duplicateIP(String, hostIDs: [UUID])
    case socketsNotCollected(hostID: UUID)
    case unparsedLines(hostID: UUID, count: Int)
}

public struct Topology: Sendable, Equatable {
    public var servers: [ServerNode]
    public var flows: [TopologyFlow]
    public var warnings: [TopologyWarning]

    public func node(_ id: UUID) -> ServerNode? { servers.first { $0.hostID == id } }
}

public enum TopologyBuilder {
    public static func build(_ snapshots: [ServerSnapshot]) -> Topology {
        var warnings: [TopologyWarning] = []

        // 1. IP → server (loại loopback/link-local/unspecified; trùng IP thì không ánh xạ).
        var owners: [IPLiteral: [UUID]] = [:]
        var order: [IPLiteral] = []
        var addressesByHost: [UUID: [IPLiteral]] = [:]
        for s in snapshots {
            var ips: [IPLiteral] = (s.addresses ?? []).map(\.ip)
            if let literal = IPLiteral(s.hostName) { ips.append(literal) }
            var seen = Set<IPLiteral>()
            let usable = ips.filter {
                !$0.isLoopback && !$0.isLinkLocal && !$0.isUnspecified && seen.insert($0).inserted
            }
            addressesByHost[s.hostID] = usable
            for ip in usable {
                if owners[ip] == nil { order.append(ip) }
                owners[ip, default: []].append(s.hostID)
            }
        }
        var ipToHost: [IPLiteral: UUID] = [:]
        for ip in order {
            let hosts = owners[ip] ?? []
            if hosts.count == 1 {
                ipToHost[ip] = hosts[0]
            } else {
                warnings.append(.duplicateIP(ip.address, hostIDs: hosts))
            }
        }

        // 2. LISTEN từng server.
        var listenByHost: [UUID: [ListenEntry]] = [:]
        for s in snapshots {
            guard let sockets = s.sockets else {
                warnings.append(.socketsNotCollected(hostID: s.hostID))
                continue
            }
            listenByHost[s.hostID] = listens(from: sockets)
        }

        // 3. Cạnh + đếm kết nối ngoài.
        var flowOrder: [Flow] = []
        var flows: [Flow: TopologyFlow] = [:]
        var external: [UUID: Int] = [:]
        for s in snapshots {
            guard let sockets = s.sockets else { continue }
            let ownListens = listenByHost[s.hostID] ?? []
            for rec in sockets where rec.state == .established {
                guard let peerIP = rec.peer.ip, let peerPort = rec.peer.port, peerPort > 0,
                    !peerIP.isLoopback, !peerIP.isUnspecified
                else { continue }
                // Kết nối vào cổng mà chính server này đang LISTEN là kết nối đến, không phải đi.
                if let lp = rec.local.port, ownListens.contains(where: { $0.port == lp }) { continue }
                guard let destID = ipToHost[peerIP] else {
                    if owners[peerIP] == nil { external[s.hostID, default: 0] += 1 }
                    continue
                }
                if destID == s.hostID { continue }
                var verifiedListen: ListenEntry?
                var verified = false
                if let destListens = listenByHost[destID] {
                    verified = true
                    verifiedListen = destListens.first {
                        $0.port == peerPort && ($0.isWildcard || $0.bind == peerIP)
                    }
                    if verifiedListen == nil { continue }
                }
                let key = Flow(source: s.hostID, destination: destID, port: peerPort)
                var entry =
                    flows[key]
                    ?? TopologyFlow(
                        flow: key, observedConnections: 0, destinationIPs: [], sourceProcesses: [],
                        destinationListen: verifiedListen, destinationVerified: verified)
                if flows[key] == nil { flowOrder.append(key) }
                entry.observedConnections += 1
                if !entry.destinationIPs.contains(peerIP) { entry.destinationIPs.append(peerIP) }
                for p in rec.processes ?? [] where !entry.sourceProcesses.contains(p) {
                    entry.sourceProcesses.append(p)
                }
                flows[key] = entry
            }
        }

        let nodes = snapshots.map { s in
            ServerNode(
                hostID: s.hostID, displayName: s.displayName, collected: s.sockets != nil,
                addresses: addressesByHost[s.hostID] ?? [],
                listening: listenByHost[s.hostID] ?? [],
                externalConnections: external[s.hostID] ?? 0)
        }
        return Topology(
            servers: nodes, flows: flowOrder.compactMap { flows[$0] }, warnings: warnings)
    }

    static func listens(from sockets: [SocketRecord]) -> [ListenEntry] {
        var result: [ListenEntry] = []
        for rec in sockets where rec.state == .listen {
            guard let port = rec.local.port else { continue }
            if let i = result.firstIndex(where: {
                $0.port == port && $0.bind == rec.local.ip && $0.isWildcard == rec.local.isWildcard
            }) {
                if let procs = rec.processes {
                    var merged = result[i].processes ?? []
                    for p in procs where !merged.contains(p) { merged.append(p) }
                    result[i].processes = merged
                }
            } else {
                result.append(
                    ListenEntry(
                        port: port, bind: rec.local.ip, isWildcard: rec.local.isWildcard,
                        processes: rec.processes))
            }
        }
        return result.sorted { ($0.port, $0.bindDisplay) < ($1.port, $1.bindDisplay) }
    }
}
