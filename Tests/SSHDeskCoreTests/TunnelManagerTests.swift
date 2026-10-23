import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

// Test dùng script giả (#!/bin/sh) làm "ssh" trong thư mục tạm và sshd tạm 127.0.0.1 (TempSshd).
// Không kết nối server thật.

private final class TunnelScratch: @unchecked Sendable {
    let dir: URL
    init() throws {
        var t = Array("/tmp/tnXXXXXX".utf8CString)
        guard let p = mkdtemp(&t) else { throw TempSshd.Failure("mkdtemp") }
        dir = URL(fileURLWithPath: String(cString: p))
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
    func file(_ n: String) -> String { dir.appendingPathComponent(n).path }
    func exists(_ n: String) -> Bool { FileManager.default.fileExists(atPath: file(n)) }
    func read(_ n: String) -> String { (try? String(contentsOfFile: file(n), encoding: .utf8)) ?? "" }

    func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("fake-ssh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url.path
    }
}

private actor TunnelEventLog {
    var events: [TunnelEvent] = []
    func add(_ e: TunnelEvent) { events.append(e) }
    func prompts() -> [PromptKind] {
        events.compactMap { if case .authPrompt(_, _, let k) = $0 { return k } else { return nil } }
    }
    func statuses(_ id: UUID) -> [TunnelStatus] {
        events.compactMap {
            if case .statusChanged(let f, _, let s) = $0, f == id { return s } else { return nil }
        }
    }
}

private func record(_ m: TunnelManager) -> (TunnelEventLog, Task<Void, Never>) {
    let log = TunnelEventLog()
    let task = Task { for await e in m.events { await log.add(e) } }
    return (log, task)
}

private func eventually(_ timeout: TimeInterval = 15, _ cond: @escaping () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 40_000_000)
    }
    return await cond()
}

private let helperAvailable = ControllingTTYHelper.defaultURL() != nil

private func host(
    user: String = "deploy", hostName: String = "web.example.com", jump: UUID? = nil, ref: String? = nil
) -> HostProfile {
    HostProfile(
        displayName: "web", hostName: hostName, user: user, jumpHostID: jump, credentialReference: ref)
}

private func forward(_ h: HostProfile, lp: Int = 15432, rh: String = "db.internal", rp: Int = 5432) -> PortForward {
    PortForward(hostID: h.id, name: "db", localPort: lp, remoteHost: rh, remotePort: rp)
}

private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

