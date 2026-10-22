import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

@Suite struct PortForwardTests {
    private let hostID = UUID()

    private func fwd(
        name: String = "db", lp: Int = 5432, rh: String = "localhost", rp: Int = 5432
    ) -> PortForward {
        PortForward(hostID: hostID, name: name, localPort: lp, remoteHost: rh, remotePort: rp)
    }

    // MARK: - Validate

    @Test(arguments: [1024, 5432, 8080, 65535])
    func acceptsLocalPortsInRange(_ port: Int) throws {
        #expect(try fwd(lp: port).validated().localPort == port)
    }

    @Test(arguments: [-1, 0, 1, 22, 80, 443, 1023, 65536, 100_000])
    func rejectsLocalPortsOutOfRange(_ port: Int) {
        #expect(throws: PortForwardError.invalidLocalPort(port)) { try fwd(lp: port).validated() }
    }

    @Test(arguments: [0, -5, 65536, 99999])
    func rejectsRemotePortsOutOfRange(_ port: Int) {
        #expect(throws: PortForwardError.invalidRemotePort(port)) { try fwd(rp: port).validated() }
    }

    @Test(arguments: [1, 22, 5432, 65535])
    func acceptsRemotePorts(_ port: Int) throws {
        #expect(try fwd(rp: port).validated().remotePort == port)
    }

    @Test(arguments: [
        "localhost", "db", "db.internal", "10.0.0.5", "my-db_1.example.com", "[::1]",
        "[2001:db8::1]", "a",
    ])
    func acceptsRemoteHosts(_ host: String) throws {
        #expect(try fwd(rh: host).validated().remoteHost == host)
    }

    @Test(arguments: [
        "db host", "db\thost", "db\nhost", "db\rhost", "db:5432", "::1", "2001:db8::1",
        "-oProxyCommand=x", ".db", "db.", "-db", "db,evil", "db/x", "user@db", "db%eth0",
        "[::1", "::1]", "[]", "[db]", "[1.2.3.4]", "[fe80::1%en0]", "db;rm", "db$(x)", "db\u{0}x",
        "db\u{7F}", "dbé", "a b", "db\u{2028}x", "[::1]:5432", String(repeating: "a", count: 254),
    ])
    func rejectsRemoteHosts(_ host: String) {
        #expect(throws: PortForwardError.invalidRemoteHost(host)) { try fwd(rh: host).validated() }
    }

    @Test func emptyRemoteHostBecomesLocalhostAndInputIsTrimmed() throws {
        #expect(try fwd(rh: "").validated().remoteHost == "localhost")
        #expect(try fwd(rh: "   ").validated().remoteHost == "localhost")
        let v = try fwd(name: "  postgres  ", rh: " db.internal ").validated()
        #expect(v.name == "postgres" && v.remoteHost == "db.internal")
    }

