import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

/// Thư mục tạm cho key (tự dọn).
final class KeyTempDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sshkeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// Script thực thi giả (chỉ dùng để thay `ssh-keygen`/`ssh-copy-id` trong test).
    func script(_ name: String, _ body: String) throws -> String {
        let p = path(name)
        try ("#!/bin/sh\n" + body + "\n").write(toFile: p, atomically: true, encoding: .utf8)
        chmod(p, 0o755)
        return p
    }
}

/// Chạy `ssh-keygen` thường (không PTY) để dựng key trong test.
@discardableResult
func runKeygen(_ args: [String]) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Lái một KeyTaskSession: trả lời lần lượt các prompt bằng `answers` (đều là bí mật), có timeout cứng.
func driveKeyTask(
    _ session: KeyTaskSession, answers: [String] = [], timeout: TimeInterval = 40,
    cancelAfterFirstPrompt: Bool = false
) async -> (prompts: [PromptKind], outcome: KeyTaskOutcome?) {
    await withTaskGroup(of: (prompts: [PromptKind], outcome: KeyTaskOutcome?).self) { group in
        group.addTask {
            var prompts: [PromptKind] = []
            var remaining = answers
            for await e in session.events {
                switch e {
                case .authPrompt(let k):
                    prompts.append(k)
                    if cancelAfterFirstPrompt {
                        await session.cancel()
                    } else if !remaining.isEmpty {
                        await session.respond(text: remaining.removeFirst(), isSecret: true)
                    }
                case .finished(let o): return (prompts, o)
                }
            }
            return (prompts, nil)
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await session.cancel()
            return ([], nil)
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

private var ptyAvailable: Bool { ControllingTTYHelper.defaultURL() != nil }

// MARK: - Inventory (không cần PTY)

@Suite struct SSHKeyInventoryTests {
    @Test func parsesKeygenLines() {
        let a = SSHKeyInventory.parseKeygenLine("256 SHA256:AbC+/123xyz me@host (ED25519)\n")
        #expect(
            a == SSHKeygenFingerprint(bits: 256, fingerprint: "SHA256:AbC+/123xyz", comment: "me@host", type: "ED25519")
        )
        let b = SSHKeyInventory.parseKeygenLine("3072 SHA256:zzz comment with spaces (and parens) (RSA)")
        #expect(b?.comment == "comment with spaces (and parens)")
        #expect(b?.type == "RSA")
        #expect(b?.bits == 3072)
        #expect(SSHKeyInventory.parseKeygenLine("256 SHA256:zzz no comment (ED25519)")?.comment == nil)
        #expect(SSHKeyInventory.parseKeygenLine("garbage") == nil)
        #expect(SSHKeyInventory.parseKeygenLine("") == nil)
        #expect(SSHKeyInventory.parseKeygenLine("abc SHA256:x c (RSA)") == nil)
    }

    @Test func permissionWarning() {
        #expect(SSHKeyInventory.permissionWarning(mode: 0o100600) == nil)
        #expect(SSHKeyInventory.permissionWarning(mode: 0o100400) == nil)
        #expect(SSHKeyInventory.permissionWarning(mode: 0o100644)?.contains("644") == true)
        #expect(SSHKeyInventory.permissionWarning(mode: 0o100660) != nil)
        #expect(SSHKeyInventory.permissionWarning(mode: 0o100700) != nil)
    }

    @Test func listsPairsAndSkipsJunk() async throws {
        let dir = try KeyTempDir()
        defer { dir.cleanup() }
        let outside = try KeyTempDir()
        defer { outside.cleanup() }
        let fm = FileManager.default

        // Hai cặp key thật (không passphrase) + một cặp RSA quyền rộng.
        #expect(
            try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "alice@laptop", "-f", dir.path("id_ed25519")]).status
                == 0)
        #expect(
            try runKeygen(["-q", "-t", "rsa", "-b", "2048", "-N", "", "-C", "", "-f", dir.path("legacy_rsa")]).status
                == 0)
        chmod(dir.path("legacy_rsa"), 0o644)
        // pub không có private
        #expect(
            try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "orphan", "-f", outside.path("orphan")]).status == 0)
        try fm.copyItem(atPath: outside.path("orphan.pub"), toPath: dir.path("orphan.pub"))
        // private không có pub: không được liệt kê
        try fm.copyItem(atPath: outside.path("orphan"), toPath: dir.path("lonely"))
        // Rác
        for name in ["known_hosts", "config", "authorized_keys", "known_hosts.old"] {
            try "junk".write(toFile: dir.path(name), atomically: true, encoding: .utf8)
        }
        try "this is not a key".write(toFile: dir.path("notes.pub"), atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: dir.path("folder.pub"), withIntermediateDirectories: false)
        // Symlink .pub trỏ ra ngoài thư mục
        try fm.createSymbolicLink(atPath: dir.path("evil.pub"), withDestinationPath: outside.path("orphan.pub"))

        let keys = await SSHKeyInventory(directory: dir.url).list()
        #expect(keys.map(\.name) == ["evil", "id_ed25519", "legacy_rsa", "orphan"])
        let by = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })

        let ed = try #require(by["id_ed25519"])
        #expect(ed.type == "ED25519" && ed.bits == 256)
        #expect(ed.comment == "alice@laptop")
        #expect(ed.fingerprint?.hasPrefix("SHA256:") == true)
        #expect(ed.privateKeyPath == dir.path("id_ed25519"))
        #expect(ed.warnings.isEmpty)
        #expect(!ed.isSymlink)
        #expect(ed.typeText == "ED25519 256")

        let rsa = try #require(by["legacy_rsa"])
        #expect(rsa.type == "RSA" && rsa.bits == 2048)
        #expect(rsa.comment == nil)
        #expect(rsa.warnings.contains { $0.contains("644") })

        let orphan = try #require(by["orphan"])
        #expect(orphan.privateKeyPath == nil && !orphan.hasPrivateKey)
        #expect(orphan.warnings.contains { $0.contains("private") })

        let link = try #require(by["evil"])
        #expect(link.isSymlink)
        #expect(link.fingerprint == nil && link.type == nil)  // không đi theo link
    }

    @Test func missingDirectoryIsEmpty() async {
        let keys = await SSHKeyInventory(directory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")).list()
        #expect(keys.isEmpty)
    }

    @Test func publicKeyTextOnlyForRegularPubInDirectory() async throws {
        let dir = try KeyTempDir()
        defer { dir.cleanup() }
        let outside = try KeyTempDir()
        defer { outside.cleanup() }
        #expect(try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "c", "-f", dir.path("k")]).status == 0)
        #expect(try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "o", "-f", outside.path("o")]).status == 0)
        try FileManager.default.createSymbolicLink(
            atPath: dir.path("l.pub"), withDestinationPath: outside.path("o.pub"))
        let inv = SSHKeyInventory(directory: dir.url)
        let keys = await inv.list()
        let k = try #require(keys.first { $0.name == "k" })
        let text = try #require(inv.publicKeyText(k))
        #expect(text.hasPrefix("ssh-ed25519 ") && !text.contains("\n"))
        #expect(!text.contains("PRIVATE"))
        let l = try #require(keys.first { $0.name == "l" })
        #expect(inv.publicKeyText(l) == nil)  // symlink
        var fake = k
        fake.publicKeyPath = outside.path("o.pub")  // ngoài thư mục
        #expect(inv.publicKeyText(fake) == nil)
        fake.publicKeyPath = dir.path("k")  // không phải .pub (private!)
        #expect(inv.publicKeyText(fake) == nil)
    }

    @Test func namingRules() throws {
        for ok in ["id_ed25519", "work.key-2", "a", "A.B_c"] { try SSHKeyNaming.validateName(ok) }
        for bad in [
            "", "a/b", "../x", "..", ".", "-rf", "a b", "a;b", "x.pub", "é", "a\nb", "a\u{0}b",
            String(repeating: "a", count: 101),
        ] {
            #expect(throws: SSHKeyError.self) { try SSHKeyNaming.validateName(bad) }
        }
        try SSHKeyNaming.validateComment("alice@laptop (work) é")
        try SSHKeyNaming.validateComment("")
        for bad in ["a\nb", "a\rb", "a\tb", "a\u{0}b", "a\u{7F}b", "a\u{1B}[0m"] {
            #expect(throws: SSHKeyError.invalidComment) { try SSHKeyNaming.validateComment(bad) }
        }
    }

    @Test func promptDetectorKeygenPassphrase() {
        var d = PromptDetector()
        #expect(
            d.feed("Enter passphrase (empty for no passphrase): ")
                == .passphrase("Enter passphrase (empty for no passphrase):"))
        #expect(d.feed("\nEnter same passphrase again: ") == .passphrase("Enter same passphrase again:"))
        let p = PromptPresentation(.passphrase("Enter passphrase (empty for no passphrase):"))
        #expect(p.input == .secret && p.note != nil)
    }
}

