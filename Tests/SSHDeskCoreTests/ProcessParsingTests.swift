import Foundation
import Testing

@testable import SSHDeskCore

// Mẫu chuỗi: viết lại từ hiểu biết về output OpenSSH (sshconnect.c, sshconnect2.c, readpass.c, scp progressmeter.c).
// Chưa đối chiếu với ssh/scp thật trên máy này.

private let fp = "SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8"
private let hostKeyBlock =
    "The authenticity of host 'example.com (203.0.113.5)' can't be established.\n"
    + "ED25519 key fingerprint is \(fp).\n"
    + "This key is not known by any other names.\n"
    + "Are you sure you want to continue connecting (yes/no/[fingerprint])? "

private func detect(_ chunks: [String]) -> PromptKind? {
    var d = PromptDetector()
    var last: PromptKind?
    for c in chunks { if let k = d.feed(c) { last = k } }
    return last
}

@Suite struct PromptDetectorTests {
    @Test func password() {
        #expect(detect(["user@example.com's password: "]) == .password("user@example.com's password:"))
        #expect(detect(["Password: "]) == .password("Password:"))
        #expect(detect(["PASSWORD:"]) == .password("PASSWORD:"))
        #expect(detect(["Password for alice@example.com: "]) == .password("Password for alice@example.com:"))
        #expect(detect(["(alice@example.com) Password: "]) == .password("(alice@example.com) Password:"))
    }

    @Test func passphrase() {
        let k = detect(["Enter passphrase for key '/Users/me/.ssh/id_ed25519': "])
        #expect(k == .passphrase("Enter passphrase for key '/Users/me/.ssh/id_ed25519':"))
        #expect(detect(["Enter passphrase for /home/me/id_rsa: "]) != nil)
    }

    @Test func keyboardInteractive() {
        #expect(
            detect(["(alice@example.com) Verification code: "])
                == .keyboardInteractive("(alice@example.com) Verification code:"))
        #expect(detect(["Enter OTP: "]) == .keyboardInteractive("Enter OTP:"))
        #expect(detect(["Token: "]) == .keyboardInteractive("Token:"))
    }

    @Test func unknownPromptKeepsText() {
        #expect(detect(["Select a realm: "]) == .unknown("Select a realm:"))
    }

    @Test func noPromptWhenLineComplete() {
        #expect(detect(["Warning: Permanently added 'h' (ED25519) to the list of known hosts.\n"]) == nil)
        #expect(detect(["Password: \n"]) == nil)
        #expect(detect(["Welcome to server\n"]) == nil)
        #expect(detect(["Authenticated to host ([1.2.3.4]:22), using \"publickey\".\n"]) == nil)
    }

    @Test func hostKeyConfirm() {
        let k = detect([hostKeyBlock])
        guard case .hostKeyConfirm(let fingerprint, let text) = k else {
            Issue.record("mong hostKeyConfirm, nhận \(String(describing: k))")
            return
        }
        #expect(fingerprint == fp)
        #expect(text.contains("Are you sure you want to continue connecting"))
        #expect(text.count <= 300)
    }

    @Test func hostKeyConfirmWithoutFingerprintLine() {
        let k = detect(["Are you sure you want to continue connecting (yes/no)? "])
        guard case .hostKeyConfirm(let fingerprint, _) = k else {
            Issue.record("mong hostKeyConfirm")
            return
        }
        #expect(fingerprint == nil)
    }

    @Test func hostKeyChangedIsNotAPrompt() {
        let banner =
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n"
            + "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
            + "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n"
            + "IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\n"
        guard case .hostKeyChanged(let text) = detect([banner]) else {
            Issue.record("mong hostKeyChanged")
            return
        }
        #expect(text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
    }

    @Test func splitAcrossChunks() {
        #expect(detect(["Pass", "word", ": "]) == .password("Password:"))
        var d = PromptDetector()
        for part in hostKeyBlock.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            #expect(d.feed(String(part) + "\n") == nil)
        }
        #expect(d.feed("Are you sure you want to continue ") == nil)
        if case .hostKeyConfirm(let f, _) = d.feed("connecting (yes/no/[fingerprint])? ") {
            #expect(f == fp)
        } else {
            Issue.record("mong hostKeyConfirm")
        }
    }

    @Test func reportsOnlyOnce() {
        var d = PromptDetector()
        #expect(d.feed("Password: ") != nil)
        #expect(d.feed("") == nil)
    }

    @Test func hostileEscapeSequencesAreStripped() {
        let k = detect(["\u{1B}]0;evil title\u{07}\u{1B}[31m\u{1B}[2KPass\u{07}word:\u{1B}[0m \r"])
        #expect(k == .password("Password:"))
        guard case .password(let t) = detect(["Pass\u{0}word\u{8}: \u{202E}"]) else {
            Issue.record("mong password")
            return
        }
        #expect(t.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && $0.value != 0x202E })
    }

    @Test func overlongPromptIsClipped() {
        let long = String(repeating: "A", count: 10_000)
        guard case .password(let t) = detect(["Password for \(long): "]) else {
            Issue.record("mong password")
            return
        }
        #expect(t.count <= 300)
        guard case .passphrase(let p) = detect(["Enter passphrase for key '\(long)': "]) else {
            Issue.record("mong passphrase")
            return
        }
        #expect(p.count <= 300)
        if case .hostKeyConfirm(_, let text) = detect([long + "\n" + hostKeyBlock]) {
            #expect(text.count <= 300)
        } else {
            Issue.record("mong hostKeyConfirm")
        }
    }
}

