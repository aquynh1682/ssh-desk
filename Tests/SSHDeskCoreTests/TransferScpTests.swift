import Foundation
import Testing

@testable import SSHDeskCore

struct ScpCommandBuilderTests {
    @Test func downloadArgv() throws {
        let id = UUID()
        let job = sampleJob(
            direction: .download, source: "/srv/my file*.txt",
            destination: "/Users/me/Downloads/a.txt", id: id)
        let inv = try ScpCommandBuilder.build(for: job)
        #expect(inv.executable == "/usr/bin/scp")
        let partial = "/Users/me/Downloads/.a.txt.sshdesk-\(id.uuidString).part"
        #expect(inv.tempPartialPath == partial)
        #expect(
            inv.arguments == [
                "-F", "/Users/me/ssh/config", "-o", "ConnectTimeout=15", "--",
                "sshdesk-abc:/srv/my file\\*.txt", partial,
            ])
        #expect(LocalFinalizer.isPartialPath(partial, jobID: id))
    }

    @Test func uploadDirectoryArgvDoesNotEscapeRemoteDestination() throws {
        let job = sampleJob(
            direction: .upload, source: "/Users/me/proj", destination: "/srv/d[1]/-x:y",
            kind: .directory)
        let inv = try ScpCommandBuilder.build(for: job)
        #expect(inv.tempPartialPath == nil)
        #expect(
            inv.arguments == [
                "-F", "/Users/me/ssh/config", "-o", "ConnectTimeout=15", "-r", "--",
                "/Users/me/proj", "sshdesk-abc:/srv/d[1]/-x:y",
            ])
    }

    @Test func forbiddenFlagsNeverPresent() throws {
        for kind in [TransferItemKind.file, .directory] {
            for dir in [TransferDirection.upload, .download] {
                let inv = try ScpCommandBuilder.build(
                    for: sampleJob(direction: dir, source: "/a", destination: "/b", kind: kind))
                #expect(!inv.arguments.contains("-O"))
                #expect(!inv.arguments.contains("-B"))
                #expect(!inv.arguments.contains { $0.contains("StrictHostKeyChecking") })
                #expect(!inv.arguments.contains("-q"))
                let dd = try #require(inv.arguments.firstIndex(of: "--"))
                #expect(inv.arguments[dd...].count == 3)
            }
        }
    }

    @Test func escape() {
        #expect(ScpCommandBuilder.escapeRemoteSource("a\\b*c?d[e]") == "a\\\\b\\*c\\?d\\[e\\]")
        #expect(ScpCommandBuilder.escapeRemoteSource("x y é'\"$") == "x y é'\"$")
    }

    @Test func rejectsBadInput() {
        func err(_ j: TransferJob) -> ScpBuildError? {
            do { _ = try ScpCommandBuilder.build(for: j) } catch { return error as? ScpBuildError }
            return nil
        }
        #expect(
            err(sampleJob(direction: .upload, source: "rel/a:b", destination: "/x"))
                == .localPathNotAbsolute("rel/a:b"))
        #expect(
            err(sampleJob(direction: .download, source: "/x", destination: "a:b"))
                == .localPathNotAbsolute("a:b"))
        #expect(err(sampleJob(direction: .upload, source: "/a\nb", destination: "/x")) != nil)
        #expect(err(sampleJob(direction: .upload, source: "/a\u{0}b", destination: "/x")) != nil)
        #expect(err(sampleJob(direction: .download, source: "/x", destination: "/a\tb")) != nil)
        #expect(err(sampleJob(direction: .upload, source: "/a", destination: "")) == .emptyRemotePath)
        #expect(err(sampleJob(direction: .download, source: "", destination: "/a")) == .emptyRemotePath)
        #expect(
            err(sampleJob(direction: .upload, source: "/a", destination: "/x\ny"))
                == .unsupportedRemotePathCharacter("U+000A"))
        #expect(
            err(sampleJob(direction: .download, source: "/x\u{7}", destination: "/a"))
                == .unsupportedRemotePathCharacter("U+0007"))
        #expect(err(sampleJob(alias: "-oProxyCommand=x")) == .invalidAlias("-oProxyCommand=x"))
        #expect(err(sampleJob(config: "relative/config")) == .invalidConfigPath)
        #expect(err(sampleJob(direction: .download, source: "/x", destination: "/")) != nil)
    }
}

