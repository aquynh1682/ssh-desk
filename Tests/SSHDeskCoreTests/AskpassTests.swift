import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - AskpassDecision (bảng ca thử)

private struct Case {
    var name: String
    var prompt: String
    var type: String? = nil
    var ref: String? = "ref-1"
    var parent: String? = "/usr/bin/ssh"
    var alreadyUsed = false
    var expect: AskpassAction
}

private let tableCases: [Case] = [
    Case(
        name: "password đúng host lần 1", prompt: "deploy@web.example.com's password: ",
        expect: .answerFromKeychain(ref: "ref-1")),
    Case(
        name: "password kiểu keyboard-interactive", prompt: "(deploy@web) Password: ",
        expect: .answerFromKeychain(ref: "ref-1")),
    Case(
        name: "password lần 2 (đã dùng)", prompt: "deploy@web.example.com's password: ",
        alreadyUsed: true, expect: .askTTY(echo: false)),
    Case(name: "không có ref", prompt: "deploy@web's password: ", ref: nil, expect: .askTTY(echo: false)),
    Case(name: "ref rỗng", prompt: "deploy@web's password: ", ref: "", expect: .askTTY(echo: false)),
    Case(
        name: "cha không phải ssh", prompt: "deploy@web's password: ", parent: "/bin/sh",
        expect: .askTTY(echo: false)),
    Case(
        name: "cha giả /tmp/ssh", prompt: "deploy@web's password: ", parent: "/tmp/ssh",
        expect: .askTTY(echo: false)),
    Case(
        name: "không rõ cha", prompt: "deploy@web's password: ", parent: nil,
        expect: .askTTY(echo: false)),
    Case(
        name: "passphrase", prompt: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ",
        expect: .askTTY(echo: false)),
    Case(
        name: "kbd-int Verification code", prompt: "(deploy@web) Verification code: ",
        expect: .askTTY(echo: false)),
    Case(
        name: "kbd-int password nhưng cha không phải ssh", prompt: "(deploy@web) Password: ",
        parent: "/bin/sh", expect: .askTTY(echo: false)),
    Case(name: "OTP", prompt: "Verification code: ", expect: .askTTY(echo: false)),
    Case(name: "OTP kết thúc bằng password:", prompt: "OTP password: ", expect: .askTTY(echo: false)),
    Case(name: "token password", prompt: "Token password: ", expect: .askTTY(echo: false)),
    Case(name: "đổi password", prompt: "New password: ", expect: .askTTY(echo: false)),
    Case(name: "retype", prompt: "Retype new password: ", expect: .askTTY(echo: false)),
    Case(
        name: "host key", prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
        type: "confirm", expect: .askTTY(echo: true)),
    Case(
        name: "host key không có SSH_ASKPASS_PROMPT",
        prompt:
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? ",
        expect: .askTTY(echo: true)),
    Case(
        name: "type=confirm ghi đè mọi thứ", prompt: "Password: ", type: "confirm",
        expect: .askTTY(echo: true)),
    Case(name: "thông báo", prompt: "Authenticated to host", type: "none", expect: .showOnly),
    Case(
        name: "hostname chứa otp không phải từ", prompt: "deploy@hotpot's password: ",
        expect: .answerFromKeychain(ref: "ref-1")),
    Case(name: "câu hỏi lạ", prompt: "Username: ", expect: .askTTY(echo: false)),
]

@Test func askpassDecisionTable() {
    for c in tableCases {
        var claims = 0
        let action = AskpassDecision.decide(
            prompt: c.prompt, promptType: c.type, hostRef: c.ref, parentPath: c.parent,
            claimUse: {
                claims += 1
                return !c.alreadyUsed
            })
        #expect(action == c.expect, "\(c.name): \(action)")
        // Chỉ "tiêu" lần dùng khi thực sự sẽ trả password.
        if case .answerFromKeychain = c.expect {
            #expect(claims == 1, "\(c.name)")
        } else {
            #expect(claims <= 1, "\(c.name)")
        }
    }
    // Cha sai / không có ref: không bao giờ chạm vào claim.
    var touched = false
    _ = AskpassDecision.decide(
        prompt: "x's password: ", promptType: nil, hostRef: "r", parentPath: "/bin/sh",
        claimUse: {
            touched = true
            return true
        })
    #expect(!touched)
}

