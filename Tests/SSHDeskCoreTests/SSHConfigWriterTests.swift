import Foundation
import Testing

@testable import SSHDeskCore

@Suite struct SSHConfigWriterTests {
    let bastion = SSHHostSpec(
        alias: "sshdesk-aaaaaaaa-0000-0000-0000-000000000001", hostName: "bastion.example.com",
        port: 2200, user: "jump")
    func target(
        alias: String = "sshdesk-bbbbbbbb-0000-0000-0000-000000000002",
        hostName: String = "10.0.0.5", port: Int = 22, user: String = "deploy",
        identityFile: String? = nil, jumpAlias: String? = nil
    ) -> SSHHostSpec {
        SSHHostSpec(
            alias: alias, hostName: hostName, port: port, user: user,
            identityFile: identityFile, jumpAlias: jumpAlias)
    }

    @Test func exactLayoutWithBastionAndInclude() throws {
        let host = target(identityFile: "/Users/me/.ssh/id_ed25519", jumpAlias: bastion.alias)
        let out = try SSHConfigWriter.render(
            hosts: [host, bastion], userConfigPath: "/Users/me/.ssh/config")
        let expected = """
            # Do SSH Desk sinh — không sửa tay
            Host sshdesk-bbbbbbbb-0000-0000-0000-000000000002
                HostName "10.0.0.5"
                Port 22
                User "deploy"
                IdentityFile "/Users/me/.ssh/id_ed25519"
                IdentitiesOnly yes
                ProxyJump sshdesk-aaaaaaaa-0000-0000-0000-000000000001
            Host sshdesk-aaaaaaaa-0000-0000-0000-000000000001
                HostName "bastion.example.com"
                Port 2200
                User "jump"
            Match all
            Include "/Users/me/.ssh/config"

            """
        #expect(out == expected)
    }

    @Test func matchAllPrecedesIncludeAndOmittedWithoutConfig() throws {
        let out = try SSHConfigWriter.render(hosts: [bastion], userConfigPath: "/a/config")
        let m = try #require(out.range(of: "Match all"))
        let i = try #require(out.range(of: "Include"))
        #expect(m.lowerBound < i.lowerBound)
        let none = try SSHConfigWriter.render(hosts: [bastion], userConfigPath: nil)
        #expect(!none.contains("Match all") && !none.contains("Include"))
        #expect(!none.contains("IdentitiesOnly"))
    }

