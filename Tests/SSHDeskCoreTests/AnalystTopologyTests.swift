import Foundation
import Testing

@testable import SSHDeskCore

enum AnalystFixtures {
    static let fe = UUID()
    static let be = UUID()
    static let api = UUID()
    static let db = UUID()
    static let cache = UUID()

    static func addrs(_ ip: String) -> [InterfaceAddress] {
        [
            InterfaceAddress(interface: "lo", ip: IPLiteral("127.0.0.1")!, prefixLength: 8),
            InterfaceAddress(interface: "eth0", ip: IPLiteral(ip)!, prefixLength: 24),
        ]
    }

    static func sockets(_ text: String) -> [SocketRecord] { SocketTableParser.parse(text).records }

    /// fe-01 -> be-01:8080 -> api-01:9000 -> db-01:5432 / cache-01:6379
    static func mockup() -> [ServerSnapshot] {
        [
            ServerSnapshot(
                hostID: fe, displayName: "fe-01", hostName: "10.0.0.1", addresses: addrs("10.0.0.1"),
                sockets: sockets(
                    """
                    LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=10,fd=6))
                    ESTAB 0 0 10.0.0.1:40001 10.0.0.2:8080 users:(("nginx",pid=11,fd=9))
                    ESTAB 0 0 10.0.0.1:40002 10.0.0.2:8080 users:(("nginx",pid=11,fd=10))
                    ESTAB 0 0 10.0.0.1:50000 203.0.113.9:443
                    ESTAB 0 0 10.0.0.1:443 198.51.100.7:51234
                    """)),
            ServerSnapshot(
                hostID: be, displayName: "be-01", hostName: "10.0.0.2", addresses: addrs("10.0.0.2"),
                sockets: sockets(
                    """
                    LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("java",pid=20,fd=4))
                    ESTAB 0 0 10.0.0.2:8080 10.0.0.1:40001
                    ESTAB 0 0 10.0.0.2:41000 10.0.0.3:9000 users:(("java",pid=20,fd=30))
                    """)),
            ServerSnapshot(
                hostID: api, displayName: "api-01", hostName: "10.0.0.3", addresses: addrs("10.0.0.3"),
                sockets: sockets(
                    """
                    LISTEN 0 128 *:9000 *:* users:(("node",pid=30,fd=4))
                    ESTAB 0 0 10.0.0.3:9000 10.0.0.2:41000
                    ESTAB 0 0 10.0.0.3:42000 10.0.0.4:5432 users:(("node",pid=30,fd=11))
                    ESTAB 0 0 10.0.0.3:42001 10.0.0.5:6379 users:(("node",pid=30,fd=12))
                    ESTAB 0 0 10.0.0.3:42002 8.8.8.8:443
                    ESTAB 0 0 10.0.0.3:42003 8.8.4.4:443
                    TIME-WAIT 0 0 10.0.0.3:42004 10.0.0.4:5432
                    """)),
            ServerSnapshot(
                hostID: db, displayName: "db-01", hostName: "10.0.0.4", addresses: addrs("10.0.0.4"),
                sockets: sockets(
                    """
                    LISTEN 0 244 0.0.0.0:5432 0.0.0.0:* users:(("postgres",pid=812,fd=5))
                    LISTEN 0 244 [::]:5432 [::]:*
                    ESTAB 0 0 10.0.0.4:5432 10.0.0.3:42000
                    """)),
            ServerSnapshot(
                hostID: cache, displayName: "cache-01", hostName: "10.0.0.5", addresses: addrs("10.0.0.5"),
                sockets: sockets(
                    """
                    LISTEN 0 511 10.0.0.5:6379 0.0.0.0:* users:(("redis-server",pid=40,fd=6))
                    ESTAB 0 0 10.0.0.5:6379 10.0.0.3:42001
                    """)),
        ]
    }
}

struct AnalystTopologyTests {
    typealias F = AnalystFixtures

    @Test func mockupGraph() throws {
        let t = TopologyBuilder.build(F.mockup())
        let keys = t.flows.map {
            "\($0.flow.source == F.fe ? "fe" : $0.flow.source == F.be ? "be" : "api")>\($0.flow.port)"
        }
        #expect(
            Set(keys) == ["fe>8080", "be>9000", "api>5432", "api>6379"])
        #expect(t.flows.count == 4)
        #expect(t.warnings.isEmpty)

        let feBe = try #require(t.flows.first { $0.flow.source == F.fe })
        #expect(feBe.flow.destination == F.be)
        #expect(feBe.observedConnections == 2)  // gộp trùng
        #expect(feBe.sourceProcesses == [ProcessRef(name: "nginx", pid: 11)])
        #expect(feBe.destinationListen?.processes == [ProcessRef(name: "java", pid: 20)])
        #expect(feBe.destinationIPs.map(\.address) == ["10.0.0.2"])
        #expect(feBe.destinationVerified)