// MARK: - Generator / Installer (cần PTY)

extension ProcessGroup {
    @Suite(.timeLimit(.minutes(3))) struct SSHKeyGeneratorTests {
        static var on: Bool { ptyAvailable }

        @Test(.enabled(if: on)) func emptyPassphrase() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let keysDir = dir.url.appendingPathComponent("ssh")  // chưa tồn tại: sẽ được tạo 0700
            let gen = try SSHKeyGenerator(directory: keysDir, name: "id_test", comment: "tester@mac")
            let session = try await gen.start()
            let r = await driveKeyTask(session, answers: ["", ""])
            #expect(r.prompts.count == 2)
            #expect(r.prompts.allSatisfy { if case .passphrase = $0 { return true } else { return false } })
            guard case .success = r.outcome else {
                Issue.record("outcome: \(String(describing: r.outcome))")
                return
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: gen.privatePath)
            #expect((attrs[.posixPermissions] as? Int) == 0o600)
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: keysDir.path)
            #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
            // Không passphrase: -y với -P "" đọc được.
            #expect(try runKeygen(["-y", "-P", "", "-f", gen.privatePath]).status == 0)
            let keys = await SSHKeyInventory(directory: keysDir).list()
            #expect(keys.map(\.name) == ["id_test"])
            #expect(keys.first?.comment == "tester@mac")
            #expect(keys.first?.type == "ED25519")
        }

        @Test(.enabled(if: on)) func withPassphrase() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let secret = "correct-horse-battery"
            let gen = try SSHKeyGenerator(directory: dir.url, name: "locked", comment: "c")
            let session = try await gen.start()
            let r = await driveKeyTask(session, answers: [secret, secret])
            guard case .success(let msg) = r.outcome else {
                Issue.record("outcome: \(String(describing: r.outcome))")
                return
            }
            #expect(!msg.contains(secret))
            #expect("\(r.prompts)".contains(secret) == false)
            // Có passphrase: mở bằng passphrase rỗng phải thất bại, đúng passphrase thì được.
            #expect(try runKeygen(["-y", "-P", "", "-f", gen.privatePath]).status != 0)
            #expect(try runKeygen(["-y", "-P", secret, "-f", gen.privatePath]).status == 0)
        }

        @Test func rejectsBadAndExistingNames() throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            for bad in ["", "a/b", "../x", "-x", "has space", "k.pub"] {
                #expect(throws: SSHKeyError.self) {
                    _ = try SSHKeyGenerator(directory: dir.url, name: bad, comment: "c")
                }
            }
            #expect(throws: SSHKeyError.invalidComment) {
                _ = try SSHKeyGenerator(directory: dir.url, name: "ok", comment: "a\nb")
            }
            // Chỉ có .pub, chỉ có private, symlink treo: đều từ chối.
            try "x".write(toFile: dir.path("onlypub.pub"), atomically: true, encoding: .utf8)
            try "x".write(toFile: dir.path("onlypriv"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                atPath: dir.path("dangling"), withDestinationPath: "/nonexistent/zz")
            for name in ["onlypub", "onlypriv", "dangling"] {
                #expect(throws: SSHKeyError.alreadyExists(dir.path(name) + (name == "onlypub" ? ".pub" : ""))) {
                    _ = try SSHKeyGenerator(directory: dir.url, name: name, comment: "c")
                }
            }
        }

        @Test(.enabled(if: on)) func overwritePromptAnsweredNo() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let record = dir.path("answer.txt")
            // ssh-keygen giả: hỏi ghi đè rồi ghi lại câu trả lời nhận được.
            let fake = try dir.script(
                "fake-keygen",
                """
                printf 'x already exists.\\nOverwrite (y/n)? '
                read a
                printf '%s' "$a" > '\(record)'
                exit 1
                """)
            let gen = try SSHKeyGenerator(
                directory: dir.url, name: "newkey", comment: "c", keygenPath: fake)
            let session = try await gen.start()
            let r = await driveKeyTask(session)
            guard case .failure(let reason) = r.outcome else {
                Issue.record("outcome: \(String(describing: r.outcome))")
                return
            }
            #expect(reason.contains("đã tồn tại"))
            #expect(r.prompts.isEmpty)
            #expect((try? String(contentsOfFile: record, encoding: .utf8)) == "n")
        }

        @Test(.enabled(if: on)) func cancelAtPrompt() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let gen = try SSHKeyGenerator(directory: dir.url, name: "c1", comment: "c")
            let session = try await gen.start()
            let r = await driveKeyTask(session, cancelAfterFirstPrompt: true)
            #expect(r.outcome == .cancelled)
            #expect(SSHKeyInventory.lstatInfo(gen.publicPath) == nil)
        }
    }

    @Suite(.timeLimit(.minutes(3))) struct SSHKeyInstallerTests {
        static var on: Bool { ptyAvailable }
        static let secret = "S3cret-Inst-pw-9"

        private func host(jump: UUID? = nil) -> HostProfile {
            HostProfile(
                displayName: "web", hostName: "web.example.com", user: "deploy",
                jumpHostID: jump, credentialReference: "ref-1")
        }

        private func pubKey(_ dir: KeyTempDir) throws -> String {
            #expect(try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "inst", "-f", dir.path("k")]).status == 0)
            return dir.path("k.pub")
        }

        @Test func argumentsAndValidation() throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let pub = try pubKey(dir)
            let i = try SSHKeyInstaller(configPath: "/c/config", publicKeyPath: pub, alias: "sshdesk-abc")
            #expect(i.arguments == ["-F", "/c/config", "-i", pub, "-o", "ConnectTimeout=15", "sshdesk-abc"])
            let f = try SSHKeyInstaller(
                configPath: "/c/config", publicKeyPath: pub, alias: "a", remoteTargetPath: "/t/ak", force: true)
            #expect(f.arguments == ["-f", "-F", "/c/config", "-i", pub, "-t", "/t/ak", "-o", "ConnectTimeout=15", "a"])
            for badAlias in ["", "-oProxyCommand=x", "a b", "a;b", "a\nb"] {
                #expect(throws: SSHKeyError.invalidAlias) {
                    _ = try SSHKeyInstaller(configPath: "/c", publicKeyPath: pub, alias: badAlias)
                }
            }
            for badPub in ["relative.pub", dir.path("k"), dir.path("missing.pub"), dir.path("k.pub\n")] {
                #expect(throws: SSHKeyError.invalidPublicKey) {
                    _ = try SSHKeyInstaller(configPath: "/c", publicKeyPath: badPub, alias: "a")
                }
            }
            for badTarget in ["", "-x", "/t/'; rm -rf ~; '", "a b", "$HOME/x"] {
                #expect(throws: SSHKeyError.invalidTargetPath) {
                    _ = try SSHKeyInstaller(
                        configPath: "/c", publicKeyPath: pub, alias: "a", remoteTargetPath: badTarget)
                }
            }
        }

        @Test func evaluatesResults() {
            let ok = SSHKeyInstaller.evaluate(
                .exited(0), ["INFO: 1 key(s) remain", "Number of key(s) added: 1", "Now try logging in"])
            #expect(ok == .success("Đã cài key lên máy chủ."))
            let dup = SSHKeyInstaller.evaluate(
                .exited(0), ["WARNING: All keys were skipped because they already exist on the remote system."])
            #expect(dup == .success("Key đã có sẵn trên máy chủ."))
            guard case .failure(let r1) = SSHKeyInstaller.evaluate(.exited(0), ["hello"]) else {
                Issue.record("1")
                return
            }
            #expect(r1.contains("không xác nhận"))
            guard
                case .failure(let r2) = SSHKeyInstaller.evaluate(
                    .exited(1), ["a", "deploy@h: Permission denied (publickey,password)."])
            else {
                Issue.record("2")
                return
            }
            #expect(r2.contains("Permission denied") && r2.contains("mã 1"))
            guard case .failure = SSHKeyInstaller.evaluate(.signaled(9), []) else {
                Issue.record("3")
                return
            }
            #expect(SSHKeyInstaller.evaluate(.cancelled, []) == .cancelled)
        }

        /// ssh-copy-id giả: hỏi password hai lần, ghi lại password nhận được ở lần đầu.
        private func fakeCopyID(_ dir: KeyTempDir, record: String) throws -> String {
            try dir.script(
                "fake-copy-id",
                """
                printf "deploy@web.example.com's password: "
                read pw1
                printf '%s' "$pw1" > '\(record)'
                printf "deploy@web.example.com's password: "
                read pw2
                printf '%s' "$pw2" > '\(record).2'
                echo "Number of key(s) added: 1"
                """)
        }

        @Test(.enabled(if: on)) func storedPasswordFilledOnceAndNeverShown() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let pub = try pubKey(dir)
            let record = dir.path("pw.txt")
            let store = InMemoryCredentialStore()
            try store.save(ref: "ref-1", password: Self.secret)
            let inst = try SSHKeyInstaller(
                configPath: "/c/config", publicKeyPath: pub, alias: "sshdesk-x", host: host(),
                credentials: store, executable: try fakeCopyID(dir, record: record))
            let session = try await inst.start()
            let r = await driveKeyTask(session, answers: ["second-answer"])
            #expect(r.outcome == .success("Đã cài key lên máy chủ."))
            // Lần 1 tự điền (không lên UI); lần 2 phải hỏi người dùng.
            #expect(r.prompts.count == 1)
            if case .password(let t) = r.prompts[0] {
                #expect(t.contains("deploy@web.example.com"))
            } else {
                Issue.record("kỳ vọng prompt password")
            }
            #expect((try? String(contentsOfFile: record, encoding: .utf8)) == Self.secret)
            #expect((try? String(contentsOfFile: record + ".2", encoding: .utf8)) == "second-answer")
            #expect(!"\(r.prompts)".contains(Self.secret))
            #expect(!"\(String(describing: r.outcome))".contains(Self.secret))
        }

        @Test(.enabled(if: on)) func bastionHostNeverAutofilled() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let pub = try pubKey(dir)
            let record = dir.path("pw.txt")
            let store = InMemoryCredentialStore()
            try store.save(ref: "ref-1", password: Self.secret)
            let inst = try SSHKeyInstaller(
                configPath: "/c/config", publicKeyPath: pub, alias: "sshdesk-x", host: host(jump: UUID()),
                credentials: store, executable: try fakeCopyID(dir, record: record))
            let session = try await inst.start()
            let r = await driveKeyTask(session, answers: ["typed-1", "typed-2"])
            #expect(r.prompts.count == 2)
            #expect((try? String(contentsOfFile: record, encoding: .utf8)) == "typed-1")
            #expect(r.outcome == .success("Đã cài key lên máy chủ."))
        }

        @Test(.enabled(if: on)) func setPasswordFilledAndHoldBlocks() async throws {
            for hold in [false, true] {
                let dir = try KeyTempDir()
                defer { dir.cleanup() }
                let pub = try pubKey(dir)
                let record = dir.path("pw.txt")
                let store = InMemoryCredentialStore()
                let setID = UUID()
                try store.save(ref: CredentialSet.passwordReference(for: setID), password: Self.secret)
                var h = HostProfile(
                    displayName: "web", hostName: "web.example.com", user: "deploy", credentialSetID: setID)
                h.autofillHold = hold
                let inst = try SSHKeyInstaller(
                    configPath: "/c/config", publicKeyPath: pub, alias: "sshdesk-x", host: h,
                    credentials: store, executable: try fakeCopyID(dir, record: record))
                let session = try await inst.start()
                let r = await driveKeyTask(session, answers: ["typed-1", "typed-2"])
                #expect(r.outcome == .success("Đã cài key lên máy chủ."))
                #expect(r.prompts.count == (hold ? 2 : 1))
                #expect((try? String(contentsOfFile: record, encoding: .utf8)) == (hold ? "typed-1" : Self.secret))
                #expect(!"\(r.prompts)".contains(Self.secret))
            }
        }

        @Test(.enabled(if: on)) func failureReasonIsSanitized() async throws {
            let dir = try KeyTempDir()
            defer { dir.cleanup() }
            let pub = try pubKey(dir)
            let fake = try dir.script(
                "fail-copy-id",
                """
                printf 'deploy@web: \\033[31mPermission denied (publickey,password).\\033[0m\\n'
                exit 1
                """)
            let inst = try SSHKeyInstaller(
                configPath: "/c/config", publicKeyPath: pub, alias: "a", executable: fake)
            let r = await driveKeyTask(try await inst.start())
            guard case .failure(let reason) = r.outcome else {
                Issue.record("\(String(describing: r.outcome))")
                return
            }
            #expect(reason.contains("Permission denied"))
            #expect(!reason.contains("\u{1B}"))
        }

        @Test(.enabled(if: TempSshd.available)) func installsKeyOnTempServerAndLoginWorks() async throws {
            let env = try TempSshd()
            do {
                do { try env.startServer() } catch {
                    Issue.record("SKIP: sshd tạm không khởi động được: \(error)", severity: .warning)
                    await env.cleanup()
                    return
                }
                try await Self.runInstall(env)
            } catch {
                await env.cleanup()
                throw error
            }
            await env.cleanup()
        }

        private static func mtime(_ path: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }

        private static func runInstall(_ env: TempSshd) async throws {
            let home = NSHomeDirectory()
            // Hệ thống thật không được bị đụng.
            let watched = [home + "/.ssh/known_hosts", home + "/.ssh/authorized_keys", home + "/.ssh/config"]
            let before = watched.map { mtime($0) }

            // Key B: chưa được server chấp nhận.
            let keyB = env.root + "/keyB"
            #expect(try runKeygen(["-q", "-t", "ed25519", "-N", "", "-C", "keyB", "-f", keyB]).status == 0)
            // Config chỉ dùng key B để kiểm đăng nhập.
            let cfgB = env.root + "/config_b"
            try """
            Host \(env.alias)
                HostName 127.0.0.1
                Port \(env.port)
                User \(NSUserName())
                IdentityFile \(keyB)
                IdentitiesOnly yes
                UserKnownHostsFile \(env.root)/known_hosts_b
                StrictHostKeyChecking accept-new
                BatchMode yes
                ConnectTimeout 10
            """.write(toFile: cfgB, atomically: true, encoding: .utf8)
            func loginB() throws -> Int32 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = ["-F", cfgB, env.alias, "true"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                return p.terminationStatus
            }
            #expect(try loginB() != 0)  // trước khi cài: bị từ chối

            // Cấu hình client có IdentityFile = key A -> phải dùng force (bước lọc sẽ nhầm vì đăng nhập được bằng A).
            let inst = try SSHKeyInstaller(
                configPath: env.clientConfig, publicKeyPath: keyB + ".pub", alias: env.alias,
                remoteTargetPath: env.root + "/authorized_keys", force: true)
            let r = await driveKeyTask(try await inst.start(), timeout: 60)
            #expect(r.outcome == .success("Đã cài key lên máy chủ."))
            #expect(r.prompts.isEmpty)

            let ak = try String(contentsOfFile: env.root + "/authorized_keys", encoding: .utf8)
            let pubB = try String(contentsOfFile: keyB + ".pub", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(ak.contains(pubB))
            #expect(try loginB() == 0)  // sau khi cài: đăng nhập được bằng key B

            let after = watched.map { mtime($0) }
            #expect(before == after, "test không được đụng ~/.ssh thật")
        }
    }
}