@Suite struct OutputSanitizerTests {
    @Test func stripsAnsiAndControls() {
        #expect(OutputSanitizer.clean("a\u{1B}[1;31mred\u{1B}[0m\u{07}b\u{0}c") == "aredbc")
        #expect(OutputSanitizer.clean("x\u{1B}]8;;http://e\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "xlink")
        #expect(OutputSanitizer.clean("a\r\nb\rc") == "a\nb\nc")
        #expect(OutputSanitizer.clean("\u{85}\u{9B}ok") == "ok")
    }

    @Test func statefulAcrossChunks() {
        var s = OutputSanitizer()
        var out = s.feed(Array("a\u{1B}[3".utf8))
        out += s.feed(Array("1mb".utf8))
        #expect(out == "ab")
        let bytes = Array("é日".utf8)  // 2 + 3 byte
        var s2 = OutputSanitizer()
        var joined = ""
        for b in bytes { joined += s2.feed([b]) }
        joined += s2.finish()
        #expect(joined == "é日")
    }

    @Test func unterminatedOscDoesNotSwallowForever() {
        let junk = "\u{1B}]0;" + String(repeating: "x", count: 10_000) + "VISIBLE"
        #expect(OutputSanitizer.clean(junk).hasSuffix("VISIBLE"))
    }
}

@Suite struct ScpProgressParserTests {
    @Test func basicLine() throws {
        let p = try #require(ScpProgressParser.parse("file.bin                 45%  1234KB   1.2MB/s   00:03 ETA"))
        #expect(p.fileName == "file.bin")
        #expect(p.fraction == 0.45)
        #expect(p.bytes == Int64(1234 * 1024))
        #expect(try #require(p.bytesPerSecond) == 1.2 * 1024 * 1024)
        #expect(p.etaSeconds == 3)
    }

    @Test func unitsAndComplete() throws {
        let a = try #require(ScpProgressParser.parse("a  100%  512   0.0KB/s   00:00    "))
        #expect(a.fraction == 1)
        #expect(a.bytes == Int64(512))
        let b = try #require(ScpProgressParser.parse("big.iso   3%   2GB  10.5MB/s   01:02:03 ETA"))
        #expect(b.bytes == Int64(2) * 1024 * 1024 * 1024)
        #expect(b.etaSeconds == 3723)
        let c = try #require(ScpProgressParser.parse("x   10%  7B  3.0B/s   00:01 ETA"))
        #expect(c.bytes == Int64(7))
        #expect(c.bytesPerSecond == 3)
    }

    @Test func spacesAndUnicodeInName() throws {
        let p = try #require(ScpProgressParser.parse("báo cáo 50% final ✓.pdf     50%  200KB 100.0KB/s   00:02 ETA"))
        #expect(p.fileName == "báo cáo 50% final ✓.pdf")
        #expect(p.fraction == 0.5)
        let q = try #require(ScpProgressParser.parse("日本語 ファイル.txt  7%  1KB  1.0KB/s  00:09 ETA"))
        #expect(q.fileName == "日本語 ファイル.txt")
    }

    @Test func missingEtaIsNotInvented() throws {
        let p = try #require(ScpProgressParser.parse("f  20%  10KB  1.0KB/s  00:05"))
        #expect(p.etaSeconds == 5)  // có thời gian trong dòng
        #expect(ScpProgressParser.parse("f  20%  10KB  1.0KB/s  - stalled -") == nil)
        #expect(ScpProgressParser.parse("f  20%  10KB  1.0KB/s  --:-- ETA") == nil)
    }

    @Test func nonMatchingLines() {
        for line in [
            "", "hello", "Password:", "file.bin 45%", "scp: /x: No such file or directory", "100% done",
            "f 150% 1KB 1KB/s 00:01",
        ] {
            #expect(ScpProgressParser.parse(line) == nil, "\(line)")
        }
    }

    @Test func stripsAnsiBeforeParsing() throws {
        let p = try #require(ScpProgressParser.parse("\u{1B}[2Kf.txt  80%  8KB  2.0KB/s  00:01 ETA\r"))
        #expect(p.fileName == "f.txt")
    }
}