        let toDb = try #require(t.flows.first { $0.flow.port == 5432 })
        #expect(toDb.flow.source == F.api && toDb.flow.destination == F.db)
        #expect(toDb.observedConnections == 1)  // TIME-WAIT không tính
    }

    @Test func listenListAndExternalCounts() throws {
        let t = TopologyBuilder.build(F.mockup())
        let db = try #require(t.node(F.db))
        #expect(db.listening.map(\.label) == ["LISTEN :5432", "LISTEN :5432"])
        #expect(db.listening.contains { $0.processes?.first?.name == "postgres" })
        // fe-01: 1 kết nối ra IP ngoài; kết nối vào :443 (inbound) không tính là ra ngoài
        #expect(t.node(F.fe)?.externalConnections == 1)
        #expect(t.node(F.api)?.externalConnections == 2)
        #expect(t.node(F.be)?.externalConnections == 0)
        #expect(t.node(F.fe)?.addresses.map(\.address) == ["10.0.0.1"])
    }

    @Test func loopbackOnlyListenIsNotReachableFromOthers() {
        var snaps = F.mockup()
        // db chỉ listen 127.0.0.1:5432
        snaps[3].sockets = F.sockets(
            """
            LISTEN 0 244 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=812,fd=5))
            """)
        let t = TopologyBuilder.build(snaps)
        #expect(!t.flows.contains { $0.flow.port == 5432 })
        let db = t.node(F.db)
        #expect(db?.listening.first?.isLoopbackOnly == true)
    }

    @Test func bindToSpecificIPMatchesOnlyThatIP() {
        // cache-01 bind 10.0.0.5 và api kết nối tới đúng 10.0.0.5 => có; bind IP khác => không
        var snaps = F.mockup()
        #expect(TopologyBuilder.build(snaps).flows.contains { $0.flow.port == 6379 })
        snaps[4].sockets = F.sockets("LISTEN 0 511 10.9.9.9:6379 0.0.0.0:*")
        #expect(!TopologyBuilder.build(snaps).flows.contains { $0.flow.port == 6379 })
    }

    @Test func duplicateIPIsWarnedNotGuessed() {
        var snaps = F.mockup()
        // cache-01 trùng IP với db-01
        snaps[4].addresses = F.addrs("10.0.0.4")
        snaps[4].hostName = "10.0.0.4"
        let t = TopologyBuilder.build(snaps)
        #expect(t.warnings.contains(.duplicateIP("10.0.0.4", hostIDs: [F.db, F.cache])))
        #expect(!t.flows.contains { $0.flow.port == 5432 })
        // kết nối tới IP trùng không bị tính "ngoài project"
        // cache-01 mất IP 10.0.0.5 nên kết nối tới đó thành "ngoài project" (+1)
        #expect(t.node(F.api)?.externalConnections == 3)
    }

    @Test func serverWithoutCollectedDataStillMappedByHostName() throws {
        var snaps = F.mockup()
        snaps[3].addresses = nil
        snaps[3].sockets = nil  // db-01 không thu thập được, hostName là IP
        let t = TopologyBuilder.build(snaps)
        #expect(t.warnings.contains(.socketsNotCollected(hostID: F.db)))
        let f = try #require(t.flows.first { $0.flow.port == 5432 })
        #expect(f.flow.destination == F.db)
        #expect(!f.destinationVerified && f.destinationListen == nil)
        #expect(t.node(F.db)?.collected == false)
    }

    @Test func hostnameThatIsNotAnIPIsNotUsedForMapping() {
        var snaps = F.mockup()
        snaps[3].addresses = nil
        snaps[3].hostName = "db.internal.example"
        let t = TopologyBuilder.build(snaps)
        // 10.0.0.4 là "ngoài project" vì không biết thuộc ai
        #expect(!t.flows.contains { $0.flow.port == 5432 })
        #expect(t.node(F.api)?.externalConnections == 3)
    }

    @Test func inboundConnectionOnOwnListenPortIsNotAnOutgoingFlow() {
        // be-01 thấy ESTAB local :8080 peer fe-01:40001 -> không được sinh be->fe:40001
        let t = TopologyBuilder.build(F.mockup())
        #expect(!t.flows.contains { $0.flow.port == 40001 || $0.flow.port == 41000 || $0.flow.port == 42000 })
    }

    @Test func ipv6AddressesMap() throws {
        let a = UUID()
        let b = UUID()
        let t = TopologyBuilder.build([
            ServerSnapshot(
                hostID: a, displayName: "a", hostName: "a.example",
                addresses: [
                    InterfaceAddress(interface: "eth0", ip: IPLiteral("fd00::1")!, prefixLength: 64)
                ],
                sockets: F.sockets("ESTAB 0 0 [fd00::1]:50000 [fd00::2]:443")),
            ServerSnapshot(
                hostID: b, displayName: "b", hostName: "fd00::2",
                sockets: F.sockets("LISTEN 0 128 [::]:443 [::]:*")),
        ])
        let f = try #require(t.flows.first)
        #expect(f.flow.source == a && f.flow.destination == b && f.flow.port == 443)
        #expect(f.destinationIPs.first?.version == .v6)
    }
}
