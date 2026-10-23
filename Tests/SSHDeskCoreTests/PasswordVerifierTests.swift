import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

// Dùng script giả (#!/bin/sh) làm "ssh": sshd tạm trên macOS không xác thực được password bằng mật khẩu giả,
// nên prompt/kết quả được giả lập. Không kết nối server thật. Script ghi argv/env ra file tạm để test kiểm tra
// password không rò vào argv/env.

private final class VerifyScratch: @unchecked Sendable {
    let dir: URL
    init() throws {
        var t = Array("/tmp/pvXXXXXX".utf8CString)
        guard let p = mkdtemp(&t) else { throw TempSshd.Failure("mkdtemp") }
        dir = URL(fileURLWithPath: String(cString: p))
    }
    func cleanup() {
        // Dừng master còn sót (nếu có) rồi xoá.
        if let pid = pid_t(read("pid").trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }
    func file(_ n: String) -> String { dir.appendingPathComponent(n).path }
    func exists(_ n: String) -> Bool { FileManager.default.fileExists(atPath: file(n)) }
    func read(_ n: String) -> String { (try? String(contentsOfFile: file(n), encoding: .utf8)) ?? "" }

    var socketDirectory: SocketDirectory { get throws { try SocketDirectory.ensure(base: dir.path) } }

    /// `scenario` chạy khi ssh được khởi chạy làm master. `-O check` thành công khi có file `ready`;
    /// `-O exit` ghi `exit-called`, xoá `ready` và dừng master.
    func script(_ scenario: String) throws -> String {
        let url = dir.appendingPathComponent("fake-ssh")
        let body = """
            #!/bin/sh
            D='\(dir.path)'
            case " $* " in
              *" -O check "*) [ -e "$D/ready" ] && exit 0; exit 255 ;;
              *" -O exit "*) touch "$D/exit-called"; rm -f "$D/ready"
                [ -f "$D/pid" ] && kill $(cat "$D/pid") 2>/dev/null; exit 0 ;;
            esac
            printf '%s\\n' "$@" > "$D/argv"
            env > "$D/env"
            echo $$ > "$D/pid"
            \(scenario)
            """
        try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }

    func verifier(ssh: String, timeout: TimeInterval = 15) throws -> PasswordVerifier {
        let dir = try socketDirectory
        return PasswordVerifier(
            configPath: "/tmp/sshdesk-test-config", helper: nil, sshPath: ssh, socketDirectory: { dir },
            timeout: timeout)
    }
}

private func host(
    user: String = "deploy", hostName: String = "web.example.com", jump: UUID? = nil,
    hold: Bool = false, setID: UUID? = nil
) -> HostProfile {
    HostProfile(
        displayName: "web", hostName: hostName, user: user, authMethod: .interactive, jumpHostID: jump,
        credentialSetID: setID, autofillHold: hold)
}

private let okScenario = """
    printf "deploy@web.example.com's password: "
    read pw
    printf '%s' "$pw" > "$D/got"
    if [ "$pw" = "right-pw-7" ]; then touch "$D/ready"; exec sleep 30; fi
    printf '\\nPermission denied, please try again.\\n'
    printf "deploy@web.example.com's password: "
    read pw2
    printf '%s' "$pw2" > "$D/got2"
    exit 255
    """

@Suite(.serialized) struct PasswordVerifierTests {
    @Test func rightPasswordIsOkAndMasterIsClosedWithExit() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let v = try s.verifier(ssh: try s.script(okScenario))
        let result = await v.verify(host: host(), password: "right-pw-7")
        #expect(result == .ok)
        #expect(s.read("got") == "right-pw-7")
        #expect(s.exists("exit-called"), "phải đóng master bằng -O exit")
    }

