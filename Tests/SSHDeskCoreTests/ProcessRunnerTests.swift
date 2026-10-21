import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

// Các test dùng script giả (#!/bin/sh) trong thư mục tạm; không kết nối server thật.

private final class Scratch {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptytest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }

    func script(_ body: String, name: String = "fake.sh") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
}

private let baseEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]

private struct Trigger: Sendable {
    let whenContains: String
    let action: @Sendable (PTYProcess) -> Void
}

/// Thu event với timeout rõ ràng; hết giờ thì huỷ job và trả exit = nil.
private func collect(
    _ p: PTYProcess, timeout: Double = 10, triggers: [Trigger] = []
) async -> (output: String, exit: ProcessExit?) {
    await withTaskGroup(of: (String, ProcessExit?, Bool).self) { group in
        group.addTask {
            var out = ""
            var exit: ProcessExit?
            var fired = Set<Int>()
            for await e in p.events {
                switch e {
                case .output(let t):
                    out += t
                    for (i, tr) in triggers.enumerated() where !fired.contains(i) && out.contains(tr.whenContains) {
                        fired.insert(i)
                        tr.action(p)
                    }
                case .exit(let x): exit = x
                }
            }
            return (out, exit, false)
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return ("", nil, true)
        }
        let first = await group.next()!
        if first.2 { p.cancel() }
        group.cancelAll()
        return (first.0, first.1)
    }
}

private func waitUntilDead(_ pid: pid_t, within seconds: Double = 3) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if kill(pid, 0) != 0 && errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

extension ProcessGroup {
    @Suite struct PTYProcessTests {
        @Test func readsPasswordFromControllingTTYViaSend() async throws {
            let s = try Scratch()
            let sh = try s.script(
                """
                printf 'Password: ' > /dev/tty || { echo NOTTY; exit 9; }
                read -s pw < /dev/tty
                echo
                echo "len=${#pw} sum=$(printf %s "$pw" | cksum | cut -d' ' -f1)"
                """)
            let p = try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv)
            let r = await collect(
                p, triggers: [Trigger(whenContains: "Password:") { $0.send("SECRET123") }])
            let sum = String(
                data: try runCapture("/bin/sh", ["-c", "printf %s SECRET123 | cksum | cut -d' ' -f1"]), encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(r.exit == .exited(0))
            #expect(!r.output.contains("NOTTY"))
            #expect(r.output.contains("len=9 sum=\(sum)"))
            #expect(!r.output.contains("SECRET123"))
        }

        @Test func childIsSessionAndGroupLeader() async throws {
            let s = try Scratch()
            let sh = try s.script("ps -o pid=,pgid=,sess=,tpgid= -p $$ > \"$1\"; echo $$")
            let p = try PTYProcess.start(executable: sh, arguments: [s.file("ps.txt").path], environment: baseEnv)
            let r = await collect(p)
            #expect(r.exit == .exited(0))
            let cols = try String(contentsOf: s.file("ps.txt"), encoding: .utf8).split(whereSeparator: \.isWhitespace)
                .map(
                    String.init)
            #expect(cols.count >= 3)
            #expect(cols[0] == cols[1])  // pgid == pid
            #expect(cols[0] == "\(p.pid)")
            if cols.count >= 4 { #expect(cols[3] == cols[1], "ps: \(cols)") }  // foreground pgrp của tty = nhóm của con
        }

        @Test func exitCodes() async throws {
            let s = try Scratch()
            for code in [0, 7, 255] {
                let sh = try s.script("exit \(code)")
                let r = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
                #expect(r.exit == .exited(Int32(code)))
            }
        }

        @Test func diesFromSignal() async throws {
            let s = try Scratch()
            let sh = try s.script("echo before; kill -KILL $$")
            let r = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
            #expect(r.exit == .signaled(SIGKILL))
            #expect(r.output.contains("before"))
        }

        @Test func cancelKillsWholeGroupAndLeavesStrangersAlone() async throws {
            let s = try Scratch()
            let stranger = Process()
            stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
            stranger.arguments = ["60"]
            try stranger.run()
            defer { stranger.terminate() }

            let sh = try s.script("sleep 60 &\necho $! > \"$1\"\necho ready\nwait")
            let pidFile = s.file("child.pid")
            let p = try PTYProcess.start(executable: sh, arguments: [pidFile.path], environment: baseEnv)
            let r = await collect(p, triggers: [Trigger(whenContains: "ready") { $0.cancel() }])
            #expect(r.exit == .cancelled)

            let childPID = try #require(
                pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(await waitUntilDead(childPID))
            #expect(await waitUntilDead(p.pid))
            #expect(kill(stranger.processIdentifier, 0) == 0)
            #expect(stranger.isRunning)
        }

        @Test func cancelEscalatesToSigkillWhenTermIsIgnored() async throws {
            let s = try Scratch()
            let sh = try s.script("trap '' TERM\necho ready\nwhile :; do sleep 1; done")
            let p = try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv)
            let t0 = Date()
            let r = await collect(p, timeout: 10, triggers: [Trigger(whenContains: "ready") { $0.cancel() }])
            let dt = Date().timeIntervalSince(t0)
            #expect(r.exit == .cancelled)
            #expect(dt >= PTYProcess.killGrace - 0.5)
            #expect(dt < 8)
            #expect(await waitUntilDead(p.pid))
        }

        @Test func cancelAfterExitIsHarmless() async throws {
            let s = try Scratch()
            let sh = try s.script("exit 3")
            let p = try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv)
            let r = await collect(p)
            p.cancel()
            p.send("ignored")
            #expect(r.exit == .exited(3))
        }

