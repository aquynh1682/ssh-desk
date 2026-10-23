import Foundation
import Testing

@testable import SSHDeskCore

/// Truyền file dùng bộ đăng nhập (ADR-030): password + passphrase của bộ tự điền qua PTY, có chặn.
extension ProcessGroup {
    @Suite struct TransferCredentialSetTests {
        static var on: Bool { ManagerHarness.available }
        static let pw = "Set-Pw-9Zx"
        static let pp = "Set-Pp-4Qk"
        static let keyPath = "/keys/team"

        /// ssh giả: hỏi passphrase (đúng dạng OpenSSH) rồi password; sai thì thoát lỗi.
        private static func script(promptPath: String = keyPath) -> String {
            """
            printf "Enter passphrase for key '\(promptPath)': " > /dev/tty
            read pp < /dev/tty
            if [ "$pp" != '\(pp)' ]; then echo "bad passphrase" > /dev/tty; exit 255; fi
            printf "deploy@web.example.com's password: " > /dev/tty
            read pw < /dev/tty
            if [ "$pw" = '\(pw)' ]; then exec \(ManagerHarness.sftp); fi
            echo "Permission denied." > /dev/tty
            exit 255

            """
        }

        private func prompts(_ h: ManagerHarness) -> [PromptKind] {
            h.log.all.compactMap { e -> PromptKind? in
                if case .authPrompt(_, let k) = e { return k } else { return nil }
            }
        }

        private func download(_ h: ManagerHarness, name: String) throws -> TransferJob {
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            return h.job(.download, source: src.path, destination: h.out.appendingPathComponent(name).path)
        }

        @Test(.enabled(if: on)) func passphraseAsksUIThenSetPasswordFills() async throws {
            let store = InMemoryCredentialStore()
            let h = try await ManagerHarness(
                script: Self.script(), credentials: store,
                credentialSet: CredentialSet(name: "Team", identityFile: Self.keyPath),
                setPassword: Self.pw, setPassphrase: Self.pp)
            defer { h.cleanup() }
            let job = try download(h, name: "ok")
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            // Passphrase qua PTY không bao giờ tự điền (QA K4s).
            if case .passphrase? = prompts(h).first {} else { Issue.record("prompt: \(prompts(h))") }
            #expect(store.reads == 0)
            try await h.manager.respond(jobID: job.id, text: Self.pp, isSecret: true)
            // Password của bộ vẫn tự điền ở prompt kế tiếp.
            let done = try await h.wait(job.id)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            #expect(prompts(h).count == 1)
            #expect(!h.databaseContains(Self.pw) && !h.databaseContains(Self.pp))
            #expect(!"\(h.log.all)".contains(Self.pw) && !"\(h.log.all)".contains(Self.pp))
        }

        @Test(.enabled(if: on)) func holdBlocksSetPasswordAndPassphrase() async throws {
            let store = InMemoryCredentialStore()
            let h = try await ManagerHarness(
                script: Self.script(), credentials: store,
                credentialSet: CredentialSet(name: "Team", identityFile: Self.keyPath),
                setPassword: Self.pw, setPassphrase: Self.pp, hold: true)
            defer { h.cleanup() }
            let job = try download(h, name: "held")
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            #expect(store.reads == 0)
            try await h.manager.cancel(jobID: job.id)
        }

        @Test(.enabled(if: on)) func setPasswordOnlyFillsMatchingHostPrompt() async throws {
            let store = InMemoryCredentialStore()
            let script = """
                printf "root@bastion.example.com's password: " > /dev/tty
                read pw < /dev/tty
                exit 255

                """
            let h = try await ManagerHarness(
                script: script, credentials: store, credentialSet: CredentialSet(name: "Team"),
                setPassword: Self.pw)
            defer { h.cleanup() }
            let job = try download(h, name: "bastion")
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            #expect(store.reads == 0)
            try await h.manager.cancel(jobID: job.id)
        }
    }
}
