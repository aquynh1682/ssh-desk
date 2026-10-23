import CredentialBackend
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

private let sampleList = """
    Key Type Public Key Hash                          Prot Label               Common Name         Email Address Valid To       Valid 
    p-256-ne 7DF501FA854644ED14600A1ABF3F6555C8C67CB9 none sshdesk-test-sample sshdesk-test-sample               14:02 23/10/27 YES   
    p-256-ne 0123456789abcdef0123456789abcdef01234567 bio  work key            work key                          14:02 23/10/27 YES   
    p-256-ne SHA256:notasha1notasha1notasha1notasha1abcd none bad                bad                               14:02 23/10/27 YES   
    this is a strange line
    p-256-ne 7DF501 none short short x
    """

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("sshdesk-test-se-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private let sk = "sk-ecdsa-sha2-nistp256@openssh.com AAAA ssh:\n"

// MARK: - Thuần

@Test func parseListReadsRowsAndSkipsStrangeLines() {
    let ids = SecureEnclaveKeyService.parseList(sampleList)
    #expect(ids.count == 2)
    #expect(ids[0].label == "sshdesk-test-sample")
    #expect(ids[0].sha1 == "7DF501FA854644ED14600A1ABF3F6555C8C67CB9")
    #expect(ids[0].keyType == "p-256-ne" && ids[0].protection == "none")
    #expect(ids[1].label == "work key")  // nhãn có dấu cách theo cột
    #expect(ids[1].sha1 == "0123456789ABCDEF0123456789ABCDEF01234567")
    #expect(ids[1].protection == "bio")
    #expect(SecureEnclaveKeyService.parseList("").isEmpty)
    #expect(SecureEnclaveKeyService.parseList("rác\nKhông có tiêu đề").isEmpty)
}

@Test func labelValidator() throws {
    for ok in ["a", "My-key_1.x", String(repeating: "a", count: 64)] {
        try SecureEnclaveKeyService.validateLabel(ok)
    }
    // `-x` hợp lệ theo ADR: nhãn đi sau `-l` như một argv riêng.
    try SecureEnclaveKeyService.validateLabel("-x")
    for bad in ["", String(repeating: "a", count: 65), "a b", "a/b", "../x", "a\nb", "ké", "a;b"] {
        #expect(throws: SecureEnclaveError.invalidLabel) { try SecureEnclaveKeyService.validateLabel(bad) }
    }
}

@Test func detectsSecurityKeyPublicFile() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = dir.appendingPathComponent("id_se").path
    try sk.write(toFile: key + ".pub", atomically: true, encoding: .utf8)
    #expect(SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: key))
    try "ssh-ed25519 AAAA c\n".write(toFile: key + ".pub", atomically: true, encoding: .utf8)
    #expect(!SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: key))
    // Không có .pub, đường dẫn tương đối, chính file .pub: không phải.
    #expect(!SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: dir.path + "/none"))
    #expect(!SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: "relative"))
    #expect(!SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: key + ".pub"))
    // symlink .pub không được đi theo
    let link = dir.appendingPathComponent("lnk").path
    try sk.write(toFile: dir.path + "/real.pub", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link + ".pub", withDestinationPath: dir.path + "/real.pub")
    #expect(!SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: link))
}

// MARK: - Writer

@Test func writerAddsSecurityKeyProviderOnlyWhenFlagged() throws {
    var spec = SSHHostSpec(
        alias: "h1", hostName: "10.0.0.5", user: "u", identityFile: "/Users/me/.ssh/id_ecdsa_sk_rk_x")
    var out = try SSHConfigWriter.render(hosts: [spec], userConfigPath: nil)
    #expect(!out.contains("SecurityKeyProvider"))
    spec.usesSecureEnclaveProvider = true
    out = try SSHConfigWriter.render(hosts: [spec], userConfigPath: nil)
    #expect(out.contains("    SecurityKeyProvider \"/usr/lib/ssh-keychain.dylib\"\n"))
    // Không identityFile → không ghi dù cờ bật.
    spec.identityFile = nil
    #expect(!(try SSHConfigWriter.render(hosts: [spec], userConfigPath: nil)).contains("SecurityKeyProvider"))
    // Chống chèn directive vẫn giữ khi bật cờ.
    spec.identityFile = "/k\nProxyCommand evil"
    #expect(throws: SSHConfigError.self) { try SSHConfigWriter.render(hosts: [spec], userConfigPath: nil) }
}

