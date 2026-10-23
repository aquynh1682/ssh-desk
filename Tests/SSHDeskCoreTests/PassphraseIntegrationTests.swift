import Foundation
import Testing

@testable import SSHDeskCore

/// Kiểm chứng dạng prompt passphrase THẬT của OpenSSH và toàn bộ đường tự điền (ADR-030) với sshd tạm
/// trên 127.0.0.1 + key có passphrase trong thư mục tạm. Không đụng `~/.ssh`.
extension ProcessGroup {
    @Suite(.timeLimit(.minutes(3)))
    struct PassphraseIntegrationTests {
        static let passphrase = "pp-Zk4-secret"

        /// sshd tạm chỉ chấp nhận key có passphrase đặt ở `keyDir` (có thể rất sâu để vượt 100 byte của prompt).
        final class Rig: @unchecked Sendable {
            let sshd: TempSshd
            let keyPath: String
            let extraConfig: String

            init(longPath: Bool) throws {
                sshd = try TempSshd()
                try sshd.startServer()
                var dir = sshd.root + "/keys"
                if longPath { dir += "/" + String(repeating: "deep-directory-name-", count: 6) }
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                keyPath = dir + "/id_team"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: TempSshd.keygen)
                p.arguments = ["-q", "-t", "ed25519", "-N", Self.pass, "-f", keyPath]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw TempSshd.Failure("ssh-keygen passphrase key") }
                // Chỉ key có passphrase được phép (bỏ key không passphrase mặc định của TempSshd).
                try FileManager.default.removeItem(atPath: sshd.root + "/authorized_keys")
                try FileManager.default.copyItem(atPath: keyPath + ".pub", toPath: sshd.root + "/authorized_keys")
                extraConfig = sshd.root + "/extra.conf"
                try """
                Host *
                    UserKnownHostsFile \(sshd.root)/known_hosts_pp
                    StrictHostKeyChecking accept-new
                    PreferredAuthentications publickey
                    IdentityAgent none
                """.write(toFile: extraConfig, atomically: true, encoding: .utf8)
            }

            static var pass: String { PassphraseIntegrationTests.passphrase }

            func cleanup() async { await sshd.cleanup() }