    @Test func escapesQuotesBackslashesAndSpaces() throws {
        let host = target(identityFile: #"/Users/me/My Keys/a"b\c"#)
        let out = try SSHConfigWriter.render(hosts: [host], userConfigPath: nil)
        #expect(out.contains(#"    IdentityFile "/Users/me/My Keys/a\"b\\c""#))
    }

    @Test func rejectsControlCharactersInEveryField() {
        let bad = ["a\nProxyCommand touch /tmp/x", "a\rb", "a\u{0}b", "a\u{1B}b", "a\tb"]
        for v in bad {
            func fails(_ h: SSHHostSpec, _ cfg: String? = nil) {
                #expect(throws: SSHConfigError.self) {
                    try SSHConfigWriter.render(hosts: [h], userConfigPath: cfg)
                }
            }
            fails(target(alias: v))
            fails(target(hostName: v))
            fails(target(user: v))
            fails(target(identityFile: "/x/" + v))
            fails(target(jumpAlias: v))
            fails(target(), "/x/" + v)
            #expect(throws: SSHConfigError.self) {
                try SSHConfigWriter.sshInvocation(configPath: "/x/" + v, alias: "ok")
            }
            #expect(throws: SSHConfigError.self) {
                try SSHConfigWriter.sshInvocation(configPath: "/x/c", alias: v)
            }
        }
        #expect(
            throws: SSHConfigError.controlCharacter(field: "identityFile")
        ) {
            try SSHConfigWriter.render(
                hosts: [target(identityFile: "/k\nProxyCommand touch /tmp/x")], userConfigPath: nil)
        }
    }

    @Test func rejectsBadAliasHostUserPort() {
        for a in ["", "-x", "a b", "a/b", ".a", "a\"b", "a*"] {
            #expect(throws: SSHConfigError.invalidAlias(a)) {
                try SSHConfigWriter.render(hosts: [target(alias: a)], userConfigPath: nil)
            }
        }
        for h in ["", "-oProxyCommand=x", "a b", "a;b", "a\"b", "::zz", "1.2.3.4 "] {
            #expect(throws: SSHConfigError.self) {
                try SSHConfigWriter.render(hosts: [target(hostName: h)], userConfigPath: nil)
            }
        }
        for u in ["", "-oFoo", "a b", "a@b", "a\"b"] {
            #expect(throws: SSHConfigError.invalidUser(u)) {
                try SSHConfigWriter.render(hosts: [target(user: u)], userConfigPath: nil)
            }
        }
        for p in [0, -1, 65536] {
            #expect(throws: SSHConfigError.invalidPort(p)) {
                try SSHConfigWriter.render(hosts: [target(port: p)], userConfigPath: nil)
            }
        }
        #expect(throws: Never.self) {
            try SSHConfigWriter.render(
                hosts: [
                    target(hostName: "2001:db8::1", user: "_svc.1"),
                    target(alias: "web-1", hostName: "host.example.com", port: 65535),
                ], userConfigPath: nil)
        }
    }

    @Test func rejectsDuplicateSelfJumpAndCycles() {
        let a = target(alias: "a")
        #expect(throws: SSHConfigError.duplicateAlias("a")) {
            try SSHConfigWriter.render(hosts: [a, a], userConfigPath: nil)
        }
        #expect(throws: SSHConfigError.selfJump("a")) {
            try SSHConfigWriter.render(hosts: [target(alias: "a", jumpAlias: "a")], userConfigPath: nil)
        }
        let x = target(alias: "x", jumpAlias: "y")
        let y = target(alias: "y", jumpAlias: "x")
        #expect(throws: SSHConfigError.self) {
            try SSHConfigWriter.render(hosts: [x, y], userConfigPath: nil)
        }
        let p = target(alias: "p", jumpAlias: "q")
        let q = target(alias: "q", jumpAlias: "r")
        let r = target(alias: "r", jumpAlias: "q")
        #expect(throws: SSHConfigError.self) {
            try SSHConfigWriter.render(hosts: [p, q, r], userConfigPath: nil)
        }
        // Jump tới alias ngoài danh sách (config của user) là hợp lệ.
        #expect(throws: Never.self) {
            try SSHConfigWriter.render(
                hosts: [target(alias: "p", jumpAlias: "bastion")], userConfigPath: nil)
        }
    }

    @Test func rejectsRelativeTildeAndPercentPaths() {
        for path in ["~/.ssh/id", "rel/id", "./id", "~root/id"] {
            #expect(throws: SSHConfigError.pathNotAbsolute(field: "identityFile")) {
                try SSHConfigWriter.render(
                    hosts: [target(identityFile: path)], userConfigPath: nil)
            }
            #expect(throws: SSHConfigError.pathNotAbsolute(field: "userConfigPath")) {
                try SSHConfigWriter.render(hosts: [target()], userConfigPath: path)
            }
            #expect(throws: SSHConfigError.pathNotAbsolute(field: "configPath")) {
                try SSHConfigWriter.sshInvocation(configPath: path, alias: "a")
            }
        }
        #expect(throws: SSHConfigError.unsupportedPathCharacter(field: "identityFile")) {
            try SSHConfigWriter.render(hosts: [target(identityFile: "/k/%d")], userConfigPath: nil)
        }
    }

    @Test func sshInvocationIsArgv() throws {
        let argv = try SSHConfigWriter.sshInvocation(configPath: "/a b/config", alias: "sshdesk-1")
        #expect(argv == ["-F", "/a b/config", "sshdesk-1"])
        #expect(throws: SSHConfigError.invalidAlias("-oProxyCommand=x")) {
            try SSHConfigWriter.sshInvocation(configPath: "/c", alias: "-oProxyCommand=x")
        }
    }

    @Test func writeCreatesFileWith0600AndParent0700() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sshdesk-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("ssh/config")
        try SSHConfigWriter.write(to: url, hosts: [bastion], userConfigPath: nil)
        func perms(_ u: URL) throws -> Int {
            (try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try perms(url) == 0o600)
        #expect(try perms(url.deletingLastPathComponent()) == 0o700)
        // Ghi đè lần 2 vẫn 0600, nội dung mới, không để file tạm.
        try SSHConfigWriter.write(
            to: url, hosts: [bastion, target()], userConfigPath: "/a/config")
        #expect(try perms(url) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Include"))
        #expect(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["config"])
        // Lỗi validate thì không ghi gì.
        let bad = root.appendingPathComponent("other/config")
        #expect(throws: SSHConfigError.self) {
            try SSHConfigWriter.write(to: bad, hosts: [target(user: "a\nb")], userConfigPath: nil)
        }
        #expect(!fm.fileExists(atPath: bad.path))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")))
    func sshDashGAgreesWithRenderedConfig() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sshdesk-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let host = target(
            hostName: "target.example.com", port: 2222, user: "deploy",
            jumpAlias: bastion.alias)
        let url = root.appendingPathComponent("config")
        try SSHConfigWriter.write(to: url, hosts: [host, bastion], userConfigPath: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + (try SSHConfigWriter.sshInvocation(configPath: url.path, alias: host.alias))
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let lines = Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(lines.contains("hostname target.example.com"))
        #expect(lines.contains("port 2222"))
        #expect(lines.contains("user deploy"))
        #expect(lines.contains("proxyjump \(bastion.alias)"))
    }
}
