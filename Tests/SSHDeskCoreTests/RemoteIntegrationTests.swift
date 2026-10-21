import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

/// sshd TẠM trên 127.0.0.1 (không dùng ~/.ssh, không sudo, StrictHostKeyChecking=accept-new chỉ ở đây).
final class TempSshd: @unchecked Sendable {
    static let sshd = "/usr/sbin/sshd"
    static let sftpServer = "/usr/libexec/sftp-server"
    static let keygen = "/usr/bin/ssh-keygen"

    let root: String
    var data: String { root + "/data" }
    var clientConfig: String { root + "/client_config" }
    let alias = "tmpsshd"
    private(set) var port = 0
    private var process: Process?
    private var sessions: [RemoteSession] = []

    static var available: Bool {
        let fm = FileManager.default
        return [sshd, sftpServer, keygen, "/usr/bin/ssh", "/usr/bin/sftp"].allSatisfy {
            fm.isExecutableFile(atPath: $0)
        } && ControllingTTYHelper.defaultURL() != nil
    }

    init() throws {
        var t = Array("/tmp/sdXXXXXX".utf8CString)
        guard let p = mkdtemp(&t) else { throw Failure("mkdtemp") }
        root = String(cString: p)
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: false)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else { throw Failure("bind") }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    func canConnect() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r == 0
    }

    /// Throw `Failure` nếu không khởi động được (test sẽ skip).
    func startServer() throws {
        guard try run(Self.keygen, ["-q", "-t", "ed25519", "-N", "", "-f", root + "/hostkey"]) == 0,
            try run(Self.keygen, ["-q", "-t", "ed25519", "-N", "", "-f", root + "/clientkey"]) == 0
        else { throw Failure("ssh-keygen") }
        try FileManager.default.copyItem(atPath: root + "/clientkey.pub", toPath: root + "/authorized_keys")
        port = try Self.freePort()
        let sshdConfig = """
            ListenAddress 127.0.0.1
            Port \(port)
            HostKey \(root)/hostkey
            AuthorizedKeysFile \(root)/authorized_keys
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            UsePAM no
            StrictModes no
            PidFile \(root)/sshd.pid
            Subsystem sftp \(Self.sftpServer)
            """
        try sshdConfig.write(toFile: root + "/sshd_config", atomically: true, encoding: .utf8)
        let client = """
            Host \(alias)
                HostName 127.0.0.1
                Port \(port)
                User \(NSUserName())
                IdentityFile \(root)/clientkey
                IdentitiesOnly yes
                UserKnownHostsFile \(root)/known_hosts
                StrictHostKeyChecking accept-new
            """
        try client.write(toFile: clientConfig, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.sshd)
        p.arguments = ["-D", "-e", "-f", root + "/sshd_config"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        process = p
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !p.isRunning { throw Failure("sshd thoát sớm (status \(p.terminationStatus))") }
            if canConnect() { return }
            usleep(50_000)
        }
        throw Failure("sshd không lắng nghe sau 5s")
    }

    func makeSession() throws -> RemoteSession {
        let dir = try SocketDirectory.ensure(base: root)
        let s = RemoteSession(
            alias: alias, configPath: clientConfig, hostID: UUID(), socketDirectory: dir)
        sessions.append(s)
        return s
    }

    func cleanup() async {
        for s in sessions { await s.close() }
        if let p = process {
            // KHÔNG dùng `Process.waitUntilExit()` ở đây: process được chạy ở thread này nhưng cleanup
            // chạy sau nhiều `await` (có thể sang thread khác) và NSTask báo thoát qua runloop của
            // thread đã chạy nó → có thể treo vô hạn. Tự đợi bằng waitpid theo pid.
            let pid = p.processIdentifier
            kill(pid, SIGTERM)
            if !Self.reap(pid, within: 3) {
                kill(pid, SIGKILL)
                _ = Self.reap(pid, within: 5)
            }
        }
        // chmod lại các thư mục đã khoá để xoá được.
        _ = try? run("/bin/chmod", ["-R", "u+rwx", root])
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Đợi con thoát (và dọn zombie) bằng waitpid; đã bị ai đó dọn trước (ECHILD) cũng coi như xong.
    static func reap(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { return true }
            usleep(20_000)
        }
        return false
    }

    func path(_ rel: String) -> String { data + "/" + rel }
}

