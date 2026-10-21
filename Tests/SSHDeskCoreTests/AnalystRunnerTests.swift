import Foundation
import Testing

@testable import SSHDeskCore

struct AnalystRunnerParsingTests {
    @Test func missingToolNames() {
        #expect(RemoteCommandRunner.missingToolName(stderr: "bash: ss: command not found", fallback: "x") == "ss")
        #expect(RemoteCommandRunner.missingToolName(stderr: "zsh:1: command not found: ss", fallback: "x") == "ss")
        #expect(RemoteCommandRunner.missingToolName(stderr: "sh: 1: nc: not found", fallback: "x") == "nc")
        #expect(
            RemoteCommandRunner.missingToolName(
                stderr: "timeout: failed to run command 'bash': No such file or directory", fallback: "x")
                == "bash")
        #expect(RemoteCommandRunner.missingToolName(stderr: "", fallback: "ip") == "ip")
    }

    @Test func truncationMarksAndCuts() {
        let (s, t) = RemoteCommandRunner.truncate(String(repeating: "a", count: 100), maxBytes: 10)
        #expect(s.count == 10 && t)
        let (s2, t2) = RemoteCommandRunner.truncate("ok", maxBytes: 10)
        #expect(s2 == "ok" && !t2)
    }

    @Test func argvPutsCommandAsSingleLastArgument() async {
        let r = RemoteCommandRunner(
            alias: "h", configPath: "/c", controlPath: "/s", aliveCheck: { true })
        let argv = r.arguments(for: "timeout 3 bash -c '</dev/tcp/1.2.3.4/80'")
        #expect(argv.suffix(3) == ["--", "h", "timeout 3 bash -c '</dev/tcp/1.2.3.4/80'"])
        #expect(argv.contains("BatchMode=yes") && argv.contains("PreferredAuthentications=none"))
        #expect(argv.contains("ConnectTimeout=10") && argv.contains("ControlPath=/s"))
    }
}

extension ProcessGroup {
    @Suite(.timeLimit(.minutes(2)))
    struct AnalystRunnerIntegrationTests {
        @Test func runsHostnameEchoAndDetectsMissingTool() async throws {
            try await withRemote { _, session, _ in
                let runner = RemoteCommandRunner(session: session, timeout: 20)
                let h = try await runner.execute(.hostname)
                #expect(h.exitStatus == 0)
                #expect(!h.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                let e = try await runner.executeRaw("echo 'a b'; echo oops >&2", toolHint: "echo")
                #expect(e.stdout == "a b\n")
                #expect(e.stderr == "oops\n")
                #expect(!e.timedOut)

                // exit != 0 không phải công cụ thiếu thì trả về kết quả, không ném lỗi
                let f = try await runner.executeRaw("exit 3", toolHint: "x")
                #expect(f.exitStatus == 3)

                do {
                    _ = try await runner.executeRaw("sshdesk-no-such-tool-xyz", toolHint: "fallback")
                    Issue.record("đáng lẽ ném toolMissing")
                } catch let err as RemoteCommandError {
                    #expect(err == .toolMissing("sshdesk-no-such-tool-xyz"))
                }
            }
        }

        @Test func truncatesLargeStdout() async throws {
            try await withRemote { _, session, _ in
                let runner = RemoteCommandRunner(session: session, timeout: 20, maxStdoutBytes: 1000)
                let r = try await runner.executeRaw("head -c 5000 /dev/zero | tr '\\0' 'x'", toolHint: "head")
                #expect(r.stdoutTruncated)
                #expect(r.stdout.utf8.count == 1000)
            }
        }

        @Test func localTimeoutIsReported() async throws {
            try await withRemote { _, session, _ in
                let runner = RemoteCommandRunner(session: session, timeout: 1)
                let r = try await runner.executeRaw("sleep 10", toolHint: "sleep")
                #expect(r.timedOut)
            }
        }

        @Test func deadMasterIsSessionLost() async throws {
            try await withRemote { _, session, _ in
                let runner = RemoteCommandRunner(session: session, timeout: 20)
                _ = try await runner.execute(.hostname)
                await session.close()
                do {
                    _ = try await runner.execute(.hostname)
                    Issue.record("đáng lẽ ném sessionLost")
                } catch let err as RemoteCommandError {
                    #expect(err == .sessionLost)
                }
            }
        }
    }
}
