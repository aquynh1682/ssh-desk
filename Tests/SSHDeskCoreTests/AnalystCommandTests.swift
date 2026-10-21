import Foundation
import Testing

@testable import SSHDeskCore

struct AnalystCommandTests {
    @Test func fixedStrings() throws {
        let ip = try #require(IPLiteral("10.0.0.5"))
        let port = try #require(Port(5432))
        #expect(AnalystCommand.sockets.commandString == "ss -Htanp")
        #expect(AnalystCommand.socketsNoProcess.commandString == "ss -Htan")
        #expect(AnalystCommand.addresses.commandString == "ip -o addr show")
        #expect(AnalystCommand.hostnameIPs.commandString == "hostname -I")
        #expect(AnalystCommand.hostname.commandString == "hostname")
        #expect(
            AnalystCommand.probeBash(ip, port).commandString
                == "timeout 3 bash -c '</dev/tcp/10.0.0.5/5432'")
        #expect(AnalystCommand.probeNc(ip, port).commandString == "nc -z -w3 10.0.0.5 5432")
    }

    @Test func ipv6OnlyThroughNc() throws {
        let ip = try #require(IPLiteral("fd00::5"))
        let port = try #require(Port(22))
        #expect(AnalystCommand.probeBash(ip, port).commandString == nil)
        #expect(AnalystCommand.probeNc(ip, port).commandString == "nc -z -w3 -6 fd00::5 22")
    }

    @Test(arguments: [
        "", " ", "1.2.3.4;id", "1.2.3.4 ", " 1.2.3.4", "$(id)", "1.2.3.4$(id)", "1.2.3.4'", "'1.2.3.4",
        "1.2.3.4\n", "1.2.3.4\nid", "1.2.3.4\0evil", "db.example.com", "localhost", "1.2.3", "256.1.1.1",
        "1.2.3.4/32", "1.2.3.4`id`", "::1;id", "[::1]", "fe80::1%eth0", "1.2.3.4|id", "1.2.3.4&", "-1.2.3.4",
        "0x7f.0.0.1", "１.2.3.4", String(repeating: "1", count: 60),
    ])
    func rejectsBadIPs(_ bad: String) {
        #expect(IPLiteral(bad) == nil)
    }

    @Test func acceptsGoodIPsAndNormalizes() {
        #expect(IPLiteral("10.0.0.5")?.address == "10.0.0.5")
        #expect(IPLiteral("::1")?.isLoopback == true)
        #expect(IPLiteral("FD00:0:0:0:0:0:0:5")?.address == "fd00::5")
        #expect(IPLiteral("::ffff:10.0.0.1")?.address == "10.0.0.1")
        #expect(IPLiteral("127.0.0.53")?.isLoopback == true)
    }

    @Test(arguments: ["", "0", "65536", "-1", "22;id", "22 ", "2 2", "$(id)", "1e3", "٢٢", "+22", "999999"])
    func rejectsBadPorts(_ bad: String) {
        #expect(Port(bad) == nil)
    }

    @Test func portBounds() {
        #expect(Port(0) == nil)
        #expect(Port(1)?.value == 1)
        #expect(Port(65535)?.value == 65535)
        #expect(Port(65536) == nil)
        #expect(Port("8080")?.value == 8080)
    }

    @Test func commandStringsContainOnlySafeCharacters() throws {
        let ip = try #require(IPLiteral("10.0.0.5"))
        let port = try #require(Port(80))
        for c in [AnalystCommand.probeBash(ip, port), .probeNc(ip, port)] {
            let s = try #require(c.commandString)
            #expect(!s.contains(";") && !s.contains("$(") && !s.contains("\n") && !s.contains("`"))
        }
    }

    @Test func prodGuardListsExactCommands() throws {
        let ip = try #require(IPLiteral("10.0.0.5"))
        let port = try #require(Port(80))
        let a = UUID()
        let b = UUID()
        let p = ProdGuard.prompt(for: [
            ProdGuardServer(
                hostID: a, displayName: "db-01", environment: .prod,
                commands: ProdGuard.collectionCommands + [.probeBash(ip, port)]),
            ProdGuardServer(hostID: b, displayName: "dev-01", environment: .dev, commands: [.hostname]),
        ])
        #expect(p.requiresConfirmation)
        #expect(p.prodNames == ["db-01"])
        #expect(p.entries[0].commandStrings.contains("ss -Htanp"))
        #expect(p.entries[0].commandStrings.last == "timeout 3 bash -c '</dev/tcp/10.0.0.5/80'")
        #expect(p.message.contains("db-01 [PROD]"))
        #expect(p.message.contains("  hostname"))

        let none = ProdGuard.prompt(for: [
            ProdGuardServer(hostID: b, displayName: "dev-01", environment: .dev, commands: [.hostname])
        ])
        #expect(!none.requiresConfirmation)
    }
}