@Test func sshSpecsFlagSecureEnclaveKeyFromSetAndHost() async throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let repo = HostRepository(database: try Database(url: dir.dbURL))
    let keys = tempDir()
    defer { try? FileManager.default.removeItem(at: keys) }
    let se = keys.appendingPathComponent("id_ecdsa_sk_rk_t").path
    try sk.write(toFile: se + ".pub", atomically: true, encoding: .utf8)
    let plain = keys.appendingPathComponent("id_plain").path
    try "ssh-ed25519 AAAA c\n".write(toFile: plain + ".pub", atomically: true, encoding: .utf8)

    let set = try await repo.createCredentialSet(CredentialSet(name: "SE", identityFile: se))
    var viaSet = managedHost("a")
    viaSet.authMethod = .keyFile
    viaSet.credentialSetID = set.id
    var own = managedHost("b")
    own.authMethod = .keyFile
    own.identityFile = plain  // key riêng của host thắng bộ
    try await repo.insert(viaSet)
    try await repo.insert(own)
    let specs = try await repo.sshSpecs()
    let a = try #require(specs.first { $0.alias == HostProfile.managedAlias(for: viaSet.id) })
    let b = try #require(specs.first { $0.alias == HostProfile.managedAlias(for: own.id) })
    #expect(a.usesSecureEnclaveProvider && a.identityFile == se)
    #expect(!b.usesSecureEnclaveProvider && b.identityFile == plain)
}

// MARK: - Service với sc_auth giả (không đụng keychain thật)

/// sc_auth giả: trạng thái trong file; `delete` thật sự xoá dòng chỉ khi `honorDelete`.
private struct FakeSC {
    let dir: URL
    var script: String { dir.appendingPathComponent("sc_auth").path }
    var dylib: String { dir.appendingPathComponent("fake.dylib").path }

    init(honorDelete: Bool) throws {
        dir = tempDir()
        let state = dir.appendingPathComponent("state").path
        try """
        p-256-ne 7DF501FA854644ED14600A1ABF3F6555C8C67CB9 none lab1  lab1  x
        p-256-ne 1111111111111111111111111111111111111111 none other other x

        """.write(toFile: state, atomically: true, encoding: .utf8)
        let body = """
            #!/bin/sh
            case "$1" in
              list-ctk-identities)
                echo "Key Type Public Key Hash                          Prot Label Common Name Email"
                cat "\(state)" ;;
              delete-ctk-identity)
                \(honorDelete ? "grep -v \"$3\" \"\(state)\" > \"\(state).n\"; mv \"\(state).n\" \"\(state)\"" : ":")
                exit 0 ;;
            esac
            """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        FileManager.default.createFile(atPath: dylib, contents: Data())
    }
    func service(into target: URL) -> SecureEnclaveKeyService {
        SecureEnclaveKeyService(directory: target, dylibPath: dylib, scAuthPath: script)
    }
}

@Test func deleteDoesNotTrustExitCodeAndKeepsFiles() async throws {
    let fake = try FakeSC(honorDelete: false)
    let target = tempDir()
    defer {
        try? FileManager.default.removeItem(at: fake.dir)
        try? FileManager.default.removeItem(at: target)
    }
    let svc = fake.service(into: target)
    let p = svc.handlePath(label: "lab1")
    try "x".write(toFile: p, atomically: true, encoding: .utf8)
    try sk.write(toFile: p + ".pub", atomically: true, encoding: .utf8)
    await #expect(throws: SecureEnclaveError.deleteNotConfirmed("lab1")) { try await svc.delete(label: "lab1") }
    #expect(FileManager.default.fileExists(atPath: p))  // identity còn → không xoá file handle
}

@Test func deleteRemovesOnlyExactHandleFilesAndRegularFiles() async throws {
    let fake = try FakeSC(honorDelete: true)
    let target = tempDir()
    defer {
        try? FileManager.default.removeItem(at: fake.dir)
        try? FileManager.default.removeItem(at: target)
    }
    let svc = fake.service(into: target)
    let fm = FileManager.default
    let p = svc.handlePath(label: "lab1")
    try "x".write(toFile: p, atomically: true, encoding: .utf8)
    try sk.write(toFile: p + ".pub", atomically: true, encoding: .utf8)
    let keep = target.appendingPathComponent("id_ecdsa_sk_rk_lab1x").path
    try "x".write(toFile: keep, atomically: true, encoding: .utf8)
    let removed = try await svc.delete(label: "lab1")
    #expect(Set(removed) == [p, p + ".pub"])
    #expect(fm.fileExists(atPath: keep))
    #expect(try await svc.list().map(\.label) == ["other"])
    await #expect(throws: SecureEnclaveError.notFound("lab1")) { try await svc.delete(label: "lab1") }

    // Handle là symlink → không xoá (và không đi theo).
    let secret = target.appendingPathComponent("precious").path
    try "keep".write(toFile: secret, atomically: true, encoding: .utf8)
    let lp = svc.handlePath(label: "other")
    try fm.createSymbolicLink(atPath: lp, withDestinationPath: secret)
    _ = try await svc.delete(label: "other")
    #expect(fm.fileExists(atPath: secret))
    #expect((try? fm.destinationOfSymbolicLink(atPath: lp)) != nil)
}