            /// Config của app (qua SSHConfigWriter) cho một host dùng key của bộ.
            func renderConfig(host: HostProfile, specs: [SSHHostSpec]) throws -> String {
                let path = sshd.root + "/app_config"
                try SSHConfigWriter.write(
                    to: URL(fileURLWithPath: path), hosts: specs, userConfigPath: extraConfig)
                return path
            }
        }

        /// Dựng rig, chạy `body`, luôn dọn (đợi sshd thoát).
        private func withRig(
            longPath: Bool, hold: Bool = false,
            _ body: (Rig, HostRepository, HostProfile, CredentialSet) async throws -> Void
        ) async throws {
            let rig = try Rig(longPath: longPath)
            let (repo, host, set, _, tmp) = try await makeHostAndRepo(rig, hold: hold)
            do {
                try await body(rig, repo, host, set)
            } catch {
                tmp.cleanup()
                await rig.cleanup()
                throw error
            }
            tmp.cleanup()
            await rig.cleanup()
        }

        private func makeHostAndRepo(_ rig: Rig, hold: Bool = false) async throws
            -> (HostRepository, HostProfile, CredentialSet, Database, HostTempDir)
        {
            let tmp = HostTempDir()
            let db = try Database(url: tmp.dbURL)
            let repo = HostRepository(database: db)
            let set = try await repo.createCredentialSet(CredentialSet(name: "Team", identityFile: rig.keyPath))
            var h = HostProfile(
                displayName: "pp", hostName: "127.0.0.1", port: rig.sshd.port, user: NSUserName(),
                authMethod: .keyFile, credentialSetID: set.id)
            h.autofillHold = hold
            try await repo.insert(h)
            if hold { try await repo.setAutofillHold(ids: [h.id], reason: "test") }
            return (repo, try #require(try await repo.host(id: h.id)), set, db, tmp)
        }

        // MARK: Dạng prompt thật

        @Test(.enabled(if: TempSshd.available), arguments: [false, true])
        func realSshPromptFormatMatchesConfiguredPath(longPath: Bool) async throws {
            try await withRig(longPath: longPath) { rig, repo, host, _ in
                #expect((rig.keyPath.utf8.count > 100) == longPath)
                let config = try rig.renderConfig(host: host, specs: try await repo.sshSpecs())
                let askpass = rig.sshd.root + "/askpass.sh"
                let log = rig.sshd.root + "/prompts.log"
                try """
                #!/bin/sh
                printf '%s\\n' "$1" >> '\(log)'
                echo '\(Self.passphrase)'
                """.write(toFile: askpass, atomically: true, encoding: .utf8)
                chmod(askpass, 0o700)

                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = [
                    "-F", config, "-o", "BatchMode=no", "-o", "ConnectTimeout=10", host.sshAlias ?? "", "true",
                ]
                var env = ProcessEnvironment.inherited()
                env["SSH_ASKPASS"] = askpass
                env["SSH_ASKPASS_REQUIRE"] = "force"
                p.environment = env
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                #expect(p.terminationStatus == 0)

                let prompts = (try String(contentsOfFile: log, encoding: .utf8)).split(separator: "\n").map(String.init)
                #expect(prompts.count == 1)
                let prompt = try #require(prompts.first)
                // Dạng thật: `Enter passphrase for key '<path>': ` và path được cắt ở 100 byte.
                #expect(prompt.hasPrefix("Enter passphrase for key '") && prompt.hasSuffix("': "))
                let shown = try #require(PassphrasePrompt.keyPath(in: prompt))
                #expect(shown == String(decoding: Array(rig.keyPath.utf8.prefix(100)), as: UTF8.self))
                #expect(PassphrasePrompt.matches(prompt: prompt, keyPath: rig.keyPath))
                // Path dài hơn 100 byte bị cắt nên hai path chung 100 byte đầu không phân biệt được (giới hạn của ssh).
                if !longPath { #expect(!PassphrasePrompt.matches(prompt: prompt, keyPath: rig.keyPath + "x")) }
                // Quyết định của helper: đúng ref cho đúng path, một lần.
                var claimed = 0
                let action = AskpassDecision.decide(
                    prompt: prompt, promptType: nil, hostRef: nil, keyRef: "setkey-1", keyPath: rig.keyPath,
                    parentPath: "/usr/bin/ssh", claimUse: { false },
                    claimKeyUse: {
                        claimed += 1
                        return claimed == 1
                    })
                #expect(action == .answerPassphraseFromKeychain(ref: "setkey-1"))
            }
        }

        // MARK: Đường PTY KHÔNG tự điền passphrase (QA K4s)

        @Test(.enabled(if: TempSshd.available), arguments: [false, true])
        func sessionConnectorNeverAutofillsPassphrase(longPath: Bool) async throws {
            try await withRig(longPath: longPath) { rig, repo, host, set in
                let config = try rig.renderConfig(host: host, specs: try await repo.sshSpecs())
                let store = InMemoryCredentialStore()
                try store.save(ref: set.passphraseReference, password: Self.passphrase)
                let dir = try SocketDirectory.ensure(base: rig.sshd.root)
                let prompts = PromptLog()
                let connector = SessionConnector(
                    configPath: config, credentials: store, helper: ControllingTTYHelper.defaultURL(),
                    socketDirectory: { dir })
                let session = try await connector.connect(host: host) { kind, respond in
                    prompts.add(kind)
                    Task { await respond(Self.passphrase, true) }
                }
                await session.close()
                #expect(prompts.all.count == 1)
                if case .passphrase(let text)? = prompts.all.first {
                    #expect(PassphrasePrompt.matches(prompt: text, keyPath: rig.keyPath))
                } else {
                    Issue.record("cần prompt passphrase, nhận \(prompts.all)")
                }
                #expect(store.reads == 0, "không được đọc passphrase từ kho qua PTY")
            }
        }
    }
}

private final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PromptKind] = []
    func add(_ k: PromptKind) { lock.withLock { items.append(k) } }
    var all: [PromptKind] { lock.withLock { items } }
}
