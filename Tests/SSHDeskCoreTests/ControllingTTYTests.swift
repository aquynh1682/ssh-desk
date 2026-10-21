import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

// Hồi quy C2b: con của PTYProcess phải có controlling tty thật. Dùng executable KHÔNG phải shell
// (`/bin/stty`, `/usr/bin/head`) vì `/bin/sh` tự mở lại tty và che lỗi (bài học A6).

private let env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]

private func run(
    _ exe: String, _ args: [String], timeout: Double = 10, send: String? = nil
) async throws -> (output: String, exit: ProcessExit?, pid: pid_t) {
    let p = try PTYProcess.start(
        executable: URL(fileURLWithPath: exe), arguments: args, environment: env)
    let pid = p.pid
    if let send { p.send(send, redact: false) }
    let timer = Task {
        try await Task.sleep(for: .seconds(timeout))
        p.cancel()
    }
    var out = ""
    var exit: ProcessExit?
    for await e in p.events {
        switch e {
        case .output(let t): out += t
        case .exit(let x): exit = x
        }
    }
    timer.cancel()
    return (out, exit, pid)
}

extension ProcessGroup {
    @Suite struct ControllingTTYTests {
        @Test func sttyOnDevTTYSucceeds() async throws {
            let r = try await run("/bin/stty", ["-f", "/dev/tty"])
            #expect(r.exit == .exited(0), "output: \(r.output)")
        }

        @Test func nonShellProgramReadsDevTTY() async throws {
            let r = try await run("/usr/bin/head", ["-n", "1", "/dev/tty"], send: "hello")
            #expect(r.exit == .exited(0), "output: \(r.output)")
            #expect(r.output.contains("hello"))
        }

        @Test func childPidIsPgidAndForegroundOfTTY() async throws {
            // `sleep` giữ con sống; ps chạy từ test (không phải trong con).
            let p = try PTYProcess.start(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: env)
            defer { p.cancel() }
            try await Task.sleep(for: .milliseconds(300))
            let out = Pipe()
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-o", "tpgid=,pgid=", "-p", "\(p.pid)"]
            ps.standardOutput = out
            try ps.run()
            ps.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let cols = text.split(whereSeparator: \.isWhitespace).map(String.init)
            #expect(cols.count == 2, "ps: \(text)")
            #expect(cols.first == cols.last, "tpgid/pgid: \(text)")
            #expect(cols.last == "\(p.pid)")
        }

        @Test func helperBadTTYPathExits126() throws {
            let r = try runHelper(["/dev/does-not-exist", "/usr/bin/true"])
            #expect(r.status == 126)
            #expect(r.stderr.contains("sshdesk-ctty"))
        }

        @Test func helperMissingExecutableExits126() async throws {
            // Qua PTYProcess với tty thật: execv thất bại => 126, PTYProcess báo đúng, không rò fd.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctty-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let bad = dir.appendingPathComponent("notexec")
            try Data("not a binary".utf8).write(to: bad)  // ENOEXEC khi execv
            chmod(bad.path, 0o755)
            let before = ptyFDCount()
            for _ in 0..<5 {
                let r = try await run(bad.path, [])
                #expect(r.exit == .exited(126), "output: \(r.output)")
                #expect(r.output.contains("sshdesk-ctty"))
            }
            try await Task.sleep(for: .milliseconds(200))
            let after = ptyFDCount()
            #expect(after <= before)
            let r = try runHelper([FileManager.default.currentDirectoryPath, "/nonexistent/xx"])
            #expect(r.status == 126)
        }

        @Test func missingHelperThrows() {
            #expect(throws: PTYProcessError.helperNotFound) {
                try PTYProcess.start(
                    executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: env,
                    helper: URL(fileURLWithPath: "/nonexistent/sshdesk-ctty"))
            }
        }
    }
}

private func runHelper(_ args: [String]) throws -> (status: Int32, stderr: String) {
    let helper = try #require(ControllingTTYHelper.defaultURL())
    let err = Pipe()
    let p = Process()
    p.executableURL = helper
    p.arguments = args
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return (
        p.terminationStatus,
        String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}