@Suite(.serialized) struct TunnelManagerTests {
    private func manager(
        _ s: TunnelScratch, ssh: String, store: any CredentialStore = InMemoryCredentialStore(),
        busy: @escaping @Sendable (Int) -> Bool
    ) -> TunnelManager {
        TunnelManager(
            configPath: "/tmp/sshdesk-test-config", credentials: store, sshPath: ssh,
            environment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"], portBusy: busy)
    }

    @Test func autofillsStoredPasswordRunsThenStopsWholeProcessGroup() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf '%s\\n' "$@" > '\(s.file("args"))'
            printf "deploy@web.example.com's password: "
            read pw
            printf '%s' "$pw" > '\(s.file("pw"))'
            sleep 60 &
            echo $! > '\(s.file("child"))'
            echo $$ > '\(s.file("self"))'
            touch '\(s.file("ready"))'
            wait
            """)
        let store = InMemoryCredentialStore()
        try store.save(ref: "r1", password: "S3cret-pw")
        let h = host(ref: "r1")
        let f = forward(h)
        let m = manager(s, ssh: ssh, store: store) { _ in s.exists("ready") }
        let (log, logTask) = record(m)
        defer { logTask.cancel() }

        await m.start(forward: f, host: h)
        #expect(await eventually { await m.status(of: f.id) == .running })
        #expect(s.read("pw") == "S3cret-pw")
        #expect(await log.prompts().isEmpty)
        #expect(
            s.read("args").split(separator: "\n").map(String.init) == [
                "-F", "/tmp/sshdesk-test-config", "-N", "-o", "ExitOnForwardFailure=yes",
                "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                "-L", "127.0.0.1:15432:db.internal:5432", "--", h.sshAlias!,
            ])
        #expect(await m.activeCount == 1)

        let pid = pid_t(s.read("self").trimmingCharacters(in: .whitespacesAndNewlines))!
        let child = pid_t(s.read("child").trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect(alive(pid) && alive(child))
        await m.stopAll()
        #expect(await m.status(of: f.id) == .stopped)
        #expect(await m.activeCount == 0)
        // Cả process group (kể cả tiến trình con) đã bị dừng.
        #expect(await eventually(5) { !alive(pid) && !alive(child) })
        // Không rò password vào bất kỳ event nào.
        let all = await log.events.map { "\($0)" }.joined()
        #expect(!all.contains("S3cret-pw"))
    }

    @Test func setPasswordFillsAndHoldBlocksInTunnel() async throws {
        guard helperAvailable else { return }
        for hold in [false, true] {
            let s = try TunnelScratch()
            defer { s.cleanup() }
            let ssh = try s.script(
                """
                printf "Enter passphrase for key '/keys/team': "
                read pp
                printf "deploy@web.example.com's password: "
                read pw
                printf '%s|%s' "$pp" "$pw" > '\(s.file("pw"))'
                touch '\(s.file("ready"))'
                sleep 60
                """)
            let store = InMemoryCredentialStore()
            let setID = UUID()
            try store.save(ref: CredentialSet.passwordReference(for: setID), password: "Set-Pw")
            try store.save(ref: CredentialSet.passphraseReference(for: setID), password: "Set-Pp")
            var h = host()
            h.credentialSetID = setID
            h.autofillHold = hold
            let f = forward(h)
            let m = manager(s, ssh: ssh, store: store) { _ in s.exists("ready") }
            let (log, logTask) = record(m)
            defer { logTask.cancel() }
            await m.start(forward: f, host: h)
            // Passphrase qua PTY luôn hỏi người dùng (không tự điền); password của bộ tự điền trừ khi hold.
            #expect(await eventually { await !log.prompts().isEmpty })
            await m.respond(forwardID: f.id, text: "typed-pp", isSecret: true)
            if hold {
                #expect(await eventually { await log.prompts().count >= 2 })
                await m.respond(forwardID: f.id, text: "typed-pw", isSecret: true)
            }
            #expect(await eventually { await m.status(of: f.id) == .running })
            #expect(s.read("pw") == (hold ? "typed-pp|typed-pw" : "typed-pp|Set-Pw"))
            #expect(await log.prompts().count == (hold ? 2 : 1))
            await m.stopAll()
        }
    }

    @Test func promptIsForwardedToUIWhenAutofillNotAllowedThenRespond() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            printf "deploy@web.example.com's password: "
            read pw
            printf '%s' "$pw" > '\(s.file("pw"))'
            touch '\(s.file("ready"))'
            sleep 60
            """)
        let store = InMemoryCredentialStore()
        try store.save(ref: "r1", password: "should-not-be-used")
        // Host có bastion: PasswordAutofillPolicy cấm điền.
        let h = host(jump: UUID(), ref: "r1")
        let f = forward(h)
        let m = manager(s, ssh: ssh, store: store) { _ in s.exists("ready") }
        let (log, logTask) = record(m)
        defer { logTask.cancel() }
        await m.start(forward: f, host: h)
        #expect(await eventually { await !log.prompts().isEmpty })
        #expect(await m.status(of: f.id) == .connecting)
        #expect(!s.exists("pw"))
        await m.respond(forwardID: f.id, text: "typed-by-user", isSecret: true)
        #expect(await eventually { await m.status(of: f.id) == .running })
        #expect(s.read("pw") == "typed-by-user")
        await m.stop(forwardID: f.id)
        #expect(await eventually { await m.status(of: f.id) == .stopped })
    }

    @Test func busyLocalPortFailsWithoutSpawningSSH() async throws {
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script("touch '\(s.file("spawned"))'")
        let h = host()
        let f = forward(h, lp: 15999)
        let m = manager(s, ssh: ssh) { $0 == 15999 }
        await m.start(forward: f, host: h)
        guard case .failed(let reason) = await m.status(of: f.id) else {
            Issue.record("phải là failed")
            return
        }
        #expect(reason.contains("127.0.0.1:15999") && reason.contains("bận"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!s.exists("spawned"))
        #expect(await m.activeCount == 0)
    }

    @Test func sshFailureShowsSanitizedReason() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            echo "bind [127.0.0.1]:15432: Address already in use"
            echo "Could not request local forwarding."
            exit 255
            """)
        let h = host()
        let f = forward(h)
        let m = manager(s, ssh: ssh) { _ in false }
        await m.start(forward: f, host: h)
        #expect(
            await eventually {
                if case .failed(let r) = await m.status(of: f.id) {
                    return r.contains("Could not request local forwarding.")
                }
                return false
            })
        #expect(await m.activeCount == 0)
        // Chạy lại sau lỗi được phép (không kẹt trạng thái cũ).
        await m.start(forward: f, host: h)
        #expect(await eventually { await m.status(of: f.id) != .stopped })
    }

    @Test func hostKeyChangedFailsAndKills() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            echo "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"
            sleep 60
            """)
        let h = host()
        let f = forward(h)
        let m = manager(s, ssh: ssh) { _ in false }
        await m.start(forward: f, host: h)
        #expect(
            await eventually {
                if case .failed(let r) = await m.status(of: f.id) { return r.contains("Host key") }
                return false
            })
        #expect(await eventually { await m.activeCount == 0 })
    }

    @Test func stopAllForHostOnlyStopsThatHost() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script("touch '\(s.file("ready"))'\nsleep 60")
        let h1 = host()
        let h2 = host(hostName: "other.example.com")
        let f1 = forward(h1, lp: 15001)
        let f2 = forward(h2, lp: 15002)
        let m = manager(s, ssh: ssh) { _ in s.exists("ready") }
        await m.start(forward: f1, host: h1)
        await m.start(forward: f2, host: h2)
        #expect(await eventually { await m.activeCount == 2 })
        #expect(await eventually { await m.status(of: f1.id) == .running })
        await m.stopAll(hostID: h1.id)
        #expect(await m.status(of: f1.id) == .stopped)
        #expect(await m.status(of: f2.id).isActive)
        await m.stopAll()
        #expect(await m.activeCount == 0)
    }

    @Test func unexpectedExitWhileRunningIsFailedNotStopped() async throws {
        guard helperAvailable else { return }
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script(
            """
            touch '\(s.file("ready"))'
            sleep 1
            echo "Connection to host closed by remote host."
            exit 255
            """)
        let h = host()
        let f = forward(h)
        let m = manager(s, ssh: ssh) { _ in s.exists("ready") }
        await m.start(forward: f, host: h)
        #expect(await eventually { await m.status(of: f.id) == .running })
        #expect(
            await eventually {
                if case .failed(let r) = await m.status(of: f.id) { return r.contains("Tunnel bị ngắt") }
                return false
            })
    }

    @Test func rejectsWindowsHostAndMismatchedForward() async throws {
        let s = try TunnelScratch()
        defer { s.cleanup() }
        let ssh = try s.script("touch '\(s.file("spawned"))'")
        let m = manager(s, ssh: ssh) { _ in false }
        let win = HostProfile(displayName: "w", kind: .windowsRDP, hostName: "10.0.0.1", port: 3389)
        let f = PortForward(hostID: win.id, localPort: 15432, remotePort: 1)
        await m.start(forward: f, host: win)
        if case .failed = await m.status(of: f.id) {} else { Issue.record("Windows phải bị từ chối") }
        let h = host()
        let wrong = PortForward(hostID: UUID(), localPort: 15433, remotePort: 1)
        await m.start(forward: wrong, host: h)
        if case .failed = await m.status(of: wrong.id) {} else { Issue.record("sai host phải bị từ chối") }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(!s.exists("spawned"))
    }
}