    @Test func wrongPasswordIsReportedWhenPromptedAgain() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let v = try s.verifier(ssh: try s.script(okScenario))
        let result = await v.verify(host: host(), password: "bad-pw-1")
        #expect(result == .wrongPassword)
        // Điền đúng MỘT lần: prompt lần hai không được trả lời.
        #expect(s.read("got") == "bad-pw-1")
        #expect(!s.exists("got2"))
    }

    @Test func permissionDeniedWithoutSecondPromptIsWrongPassword() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf "deploy@web.example.com's password: "
            read pw
            printf 'deploy@web.example.com: Permission denied (publickey,password).\\n'
            exit 255
            """)
        let result = await (try s.verifier(ssh: ssh)).verify(host: host(), password: "whatever")
        #expect(result == .wrongPassword)
    }

    @Test func hostKeyPromptStopsAndIsNeverAnswered() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf "The authenticity of host 'web.example.com (10.0.0.1)' can't be established.\\n"
            printf "ED25519 key fingerprint is SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG.\\n"
            printf "This key is not known by any other names.\\n"
            printf "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
            read ans
            printf '%s' "$ans" > "$D/answer"
            exec sleep 30
            """)
        let result = await (try s.verifier(ssh: ssh)).verify(host: host(), password: "right-pw-7")
        #expect(result == .hostKeyUnconfirmed)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!s.exists("answer"), "không được tự trả lời yes/no")
        #expect(!s.read("got").contains("right-pw-7"))
    }

    @Test func otpPromptAfterPasswordIsOtherPrompt() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf "deploy@web.example.com's password: "
            read pw
            printf "Verification code: "
            read otp
            printf '%s' "$otp" > "$D/otp"
            exec sleep 30
            """)
        let result = await (try s.verifier(ssh: ssh)).verify(host: host(), password: "right-pw-7")
        guard case .otherPrompt(let text) = result else {
            Issue.record("cần otherPrompt, nhận \(result)")
            return
        }
        #expect(text.contains("Verification code"))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!s.exists("otp"))
    }

    @Test func passwordPromptForOtherUserIsNotAutofilledSoNotConclusive() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf "bastion@jump.example.com's password: "
            read pw
            printf '%s' "$pw" > "$D/got"
            exec sleep 30
            """)
        let result = await (try s.verifier(ssh: ssh)).verify(host: host(), password: "right-pw-7")
        guard case .otherPrompt = result else {
            Issue.record("cần otherPrompt, nhận \(result)")
            return
        }
        #expect(s.read("got").isEmpty, "không được điền password cho prompt của user/host khác")
    }

    @Test func connectionRefusedIsNetworkError() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf 'ssh: connect to host web.example.com port 22: Connection refused\\n'
            exit 255
            """)
        let result = await (try s.verifier(ssh: ssh)).verify(host: host(), password: "right-pw-7")
        guard case .networkError(let message) = result else {
            Issue.record("cần networkError, nhận \(result)")
            return
        }
        #expect(message.contains("Connection refused"))
        #expect(!message.contains("right-pw-7"))
        #expect(result.isInconclusive)
    }

    @Test func silentServerTimesOut() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script("exec sleep 30")
        let started = Date()
        let result = await (try s.verifier(ssh: ssh, timeout: 1)).verify(host: host(), password: "x")
        #expect(result == .timeout)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(result.isInconclusive)
    }

    @Test func passwordNeverReachesArgvOrEnvironment() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let secret = "Zq9-unique-secret-pw"
        let v = try s.verifier(ssh: try s.script(okScenario))
        _ = await v.verify(host: host(), password: secret)
        let argv = s.read("argv")
        let env = s.read("env")
        #expect(!argv.isEmpty && !env.isEmpty)
        #expect(!argv.contains(secret))
        #expect(!env.contains(secret))
        // Không mở nới lỏng kiểm tra host key, không BatchMode.
        #expect(!argv.contains("StrictHostKeyChecking"))
        #expect(!argv.contains("BatchMode"))
        #expect(!env.contains("SSH_ASKPASS"))
    }

    @Test func refusesImportedHostsWithoutRunningSSH() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(okScenario)
        let imported = HostProfile(
            displayName: "legacy", connectionMode: .existingSSHConfigAlias, authMethod: .interactive,
            sshConfigPath: "/Users/me/.ssh/config", sshConfigAlias: "legacy")
        let result = await (try s.verifier(ssh: ssh)).verify(host: imported, password: "right-pw-7")
        #expect(result.isInconclusive)
        #expect(!s.exists("argv"))
    }

    @Test func refusesBastionHostsWithoutRunningSSH() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let ssh = try s.script(okScenario)
        let result = await (try s.verifier(ssh: ssh)).verify(
            host: host(jump: UUID()), password: "right-pw-7")
        #expect(result.isInconclusive)
        #expect(!s.exists("argv"), "không được chạy ssh khi host có bastion")
    }

    @Test func holdAndSetOnTheProbeAreIgnoredButOriginalHostIsUntouched() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let v = try s.verifier(ssh: try s.script(okScenario))
        let h = host(hold: true, setID: UUID())
        let result = await v.verify(host: h, password: "right-pw-7")
        #expect(result == .ok)
        #expect(h.credentialReference == nil && h.autofillHold)
    }

    /// "Không tích lưu" (ADR-029): connector tự điền từ kho tạm qua hostAdjuster; không có gì trong kho thật.
    @Test func connectorAutofillsFromEphemeralVaultViaHostAdjuster() async throws {
        let s = try VerifyScratch()
        defer { s.cleanup() }
        let vault = EphemeralPasswordVault()
        let real = InMemoryCredentialStore()
        let h = host()
        vault.retain(host: h, password: "right-pw-7", owner: "analyst")
        let dir = try s.socketDirectory
        let connector = SessionConnector(
            configPath: "/tmp/sshdesk-test-config",
            credentials: EphemeralOverlayCredentialStore(base: real, vault: vault), helper: nil,
            sshPath: try s.script(okScenario), socketDirectory: { dir },
            hostAdjuster: { vault.adjusted($0) })
        let session = try await connector.connect(host: h) { _, _ in
            Issue.record("không được hiện prompt: password tạm phải được tự điền")
        }
        await session.close()
        #expect(s.read("got") == "right-pw-7")
        #expect(!s.read("argv").contains("right-pw-7") && !s.read("env").contains("right-pw-7"))
        vault.releaseAll(owner: "analyst")
        #expect(!vault.has(hostID: h.id))
    }

    @Test func classifyTable() {
        #expect(PasswordVerifier.classify(prompt: .password("p"), autofilled: true) == .wrongPassword)
        #expect(PasswordVerifier.classify(prompt: .password("p"), autofilled: false) == .otherPrompt("p"))
        #expect(
            PasswordVerifier.classify(prompt: .hostKeyConfirm(fingerprint: nil, text: "t"), autofilled: false)
                == .hostKeyUnconfirmed)
        #expect(PasswordVerifier.classify(prompt: .hostKeyChanged("x"), autofilled: true) == .hostKeyChanged)
        #expect(PasswordVerifier.classify(prompt: .passphrase("k"), autofilled: true) == .otherPrompt("k"))
        #expect(PasswordVerifier.classify(failure: "Permission denied (password).") == .wrongPassword)
        #expect(
            PasswordVerifier.classify(failure: "Host key của máy chủ đã thay đổi: x") == .hostKeyChanged)
        #expect(
            PasswordVerifier.classify(failure: "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @")
                == .hostKeyChanged)
        #expect(PasswordVerifier.classify(failure: "Hết thời gian chờ kết nối (60 giây).") == .timeout)
        #expect(
            PasswordVerifier.classify(failure: "Could not resolve hostname")
                == .networkError("Could not resolve hostname"))
    }
}
