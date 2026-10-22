import CryptoKit
import Foundation
import Testing

@testable import SSHDeskCore

/// Chạy TransferManager thật với `/usr/bin/scp` + fake ssh (`-S`), không mạng, không server thật.
/// Bỏ qua nếu máy không có sftp-server.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferEvent] = []
    var all: [TransferEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
    func start(_ stream: AsyncStream<TransferEvent>) -> Task<Void, Never> {
        Task {
            for await e in stream {
                lock.withLock { items.append(e) }
            }
        }
    }
}

final class ManagerHarness: @unchecked Sendable {
    static let sftp = "/usr/libexec/sftp-server"
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: sftp)
            && FileManager.default.isExecutableFile(atPath: ScpCommandBuilder.executable)
    }

    let dirs = HostTempDir()
    let root: URL
    let hostRepo: HostRepository
    let repo: TransferRepository
    let host: HostProfile
    let manager: TransferManager
    let log = EventLog()
    var remote: URL { root.appendingPathComponent("remote") }
    var local: URL { root.appendingPathComponent("local") }
    var out: URL { root.appendingPathComponent("out") }
    var alias: String { host.sshAlias ?? "" }

    init(
        script: String = "exec \(ManagerHarness.sftp)\n", concurrency: Int = 1,
        credentials: (any CredentialStore)? = nil, storedPassword: String? = nil
    ) async throws {
        let fm = FileManager.default
        root = dirs.url.appendingPathComponent("work")
        for d in ["remote", "local", "out"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let fake = root.appendingPathComponent("fakessh")
        try Data("#!/bin/sh\n\(script)".utf8).write(to: fake)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let db = try Database(url: dirs.dbURL)
        hostRepo = HostRepository(database: db)
        repo = TransferRepository(database: db)
        var h = managedHost()
        if let credentials, let storedPassword {
            h.credentialReference = "ref-" + UUID().uuidString
            try credentials.save(ref: h.credentialReference ?? "", password: storedPassword)
        }
        host = h
        try await hostRepo.insert(host)
        manager = TransferManager(
            repository: repo, hosts: hostRepo, concurrency: concurrency, extraSSHProgram: fake,
            credentials: credentials)
        _ = log.start(manager.events)
    }

    func cleanup() { dirs.cleanup() }

    func job(
        _ dir: TransferDirection, source: String, destination: String,
        kind: TransferItemKind = .file, policy: OverwritePolicy = .overwrite
    ) -> TransferJob {
        TransferJob(
            hostID: host.id, hostDisplayNameSnapshot: host.displayName,
            targetSnapshot: "deploy@web.example.com:22", sshAliasSnapshot: alias,
            configPathSnapshot: "/dev/null", direction: dir, sourcePath: source,
            destinationPath: destination, itemKind: kind, overwritePolicy: policy)
    }

    func wait(
        _ id: UUID, timeout: TimeInterval = 12, until: (TransferJob) -> Bool = { $0.state.isTerminal }
    ) async throws -> TransferJob {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let j = try await repo.job(id: id), until(j) { return j }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let j = try await repo.job(id: id)
        Issue.record("hết giờ chờ job: \(String(describing: j?.state))")
        return try #require(j)
    }

    func run(_ job: TransferJob) async throws -> TransferJob {
        try await manager.enqueue(job)
        return try await wait(job.id)
    }

    func write(_ url: URL, _ s: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func randomFile(_ url: URL, bytes: Int) throws {
        var d = Data(count: bytes)
        d.withUnsafeMutableBytes { p in
            for i in 0..<p.count { p[i] = UInt8.random(in: 0...255) }
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url)
    }

    func leftoverParts(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            $0.hasSuffix(".part")
        }
    }

    /// Mọi byte trong thư mục DB (kể cả -wal/-shm) có chứa `needle` không.
    func databaseContains(_ needle: String) -> Bool {
        let n = Data(needle.utf8)
        let base = dirs.dbURL.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            if let d = try? Data(contentsOf: base.appendingPathComponent(f)), d.range(of: n) != nil {
                return true
            }
        }
        return false
    }
}