@Test func createRejectsBadLabelDuplicateAndExistingFiles() async throws {
    let fake = try FakeSC(honorDelete: true)
    let target = tempDir()
    defer {
        try? FileManager.default.removeItem(at: fake.dir)
        try? FileManager.default.removeItem(at: target)
    }
    let svc = fake.service(into: target)
    await #expect(throws: SecureEnclaveError.invalidLabel) { try await svc.create(label: "a b", protection: .none) }
    await #expect(throws: SecureEnclaveError.labelInUse("lab1")) {
        try await svc.create(label: "lab1", protection: .none)
    }
    // File đích đã có → lỗi trước khi tạo identity (fake không có create nên nếu tới đó sẽ báo khác).
    let p = svc.handlePath(label: "fresh")
    try "x".write(toFile: p, atomically: true, encoding: .utf8)
    await #expect(throws: SecureEnclaveError.fileExists(p)) {
        try await svc.create(label: "fresh", protection: .none)
    }
}

@Test func unavailableWhenToolsMissing() async {
    let svc = SecureEnclaveKeyService(
        directory: tempDir(), dylibPath: "/nonexistent/x.dylib", scAuthPath: "/nonexistent/sc_auth")
    #expect(!svc.isAvailable)
    await #expect(throws: SecureEnclaveError.unavailable) { try await svc.list() }
}

// MARK: - Fake ssh-keygen (PTY thật, không keychain)

/// sc_auth giả có `create-ctk-identity`, ssh-keygen giả theo kịch bản.
private struct FakeKeygenRig {
    let dir: URL
    let target: URL
    let tmpBase: URL
    var keygen: String { dir.appendingPathComponent("ssh-keygen").path }
    var log: String { dir.appendingPathComponent("log").path }
    var pwdFile: String { dir.appendingPathComponent("pwd").path }
    var scAuth: String { dir.appendingPathComponent("sc_auth").path }
    var dylib: String { dir.appendingPathComponent("fake.dylib").path }

