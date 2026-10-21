import Foundation
import Testing

@testable import SSHDeskCore

/// Thư mục tạm riêng cho mỗi test; không bao giờ đọc ~/.ssh thật.
private final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshimport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let u = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: u)
        return u
    }

    func scan(_ name: String = "config", depth: Int = 5) -> SSHConfigScanResult {
        SSHConfigImporter.scan(
            path: url.appendingPathComponent(name), maxIncludeDepth: depth,
            includeBaseDirectory: url)
    }
}

@Suite struct SSHImportParserTests {
    @Test func hostDonVaGiaTriTho() {
        let d = TempDir()
        d.write(
            "config",
            """
            Host web
                HostName 10.0.0.5
                User deploy
                Port 2222
                IdentityFile ~/.ssh/id_web
                ProxyJump bastion
            """)
        let r = d.scan()
        #expect(r.candidates.count == 1)
        let c = r.candidates[0]
        #expect(c.alias == "web")
        #expect(c.line == 1)
        #expect(c.hostName == "10.0.0.5")
        #expect(c.user == "deploy")
        #expect(c.port == 2222)
        #expect(c.identityFile == "~/.ssh/id_web")
        #expect(c.proxyJump == "bastion")
        #expect(!c.hasProxyCommand)
        #expect(!c.hasMatchOrComplexity)
        #expect(r.warnings.isEmpty)
    }

    @Test func nhieuAliasMotDong() {
        let d = TempDir()
        d.write("config", "Host a b c\n  User u\n")
        let r = d.scan()
        #expect(r.candidates.map(\.alias) == ["a", "b", "c"])
        #expect(r.candidates.allSatisfy { $0.user == "u" })
    }

    @Test func wildcardVaNegationBiBoQua() {
        let d = TempDir()
        d.write(
            "config",
            """
            Host *
                User all
            Host *.internal
                User x
            Host real !other
                HostName r
            Host ?db
            """)
        let r = d.scan()
        #expect(r.candidates.map(\.alias) == ["real"])
        #expect(r.candidates[0].hasMatchOrComplexity)
        #expect(r.candidates[0].user == nil)
        #expect(r.skippedPatterns == ["*", "*.internal", "!other", "?db"])
    }

    @Test func keyBangDauBangNhayVaComment() {
        let d = TempDir()
        d.write(
            "config",
            """
            # comment
            HOST=srv   # ghi chu
            \thostname = "my host.example"
              USER="a b"

            port=22
            """)
        let r = d.scan()
        #expect(r.candidates.count == 1)
        #expect(r.candidates[0].alias == "srv")
        #expect(r.candidates[0].hostName == "my host.example")
        #expect(r.candidates[0].user == "a b")
        #expect(r.candidates[0].port == 22)
    }

    @Test func giaTriDauTienThang() {
        let d = TempDir()
        d.write("config", "Host a\nUser first\nUser second\n")
        #expect(d.scan().candidates[0].user == "first")
    }

    @Test func nhayKhongDongBiBoQuaVaCanhBao() {
        let d = TempDir()
        d.write("config", "Host \"abc\nUser u\n")
        let r = d.scan()
        #expect(r.candidates.isEmpty)
        #expect(r.warnings.contains { $0.kind == .malformedLine && $0.line == 1 })
    }

    @Test func aliasLaKhongThanhCandidate() {
        let d = TempDir()
        d.write(
            "config",
            "Host ok bad;rm $HOME \"with space\" -lead\nHost evil\rProxyCommand touch /tmp/x\n")
        let r = d.scan()
        #expect(r.candidates.map(\.alias) == ["ok"])
        let kinds = r.warnings.map(\.kind)
        #expect(kinds.filter { $0 == .invalidAlias }.count == 4)  // bad;rm, $HOME, "with space", -lead
        #expect(kinds.contains(.malformedLine))  // dòng có \r giữa dòng
        #expect(r.warnings.allSatisfy { !$0.message.contains("\r") })
    }

