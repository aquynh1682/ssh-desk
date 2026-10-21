import Foundation
import Testing

@testable import SSHDeskCore

/// Tự điền password đã lưu cho truyền file: đúng một lần mỗi job, chỉ cho prompt password.
extension ProcessGroup {
    @Suite struct TransferAutofillTests {
        static var on: Bool { ManagerHarness.available }
        static let good = "Auto-Fill-pw-7Qz"

        private static func script(passphraseFirst: Bool = false) -> String {
            let passphrase =
                passphraseFirst
                ? "printf \"Enter passphrase for key '/Users/me/.ssh/id': \" > /dev/tty\nread pp < /dev/tty\n"
                : ""
            return passphrase
                + """
                printf "deploy@web.example.com's password: " > /dev/tty
                read pw < /dev/tty
                if [ "$pw" = '\(good)' ]; then exec \(ManagerHarness.sftp); fi
                echo "Permission denied, please try again." > /dev/tty
                printf "deploy@web.example.com's password: " > /dev/tty
                read pw < /dev/tty
                if [ "$pw" = '\(good)' ]; then exec \(ManagerHarness.sftp); fi
                echo "deploy@web: Permission denied (publickey,password)." > /dev/tty
                exit 255

                """
        }

        private func prompts(_ h: ManagerHarness) -> [PromptKind] {
            h.log.all.compactMap { e -> PromptKind? in
                if case .authPrompt(_, let k) = e { return k } else { return nil }
            }
        }

        @Test(.enabled(if: on)) func storedPasswordFillsFirstPromptWithoutUI() async throws {
            let store = InMemoryCredentialStore()
            let h = try await ManagerHarness(
                script: Self.script(), credentials: store, storedPassword: Self.good)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let job = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("ok").path)
            let done = try await h.run(job)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(prompts(h).isEmpty)
            #expect(!h.databaseContains(Self.good))
            #expect(!"\(h.log.all)".contains(Self.good))
            for j in try await h.repo.history() { #expect(!(j.failureReason ?? "").contains(Self.good)) }
        }

        @Test(.enabled(if: on)) func wrongStoredPasswordFillsOnceThenAsksUI() async throws {
            let store = InMemoryCredentialStore()
            let h = try await ManagerHarness(
                script: Self.script(), credentials: store, storedPassword: "WRONG-stored-pw")
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let job = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("o").path)
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            let ks = prompts(h)
            #expect(ks.count == 1)
            if case .password? = ks.first {} else { Issue.record("prompt: \(ks)") }
            #expect(store.reads == 1, "chỉ đọc Keychain đúng một lần")
            try await h.manager.respond(jobID: job.id, text: Self.good, isSecret: true)
            let done = try await h.wait(job.id)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            #expect(!h.databaseContains("WRONG-stored-pw"))
            #expect(!"\(h.log.all)".contains("WRONG-stored-pw"))
        }

        @Test(.enabled(if: on)) func passphraseAlwaysAsksUI() async throws {
            let store = InMemoryCredentialStore()
            let h = try await ManagerHarness(
                script: Self.script(passphraseFirst: true), credentials: store,
                storedPassword: Self.good)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let job = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("p").path)
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            if case .passphrase? = prompts(h).first {} else { Issue.record("prompt: \(prompts(h))") }
            #expect(store.reads == 0)
            try await h.manager.respond(jobID: job.id, text: "pp", isSecret: true)
            // Sau passphrase, prompt password đầu tiên được tự điền.
            let done = try await h.wait(job.id)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            #expect(prompts(h).count == 1)
        }

        /// Prompt của bastion (`jump@10.0.0.1's password:`) với host đích managed: KHÔNG tự điền,
        /// Keychain không bị đọc, prompt hiện ra UI.
        @Test(.enabled(if: on)) func bastionPromptIsNeverAutofilled() async throws {
            let store = InMemoryCredentialStore()
            let script = """
                printf "jump@10.0.0.1's password: " > /dev/tty
                read pw < /dev/tty
                if [ "$pw" = 'BASTION-pw' ]; then exec \(ManagerHarness.sftp); fi
                exit 255

                """
            let h = try await ManagerHarness(
                script: script, credentials: store, storedPassword: Self.good)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let job = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("b").path)
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            #expect(store.reads == 0, "không được đọc Keychain cho prompt của bastion")
            if case .password(let t)? = prompts(h).first {
                #expect(t.contains("jump@10.0.0.1"))
            } else {
                Issue.record("prompt: \(prompts(h))")
            }
            try await h.manager.respond(jobID: job.id, text: "BASTION-pw", isSecret: true)
            #expect(try await h.wait(job.id).state == .completed)
            #expect(!"\(h.log.all)".contains(Self.good))
        }

        @Test(.enabled(if: on)) func noStoredPasswordAsksUI() async throws {
            let h = try await ManagerHarness(
                script: Self.script(), credentials: InMemoryCredentialStore(), storedPassword: nil)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let job = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("n").path)
            try await h.manager.enqueue(job)
            _ = try await h.wait(job.id) { $0.state == .awaitingUserInput }
            try await h.manager.respond(jobID: job.id, text: Self.good, isSecret: true)
            #expect(try await h.wait(job.id).state == .completed)
            #expect(prompts(h).count == 1)
        }
    }
}
