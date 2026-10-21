import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

/// scp dùng chung master của tab (ControlPath), kiểm chứng bằng sshd tạm: đổi tên key client SAU khi
/// master đã mở — chỉ truyền được nếu thật sự đi qua master.
extension ProcessGroup {
    @Suite(.timeLimit(.minutes(2)))
    struct TransferControlPathTests {
        private func makeManager(
            _ env: TempSshd, dir: HostTempDir
        ) async throws -> (TransferManager, TransferRepository, HostProfile) {
            let db = try Database(url: dir.dbURL)
            let hosts = HostRepository(database: db)
            let repo = TransferRepository(database: db)
            let host = importedHost("tmp", alias: env.alias)
            try await hosts.insert(host)
            let manager = TransferManager(
                repository: repo, hosts: hosts,
                controllingTTYHelper: ControllingTTYHelper.defaultURL())
            return (manager, repo, host)
        }

        private func job(
            _ env: TempSshd, host: HostProfile, _ dir: TransferDirection, source: String,
            destination: String
        ) -> TransferJob {
            TransferJob(
                hostID: host.id, hostDisplayNameSnapshot: host.displayName,
                targetSnapshot: "tmp", sshAliasSnapshot: env.alias,
                configPathSnapshot: env.clientConfig, direction: dir, sourcePath: source,
                destinationPath: destination, itemKind: .file, overwritePolicy: .overwrite)
        }

        private func wait(_ repo: TransferRepository, _ id: UUID) async throws -> TransferJob {
            let end = Date().addingTimeInterval(30)
            while Date() < end {
                if let j = try await repo.job(id: id), j.state.isTerminal { return j }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            Issue.record("hết giờ chờ job")
            return try #require(try await repo.job(id: id))
        }

        @Test func scpReusesTabMasterEvenWithoutClientKey() async throws {
            let dir = HostTempDir()
            defer { dir.cleanup() }
            try await withRemote { env, session, _ in
                let fm = FileManager.default
                let (manager, repo, host) = try await makeManager(env, dir: dir)
                let local = dir.url.appendingPathComponent("local.txt")
                try Data("hello-master".utf8).write(to: local)

                // Master đã mở; giờ cất key đi: kết nối MỚI sẽ không xác thực được.
                try fm.moveItem(atPath: env.root + "/clientkey", toPath: env.root + "/clientkey.off")

                // Upload qua master.
                let upDest = env.path("up.txt")
                let up = try await manager.enqueue(
                    job(env, host: host, .upload, source: local.path, destination: upDest),
                    controlPath: session.controlPath)
                let upDone = try await wait(repo, up.id)
                #expect(upDone.state == .completed, "\(upDone.failureReason ?? "")")
                #expect((try? String(contentsOfFile: upDest, encoding: .utf8)) == "hello-master")

                // Download qua master.
                let back = dir.url.appendingPathComponent("back.txt")
                let down = try await manager.enqueue(
                    job(env, host: host, .download, source: upDest, destination: back.path),
                    controlPath: session.controlPath)
                let downDone = try await wait(repo, down.id)
                #expect(downDone.state == .completed, "\(downDone.failureReason ?? "")")
                #expect((try? String(contentsOfFile: back.path, encoding: .utf8)) == "hello-master")

                // Đối chứng: cùng việc nhưng KHÔNG ControlPath → phải lỗi (chứng minh ở trên dùng master).
                let direct = try await manager.enqueue(
                    job(
                        env, host: host, .upload, source: local.path,
                        destination: env.path("direct.txt")))
                let directDone = try await wait(repo, direct.id)
                #expect(directDone.state == .failed)
                #expect(!fm.fileExists(atPath: env.path("direct.txt")))

                // Master chết → job (kể cả retry) không treo trên socket cũ: chạy không ControlPath.
                let pid = try #require(await session.masterPID)
                kill(pid, SIGKILL)
                var alive = true
                for _ in 0..<50 where alive {
                    alive = await session.checkAlive()
                    if alive { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                #expect(!alive)
                let orphan = try await manager.enqueue(
                    job(
                        env, host: host, .upload, source: local.path,
                        destination: env.path("after.txt")),
                    controlPath: session.controlPath)
                let orphanDone = try await wait(repo, orphan.id)
                #expect(orphanDone.state == .failed, "không còn master và không còn key")
                // Trả key lại → thử lại thành công qua kết nối trực tiếp.
                try fm.moveItem(atPath: env.root + "/clientkey.off", toPath: env.root + "/clientkey")
                let retried = try await manager.retry(jobID: orphan.id)
                let retriedDone = try await wait(repo, retried.id)
                #expect(retriedDone.state == .completed, "\(retriedDone.failureReason ?? "")")
                #expect((try? String(contentsOfFile: env.path("after.txt"), encoding: .utf8)) == "hello-master")
                await manager.shutdown(cancelRunning: true)
            }
        }

        @Test func invalidControlPathIsRejectedAtEnqueue() async throws {
            guard TempSshd.available else { return }
            let dir = HostTempDir()
            defer { dir.cleanup() }
            let db = try Database(url: dir.dbURL)
            let hosts = HostRepository(database: db)
            let repo = TransferRepository(database: db)
            let host = importedHost("tmp", alias: "x")
            try await hosts.insert(host)
            let manager = TransferManager(repository: repo, hosts: hosts)
            let j = TransferJob(
                hostID: host.id, hostDisplayNameSnapshot: "tmp", targetSnapshot: "t",
                sshAliasSnapshot: "x", configPathSnapshot: "/dev/null", direction: .upload,
                sourcePath: "/etc/hosts", destinationPath: "/tmp/h", itemKind: .file,
                overwritePolicy: .overwrite)
            await #expect(throws: ScpBuildError.invalidControlPath("rel")) {
                try await manager.enqueue(j, controlPath: "rel")
            }
            #expect(try await repo.history().isEmpty)
        }
    }
}