    @Test func aliasTrungGiuBanDauVaCanhBao() {
        let d = TempDir()
        d.write("a", "Host dup\nUser one\nInclude b\n")
        d.write("b", "Host dup\nUser two\n")
        let r = d.scan("a")
        #expect(r.candidates.count == 1)
        #expect(r.candidates[0].user == "one")
        #expect(r.warnings.contains { $0.kind == .duplicateAlias && $0.file.lastPathComponent == "b" && $0.line == 1 })
    }

    @Test func portKhongHopLeCanhBao() {
        let d = TempDir()
        d.write("config", "Host a\nPort abc\nPort 99999\n")
        let r = d.scan()
        #expect(r.candidates[0].port == nil)
        #expect(r.warnings.filter { $0.kind == .invalidValue }.count == 2)
    }

    @Test func fileGocKhongTonTaiKhongCrash() {
        let d = TempDir()
        let r = d.scan("none")
        #expect(r.candidates.isEmpty)
        #expect(r.warnings.first?.kind == .fileUnreadable)
    }

    @Test func defaultUserConfigURL() {
        #expect(SSHConfigImporter.defaultUserConfigURL.path.hasSuffix("/.ssh/config"))
    }
}

@Suite struct SSHImportIncludeTests {
    @Test func includeTuyetDoiVaTuongDoi() {
        let d = TempDir()
        let abs = d.write("elsewhere/abs.conf", "Host fromabs\n")
        d.write("rel.conf", "Host fromrel\n")
        d.write("config", "Include \(abs.path)\nInclude rel.conf\nHost main\n")
        let r = d.scan()
        #expect(r.candidates.map(\.alias) == ["fromabs", "fromrel", "main"])
        #expect(r.candidates[0].sourceFile.lastPathComponent == "abs.conf")
        #expect(r.candidates[0].line == 1)
        #expect(r.warnings.isEmpty)
    }

    @Test func includeGlobDonGian() {
        let d = TempDir()
        d.write("conf.d/10-a.conf", "Host ga\n")
        d.write("conf.d/20-b.conf", "Host gb\n")
        d.write("conf.d/skip.txt", "Host gc\n")
        d.write("config", "Include conf.d/*.conf\n")
        let r = d.scan()
        #expect(r.candidates.map(\.alias) == ["ga", "gb"])
    }

    @Test func includeKhongTonTaiCanhBao() {
        let d = TempDir()
        d.write("config", "Host a\nInclude missing.conf\nInclude ~nobody/x\nInclude $HOME/x\nInclude conf.d/*.zzz\n")
        let r = d.scan()
        #expect(r.candidates.count == 1)
        let w = r.warnings.filter { $0.kind == .includeUnresolved }
        #expect(w.count == 4)
        #expect(w.map(\.line) == [2, 3, 4, 5])
    }

    @Test func doSauGioiHan() {
        let d = TempDir()
        d.write("config", "Host h0\nInclude f1\n")
        d.write("f1", "Host h1\nInclude f2\n")
        d.write("f2", "Host h2\nInclude f3\n")
        d.write("f3", "Host h3\n")
        let r = d.scan(depth: 2)
        #expect(r.candidates.map(\.alias) == ["h0", "h1", "h2"])
        #expect(
            r.warnings.contains {
                $0.kind == .includeDepthExceeded && $0.file.lastPathComponent == "f2" && $0.line == 2
            })
        #expect(d.scan(depth: 3).candidates.count == 4)
    }

    @Test func vongInclude() {
        let d = TempDir()
        d.write("a", "Host ha\nInclude b\n")
        d.write("b", "Host hb\nInclude a\n")
        let r = d.scan("a")
        #expect(r.candidates.map(\.alias) == ["ha", "hb"])
        #expect(r.warnings.filter { $0.kind == .includeCycle }.count == 1)
        #expect(r.warnings.first { $0.kind == .includeCycle }?.file.lastPathComponent == "b")
    }

    @Test func vongQuaSymlink() throws {
        let d = TempDir()
        d.write("a", "Host ha\nInclude link\n")
        try FileManager.default.createSymbolicLink(
            at: d.url.appendingPathComponent("link"),
            withDestinationURL: d.url.appendingPathComponent("a"))
        let r = d.scan("a")
        #expect(r.candidates.count == 1)
        #expect(r.warnings.contains { $0.kind == .includeCycle })
    }

    @Test func includeTrongKhoiHostDanhDauPhucTap() {
        let d = TempDir()
        d.write("inc", "Host inner\n")
        d.write("config", "Host outer\nInclude inc\n")
        let r = d.scan()
        #expect(r.candidates.first { $0.alias == "inner" }?.hasMatchOrComplexity == true)
        #expect(r.candidates.first { $0.alias == "outer" }?.hasMatchOrComplexity == true)
    }
}