/// Chờ event theo điều kiện với timeout cứng (không treo suite).
func waitForSessionEvent(
    _ session: RemoteSession, timeout: TimeInterval = 20,
    where match: @escaping @Sendable (SessionEvent) -> Bool
) async -> SessionEvent? {
    await withTaskGroup(of: SessionEvent?.self) { group in
        group.addTask {
            for await e in session.events where match(e) { return e }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Dựng sshd tạm + một phiên đã kết nối, luôn dọn.
func withRemote(
    _ body: (TempSshd, RemoteSession, RemoteFileService) async throws -> Void
) async throws {
    guard TempSshd.available else { return }
    let env = try TempSshd()
    do {
        do {
            try env.startServer()
        } catch {
            // Không có sshd dùng được -> bỏ qua có lý do (không đỏ suite).
            Issue.record("SKIP: sshd tạm không khởi động được: \(error)", severity: .warning)
            await env.cleanup()
            return
        }
        let session = try env.makeSession()
        try await session.start()
        let ev = await waitForSessionEvent(session) { $0 == .connected || isDisconnected($0) }
        #expect(ev == .connected)
        guard ev == .connected else {
            await env.cleanup()
            return
        }
        try await body(env, session, RemoteFileService(session: session, timeout: 20))
    } catch {
        await env.cleanup()
        throw error
    }
    await env.cleanup()
}

func isDisconnected(_ e: SessionEvent) -> Bool {
    if case .disconnected = e { return true }
    return false
}

extension ProcessGroup {
    @Suite(.timeLimit(.minutes(2)))
    struct RemoteIntegrationTests {
        static func shell(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ln")
            p.arguments = args
            try p.run()
            p.waitUntilExit()
        }

        @Test func listsMixedDirectory() async throws {
            try await withRemote { env, _, files in
                let fm = FileManager.default
                let d = env.path("list")
                try fm.createDirectory(atPath: d + "/sub dir é", withIntermediateDirectories: true)
                fm.createFile(atPath: d + "/plain.txt", contents: Data("hello".utf8))
                fm.createFile(atPath: d + "/tên 日本 \"q\" $x \\b.txt", contents: Data("x".utf8))
                fm.createFile(atPath: d + "/ lead", contents: Data())
                try fm.createSymbolicLink(atPath: d + "/link", withDestinationPath: "plain.txt")

                let listing = try await files.list(d)
                #expect(listing.unparsedLines == 0)
                let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
                #expect(byName["plain.txt"]?.kind == .file)
                #expect(byName["plain.txt"]?.size == 5)
                #expect(byName["sub dir é"]?.kind == .directory)
                #expect(byName["link"]?.kind == .symlink)
                #expect(byName["tên 日本 \"q\" $x \\b.txt"]?.kind == .file)
                #expect(byName[" lead"] != nil)
                #expect(byName["plain.txt"]?.modified != nil)
                #expect(byName["plain.txt"]?.permissions.count == 10)
                #expect(listing.entries.count == 5)

                let home = try await files.home()
                #expect(home.hasPrefix("/"))
                // Thư mục không tồn tại.
                await #expect(throws: RemoteFileError.notFound(d + "/nope")) {
                    try await files.list(d + "/nope")
                }
                await #expect(throws: RemoteFileError.invalidPath("relative")) {
                    try await files.list("relative")
                }
                await #expect(throws: RemoteFileError.unsupportedName("/a\nb")) {
                    try await files.list("/a\nb")
                }
            }
        }

        @Test func mkdirRenameRemoveRmdir() async throws {
            try await withRemote { env, _, files in
                let fm = FileManager.default
                let base = env.path("ops")
                try fm.createDirectory(atPath: base, withIntermediateDirectories: true)

                try await files.mkdir(base + "/new dir")
                var isDir: ObjCBool = false
                #expect(fm.fileExists(atPath: base + "/new dir", isDirectory: &isDir) && isDir.boolValue)

                fm.createFile(atPath: base + "/a.txt", contents: Data("A".utf8))
                fm.createFile(atPath: base + "/b.txt", contents: Data("B".utf8))
                // Không ghi đè khi đích tồn tại.
                await #expect(throws: RemoteFileError.destinationExists(base + "/b.txt")) {
                    try await files.rename(from: base + "/a.txt", to: base + "/b.txt", overwrite: false)
                }
                #expect(fm.fileExists(atPath: base + "/a.txt"))
                #expect(try String(contentsOfFile: base + "/b.txt", encoding: .utf8) == "B")
                // Đích chưa có -> đổi tên.
                try await files.rename(from: base + "/a.txt", to: base + "/c d.txt", overwrite: false)
                #expect(!fm.fileExists(atPath: base + "/a.txt"))
                #expect(fm.fileExists(atPath: base + "/c d.txt"))
                // Ghi đè.
                try await files.rename(from: base + "/c d.txt", to: base + "/b.txt", overwrite: true)
                #expect(try String(contentsOfFile: base + "/b.txt", encoding: .utf8) == "A")

                try await files.remove(file: base + "/b.txt")
                #expect(!fm.fileExists(atPath: base + "/b.txt"))
                await #expect(throws: RemoteFileError.notFound(base + "/b.txt")) {
                    try await files.remove(file: base + "/b.txt")
                }

                // rmdir thư mục rỗng ok; không rỗng -> directoryNotEmpty.
                try await files.removeEmptyDirectory(base + "/new dir")
                #expect(!fm.fileExists(atPath: base + "/new dir"))
                try fm.createDirectory(atPath: base + "/full", withIntermediateDirectories: true)
                fm.createFile(atPath: base + "/full/x", contents: Data())
                await #expect(throws: RemoteFileError.directoryNotEmpty(base + "/full")) {
                    try await files.removeEmptyDirectory(base + "/full")
                }
                #expect(fm.fileExists(atPath: base + "/full/x"))
            }
        }

        @Test func recursiveDeleteDoesNotFollowSymlinkOutOfTree() async throws {
            try await withRemote { env, _, files in
                let fm = FileManager.default
                let outside = env.path("outside")
                try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
                fm.createFile(atPath: outside + "/precious.txt", contents: Data("keep".utf8))
                let tree = env.path("tree")
                try fm.createDirectory(atPath: tree + "/a/b", withIntermediateDirectories: true)
                fm.createFile(atPath: tree + "/top.txt", contents: Data())
                fm.createFile(atPath: tree + "/a/b/deep file.txt", contents: Data())
                try fm.createSymbolicLink(atPath: tree + "/a/out-file", withDestinationPath: outside + "/precious.txt")
                try fm.createSymbolicLink(atPath: tree + "/a/b/out-dir", withDestinationPath: outside)

                let plan = try await files.planRecursiveDelete(tree)
                // top.txt, deep file.txt, out-file, out-dir, thư mục a/b, a, tree = 7
                #expect(plan.totalCount == 7)
                #expect(plan.items.last == RemoteDeleteItem(path: tree, kind: .directory))
                #expect(!plan.items.contains { $0.path.hasPrefix(outside) })
                // Thư mục sâu xoá trước cha.
                let idxB = plan.items.firstIndex { $0.path == tree + "/a/b" }!
                let idxA = plan.items.firstIndex { $0.path == tree + "/a" }!
                #expect(idxB < idxA)

                let deleted = try await files.executeRecursiveDelete(plan)
                #expect(deleted == 7)
                #expect(!fm.fileExists(atPath: tree))
                #expect(try String(contentsOfFile: outside + "/precious.txt", encoding: .utf8) == "keep")
                #expect(fm.fileExists(atPath: outside))
            }
        }

        @Test func recursiveDeleteStopsAtFirstError() async throws {
            try await withRemote { env, _, files in
                let fm = FileManager.default
                let tree = env.path("tree2")
                try fm.createDirectory(atPath: tree, withIntermediateDirectories: true)
                fm.createFile(atPath: tree + "/one", contents: Data())
                let plan = try await files.planRecursiveDelete(tree)
                #expect(plan.totalCount == 2)
                try fm.removeItem(atPath: tree + "/one")  // file biến mất trước khi thực thi
                do {
                    _ = try await files.executeRecursiveDelete(plan)
                    Issue.record("phải lỗi")
                } catch let RemoteFileError.deleteInterrupted(deleted, failed, _) {
                    #expect(deleted == 0)
                    #expect(failed == tree + "/one")
                }
                #expect(fm.fileExists(atPath: tree))
            }
        }

        @Test func planLimit() async throws {
            try await withRemote { env, _, files in
                let fm = FileManager.default
                let tree = env.path("big")
                try fm.createDirectory(atPath: tree, withIntermediateDirectories: true)
                for i in 0..<(RemoteFileService.maxPlanEntries + 1) {
                    fm.createFile(atPath: tree + "/f\(i)", contents: nil)
                }
                await #expect(throws: RemoteFileError.tooManyEntries(limit: RemoteFileService.maxPlanEntries)) {
                    try await files.planRecursiveDelete(tree)
                }
            }
        }

        @Test func permissionDenied() async throws {
            try await withRemote { env, _, files in
                guard getuid() != 0 else { return }
                let fm = FileManager.default
                let ro = env.path("ro")
                try fm.createDirectory(atPath: ro, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro)
                await #expect(throws: RemoteFileError.permissionDenied(ro + "/x")) {
                    try await files.mkdir(ro + "/x")
                }
            }
        }

        @Test func killedMasterGivesSessionLostWithoutHanging() async throws {
            try await withRemote { env, session, files in
                _ = try await files.list(env.data)
                let pid = try #require(await session.masterPID)
                kill(pid, SIGKILL)
                // Chờ master chết thật.
                var alive = true
                for _ in 0..<50 where alive {
                    alive = await session.checkAlive()
                    if alive { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                #expect(!alive)
                let start = Date()
                await #expect(throws: RemoteFileError.sessionLost) { try await files.list(env.data) }
                #expect(Date().timeIntervalSince(start) < 10)
                await #expect(throws: RemoteFileError.sessionLost) { try await files.home() }
                // Bỏ qua pre-check: đúng bộ cờ của RemoteFileService KHÔNG được âm thầm xác thực lại
                // bằng key (sshd tạm chấp nhận key!) mà phải thất bại nhanh với 255.
                let out = try await SimpleProcess.run(
                    executable: "/usr/bin/sftp",
                    arguments: [
                        "-q", "-F", session.configPath, "-o", "ControlPath=\(session.controlPath)",
                        "-o", "BatchMode=yes", "-o", "PreferredAuthentications=none",
                        "-o", "ConnectTimeout=10", "-b", "-", "--", session.alias,
                    ], stdin: "pwd\n", environment: ProcessEnvironment.inherited(), timeout: 15)
                #expect(out.status == 255)
                #expect(!out.timedOut)
                #expect(!out.stdout.contains("Remote working directory"))
            }
        }

        @Test func closeLeavesNoMasterAndNoSocket() async throws {
            try await withRemote { _, session, files in
                let pid = try #require(await session.masterPID)
                #expect(FileManager.default.fileExists(atPath: session.controlPath))
                await session.close()
                #expect(kill(pid, 0) != 0)  // đã thoát và được reap
                #expect(!FileManager.default.fileExists(atPath: session.controlPath))
                #expect(await session.masterPID == nil)
                #expect(await !session.checkAlive())
                await #expect(throws: RemoteFileError.sessionLost) { try await files.home() }
                await session.close()  // idempotent
            }
        }

        @Test func staleSocketIsRemovedAndStartSucceeds() async throws {
            guard TempSshd.available else { return }
            let env = try TempSshd()
            do {
                try env.startServer()
            } catch {
                Issue.record("SKIP: sshd tạm không khởi động được: \(error)", severity: .warning)
                await env.cleanup()
                return
            }
            let session = try env.makeSession()
            // Tạo socket cũ: bind unix socket rồi đóng fd (file vẫn còn, không ai listen).
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let path = session.controlPath
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let bytes = Array(path.utf8)
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(fd)
            #expect(rc == 0)
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(await !session.checkAlive())
            try await session.start()
            let ev = await waitForSessionEvent(session) { $0 == .connected || isDisconnected($0) }
            #expect(ev == .connected)
            let files = RemoteFileService(session: session, timeout: 20)
            _ = try await files.list(env.data)
            await env.cleanup()
        }

        @Test func secondSessionOnSameSocketIsRejected() async throws {
            try await withRemote { env, session, _ in
                let dup = RemoteSession(
                    alias: env.alias, configPath: env.clientConfig, controlPath: session.controlPath)
                await #expect(throws: RemoteSessionError.socketInUse(session.controlPath)) {
                    try await dup.start()
                }
                // Master gốc không bị đụng tới.
                #expect(await session.checkAlive())
            }
        }

        @Test func unreachableHostEmitsDisconnected() async throws {
            guard TempSshd.available else { return }
            let env = try TempSshd()
            do {
                try env.startServer()
            } catch {
                await env.cleanup()
                return
            }
            // Dừng sshd để cổng đóng: ssh thoát ngay với lỗi.
            try "Host dead\n    HostName 127.0.0.1\n    Port 1\n    User x\n    BatchMode yes\n"
                .write(toFile: env.root + "/dead_config", atomically: true, encoding: .utf8)
            let dir = try SocketDirectory.ensure(base: env.root)
            let s = RemoteSession(
                alias: "dead", configPath: env.root + "/dead_config", hostID: UUID(), socketDirectory: dir)
            try await s.start()
            let ev = await waitForSessionEvent(s) { isDisconnected($0) }
            if case .disconnected(let reason) = ev {
                #expect(!reason.isEmpty)
            } else {
                Issue.record("không có disconnected")
            }
            await env.cleanup()
        }
    }
}
