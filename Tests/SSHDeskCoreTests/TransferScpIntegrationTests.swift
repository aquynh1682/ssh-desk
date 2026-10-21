import Foundation
import Testing

@testable import SSHDeskCore

/// Chạy `/usr/bin/scp` thật với "fake ssh" (`exec /usr/libexec/sftp-server`): không có mạng.
/// Bỏ qua nếu máy không có sftp-server.
struct ScpIntegrationTests {
    static let sftpServer = "/usr/libexec/sftp-server"
    static var available: Bool {
        FileManager.default.isExecutableFile(atPath: sftpServer)
            && FileManager.default.isExecutableFile(atPath: ScpCommandBuilder.executable)
    }

    struct Env {
        let root: URL
        let fakeSSH: String
        var remote: URL { root.appendingPathComponent("remote") }
        var local: URL { root.appendingPathComponent("local") }
        var out: URL { root.appendingPathComponent("out") }

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("sshdesk-scp-\(UUID().uuidString)")
            for d in ["remote", "local", "out"] {
                try fm.createDirectory(
                    at: root.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            let fake = root.appendingPathComponent("fakessh")
            try Data("#!/bin/sh\nexec \(ScpIntegrationTests.sftpServer)\n".utf8).write(to: fake)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            fakeSSH = fake.path
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func run(_ job: TransferJob) throws -> (status: Int32, partial: String?) {
            let inv = try ScpCommandBuilder.build(for: job)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: inv.executable)
            p.arguments = ["-S", fakeSSH, "-q"] + inv.arguments
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return (p.terminationStatus, inv.tempPartialPath)
        }

        func job(
            _ dir: TransferDirection, source: String, destination: String,
            kind: TransferItemKind = .file
        ) -> TransferJob {
            sampleJob(
                direction: dir, source: source, destination: destination, kind: kind,
                config: "/dev/null")
        }
    }

    static let names = [
        "x?", "x[a]", "x]b[", "x a", "x'q", "x\"q", "x$HOME", "xé日本", "x;y", "x&y", "x(y)",
        "x{a,b}", "x~", "x#y", "x!y", "x%y", "x`y`", "x|y", "x<y>", "x\\y", "x\\", "-dash",
        "x*", "x:y", "x**", "[a]", "?",
    ]

    @Test(.enabled(if: ScpIntegrationTests.available))
    func downloadLiteralNamesWithDecoys() throws {
        let env = try Env()
        defer { env.cleanup() }
        let fm = FileManager.default
        // Mồi nhử để glob không escape sẽ khớp nhầm.
        for d in ["xa", "xb", "x1", "xaa", "a", "b", "-dashed", "x\\z"] {
            try Data("decoy".utf8).write(to: env.remote.appendingPathComponent(d))
        }
        for n in Self.names {
            try Data("R:\(n)".utf8).write(to: env.remote.appendingPathComponent(n))
        }
        for n in Self.names {
            let dest = env.out.appendingPathComponent("res")
            let job = env.job(
                .download, source: env.remote.path + "/" + n, destination: dest.path)
            let r = try env.run(job)
            let partial = try #require(r.partial)
            #expect(r.status == 0, "tải \(n)")
            #expect(
                (try? String(contentsOfFile: partial, encoding: .utf8)) == "R:\(n)", "nội dung \(n)")
            try LocalFinalizer.finalize(
                partialPath: partial, destination: dest.path, policy: .overwrite, jobID: job.id)
            #expect(try String(contentsOf: dest, encoding: .utf8) == "R:\(n)")
            try fm.removeItem(at: dest)
        }
    }