// MARK: - Tích hợp với sshd tạm 127.0.0.1

private func readBanner(port: Int) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = UInt16(port).bigEndian
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard r == 0 else { return nil }
    var buf = [UInt8](repeating: 0, count: 16)
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { return nil }
    return String(decoding: buf[0..<n], as: UTF8.self)
}

@Suite(.serialized) struct TunnelIntegrationTests {
    private func imported(alias: String) -> HostProfile {
        HostProfile(
            displayName: "tmp", connectionMode: .existingSSHConfigAlias,
            sshConfigPath: "/tmp/x", sshConfigAlias: alias)
    }

    @Test func realTunnelForwardsToTempSshdAndStops() async throws {
        guard TempSshd.available else { return }
        let env = try TempSshd()
        do { try env.startServer() } catch {
            await env.cleanup()
            return
        }
        let h = imported(alias: env.alias)
        let lp = try TempSshd.freePort()
        let f = PortForward(hostID: h.id, name: "ssh", localPort: lp, remoteHost: "127.0.0.1", remotePort: env.port)
        let m = TunnelManager(configPath: env.clientConfig, credentials: InMemoryCredentialStore())
        await m.start(forward: f, host: h)
        let running = await eventually(20) { await m.status(of: f.id) == .running }
        #expect(running)
        if running {
            // Nối vào đầu local của tunnel → nhận banner SSH của sshd phía bên kia.
            #expect(readBanner(port: lp)?.hasPrefix("SSH-2.0") == true)
            // Cổng chỉ bind 127.0.0.1 (không phải 0.0.0.0): bind lại cùng cổng phải thất bại.
            #expect(PortProbe.isBusy(lp))
        }
        await m.stopAll()
        #expect(await m.status(of: f.id) == .stopped)
        #expect(await eventually(5) { !PortProbe.isBusy(lp) })
        await env.cleanup()
    }

    @Test func busyPortIsReportedBeforeAnySSHRuns() async throws {
        guard TempSshd.available else { return }
        let lp = try TempSshd.freePort()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(lp).bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 1)
        let h = imported(alias: "tmpsshd")
        let f = PortForward(hostID: h.id, localPort: lp, remotePort: 22)
        let m = TunnelManager(configPath: "/tmp/none", credentials: InMemoryCredentialStore())
        await m.start(forward: f, host: h)
        guard case .failed(let r) = await m.status(of: f.id) else {
            Issue.record("phải failed")
            return
        }
        #expect(r.contains("\(lp)") && r.contains("bận"))
    }
}