struct ScpControlPathTests {
    @Test func controlPathAddsOptionBeforeDoubleDash() throws {
        let job = sampleJob(direction: .upload, source: "/tmp/a", destination: "/srv/a")
        let plain = try ScpCommandBuilder.build(for: job)
        #expect(!plain.arguments.contains { $0.hasPrefix("ControlPath=") })
        let inv = try ScpCommandBuilder.build(for: job, controlPath: "/tmp/sshdesk-501/abc")
        let i = try #require(inv.arguments.firstIndex(of: "ControlPath=/tmp/sshdesk-501/abc"))
        #expect(inv.arguments[i - 1] == "-o")
        #expect(i < (inv.arguments.firstIndex(of: "--") ?? 0))
    }

    @Test(arguments: ["relative/x", "/tmp/a b", "/tmp/%C", "/tmp/a\nb", ""])
    func invalidControlPathIsRejected(_ path: String) {
        let job = sampleJob(direction: .upload, source: "/tmp/a", destination: "/srv/a")
        #expect(throws: ScpBuildError.invalidControlPath(path)) {
            try ScpCommandBuilder.build(for: job, controlPath: path)
        }
    }
}

struct LocalFinalizerTests {
    func tmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sshdesk-fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func write(_ u: URL, _ s: String) throws { try Data(s.utf8).write(to: u) }
    func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    @Test func overwriteReplacesAtomically() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let dest = d.appendingPathComponent("a.txt")
        let part = URL(fileURLWithPath: try ScpCommandBuilder.partialPath(for: dest.path, jobID: id))
        try write(dest, "old")
        try write(part, "new")
        let out = try LocalFinalizer.finalize(
            partialPath: part.path, destination: dest.path, policy: .overwrite, jobID: id)
        #expect(out == .replaced(dest.path))
        #expect(read(dest) == "new")
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func overwriteWhenNoExistingDestination() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let dest = d.appendingPathComponent("a.txt")
        let part = URL(fileURLWithPath: try ScpCommandBuilder.partialPath(for: dest.path, jobID: id))
        try write(part, "new")
        try LocalFinalizer.finalize(
            partialPath: part.path, destination: dest.path, policy: .overwrite, jobID: id)
        #expect(read(dest) == "new")
    }

    @Test func renameUsesNewNameAndNeverOverwrites() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let dest = d.appendingPathComponent("a.txt")
        let part = URL(fileURLWithPath: try ScpCommandBuilder.partialPath(for: dest.path, jobID: id))
        try write(dest, "old")
        try write(part, "new")
        let out = try LocalFinalizer.finalize(
            partialPath: part.path, destination: dest.path, policy: .rename("a (1).txt"), jobID: id)
        #expect(out == .renamed(d.appendingPathComponent("a (1).txt").path))
        #expect(read(dest) == "old")
        #expect(read(d.appendingPathComponent("a (1).txt")) == "new")

        // Đích mới cũng tồn tại → lỗi, không ghi đè, .part còn nguyên.
        try write(part, "newer")
        #expect(throws: LocalFinalizeError.destinationExists(d.appendingPathComponent("a (1).txt").path)) {
            try LocalFinalizer.finalize(
                partialPath: part.path, destination: dest.path, policy: .rename("a (1).txt"),
                jobID: id)
        }
        #expect(read(d.appendingPathComponent("a (1).txt")) == "new")
        #expect(read(part) == "newer")
        for bad in ["", ".", "..", "x/y", "a\nb"] {
            #expect(throws: LocalFinalizeError.invalidNewName(bad)) {
                try LocalFinalizer.finalize(
                    partialPath: part.path, destination: dest.path, policy: .rename(bad), jobID: id)
            }
        }
    }

    @Test func skipRemovesOnlyPartial() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let dest = d.appendingPathComponent("a.txt")
        let part = URL(fileURLWithPath: try ScpCommandBuilder.partialPath(for: dest.path, jobID: id))
        try write(dest, "old")
        try write(part, "new")
        #expect(
            try LocalFinalizer.finalize(
                partialPath: part.path, destination: dest.path, policy: .skip, jobID: id)
                == .skipped)
        #expect(read(dest) == "old")
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func cleanupOnlyRemovesThisJobsPartial() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let other = UUID()
        let mine = d.appendingPathComponent(".a.sshdesk-\(id.uuidString).part")
        let theirs = d.appendingPathComponent(".a.sshdesk-\(other.uuidString).part")
        let user = d.appendingPathComponent("a.txt")
        let userDir = d.appendingPathComponent("important")
        try write(mine, "m")
        try write(theirs, "t")
        try write(user, "u")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        #expect(!LocalFinalizer.cleanupPartial(path: user.path, jobID: id))
        #expect(!LocalFinalizer.cleanupPartial(path: theirs.path, jobID: id))
        #expect(!LocalFinalizer.cleanupPartial(path: userDir.path, jobID: id))
        #expect(!LocalFinalizer.cleanupPartial(path: "relative", jobID: id))
        #expect(!LocalFinalizer.cleanupPartial(path: d.path, jobID: id))
        #expect(LocalFinalizer.cleanupPartial(path: mine.path, jobID: id))
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
        #expect(FileManager.default.fileExists(atPath: user.path))
        #expect(!LocalFinalizer.cleanupPartial(path: mine.path, jobID: id))  // đã mất
    }

    @Test func cleanupPartialDirectoryAndSymlinkNotFollowed() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let id = UUID()
        let victim = d.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try write(victim.appendingPathComponent("keep"), "k")
        let link = d.appendingPathComponent(".v.sshdesk-\(id.uuidString).part")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        #expect(LocalFinalizer.cleanupPartial(path: link.path, jobID: id))
        #expect(read(victim.appendingPathComponent("keep")) == "k")
        let dir = d.appendingPathComponent(".t.sshdesk-\(id.uuidString).part")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(dir.appendingPathComponent("f"), "f")
        #expect(LocalFinalizer.cleanupPartial(path: dir.path, jobID: id))
    }

    @Test func finalizeRefusesForeignPartial() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("user.txt")
        try write(f, "u")
        #expect(throws: LocalFinalizeError.self) {
            try LocalFinalizer.finalize(
                partialPath: f.path, destination: d.appendingPathComponent("z").path,
                policy: .skip, jobID: UUID())
        }
        #expect(read(f) == "u")
    }

    @Test func uniqueNamesAndConflict() throws {
        let d = try tmp()
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(LocalFinalizer.numbered("a.txt", 1) == "a (1).txt")
        #expect(LocalFinalizer.numbered(".bashrc", 2) == ".bashrc (2)")
        #expect(LocalFinalizer.numbered("dir", 3) == "dir (3)")
        #expect(LocalFinalizer.suggestUniqueName("a.txt", in: d.path) == "a.txt")
        try write(d.appendingPathComponent("a.txt"), "1")
        #expect(LocalFinalizer.suggestUniqueName("a.txt", in: d.path) == "a (1).txt")
        try write(d.appendingPathComponent("a (1).txt"), "1")
        #expect(LocalFinalizer.suggestUniqueName("a.txt", in: d.path) == "a (2).txt")
        #expect(LocalFinalizer.localConflict(d.appendingPathComponent("a.txt").path))
        #expect(!LocalFinalizer.localConflict(d.appendingPathComponent("zzz").path))
        let dangling = d.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            atPath: dangling.path, withDestinationPath: "/nonexistent/x")
        #expect(LocalFinalizer.localConflict(dangling.path))
    }
}