        @Test func doesNotLeakFileDescriptors() async throws {
            let s = try Scratch()
            let sh = try s.script("printf 'hi\\n'; exit 0")
            // Chạy 1 lần làm nóng (các fd lazy của runtime) rồi đo.
            _ = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
            let before = ptyFDCount()
            for _ in 0..<20 {
                let r = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
                #expect(r.exit == .exited(0))
            }
            // Reader thread đóng master ngay trước khi finish stream; chờ ngắn cho chắc.
            try await Task.sleep(for: .milliseconds(200))
            #expect(ptyFDCount() <= before)
            // Cả khi spawn lỗi.
            for _ in 0..<5 {
                #expect(throws: PTYProcessError.self) {
                    try PTYProcess.start(
                        executable: URL(fileURLWithPath: "/nonexistent/xx"), arguments: [], environment: baseEnv)
                }
            }
            #expect(ptyFDCount() <= before)
        }

        @Test func secretNeverInArgvEnvOrEvents() async throws {
            let s = try Scratch()
            let sh = try s.script(
                """
                env > "$1"
                ps -o command= -p $$ > "$2"
                printf 'Password: ' > /dev/tty
                read line
                echo "child saw: $line"
                cat "$1" "$2" > /dev/null
                """)
            let envFile = s.file("env.txt")
            let argvFile = s.file("argv.txt")
            let p = try PTYProcess.start(
                executable: sh, arguments: [envFile.path, argvFile.path], environment: baseEnv)
            let r = await collect(p, triggers: [Trigger(whenContains: "Password:") { $0.send("SECRET123") }])
            #expect(r.exit == .exited(0))
            #expect(!r.output.contains("SECRET123"))  // kể cả khi con tự in lại
            #expect(r.output.contains("child saw:"))
            let env = try String(contentsOf: envFile, encoding: .utf8)
            let argv = try String(contentsOf: argvFile, encoding: .utf8)
            #expect(!env.contains("SECRET123"))
            #expect(!argv.contains("SECRET123"))
            #expect(env.contains("TERM=dumb"))
        }

        @Test func catDoesNotEchoSentTextIntoEvents() async throws {
            let s = try Scratch()
            let sh = try s.script("printf 'ready\\n'; cat")
            let p = try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv)
            let r = await collect(
                p,
                triggers: [
                    Trigger(whenContains: "ready") { $0.send("SECRET123") },
                    Trigger(whenContains: "•••") { $0.cancel() },
                ])
            #expect(!r.output.contains("SECRET123"))
            #expect(r.output.contains("•••"))
            #expect(r.exit == .cancelled)
        }

        @Test func ttyEchoIsOff() async throws {
            let s = try Scratch()
            let sh = try s.script(
                "echo ready; sleep 0.5; stty -a < /dev/tty | grep -o -- '-echo ' | head -1; echo done")
            let p = try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv)
            let r = await collect(p, triggers: [Trigger(whenContains: "ready") { $0.send("visible?", redact: false) }])
            #expect(r.output.contains("-echo"))
            #expect(r.exit == .exited(0))
            // Dòng "visible?" không xuất hiện do tty echo (chỉ 1 lần nếu có).
            #expect(r.output.components(separatedBy: "visible?").count <= 2)
        }

        @Test func finalOutputIsNotLost() async throws {
            let s = try Scratch()
            let sh = try s.script(
                "i=0; while [ $i -lt 3000 ]; do echo \"line $i\"; i=$((i+1)); done; printf 'LAST-NO-NEWLINE'")
            let r = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
            #expect(r.exit == .exited(0))
            let lines = r.output.split(separator: "\n").map(String.init)
            #expect(lines.count == 3001)
            #expect(lines.first == "line 0")
            #expect(lines[2999] == "line 2999")
            #expect(lines.last == "LAST-NO-NEWLINE")
        }

        @Test func outputIsSanitized() async throws {
            let s = try Scratch()
            let sh = try s.script("printf 'a\\033[31mred\\033[0m\\033]0;title\\007 b\\rprogress\\n'")
            let r = await collect(try PTYProcess.start(executable: sh, arguments: [], environment: baseEnv))
            #expect(r.output == "ared b\nprogress\n")
        }

        @Test func spawnFailureThrows() {
            #expect(throws: PTYProcessError.self) {
                try PTYProcess.start(
                    executable: URL(fileURLWithPath: "/nonexistent/xx"), arguments: [], environment: baseEnv)
            }
            #expect(throws: PTYProcessError.self) {
                try PTYProcess.start(
                    executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["a\0b"], environment: baseEnv)
            }
            #expect(throws: PTYProcessError.self) {
                try PTYProcess.start(
                    executable: URL(fileURLWithPath: "/bin/echo"), arguments: [], environment: ["A=B": "c"])
            }
        }
    }
}

@Test func inheritedEnvironmentIsAllowListOnly() {
    let source = [
        "HOME": "/h", "PATH": "/p", "USER": "u", "LANG": "en", "LC_ALL": "C", "SSH_AUTH_SOCK": "/s",
        "TMPDIR": "/t", "AWS_SECRET_ACCESS_KEY": "x", "SSH_ASKPASS": "y", "TERM": "xterm", "LC_CTYPE": "z",
    ]
    let env = ProcessEnvironment.inherited(from: source)
    #expect(
        Set(env.keys) == ["HOME", "PATH", "USER", "LANG", "LC_ALL", "SSH_AUTH_SOCK", "TMPDIR", "TERM"])
    #expect(env["TERM"] == "dumb")
    #expect(ProcessEnvironment.inherited(from: [:]) == ["TERM": "dumb"])
}

private func runCapture(_ exe: String, _ args: [String]) throws -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}