@Test func multilineHostKeyPromptWithoutPromptTypeIsConfirmWithNewlines() {
    let prompt =
        "The authenticity of host 'h (1.2.3.4)' can't be established.\nED25519 key fingerprint is: SHA256:abc.\nThis key is not known by any other names.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
    #expect(AskpassDecision.classify(prompt: prompt, promptType: nil) == .confirm)
    let action = AskpassDecision.decide(
        prompt: prompt, promptType: nil, hostRef: "r", parentPath: "/usr/bin/ssh",
        claimUse: { true })
    #expect(action == .askTTY(echo: true))
    #expect(AskpassDecision.sanitizeForDisplay(prompt).filter { $0 == "\n" }.count == 3)
}

@Test func askpassSecondAskInSameProcessGoesToTTY() {
    // Mô phỏng claim nguyên tử: lần đầu true, sau đó false.
    var used = false
    let claim = { () -> Bool in
        defer { used = true }
        return !used
    }
    func ask() -> AskpassAction {
        AskpassDecision.decide(
            prompt: "u@h's password: ", promptType: nil, hostRef: "r",
            parentPath: "/usr/bin/ssh", claimUse: claim)
    }
    #expect(ask() == .answerFromKeychain(ref: "r"))
    #expect(ask() == .askTTY(echo: false))
}

@Test func sanitizeStripsControlCharacters() {
    let hostile = "Password:\u{1B}[2J\u{07}\r\nfake\u{9B}x"
    let clean = AskpassDecision.sanitizeForDisplay(hostile)
    #expect(!clean.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x0A })
    #expect(!clean.contains("\u{1B}"))
}

// MARK: - Lệnh Warp có askpass (chạy qua zsh thật với executable thay ssh)

private func makeFakeSSH(in dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("fake ssh's")  // tên có space + nháy
    try Data("#!/bin/sh\nenv\nfor a in \"$@\"; do echo \"ARG=$a\"; done\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func runZsh(_ command: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-f", "-c", command]
    p.environment = ["PATH": "/usr/bin:/bin"]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
func askpassCommandSetsOnlyReferenceInEnvironment() throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let fake = try makeFakeSSH(in: dir.url)
    let helper = "/Applications/SSH Desk's/sshdesk-askpass"
    let ref = "9a1b2c3d-0000-4000-8000-123456789abc"
    let cmd = try ZshQuoting.askpassSshCommand(
        helperPath: helper, hostRef: ref, sshPath: fake.path, configPath: "/tmp/a b/config",
        alias: "sshdesk-x")
    #expect(cmd.hasPrefix("SSH_ASKPASS='"))
    let out = try runZsh(cmd)
    let lines = Set(out.split(separator: "\n").map(String.init))
    #expect(lines.contains("SSH_ASKPASS=\(helper)"))
    #expect(lines.contains("SSH_ASKPASS_REQUIRE=force"))
    #expect(lines.contains("SSHDESK_HOST_REF=\(ref)"))
    #expect(lines.contains("ARG=-F"))
    #expect(lines.contains("ARG=/tmp/a b/config"))
    #expect(lines.contains("ARG=sshdesk-x"))
    #expect(lines.contains("ARG=-o") && lines.contains("ARG=BatchMode=no"))
    #expect(!out.lowercased().contains("password"))
    // Ref độc hại vẫn chỉ là một giá trị.
    let evil = try ZshQuoting.askpassSshCommand(
        helperPath: helper, hostRef: "x'; touch \(dir.url.path)/pwned; '", sshPath: fake.path,
        configPath: "/c", alias: "a")
    _ = try runZsh(evil)
    #expect(!FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("pwned").path))
}

// MARK: - ConnectionService + lưu trữ

private struct SvcEnv {
    let dir = HostTempDir()
    let store = InMemoryCredentialStore()
    let paths: AppPaths
    let repo: HostRepository
    let service: ConnectionService
    let helper = URL(fileURLWithPath: "/Applications/SSH Desk.app/Contents/MacOS/sshdesk-askpass")
    var tabDir: URL { dir.url.appendingPathComponent("tabs") }

    private final class Warp: WarpURLHandler, @unchecked Sendable {
        func isWarpAvailable() -> Bool { true }
        func open(_ url: URL) async -> Bool { true }
    }

    init(helper hasHelper: Bool = true) throws {
        paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
        try paths.prepareDirectories()
        repo = HostRepository(database: try Database(url: paths.databaseURL))
        service = ConnectionService(
            repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
            launcher: WarpLauncher(
                tabConfigsDirectory: dir.url.appendingPathComponent("tabs"), handler: Warp()),
            credentials: store, askpassHelper: hasHelper ? helper : nil)
    }

    func tomlText(_ id: UUID) throws -> String {
        try String(
            contentsOf: tabDir.appendingPathComponent("sshdesk_\(id.uuidString.lowercased()).toml"),
            encoding: .utf8)
    }
}