    @Test func rejectsBadNames() {
        #expect(throws: PortForwardError.invalidName) { try fwd(name: "a\nb").validated() }
        #expect(throws: PortForwardError.invalidName) { try fwd(name: "a\u{1B}[0m").validated() }
        #expect(throws: PortForwardError.invalidName) {
            try fwd(name: String(repeating: "x", count: 101)).validated()
        }
        #expect(throws: Never.self) { try fwd(name: "").validated() }
    }

    @Test func summaryAndLocalAddress() {
        let f = fwd(lp: 15432, rh: "db", rp: 5432)
        #expect(f.localAddress == "127.0.0.1:15432")
        #expect(f.summary == "127.0.0.1:15432 → db:5432")
    }

    // MARK: - argv

    @Test func argvMatchesADR011Exactly() throws {
        let args = try TunnelCommand.arguments(
            configPath: "/Users/me/Library/Application Support/SSHDesk/ssh/config",
            alias: "sshdesk-abc", forward: fwd(lp: 15432, rh: "db.internal", rp: 5432))
        #expect(
            args == [
                "-F", "/Users/me/Library/Application Support/SSHDesk/ssh/config", "-N",
                "-o", "ExitOnForwardFailure=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-L", "127.0.0.1:15432:db.internal:5432", "--", "sshdesk-abc",
            ])
    }

    @Test func argvDefaultsRemoteHostAndBracketsIPv6() throws {
        let a = try TunnelCommand.arguments(configPath: "/c", alias: "a", forward: fwd(rh: ""))
        #expect(a.contains("127.0.0.1:5432:localhost:5432"))
        let b = try TunnelCommand.arguments(configPath: "/c", alias: "a", forward: fwd(rh: "[::1]"))
        #expect(b.contains("127.0.0.1:5432:[::1]:5432"))
    }

    @Test func argvRejectsInjectionInEveryField() {
        #expect(throws: (any Error).self) {
            try TunnelCommand.arguments(configPath: "/c", alias: "-oProxyCommand=x", forward: fwd())
        }
        #expect(throws: (any Error).self) {
            try TunnelCommand.arguments(configPath: "relative", alias: "a", forward: fwd())
        }
        #expect(throws: (any Error).self) {
            try TunnelCommand.arguments(configPath: "/c\n", alias: "a", forward: fwd())
        }
        #expect(throws: (any Error).self) {
            try TunnelCommand.arguments(configPath: "/c", alias: "a", forward: fwd(rh: "x -R 1:2:3"))
        }
        // Bind luôn 127.0.0.1, không có phần tử nào bind 0.0.0.0/*.
        let args =
            (try? TunnelCommand.arguments(configPath: "/c", alias: "a", forward: fwd())) ?? []
        #expect(!args.contains { $0.contains("0.0.0.0") || $0.hasPrefix("*:") })
    }

    // MARK: - Thử bind

    @Test func portProbeDetectsBusyAndFree() throws {
        let port = try TempSshd.freePort()
        #expect(!PortProbe.isBusy(port))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(r == 0)
        listen(fd, 1)
        #expect(PortProbe.isBusy(port))
        #expect(PortProbe.isBusy(0) && PortProbe.isBusy(70000))
    }

    @Test func failureReasonUsesLastMeaningfulLine() {
        let tail =
            "Warning: Permanently added 'x' to the list of known hosts.\nbind [127.0.0.1]:5432: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 5432\nCould not request local forwarding.\n"
        let r = TunnelManager.reason(exit: .exited(255), tail: tail, wasRunning: false)
        #expect(r == "ssh không mở được tunnel: Could not request local forwarding.")
        #expect(TunnelManager.reason(exit: .exited(255), tail: "", wasRunning: true).contains("mã 255"))
        #expect(TunnelManager.reason(exit: .signaled(9), tail: "", wasRunning: true).contains("tín hiệu 9"))
        let long = TunnelManager.reason(
            exit: .exited(1), tail: String(repeating: "x", count: 1000), wasRunning: false)
        #expect(long.count < 360)
    }
}

@Suite struct PortForwardRepositoryTests {
    private func setup(_ t: HostTempDir) throws -> (HostRepository, PortForwardRepository) {
        let db = try Database(url: t.dbURL)
        return (HostRepository(database: db), PortForwardRepository(database: db))
    }