    /// `body`: phần sau khi đọc prompt của ssh-keygen giả (chạy trong cwd = thư mục tạm của app).
    init(keygenBody: String) throws {
        dir = tempDir()
        target = tempDir()
        tmpBase = tempDir()
        let state = dir.appendingPathComponent("state").path
        try "".write(toFile: state, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        case "$1" in
          list-ctk-identities)
            echo "Key Type Public Key Hash                          Prot Label Common Name Email"
            cat "\(state)" ;;
          create-ctk-identity)
            printf 'p-256-ne 2222222222222222222222222222222222222222 none %-6s %-6s x\n' "$3" "$3" >> "\(state)" ;;
        esac
        """.write(toFile: scAuth, atomically: true, encoding: .utf8)
        chmod(scAuth, 0o755)
        try ("#!/bin/sh\npwd > \"\(pwdFile)\"\n" + keygenBody).write(
            toFile: keygen, atomically: true, encoding: .utf8)
        chmod(keygen, 0o755)
        FileManager.default.createFile(atPath: dylib, contents: Data())
    }

    func cleanup() {
        for d in [dir, target, tmpBase] { try? FileManager.default.removeItem(at: d) }
    }

    func service(timeout: TimeInterval = 20) -> SecureEnclaveKeyService {
        SecureEnclaveKeyService(
            directory: target, dylibPath: dylib, scAuthPath: scAuth, keygenPath: keygen,
            helper: ControllingTTYHelper.defaultURL(), tempBase: tmpBase, keygenTimeout: timeout)
    }

    static let writeFiles = """
        printf 'x' > id_ecdsa_sk_rk_new1
        printf '%s' 'sk-ecdsa-sha2-nistp256@openssh.com AAAA ssh:' > id_ecdsa_sk_rk_new1.pub
        """
    static let prompts = """
        printf 'Enter PIN for authenticator: '; read pin
        printf 'Enter passphrase for "id_ecdsa_sk_rk_new1" (empty for no passphrase): '; read p1
        printf 'Enter same passphrase again: '; read p2
        """
}

private let seAvailable =
    FileManager.default.fileExists(atPath: SecureEnclaveKeyService.dylibPath)
    && FileManager.default.isExecutableFile(atPath: SecureEnclaveKeyService.scAuthPath)

extension ProcessGroup {
    @Suite(.serialized) struct SecureEnclaveProcessTests {
        @Test func ptyCurrentDirectoryIsApplied() async throws {
            guard let helper = ControllingTTYHelper.defaultURL() else { return }
            let dir = tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let proc = try PTYProcess.start(
                executable: URL(fileURLWithPath: "/bin/pwd"), arguments: [],
                environment: ProcessEnvironment.inherited(), helper: helper, currentDirectory: dir)
            var out = ""
            for await e in proc.events { if case .output(let t) = e { out += t } }
            let real = dir.resolvingSymlinksInPath().path
            #expect(
                URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
                    .resolvingSymlinksInPath().path == real)
        }

        @Test func createAnswersPromptsWithEmptyLinesAndMovesFiles() async throws {
            guard ControllingTTYHelper.defaultURL() != nil else { return }
            let rig = try FakeKeygenRig(keygenBody: "exit 0\n")
            defer { rig.cleanup() }
            // Ghi log đáp án vào file riêng của rig.
            try
                ("#!/bin/sh\npwd > \"\(rig.pwdFile)\"\n" + FakeKeygenRig.prompts
                + "\necho \"[$pin][$p1][$p2]\" > \"\(rig.log)\"\n" + FakeKeygenRig.writeFiles + "\n")
                .write(toFile: rig.keygen, atomically: true, encoding: .utf8)
            let svc = rig.service()
            let handle = try await svc.create(label: "new1", protection: .none)
            #expect(try String(contentsOfFile: rig.log, encoding: .utf8) == "[][][]\n")
            let priv = try #require(SSHKeyInventory.lstatInfo(handle))
            let pub = try #require(SSHKeyInventory.lstatInfo(handle + ".pub"))
            #expect(priv.mode & 0o777 == 0o600 && pub.mode & 0o777 == 0o644)
            #expect(svc.hasHandleFiles(label: "new1"))
            // cwd là thư mục tạm của app (nằm trong tmpBase) và đã được dọn.
            let cwd = try String(contentsOfFile: rig.pwdFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                URL(fileURLWithPath: cwd).deletingLastPathComponent().resolvingSymlinksInPath().path
                    == rig.tmpBase.resolvingSymlinksInPath().path)
            #expect(!FileManager.default.fileExists(atPath: cwd))
            // Tạo lại: file đã có → lỗi trước khi động vào identity.
            await #expect(throws: SecureEnclaveError.fileExists(handle)) {
                try await svc.create(label: "new1", protection: .none)
            }
        }

        @Test func unknownPromptCancelsAndReportsExportFailure() async throws {
            guard ControllingTTYHelper.defaultURL() != nil else { return }
            let rig = try FakeKeygenRig(
                keygenBody: "printf 'Enter secret code word: '; read w\n" + FakeKeygenRig.writeFiles + "\n")
            defer { rig.cleanup() }
            let svc = rig.service()
            do {
                _ = try await svc.create(label: "new1", protection: .none)
                Issue.record("phải lỗi")
            } catch SecureEnclaveError.handleExportFailed(let label, _) {
                #expect(label == "new1")
            }
            #expect(!svc.hasHandleFiles(label: "new1"))
            // Identity vẫn còn (không tự xoá im lặng).
            #expect(try await svc.list().contains { $0.label == "new1" })
        }

        @Test func missingOutputFilesReportsExportFailure() async throws {
            guard ControllingTTYHelper.defaultURL() != nil else { return }
            let rig = try FakeKeygenRig(keygenBody: "exit 0\n")
            defer { rig.cleanup() }
            await #expect(throws: SecureEnclaveError.self) {
                try await rig.service().create(label: "new1", protection: .none)
            }
            do { _ = try await rig.service().create(label: "new2", protection: .none) } catch {
                guard case SecureEnclaveError.handleExportFailed = error else {
                    Issue.record("sai loại lỗi: \(error)")
                    return
                }
            }
        }

        @Test func linkCollisionDoesNotOverwriteAndRollsBack() async throws {
            guard ControllingTTYHelper.defaultURL() != nil else { return }
            // ssh-keygen giả tạo sẵn .pub ở đích ngay trước khi kết thúc (mô phỏng file xuất hiện giữa chừng).
            let rig = try FakeKeygenRig(keygenBody: "exit 0\n")
            defer { rig.cleanup() }
            let dest = rig.target.appendingPathComponent("id_ecdsa_sk_rk_new1.pub").path
            try ("#!/bin/sh\n" + FakeKeygenRig.writeFiles + "\nprintf 'KEEP' > \"\(dest)\"\n")
                .write(toFile: rig.keygen, atomically: true, encoding: .utf8)
            do {
                _ = try await rig.service().create(label: "new1", protection: .none)
                Issue.record("phải lỗi")
            } catch SecureEnclaveError.handleExportFailed(_, let reason) {
                #expect(reason.contains("đã tồn tại"))
            }
            #expect(try String(contentsOfFile: dest, encoding: .utf8) == "KEEP")
            #expect(!FileManager.default.fileExists(atPath: rig.target.path + "/id_ecdsa_sk_rk_new1"))
        }

        @Test func deleteRefusesDuplicateLabels() async throws {
            let fake = try FakeSC(honorDelete: true)
            let target = tempDir()
            defer {
                try? FileManager.default.removeItem(at: fake.dir)
                try? FileManager.default.removeItem(at: target)
            }
            let state = fake.dir.appendingPathComponent("state")
            let dup =
                try String(contentsOf: state, encoding: .utf8)
                + "p-256-ne 3333333333333333333333333333333333333333 none lab1  lab1  x\n"
            try dup.write(to: state, atomically: true, encoding: .utf8)
            let svc = fake.service(into: target)
            let p = svc.handlePath(label: "lab1")
            try "x".write(toFile: p, atomically: true, encoding: .utf8)
            await #expect(throws: SecureEnclaveError.ambiguousLabel(label: "lab1", count: 2)) {
                try await svc.delete(label: "lab1")
            }
            #expect(FileManager.default.fileExists(atPath: p))
            #expect(try await svc.list().count == 3)
        }

        // MARK: Secure Enclave thật + sshd tạm (có điều kiện); chung một suite tuần tự với test SE của backend.

        @Test(.enabled(if: seAvailable)) func realSecureEnclaveEndToEndWithTempSshd() async throws {
            guard TempSshd.available else { return }
            let testLabel = "sshdesk-test-" + UUID().uuidString.prefix(8).lowercased()
            precondition(testLabel.hasPrefix("sshdesk-test-"))
            let target = tempDir()
            let sshd = try TempSshd()
            let tmpBase = tempDir()
            defer { try? FileManager.default.removeItem(at: tmpBase) }
            let svc = SecureEnclaveKeyService(
                directory: target, helper: ControllingTTYHelper.defaultURL(), tempBase: tmpBase)

            func cleanupIdentity() async {
                // Chỉ xoá identity có tiền tố test.
                guard testLabel.hasPrefix("sshdesk-test-"), let ids = try? await svc.list() else { return }
                if ids.contains(where: { $0.label == testLabel }) { _ = try? await svc.delete(label: testLabel) }
            }
            do {
                let handle = try await svc.create(label: testLabel, protection: .none)
                #expect(handle == target.appendingPathComponent("id_ecdsa_sk_rk_\(testLabel)").path)
                #expect(svc.hasHandleFiles(label: testLabel))
                let priv = try #require(SSHKeyInventory.lstatInfo(handle))
                let pub = try #require(SSHKeyInventory.lstatInfo(handle + ".pub"))
                #expect(priv.mode & 0o777 == 0o600 && pub.mode & 0o777 == 0o644)
                #expect(SecureEnclaveKeyDetector.isSecureEnclaveKey(identityFile: handle))
                #expect(try await svc.list().contains { $0.label == testLabel })
                // Không ghi đè: tạo lại cùng nhãn → lỗi.
                await #expect(throws: SecureEnclaveError.self) {
                    try await svc.create(label: testLabel, protection: .none)
                }
                // Thư mục tạm của app đã được dọn.
                #expect(((try? FileManager.default.contentsOfDirectory(atPath: tmpBase.path)) ?? ["x"]).isEmpty)

                // Kết nối sshd tạm bằng config app sinh ra.
                try sshd.startServer()
                let pubLine = try String(contentsOfFile: handle + ".pub", encoding: .utf8)
                let ak = (try String(contentsOfFile: sshd.root + "/authorized_keys", encoding: .utf8)) + pubLine
                try ak.write(toFile: sshd.root + "/authorized_keys", atomically: true, encoding: .utf8)
                let spec = SSHHostSpec(
                    alias: "sdse", hostName: "127.0.0.1", port: sshd.port, user: NSUserName(),
                    identityFile: handle, usesSecureEnclaveProvider: true)
                let cfg = sshd.root + "/se_config"
                try SSHConfigWriter.write(to: URL(fileURLWithPath: cfg), hosts: [spec], userConfigPath: nil)
                let common = [
                    "-F", cfg, "-o", "UserKnownHostsFile=\(sshd.root)/known_hosts",
                    "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                ]
                let ok = try await SimpleProcess.run(
                    executable: "/usr/bin/ssh", arguments: common + ["sdse", "echo", "se-ok"],
                    environment: ProcessEnvironment.inherited(), timeout: 30)
                #expect(ok.status == 0 && ok.stdout.contains("se-ok"))
                // Bỏ SecurityKeyProvider → không đăng nhập được.
                var noProvider = spec
                noProvider.usesSecureEnclaveProvider = false
                let cfg2 = sshd.root + "/plain_config"
                try SSHConfigWriter.write(to: URL(fileURLWithPath: cfg2), hosts: [noProvider], userConfigPath: nil)
                var args2 = common
                args2[1] = cfg2
                let bad = try await SimpleProcess.run(
                    executable: "/usr/bin/ssh", arguments: args2 + ["sdse", "true"],
                    environment: ProcessEnvironment.inherited(), timeout: 30)
                #expect(bad.status != 0)

                // Xoá.
                let removed = try await svc.delete(label: testLabel)
                #expect(removed.count == 2)
                #expect(!svc.hasHandleFiles(label: testLabel))
                #expect(!(try await svc.list().contains { $0.label == testLabel }))
            } catch {
                await cleanupIdentity()
                await sshd.cleanup()
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            await cleanupIdentity()
            await sshd.cleanup()
            try? FileManager.default.removeItem(at: target)
            #expect(!(try await svc.list().contains { $0.label.hasPrefix("sshdesk-test-") && $0.label == testLabel }))
        }

        @Test func realSecureEnclaveRoundTripWithTestServices() throws {
            guard SecureEnclave.isAvailable else {
                print("BỎ QUA: máy không có Secure Enclave.")
                return
            }
            let tag = UUID().uuidString
            let keyService = "sshdesk-test-sekey-\(tag)"
            let sealedService = "sshdesk-test-sealed-\(tag)"
            let legacyService = "sshdesk-test-legacy-\(tag)"
            let backend = SecureEnclaveBackend(
                keyService: keyService, sealedService: sealedService, legacyService: legacyService)
            let keyKC = KeychainBackend(service: keyService)
            let sealedKC = KeychainBackend(service: sealedService)
            let legacyKC = KeychainBackend(service: legacyService)
            let ref = "set-\(UUID().uuidString.lowercased())"
            defer {
                try? keyKC.delete(account: SecureEnclaveBackend.keyAccount)
                try? sealedKC.delete(account: ref)
                try? legacyKC.delete(account: ref)
                try? sealedKC.delete(account: "mig")
                try? legacyKC.delete(account: "mig")
            }
            do { try backend.save(account: ref, secret: "se-secret-é") } catch {
                print("BỎ QUA: không ghi được Keychain/SE trong môi trường test: \(error)")
                return
            }
            #expect(backend.read(account: ref) == "se-secret-é")
            #expect(backend.status(account: ref) == .present)
            // Instance khác (như helper) đọc được qua blob đã lưu.
            let other = SecureEnclaveBackend(
                keyService: keyService, sealedService: sealedService, legacyService: legacyService)
            #expect(other.read(account: ref) == "se-secret-é")
            // Migration thật: plaintext -> sealed.
            try legacyKC.save(account: "mig", secret: "legacy-pw")
            #expect(backend.migrateLegacy(accounts: ["mig"]).migrated == 1)
            #expect(!legacyKC.exists(account: "mig"))
            #expect(backend.read(account: "mig") == "legacy-pw")
            // Mất blob khoá -> undecryptable.
            try keyKC.delete(account: SecureEnclaveBackend.keyAccount)
            #expect(backend.status(account: ref) == .undecryptable)
            try backend.save(account: ref, secret: "again")
            #expect(backend.read(account: ref) == "again")
        }
    }
}