@Test func savePasswordCreatesReferenceAndDbHoldsNoPassword() async throws {
    let env = try SvcEnv()
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    let saved = try await env.service.savePassword(hostID: h.id, password: "Pw-Zx81-secret")
    let ref = try #require(saved.credentialReference)
    #expect(UUID(uuidString: ref) != nil)
    #expect(env.store.read(ref: ref) == "Pw-Zx81-secret")
    #expect(try await env.repo.host(id: h.id)?.credentialReference == ref)
    // Lưu lại: giữ nguyên ref.
    let again = try await env.service.savePassword(hostID: h.id, password: "Pw-2-secret")
    #expect(again.credentialReference == ref)
    #expect(env.store.read(ref: ref) == "Pw-2-secret")
    // Không có password trong DB / config / TOML.
    try await env.service.regenerateSSHConfig()
    _ = await env.service.openInWarp(again)
    let base = env.paths.baseDirectory
    let files = FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []
    for f in files {
        guard let d = FileManager.default.contents(atPath: base.appendingPathComponent(f).path) else {
            continue
        }
        for secret in ["Pw-Zx81-secret", "Pw-2-secret"] { #expect(d.range(of: Data(secret.utf8)) == nil, "\(f)") }
    }
    let toml = try env.tomlText(h.id)
    #expect(!toml.contains("secret"))
    #expect(toml.contains(ref))

    // Xoá mật khẩu.
    let cleared = try await env.service.clearPassword(hostID: h.id)
    #expect(cleared.credentialReference == nil)
    #expect(!env.store.exists(ref: ref))
    // Xoá host xoá item.
    let again2 = try await env.service.savePassword(hostID: h.id, password: "x1")
    let ref2 = try #require(again2.credentialReference)
    try await env.service.delete(id: h.id)
    #expect(!env.store.exists(ref: ref2))
}

@Test func importedHostGetsReferenceToo() async throws {
    let env = try SvcEnv()
    defer { env.dir.cleanup() }
    let h = importedHost()
    try await env.service.add(h)
    let saved = try await env.service.savePassword(hostID: h.id, password: "imp-pw")
    #expect(saved.credentialReference != nil)
    let (cmd, notice) = try await env.service.warpSSHCommand(for: saved)
    #expect(notice == nil)
    #expect(cmd.contains("SSHDESK_HOST_REF='\(saved.credentialReference ?? "")'"))
    #expect(cmd.contains("'web-u'"))
    try await env.service.delete(id: h.id)
    #expect(!env.store.exists(ref: saved.credentialReference ?? ""))
}

@Test func warpCommandVariants() async throws {
    let env = try SvcEnv()
    defer { env.dir.cleanup() }
    let plainHost = managedHost("plain", hostName: "a.example.com")
    try await env.service.add(plainHost)
    var (cmd, notice) = try await env.service.warpSSHCommand(for: plainHost)
    #expect(!cmd.contains("SSH_ASKPASS"))
    #expect(notice == nil)

    let h = managedHost("pw", hostName: "b.example.com")
    try await env.service.add(h)
    let withPw = try await env.service.savePassword(hostID: h.id, password: "pw")
    (cmd, notice) = try await env.service.warpSSHCommand(for: withPw)
    #expect(cmd.hasPrefix("SSH_ASKPASS='\(env.helper.path)' SSH_ASKPASS_REQUIRE='force' SSHDESK_HOST_REF='"))
    #expect(
        cmd.hasSuffix(
            "'/usr/bin/ssh' '-F' '\(env.paths.sshConfigURL.path)' '-o' 'BatchMode=no' 'sshdesk-\(h.id.uuidString.lowercased())'"
        ))
    #expect(!cmd.contains("'pw'"))
    // Copy lệnh SSH luôn là lệnh thường.
    let copy = try await env.service.copyableSSHCommand(for: withPw)
    #expect(!copy.contains("SSH_ASKPASS") && !copy.contains("SSHDESK_HOST_REF"))

    // Item bị mất khỏi Keychain: lệnh thường.
    try env.store.delete(ref: withPw.credentialReference ?? "")
    (cmd, notice) = try await env.service.warpSSHCommand(for: withPw)
    #expect(!cmd.contains("SSH_ASKPASS"))

    // Host có bastion: không askpass.
    let jumped = managedHost("j", hostName: "c.example.com", jump: h.id)
    try await env.service.add(jumped)
    let jumpedPw = try await env.service.savePassword(hostID: jumped.id, password: "pw")
    (cmd, notice) = try await env.service.warpSSHCommand(for: jumpedPw)
    #expect(!cmd.contains("SSH_ASKPASS"))
    #expect(notice != nil)
}