    @Test func migrationV6CreatesTable() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        #expect(Database.migrations.count >= 6)
        let rows = try db.query("SELECT name FROM sqlite_master WHERE name='port_forwards'")
        #expect(rows.count == 1)
    }

    @Test func crudAndPersistence() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let host = managedHost("web")
        var id = UUID()
        do {
            let (hosts, repo) = try setup(t)
            try await hosts.insert(host)
            let saved = try await repo.add(
                PortForward(hostID: host.id, name: " pg ", localPort: 15432, remoteHost: "", remotePort: 5432))
            id = saved.id
            #expect(saved.name == "pg" && saved.remoteHost == "localhost")
            try await repo.add(PortForward(hostID: host.id, localPort: 18080, remoteHost: "web", remotePort: 80))
        }
        let (_, repo) = try setup(t)
        let list = try await repo.forwards(hostID: host.id)
        #expect(list.map(\.localPort) == [15432, 18080])
        #expect(try await repo.all().count == 2)

        var edit = try #require(await repo.forward(id: id))
        edit.localPort = 15433
        edit.remoteHost = "db.internal"
        edit.hostID = UUID()  // phải bị bỏ qua
        let updated = try await repo.update(edit)
        #expect(updated.hostID == host.id && updated.localPort == 15433 && updated.remoteHost == "db.internal")

        try await repo.delete(id: id)
        #expect(try await repo.forward(id: id) == nil)
        await #expect(throws: PortForwardError.notFound(id)) { try await repo.delete(id: id) }
    }

    @Test func localPortMustBeUniqueAcrossHosts() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let (hosts, repo) = try setup(t)
        let a = managedHost("a")
        let b = managedHost("b", hostName: "b.example.com")
        try await hosts.insert(a)
        try await hosts.insert(b)
        let first = try await repo.add(PortForward(hostID: a.id, localPort: 15432, remotePort: 5432))
        await #expect(throws: PortForwardError.localPortTaken(port: 15432, usedBy: first.id)) {
            try await repo.add(PortForward(hostID: b.id, localPort: 15432, remotePort: 5432))
        }
        let other = try await repo.add(PortForward(hostID: b.id, localPort: 15433, remotePort: 5432))
        var clash = other
        clash.localPort = 15432
        await #expect(throws: PortForwardError.localPortTaken(port: 15432, usedBy: first.id)) {
            try await repo.update(clash)
        }
        // Sửa giữ nguyên cổng của chính nó là hợp lệ.
        var same = other
        same.name = "đổi tên"
        #expect(try await repo.update(same).name == "đổi tên")
    }

    @Test func rejectsInvalidMissingHostAndWindowsHost() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let (hosts, repo) = try setup(t)
        let win = HostProfile(displayName: "win", kind: .windowsRDP, hostName: "10.0.0.9", port: 3389)
        try await hosts.insert(win)
        await #expect(throws: PortForwardError.hostNotSupported(win.id)) {
            try await repo.add(PortForward(hostID: win.id, localPort: 15432, remotePort: 1))
        }
        let ghost = UUID()
        await #expect(throws: PortForwardError.hostNotFound(ghost)) {
            try await repo.add(PortForward(hostID: ghost, localPort: 15432, remotePort: 1))
        }
        let ok = managedHost("ok")
        try await hosts.insert(ok)
        await #expect(throws: PortForwardError.invalidLocalPort(80)) {
            try await repo.add(PortForward(hostID: ok.id, localPort: 80, remotePort: 80))
        }
        await #expect(throws: PortForwardError.invalidRemoteHost("a b")) {
            try await repo.add(PortForward(hostID: ok.id, localPort: 15000, remoteHost: "a b", remotePort: 80))
        }
        #expect(try await repo.all().isEmpty)
    }

    @Test func deletingHostCascadesForwards() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let (hosts, repo) = try setup(t)
        let h = managedHost("x")
        try await hosts.insert(h)
        try await repo.add(PortForward(hostID: h.id, localPort: 15432, remotePort: 5432))
        try await hosts.delete(id: h.id)
        #expect(try await repo.all().isEmpty)
    }

    @Test func injectionStringsAreStoredVerbatimAsData() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let (hosts, repo) = try setup(t)
        let h = managedHost("x")
        try await hosts.insert(h)
        let nasty = "x'); DROP TABLE port_forwards;--"
        let saved = try await repo.add(
            PortForward(hostID: h.id, name: nasty, localPort: 15432, remotePort: 1))
        #expect(try await repo.forward(id: saved.id)?.name == nasty)
        #expect(try await repo.all().count == 1)
    }
}