@Suite struct SSHImportSafetyTests {
    @Test func fileNhiPhanHoacKhongPhaiUTF8() {
        let d = TempDir()
        try? Data([0x48, 0x6F, 0x73, 0x74, 0x20, 0x61, 0x00, 0xFF, 0xFE]).write(
            to: d.url.appendingPathComponent("bin"))
        try? Data([0x48, 0x6F, 0x73, 0x74, 0x20, 0xFF, 0xFE, 0x0A]).write(
            to: d.url.appendingPathComponent("latin"))
        for n in ["bin", "latin"] {
            let r = d.scan(n)
            #expect(r.candidates.isEmpty)
            #expect(r.warnings.first?.kind == .notUTF8)
        }
    }

    @Test func fileQuaLon() {
        let d = TempDir()
        let big = "Host a\n" + String(repeating: "# pad pad pad pad pad pad\n", count: 50_000)
        d.write("config", big)
        let r = d.scan()
        #expect(r.candidates.isEmpty)
        #expect(r.warnings.first?.kind == .fileTooLarge)
    }

    @Test func quaNhieuDongCatBot() {
        let d = TempDir()
        let text = String(repeating: "\n", count: SSHConfigImporter.maxLines) + "Host late\n"
        d.write("config", text)
        let r = d.scan()
        #expect(r.candidates.isEmpty)
        #expect(r.warnings.contains { $0.kind == .tooManyLines })
    }

    @Test func matchExecKhongChayVaDuocGanCo() {
        let d = TempDir()
        let marker = "/tmp/pwned_test"
        try? FileManager.default.removeItem(atPath: marker)
        d.write(
            "config",
            """
            Host before
            Match exec "touch /tmp/pwned_test"
                User x
            Host after
                ProxyCommand touch /tmp/pwned_test
            """)
        let r = d.scan()
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(
            r.warnings.contains {
                $0.kind == .matchNotEvaluated && $0.line == 2 && $0.message.contains("Match chưa được đánh giá")
            })
        #expect(r.warnings.contains { $0.kind == .matchExec && $0.line == 2 })
        #expect(r.warnings.contains { $0.kind == .proxyCommand && $0.line == 5 })
        let before = r.candidates.first { $0.alias == "before" }
        let after = r.candidates.first { $0.alias == "after" }
        #expect(before?.user == nil)  // dòng thuộc khối Match, không gán cho Host before
        #expect(before?.hasMatchOrComplexity == false)
        #expect(after?.hasMatchOrComplexity == true)
        #expect(after?.hasProxyCommand == true)
    }

    @Test func chiDoc_KhongDoiFileNguonVaKhongTaoFile() throws {
        let d = TempDir()
        d.write("inc.conf", "Host i\n")
        let cfg = d.write("config", "Host a\nInclude inc.conf\nMatch exec \"x\"\nHost b\n")
        let fm = FileManager.default
        func snapshot() throws -> (Data, Date?, [String]) {
            let data = try Data(contentsOf: cfg)
            let m = try fm.attributesOfItem(atPath: cfg.path)[.modificationDate] as? Date
            return (data, m, try fm.contentsOfDirectory(atPath: d.url.path).sorted())
        }
        let before = try snapshot()
        _ = d.scan()
        let after = try snapshot()
        #expect(before.0 == after.0)
        #expect(before.1 == after.1)
        #expect(before.2 == after.2)
    }
}