@Test func missingHelperFallsBackWithNotice() async throws {
    let env = try SvcEnv(helper: false)
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    let saved = try await env.service.savePassword(hostID: h.id, password: "pw")
    let report = await env.service.openInWarpReport(saved)
    #expect(report.result == .requested)
    #expect(report.notice == "Không tìm thấy helper đăng nhập tự động — nhập mật khẩu trong Warp.")
    #expect(!(try env.tomlText(h.id)).contains("SSH_ASKPASS"))
}

@Test func warpTomlHasAskpassCommandWithoutPassword() async throws {
    let env = try SvcEnv()
    defer { env.dir.cleanup() }
    let h = managedHost()
    try await env.service.add(h)
    let saved = try await env.service.savePassword(hostID: h.id, password: "Hunter2-Zz")
    let report = await env.service.openInWarpReport(saved)
    #expect(report.result == .requested)
    let toml = try env.tomlText(h.id)
    #expect(toml.contains("SSH_ASKPASS="))
    #expect(toml.contains("SSH_ASKPASS_REQUIRE="))
    #expect(!toml.contains("Hunter2-Zz"))
}

// MARK: - Helper thật

private func helperURL() -> URL? { AskpassHelper.defaultURL() }

/// Chạy helper thật trên PTY (cha là tiến trình test, KHÔNG phải ssh). Dù Keychain có item khớp ref,
/// helper phải hỏi trên tty và không in password.
extension ProcessGroup {
    @Suite struct AskpassPTYTests {
        @Test(.enabled(if: AskpassHelper.defaultURL() != nil))
        func helperWithNonSSHParentNeverPrintsPassword() async throws {
            let helper = try #require(helperURL())
            let ref = UUID().uuidString.lowercased()
            let store = KeychainCredentialStore()  // service thật của app, ref ngẫu nhiên, dọn ngay
            var seeded = false
            do {
                try store.save(ref: ref, password: "KEYCHAIN-PW-should-not-leak")
                seeded = true
            } catch { print("Keychain không dùng được trong môi trường test; chỉ kiểm chứng nhánh không có item.") }
            defer { try? store.delete(ref: ref) }

            let env = [
                "PATH": "/usr/bin:/bin", "TERM": "dumb", "SSHDESK_HOST_REF": ref,
                "SSH_ASKPASS_REQUIRE": "force",
            ]
            let p = try PTYProcess.start(
                executable: helper, arguments: ["deploy@web's password: "], environment: env)
            let timer = Task {
                try await Task.sleep(for: .seconds(10))
                p.cancel()
            }
            // Đợi prompt xuất hiện rồi gõ đáp án.
            var out = ""
            var exit: ProcessExit?
            var sent = false
            for await e in p.events {
                switch e {
                case .output(let t):
                    out += t
                    if !sent, out.contains("password:") {
                        sent = true
                        p.send("typed-by-user", redact: false)
                    }
                case .exit(let x): exit = x
                }
            }
            timer.cancel()
            #expect(exit == .exited(0), "output: \(out)")
            #expect(out.contains("deploy@web's password:"), "đã hỏi trên tty")
            #expect(out.contains("typed-by-user"), "trả lời của người dùng đi ra stdout")
            #expect(!out.contains("KEYCHAIN-PW-should-not-leak"))
            _ = seeded
        }

        @Test(.enabled(if: AskpassHelper.defaultURL() != nil))
        func helperHostKeyConfirmKeepsEchoAndInfoPromptReturnsNothing() async throws {
            let helper = try #require(helperURL())
            let env = ["PATH": "/usr/bin:/bin", "TERM": "dumb", "SSH_ASKPASS_PROMPT": "confirm"]
            let p = try PTYProcess.start(
                executable: helper, arguments: ["Are you sure you want to continue connecting (yes/no)? "],
                environment: env)
            var out = ""
            var exit: ProcessExit?
            var sent = false
            let timer = Task {
                try await Task.sleep(for: .seconds(10))
                p.cancel()
            }
            for await e in p.events {
                switch e {
                case .output(let t):
                    out += t
                    if !sent, out.contains("(yes/no)?") {
                        sent = true
                        p.send("yes", redact: false)
                    }
                case .exit(let x): exit = x
                }
            }
            timer.cancel()
            #expect(exit == .exited(0), "output: \(out)")
            #expect(out.contains("yes"))

            let info = try PTYProcess.start(
                executable: helper, arguments: ["Authenticated to web"],
                environment: ["PATH": "/usr/bin:/bin", "SSH_ASKPASS_PROMPT": "none"])
            var infoExit: ProcessExit?
            for await e in info.events { if case .exit(let x) = e { infoExit = x } }
            #expect(infoExit == .exited(0))
        }
    }
}
