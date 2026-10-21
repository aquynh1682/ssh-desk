import Foundation
import Testing

@testable import SSHDeskCore

/// Fixture viết theo định dạng output của iproute2 `ss -H -t -a -n -p` và `ip -o addr show` trên Linux
/// (man ss(8), ip-address(8)); không lấy từ server thật.
struct AnalystParserTests {
    static let ssFixture = """
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=701,fd=3))
        LISTEN 0      244        127.0.0.1:5432       0.0.0.0:*    users:(("postgres",pid=812,fd=5))
        LISTEN 0      4096               *:8080             *:*    users:(("java",pid=900,fd=12),("java",pid=901,fd=12))
        LISTEN 0      128             [::]:22            [::]:*
        LISTEN 0      128            [::1]:631           [::]:*    users:(("cupsd",pid=44,fd=7))
        ESTAB  0      0         10.0.0.2:44321     10.0.0.3:9000  users:(("nginx",pid=15,fd=9))
        ESTAB  0      0     [::ffff:10.0.0.2]:80  [::ffff:10.0.0.1]:55000
        ESTAB  0      0     [fe80::1%eth0]:22   [fe80::2%eth0]:5555
        TIME-WAIT 0   0         10.0.0.2:44400     10.0.0.3:9000
        UNCONN 0      0     127.0.0.53%lo:53         0.0.0.0:*
        """

    @Test func parsesSocketTable() {
        let r = SocketTableParser.parse(Self.ssFixture)
        #expect(r.unparsed == 0)
        #expect(r.records.count == 10)

        let ssh = r.records[0]
        #expect(ssh.state == .listen)
        #expect(ssh.local.port == 22 && ssh.local.isWildcard)
        #expect(ssh.peer.port == nil)
        #expect(ssh.processes == [ProcessRef(name: "sshd", pid: 701)])

        let pg = r.records[1]
        #expect(pg.local.ip?.address == "127.0.0.1" && !pg.local.isWildcard)
        #expect(pg.local.ip?.isLoopback == true)

        let star = r.records[2]
        #expect(star.local.isWildcard && star.local.ip == nil && star.local.port == 8080)
        #expect(star.processes?.count == 2)

        let v6 = r.records[3]
        #expect(v6.local.isWildcard && v6.local.ip?.version == .v6)
        #expect(v6.processes == nil)
        #expect(r.records[4].local.ip?.address == "::1")

        #expect(r.records[5].state == .established)
        #expect(r.records[5].peer.ip?.address == "10.0.0.3" && r.records[5].peer.port == 9000)

        // ::ffff:a.b.c.d quy về IPv4
        #expect(r.records[6].local.ip?.address == "10.0.0.2")
        #expect(r.records[6].peer.ip?.address == "10.0.0.1")
        // %iface bị bỏ
        #expect(r.records[7].local.ip?.address == "fe80::1")
        #expect(r.records[7].local.ip?.isLinkLocal == true)
        #expect(r.records[8].state == .timeWait)
        #expect(r.records[9].state == .unconnected)
        #expect(r.records[9].local.ip?.address == "127.0.0.53")
    }

    @Test func legacyUnbracketedIPv6() {
        let r = SocketTableParser.parse(
            "LISTEN 0 128 :::22 :::*\nESTAB 0 0 ::1:22 ::1:40000\n")
        #expect(r.unparsed == 0)
        #expect(r.records[0].local.isWildcard && r.records[0].local.port == 22)
        #expect(r.records[1].local.ip?.address == "::1" && r.records[1].local.port == 22)
    }

    @Test func countsUnparsedLines() {
        let text = """
            LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
            this is not a socket line
            ESTAB x y 1.2.3.4:1 5.6.7.8:2
            ESTAB 0 0 notanip:1 5.6.7.8:2

            LISTEN 0 128 0.0.0.0:99999 0.0.0.0:*
            """
        let r = SocketTableParser.parse(text)
        #expect(r.records.count == 1)
        #expect(r.unparsed == 4)
    }

    @Test func processNamesWithSpacesAndMultiple() {
        let r = SocketTableParser.parse(
            #"LISTEN 0 1 0.0.0.0:80 0.0.0.0:* users:(("Web Content",pid=5,fd=1),("b",pid=6,fd=2))"#)
        #expect(r.records[0].processes == [ProcessRef(name: "Web Content", pid: 5), ProcessRef(name: "b", pid: 6)])
    }

    static let ipFixture = """
        1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever
        1: lo    inet6 ::1/128 scope host \\       valid_lft forever preferred_lft forever
        2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0\\       valid_lft forever preferred_lft forever
        2: eth0    inet6 fd00::5/64 scope global \\       valid_lft forever preferred_lft forever
        2: eth0    inet6 fe80::a00:27ff:fe4e:66a1/64 scope link \\       valid_lft forever preferred_lft forever
        3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever preferred_lft forever
        """

    @Test func parsesIpAddr() {
        let r = AddressParser.parseIPAddr(Self.ipFixture)
        #expect(r.unparsed == 0)
        #expect(r.addresses.count == 6)
        #expect(r.addresses[2].interface == "eth0" && r.addresses[2].prefixLength == 24)
        // routable: bỏ loopback và link-local
        #expect(r.routableIPs.map(\.address) == ["10.0.0.5", "fd00::5", "172.17.0.1"])
    }

    @Test func parsesHostnameI() {
        let r = AddressParser.parseHostnameIPs("10.0.0.5 172.17.0.1 fd00::5 \n")
        #expect(r.unparsed == 0)
        #expect(r.routableIPs.map(\.address) == ["10.0.0.5", "172.17.0.1", "fd00::5"])
        #expect(AddressParser.parseHostnameIPs("server.example.com").unparsed == 1)
    }

    @Test func unknownIpLinesAreCounted() {
        let r = AddressParser.parseIPAddr("garbage\n2: eth0 inet 10.0.0.5/24 scope global\n")
        #expect(r.addresses.count == 1)
        #expect(r.unparsed == 1)
    }
}