extension ProcessGroup {
    @Suite struct TransferManagerTests {
        static let on = ManagerHarness.available

        @Test(.enabled(if: on)) func fileRoundTripWithAwkwardNames() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let names = ["a b.txt", "日本é ü.bin", "[a]*.dat", "x'q$HOME;y.txt"]
            for (i, n) in names.enumerated() {
                try h.randomFile(h.local.appendingPathComponent(n), bytes: 200_000 + i * 17)
            }
            for n in names {
                let src = h.local.appendingPathComponent(n)
                let dst = h.remote.appendingPathComponent(n)
                let up = try await h.run(h.job(.upload, source: src.path, destination: dst.path))
                #expect(up.state == .completed, "upload \(n): \(up.failureReason ?? "")")
                #expect(try ManagerHarness.sha(src) == ManagerHarness.sha(dst))
                let back = h.out.appendingPathComponent(n)
                let dl = try await h.run(h.job(.download, source: dst.path, destination: back.path))
                #expect(dl.state == .completed, "download \(n): \(dl.failureReason ?? "")")
                #expect(try ManagerHarness.sha(src) == ManagerHarness.sha(back))
                #expect(dl.progress.fraction == 1)
                #expect(dl.startedAt != nil && dl.finishedAt != nil)
            }
            #expect(h.leftoverParts(in: h.out).isEmpty)
            // Thứ tự state trong event stream của một job: đúng máy trạng thái.
            try await Task.sleep(nanoseconds: 100_000_000)
            let last = names[0]
            let id = try #require(
                try await h.repo.history().first(where: { $0.destinationPath.hasSuffix("/out/\(last)") })?.id)
            var seen: [TransferState] = []
            for case .jobUpdated(let j) in h.log.all where j.id == id && seen.last != j.state {
                seen.append(j.state)
            }
            #expect(seen.first == .queued && seen.last == .completed)
            #expect(seen.contains(.connecting) && seen.contains(.finalizing))
            for (a, b) in zip(seen, seen.dropFirst()) {
                #expect(TransferStateMachine.isValid(from: a, to: b), "\(a) -> \(b)")
            }
        }

        @Test(.enabled(if: on)) func directoryRoundTrip() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let tree = h.local.appendingPathComponent("proj [1]")
            try h.randomFile(tree.appendingPathComponent("a.bin"), bytes: 50_000)
            try h.randomFile(tree.appendingPathComponent("sub dir/b c.bin"), bytes: 70_000)
            let up = try await h.run(
                h.job(
                    .upload, source: tree.path, destination: h.remote.appendingPathComponent("up").path,
                    kind: .directory))
            #expect(up.state == .completed, "\(up.failureReason ?? "")")
            #expect(up.progress.fraction == nil)
            let upDir = h.remote.appendingPathComponent("up")
            #expect(
                try ManagerHarness.sha(upDir.appendingPathComponent("sub dir/b c.bin"))
                    == ManagerHarness.sha(tree.appendingPathComponent("sub dir/b c.bin")))
            let dst = h.out.appendingPathComponent("down")
            let dl = try await h.run(
                h.job(.download, source: upDir.path, destination: dst.path, kind: .directory))
            #expect(dl.state == .completed, "\(dl.failureReason ?? "")")
            #expect(
                try ManagerHarness.sha(dst.appendingPathComponent("a.bin"))
                    == ManagerHarness.sha(tree.appendingPathComponent("a.bin")))
            #expect(h.leftoverParts(in: h.out).isEmpty)
        }

        /// Upload thư mục với đích là CHÍNH thư mục cha (cách `BrowserTransferPlanner` dùng): thư mục
        /// trùng tên được gộp vào, không lồng thêm một cấp.
        @Test(.enabled(if: on)) func directoryUploadToParentMergesIntoExisting() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let proj = h.local.appendingPathComponent("proj")
            try h.write(proj.appendingPathComponent("a.txt"), "NEW")
            try h.write(proj.appendingPathComponent("sub/b.txt"), "B")
            try h.write(h.remote.appendingPathComponent("proj/a.txt"), "OLD")
            try h.write(h.remote.appendingPathComponent("proj/keep.txt"), "KEEP")

            let plan = BrowserTransferPlanner.planUpload(
                items: [BatchItem(name: "proj", path: proj.path, kind: .directory)],
                remoteDirectory: h.remote.path, remoteNames: ["proj"])
            #expect(plan.conflicts == ["proj"])
            let planned = BrowserTransferPlanner.uploadJobs(plan, choice: .overwriteAll)
            let job = h.job(
                .upload, source: planned[0].source, destination: planned[0].destination,
                kind: planned[0].kind)
            let done = try await h.run(job)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            func read(_ rel: String) -> String? {
                try? String(contentsOf: h.remote.appendingPathComponent(rel), encoding: .utf8)
            }
            #expect(read("proj/a.txt") == "NEW")
            #expect(read("proj/keep.txt") == "KEEP")
            #expect(read("proj/sub/b.txt") == "B")
            #expect(!FileManager.default.fileExists(atPath: h.remote.appendingPathComponent("proj/proj").path))
        }

        @Test(.enabled(if: on)) func downloadConflictPolicies() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "REMOTE")
            let dest = h.out.appendingPathComponent("f.txt")

            // overwrite
            try h.write(dest, "OLD")
            var j = try await h.run(h.job(.download, source: src.path, destination: dest.path))
            #expect(j.state == .completed)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "REMOTE")

            // skip + xung đột: không đổi file, không tải
            try h.write(dest, "KEEP")
            j = try await h.run(
                h.job(.download, source: src.path, destination: dest.path, policy: .skip))
            #expect(j.state == .completed)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "KEEP")

            // skip + không xung đột: vẫn đặt file vào đích
            try FileManager.default.removeItem(at: dest)
            j = try await h.run(
                h.job(.download, source: src.path, destination: dest.path, policy: .skip))
            #expect(j.state == .completed)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "REMOTE")

            // rename
            j = try await h.run(
                h.job(
                    .download, source: src.path, destination: dest.path, policy: .rename("f (1).txt")))
            #expect(j.state == .completed)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "REMOTE")
            #expect(
                try String(contentsOf: h.out.appendingPathComponent("f (1).txt"), encoding: .utf8)
                    == "REMOTE")

            // rename vào tên đã tồn tại: từ chối ngay khi enqueue
            await #expect(throws: TransferManagerError.self) {
                try await h.manager.enqueue(
                    h.job(
                        .download, source: src.path, destination: dest.path,
                        policy: .rename("f (1).txt")))
            }
            #expect(h.leftoverParts(in: h.out).isEmpty)
        }

        @Test(.enabled(if: on)) func failedDownloadHasCleanReasonAndNoPartial() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let dest = h.out.appendingPathComponent("nope.txt")
            let j = try await h.run(
                h.job(
                    .download, source: h.remote.appendingPathComponent("missing").path,
                    destination: dest.path))
            #expect(j.state == .failed)
            #expect(j.failureReason?.contains("No such file") == true, "\(j.failureReason ?? "nil")")
            #expect(j.exitStatus != nil && j.exitStatus != .exited(0))
            #expect(!FileManager.default.fileExists(atPath: dest.path))
            #expect(h.leftoverParts(in: h.out).isEmpty)
        }

        @Test(.enabled(if: on)) func cancelQueuedAndRunning() async throws {
            let h = try await ManagerHarness(script: "")
            defer { h.cleanup() }
            let pid = h.root.appendingPathComponent("pid").path
            try Data(
                "#!/bin/sh\necho $$ > '\(pid)'\nsleep 30\nexec \(ManagerHarness.sftp)\n".utf8
            ).write(to: h.root.appendingPathComponent("fakessh"))
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let dest1 = h.out.appendingPathComponent("one.txt")
            let dest2 = h.out.appendingPathComponent("two.txt")
            let j1 = h.job(.download, source: src.path, destination: dest1.path)
            let j2 = h.job(.download, source: src.path, destination: dest2.path)
            try await h.manager.enqueue(j1)
            try await h.manager.enqueue(j2)
            _ = try await h.wait(j1.id) { $0.state == .connecting }
            // chờ fake ssh thực sự chạy
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pid) {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let childPID = try #require(
                pid_t(
                    (try? String(contentsOfFile: pid, encoding: .utf8))?.trimmingCharacters(
                        in: .whitespacesAndNewlines) ?? ""))
            // .part giả để chắc chắn việc dọn
            let partial = try #require(try ScpCommandBuilder.build(for: j1).tempPartialPath)
            try h.write(URL(fileURLWithPath: partial), "partial")

            #expect(await h.manager.hasActiveJobs)
            try await h.manager.cancel(jobID: j2.id)
            let c2 = try await h.wait(j2.id)
            #expect(c2.state == .cancelled && c2.startedAt == nil)

            try await h.manager.cancel(jobID: j1.id)
            let c1 = try await h.wait(j1.id)
            #expect(c1.state == .cancelled && c1.exitStatus == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: partial))
            #expect(!FileManager.default.fileExists(atPath: dest1.path))
            // process con đã chết
            var dead = false
            for _ in 0..<100 {
                if kill(childPID, 0) != 0 {
                    dead = true
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(dead)
            // job đã kết thúc không huỷ được; job lạ báo lỗi
            await #expect(throws: TransferManagerError.self) { try await h.manager.cancel(jobID: j1.id) }
            await #expect(throws: TransferManagerError.self) {
                try await h.manager.cancel(jobID: UUID())
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(await h.manager.hasActiveJobs == false)
        }

        @Test(.enabled(if: on)) func shutdownCancelsRunningAndInterruptsQueued() async throws {
            let h = try await ManagerHarness(script: "")
            defer { h.cleanup() }
            try Data("#!/bin/sh\nsleep 30\nexec \(ManagerHarness.sftp)\n".utf8)
                .write(to: h.root.appendingPathComponent("fakessh"))
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let j1 = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("1").path)
            let j2 = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("2").path)
            try await h.manager.enqueue(j1)
            try await h.manager.enqueue(j2)
            _ = try await h.wait(j1.id) { $0.state == .connecting }
            await h.manager.shutdown(cancelRunning: true)
            #expect(try await h.wait(j1.id).state == .cancelled)
            #expect(try await h.wait(j2.id).state == .interrupted)
            #expect(await h.manager.hasActiveJobs == false)
        }

        @Test(.enabled(if: on)) func concurrencyCanBeRaisedWhileQueued() async throws {
            let h = try await ManagerHarness(script: "")
            defer { h.cleanup() }
            try Data("#!/bin/sh\nsleep 30\nexec \(ManagerHarness.sftp)\n".utf8)
                .write(to: h.root.appendingPathComponent("fakessh"))
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let j1 = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("1").path)
            let j2 = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("2").path)
            try await h.manager.enqueue(j1)
            try await h.manager.enqueue(j2)
            _ = try await h.wait(j1.id) { $0.state == .connecting }
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(try await h.repo.job(id: j2.id)?.state == .queued)  // đồng thời = 1
            await h.manager.setConcurrency(2)
            _ = try await h.wait(j2.id) { $0.state == .connecting }
            await h.manager.shutdown(cancelRunning: true)
        }

        private static let secret = "S3cr3t-Zq7!pw"
        private static let promptScript = """
            printf "deploy@web.example.com's password: " > /dev/tty
            read pw < /dev/tty
            if [ "$pw" = '\(secret)' ]; then exec \(ManagerHarness.sftp); fi
            echo "Permission denied, please try again." > /dev/tty
            echo "deploy@web: Permission denied (publickey,password)." > /dev/tty
            exit 255

            """

        @Test(.enabled(if: on)) func passwordPromptRightAndWrong() async throws {
            let h = try await ManagerHarness(script: Self.promptScript)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")

            let ok = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("ok").path)
            try await h.manager.enqueue(ok)
            _ = try await h.wait(ok.id) { $0.state == .awaitingUserInput }
            // Không tự trả lời: đứng yên ở awaitingUserInput.
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(try await h.repo.job(id: ok.id)?.state == .awaitingUserInput)
            // sai kiểu: job khác không có prompt
            await #expect(throws: TransferManagerError.self) {
                try await h.manager.respond(jobID: UUID(), text: "x", isSecret: true)
            }
            try await h.manager.respond(jobID: ok.id, text: Self.secret, isSecret: true)
            let done = try await h.wait(ok.id)
            #expect(done.state == .completed, "\(done.failureReason ?? "")")
            #expect(try String(contentsOf: h.out.appendingPathComponent("ok"), encoding: .utf8) == "R")

            let bad = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("bad").path)
            try await h.manager.enqueue(bad)
            _ = try await h.wait(bad.id) { $0.state == .awaitingUserInput }
            let wrong = "WRONG-pw-Qx9"
            try await h.manager.respond(jobID: bad.id, text: wrong, isSecret: true)
            let failed = try await h.wait(bad.id)
            #expect(failed.state == .failed)
            #expect(failed.failureReason?.contains("Permission denied") == true, "\(failed.failureReason ?? "nil")")
            #expect(!FileManager.default.fileExists(atPath: h.out.appendingPathComponent("bad").path))
            #expect(h.leftoverParts(in: h.out).isEmpty)

            try await Task.sleep(nanoseconds: 200_000_000)
            let events = h.log.all
            var prompts = 0
            for e in events {
                if case .authPrompt(_, let k) = e {
                    prompts += 1
                    if case .password = k {} else { Issue.record("loại prompt: \(k)") }
                }
            }
            #expect(prompts == 2)
            for secret in [Self.secret, wrong] {
                #expect(!h.databaseContains(secret))
                #expect(!"\(events)".contains(secret))
                for j in try await h.repo.history() { #expect(!(j.failureReason ?? "").contains(secret)) }
            }
        }

        @Test(.enabled(if: on)) func hostKeyConfirmShowsFingerprintAndAcceptsYes() async throws {
            let script = """
                printf "The authenticity of host 'web (1.2.3.4)' can't be established.\\r\\n" > /dev/tty
                printf "ED25519 key fingerprint is SHA256:abcDEF123+/xyz.\\r\\n" > /dev/tty
                printf "Are you sure you want to continue connecting (yes/no/[fingerprint])? " > /dev/tty
                read a < /dev/tty
                if [ "$a" = yes ]; then exec \(ManagerHarness.sftp); fi
                echo "Host key verification failed." > /dev/tty
                exit 255

                """
            let h = try await ManagerHarness(script: script)
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let yes = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("y").path)
            try await h.manager.enqueue(yes)
            _ = try await h.wait(yes.id) { $0.state == .awaitingUserInput }
            try await Task.sleep(nanoseconds: 100_000_000)
            let kind = h.log.all.compactMap { e -> PromptKind? in
                if case .authPrompt(yes.id, let k) = e { return k } else { return nil }
            }.first
            guard case .hostKeyConfirm(let fp, _)? = kind else {
                Issue.record("prompt: \(String(describing: kind))")
                return
            }
            #expect(fp == "SHA256:abcDEF123+/xyz", "\(String(describing: kind))")
            try await h.manager.respond(jobID: yes.id, text: "yes", isSecret: false)
            #expect(try await h.wait(yes.id).state == .completed)

            let no = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("n").path)
            try await h.manager.enqueue(no)
            _ = try await h.wait(no.id) { $0.state == .awaitingUserInput }
            try await h.manager.respond(jobID: no.id, text: "no", isSecret: false)
            let f = try await h.wait(no.id)
            #expect(f.state == .failed)
            #expect(f.failureReason?.contains("Host key verification failed") == true, "\(f.failureReason ?? "nil")")
        }

        @Test(.enabled(if: on)) func hostKeyChangedFailsAndNothingIsSent() async throws {
            let h = try await ManagerHarness(script: "")
            defer { h.cleanup() }
            let got = h.root.appendingPathComponent("received").path
            let script = """
                #!/bin/sh
                printf "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\\r\\n" > /dev/tty
                printf "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\\r\\n" > /dev/tty
                printf "Offending key in /Users/x/.ssh/known_hosts:1\\r\\n" > /dev/tty
                sleep 1
                printf "Are you sure you want to continue connecting (yes/no)? " > /dev/tty
                if read -t 2 line < /dev/tty; then echo "$line" > '\(got)'; fi
                sleep 20

                """
            try Data(script.utf8).write(to: h.root.appendingPathComponent("fakessh"))
            let src = h.remote.appendingPathComponent("f.txt")
            try h.write(src, "R")
            let j = h.job(
                .download, source: src.path, destination: h.out.appendingPathComponent("x").path)
            let t0 = Date()
            let r = try await h.run(j)
            #expect(r.state == .failed)
            #expect(r.failureReason == "Host key đã thay đổi — dừng lại; kiểm tra known_hosts thủ công")
            #expect(Date().timeIntervalSince(t0) < 8)
            #expect(!FileManager.default.fileExists(atPath: got))
            #expect(
                !h.log.all.contains {
                    if case .authPrompt = $0 { return true } else { return false }
                })
        }

        @Test(.enabled(if: on)) func recoveryMarksInterruptedAndRemovesPartials() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let dest = h.out.appendingPathComponent("r.bin")
            let j = h.job(.download, source: "/srv/r.bin", destination: dest.path)
            let partial = try #require(try ScpCommandBuilder.build(for: j).tempPartialPath)
            try await h.repo.insert(j)
            try await h.repo.transition(id: j.id, to: .connecting)
            try await h.repo.transition(id: j.id, to: .transferring)
            try await h.repo.setTempPartialPath(id: j.id, partial)
            try h.write(URL(fileURLWithPath: partial), "half")
            let queued = h.job(.download, source: "/srv/q", destination: h.out.appendingPathComponent("q").path)
            try await h.repo.insert(queued)

            let changed = try await h.manager.recoverInterrupted()
            #expect(Set(changed.map(\.id)) == [j.id, queued.id])
            #expect(try await h.repo.job(id: j.id)?.state == .interrupted)
            #expect(try await h.repo.job(id: queued.id)?.state == .interrupted)
            #expect(!FileManager.default.fileExists(atPath: partial))
            // file ngoài dạng .part của job không bị đụng
            let other = h.out.appendingPathComponent("keep.txt")
            try h.write(other, "k")
            _ = try await h.manager.recoverInterrupted()
            #expect(FileManager.default.fileExists(atPath: other.path))
        }

        @Test(.enabled(if: on)) func retryCreatesNewJobAndKeepsOld() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let src = h.remote.appendingPathComponent("late.txt")
            let dest = h.out.appendingPathComponent("late.txt")
            let first = try await h.run(h.job(.download, source: src.path, destination: dest.path))
            #expect(first.state == .failed)
            try h.write(src, "NOW")
            let new = try await h.manager.retry(jobID: first.id)
            #expect(new.id != first.id && new.previousAttemptID == first.id)
            let done = try await h.wait(new.id)
            #expect(done.state == .completed)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "NOW")
            let old = try #require(try await h.repo.job(id: first.id))
            #expect(old.state == .failed && old.failureReason == first.failureReason)
            await #expect(throws: TransferRepositoryError.self) {
                try await h.manager.retry(jobID: new.id)
            }
        }

        @Test(.enabled(if: on)) func enqueueValidation() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let fm = FileManager.default
            let target = h.local.appendingPathComponent("target.txt")
            try h.write(target, "t")
            let tree = h.local.appendingPathComponent("tree")
            try fm.createDirectory(at: tree, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: tree.appendingPathComponent("ln").path, withDestinationPath: target.path)
            let link = h.local.appendingPathComponent("link.txt")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            let dest = h.remote.appendingPathComponent("x").path

            await #expect(throws: TransferManagerError.symlinksNotSupported(["ln"])) {
                try await h.manager.enqueue(
                    h.job(.upload, source: tree.path, destination: dest, kind: .directory))
            }
            await #expect(throws: TransferManagerError.symlinksNotSupported(["."])) {
                try await h.manager.enqueue(h.job(.upload, source: link.path, destination: dest))
            }
            await #expect(throws: TransferManagerError.localSourceMissing(h.local.path + "/none")) {
                try await h.manager.enqueue(
                    h.job(.upload, source: h.local.path + "/none", destination: dest))
            }
            var ghost = h.job(.upload, source: target.path, destination: dest)
            ghost.hostID = UUID()
            await #expect(throws: TransferManagerError.hostNotFound(ghost.hostID)) {
                try await h.manager.enqueue(ghost)
            }
            var renamed = h.job(.upload, source: target.path, destination: dest)
            renamed.sshAliasSnapshot = "other-alias"
            await #expect(throws: TransferManagerError.hostChanged("other-alias")) {
                try await h.manager.enqueue(renamed)
            }
            #expect(try await h.repo.history().isEmpty)
            #expect(await h.manager.hasActiveJobs == false)
        }

        // MARK: - Thí nghiệm (ghi nhận hành vi thật của scp + sftp-server)

        @Test(.enabled(if: on)) func uploadDirectoryIntoExistingDirectoryNests() async throws {
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            let tree = h.local.appendingPathComponent("proj")
            try h.write(tree.appendingPathComponent("a.txt"), "A")
            let existing = h.remote.appendingPathComponent("dest")
            try h.write(existing.appendingPathComponent("old.txt"), "OLD")
            let j = try await h.run(
                h.job(.upload, source: tree.path, destination: existing.path, kind: .directory))
            #expect(j.state == .completed, "\(j.failureReason ?? "")")
            // Kết quả ghi nhận: nếu đích đã tồn tại → LỒNG (dest/proj/a.txt), không gộp vào dest/a.txt.
            let nested = existing.appendingPathComponent("proj/a.txt").path
            let merged = existing.appendingPathComponent("a.txt").path
            #expect(FileManager.default.fileExists(atPath: nested))
            #expect(!FileManager.default.fileExists(atPath: merged))
            #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("old.txt").path))
        }

        @Test(.enabled(if: on)) func remoteTildePathIsExpandedBySftpServer() async throws {
            // sftp-server -d <dir>: thư mục gốc "tạm" để không đụng HOME thật.
            let h = try await ManagerHarness()
            defer { h.cleanup() }
            try Data(
                "#!/bin/sh\ncd '\(h.remote.path)' && exec \(ManagerHarness.sftp) -d '\(h.remote.path)'\n".utf8
            ).write(to: h.root.appendingPathComponent("fakessh"))
            let name = "tilde-\(UUID().uuidString).txt"
            let src = h.local.appendingPathComponent("t.txt")
            try h.write(src, "T")
            let j = try await h.run(h.job(.upload, source: src.path, destination: "~/" + name))
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: home) }
            // Kết quả ghi nhận: xem assertion bên dưới.
            let inRemote = FileManager.default.fileExists(
                atPath: h.remote.appendingPathComponent(name).path)
            let inHome = FileManager.default.fileExists(atPath: home.path)
            #expect(j.state == .completed, "\(j.failureReason ?? "")")
            #expect(inRemote && !inHome, "inRemote=\(inRemote) inHome=\(inHome)")
        }
    }
}