    @Test(.enabled(if: ScpIntegrationTests.available))
    func uploadLiteralNames() throws {
        let env = try Env()
        defer { env.cleanup() }
        for n in Self.names {
            try Data("L:\(n)".utf8).write(to: env.local.appendingPathComponent(n))
        }
        for n in Self.names {
            let job = env.job(
                .upload, source: env.local.path + "/" + n, destination: env.remote.path + "/" + n)
            let r = try env.run(job)
            #expect(r.status == 0, "tải lên \(n)")
        }
        let remoteNames = try FileManager.default.contentsOfDirectory(atPath: env.remote.path)
        #expect(Set(remoteNames) == Set(Self.names))
        for n in Self.names {
            #expect(
                (try? String(contentsOf: env.remote.appendingPathComponent(n), encoding: .utf8))
                    == "L:\(n)", "nội dung \(n)")
        }
    }

    @Test(.enabled(if: ScpIntegrationTests.available))
    func directoryRoundTripWithGlobCharsInPath() throws {
        let env = try Env()
        defer { env.cleanup() }
        let fm = FileManager.default
        let src = env.remote.appendingPathComponent("tree[1]?")
        try fm.createDirectory(
            at: src.appendingPathComponent("sub*"), withIntermediateDirectories: true)
        try Data("A".utf8).write(to: src.appendingPathComponent("sub*/a[1].txt"))
        try Data("B".utf8).write(to: src.appendingPathComponent("b?.txt"))
        // Mồi nhử
        try fm.createDirectory(
            at: env.remote.appendingPathComponent("tree1x"), withIntermediateDirectories: true)
        try Data("D".utf8).write(to: env.remote.appendingPathComponent("tree1x/decoy"))

        let dest = env.out.appendingPathComponent("tree")
        let dl = env.job(.download, source: src.path, destination: dest.path, kind: .directory)
        let r = try env.run(dl)
        #expect(r.status == 0)
        try LocalFinalizer.finalize(
            partialPath: try #require(r.partial), destination: dest.path, policy: .overwrite,
            jobID: dl.id)
        #expect(try String(contentsOf: dest.appendingPathComponent("sub*/a[1].txt")) == "A")
        #expect(try String(contentsOf: dest.appendingPathComponent("b?.txt")) == "B")
        #expect(!fm.fileExists(atPath: dest.appendingPathComponent("decoy").path))

        let up = env.job(
            .upload, source: dest.path, destination: env.root.path + "/up[1]", kind: .directory)
        #expect(try env.run(up).status == 0)
        let upDir = env.root.appendingPathComponent("up[1]")
        #expect(try String(contentsOf: upDir.appendingPathComponent("sub*/a[1].txt")) == "A")
    }

    /// Ghi lại hành vi symlink của `scp -r` (SFTP) làm căn cứ cho KNOWN_LIMITATIONS:
    /// nó THEO symlink ra ngoài cây. Nếu test này đỏ, hành vi đã đổi → xem lại chính sách chặn.
    @Test(.enabled(if: ScpIntegrationTests.available))
    func uploadDirectoryFollowsSymlinksSoInspectorMustBlock() throws {
        let env = try Env()
        defer { env.cleanup() }
        let fm = FileManager.default
        let outside = env.root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("SECRET".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        let tree = env.local.appendingPathComponent("proj")
        try fm.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("IN".utf8).write(to: tree.appendingPathComponent("in.txt"))
        try fm.createSymbolicLink(
            atPath: tree.appendingPathComponent("sub/link").path,
            withDestinationPath: outside.path)

        #expect(LocalTreeInspector.symlinks(at: tree.path) == ["sub/link"])
        #expect(LocalTreeInspector.symlinks(at: outside.path).isEmpty)
        #expect(LocalTreeInspector.symlinks(at: tree.appendingPathComponent("sub/link").path) == ["."])
        #expect(LocalTreeInspector.symlinks(at: tree.appendingPathComponent("in.txt").path).isEmpty)

        let up = env.job(
            .upload, source: tree.path, destination: env.root.path + "/up", kind: .directory)
        #expect(try env.run(up).status == 0)
        let leaked = env.root.appendingPathComponent("up/sub/link/secret.txt")
        #expect(fm.fileExists(atPath: leaked.path))
    }
}
