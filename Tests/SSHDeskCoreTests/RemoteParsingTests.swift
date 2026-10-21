import Foundation
import Testing

@testable import SSHDeskCore

struct SftpBatchTests {
    @Test func quoteEscapesBackslashAndQuote() throws {
        #expect(try SftpBatch.quote("/a b/c") == "\"/a b/c\"")
        #expect(try SftpBatch.quote(#"/a"b"#) == #""/a\"b""#)
        #expect(try SftpBatch.quote(#"/a\b"#) == #""/a\\b""#)
        #expect(try SftpBatch.quote(#"/a\"b"#) == #""/a\\\"b""#)
        #expect(try SftpBatch.quote("/$HOME `x` ;&|") == "\"/$HOME `x` ;&|\"")
        #expect(try SftpBatch.quote("/日本/é ñ 😀") == "\"/日本/é ñ 😀\"")
        #expect(try SftpBatch.quote("/-lead") == "\"/-lead\"")
    }

    @Test(arguments: ["a\nb", "a\tb", "a\0b", "a\rb", "a\u{7F}b", "\u{1B}[0m"])
    func rejectsControlCharacters(_ s: String) {
        #expect(throws: SftpBatchError.controlCharacter(s)) { try SftpBatch.quote(s) }
    }

    @Test func rejectsEmpty() {
        #expect(throws: SftpBatchError.emptyPath) { try SftpBatch.quote("") }
    }

    @Test func commands() throws {
        #expect(try SftpBatch.list("/x y") == "cd \"/x y\"\nls -la\n")
        #expect(try SftpBatch.mkdir("/x") == "mkdir \"/x\"\n")
        #expect(try SftpBatch.rename("/a", "/b c") == "rename \"/a\" \"/b c\"\n")
        #expect(try SftpBatch.rm("/f") == "rm \"/f\"\n")
        #expect(try SftpBatch.rmdir("/d") == "rmdir \"/d\"\n")
        #expect(SftpBatch.pwd == "pwd\n")
        #expect(throws: SftpBatchError.self) { try SftpBatch.rename("/a", "/b\nrm /") }
    }
}

struct SftpListingParserTests {
    // Nguồn: định dạng `ls -la` của sftp (ls_file của OpenSSH: "%s %3u %-8.8s %-8.8s %8llu %s %s")
    // đã ghi trong ADR-013 (kết quả spike R1 trên OpenSSH 10.3 + sshd tạm), nlink luôn là `?`.
    static let sample = """
        sftp> cd "/tmp/x"
        sftp> ls -la
        drwxr-xr-x    ? quynh    staff         192 Oct 21 13:40 .
        drwxr-xr-x    ? root     wheel         512 Oct 21 13:00 ..
        drwxr-xr-x    ? quynh    staff          96 Oct 21 13:40 sub dir
        -rw-r--r--    ? quynh    staff        1234 Oct 21 13:40 file.txt
        -rw-------    ? quynh    staff           0 Jan 15  2020 old file.log
        lrwxr-xr-x    ? quynh    staff          11 Oct  5 09:01 link
        prw-r--r--    ? quynh    staff           0 Oct  5 09:01 fifo
        -rw-r--r--    ? quynh    staff          10 Oct 21 13:40 日本語 é.txt
        -rw-r--r--    ? quynh    staff          10 Oct 21 13:40  lead space
        """

    // Cố định "bây giờ" để test ngày: 2026-10-21 14:00 theo calendar local.
    static var calendar: Calendar { Calendar(identifier: .gregorian) }
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    static var now: Date { date(2026, 10, 21, 14, 0) }

    @Test func parsesSample() {
        let r = SftpListingParser.parse(Self.sample, now: Self.now, calendar: Self.calendar)
        #expect(r.unparsedLines == 0)
        #expect(
            r.entries.map(\.name) == [
                "sub dir", "file.txt", "old file.log", "link", "fifo", "日本語 é.txt", " lead space",
            ])
        let kinds = r.entries.map(\.kind)
        #expect(kinds == [.directory, .file, .file, .symlink, .other, .file, .file])
        let f = r.entries[1]
        #expect(f.size == 1234)
        #expect(f.permissions == "-rw-r--r--")
        #expect(f.owner == "quynh")
        #expect(f.group == "staff")
        #expect(f.rawDate == "Oct 21 13:40")
        #expect(f.modified == Self.date(2026, 10, 21, 13, 40))
        // Dạng năm.
        #expect(r.entries[2].modified == Self.date(2020, 1, 15))
        #expect(r.entries[2].rawDate == "Jan 15 2020")
        // Ngày một chữ số có hai khoảng trắng.
        #expect(r.entries[3].modified == Self.date(2026, 10, 5, 9, 1))
        // Khoảng trắng đầu tên được giữ (chỉ bỏ ĐÚNG một khoảng trắng phân cách).
        #expect(r.entries[6].name == " lead space")
    }

    @Test func futureTimeRollsBackOneYear() {
        let line = "-rw-r--r--    ? u        g               1 Dec 25 10:00 xmas"
        let r = SftpListingParser.parse(line, now: Self.now, calendar: Self.calendar)
        #expect(r.entries.first?.modified == Self.date(2025, 12, 25, 10, 0))
        // Chỉ lệch dưới 1 ngày ở tương lai thì giữ năm hiện tại (lệch múi giờ).
        let near = "-rw-r--r--    ? u        g               1 Oct 21 20:00 near"
        let r2 = SftpListingParser.parse(near, now: Self.now, calendar: Self.calendar)
        #expect(r2.entries.first?.modified == Self.date(2026, 10, 21, 20, 0))
    }

    @Test func leapDayInNonLeapYearDoesNotCrash() {
        let line = "-rw-r--r--    ? u        g               1 Feb 29 10:00 leap"
        let r = SftpListingParser.parse(line, now: Self.now, calendar: Self.calendar)
        // 2026 không nhuận -> thử 2025 cũng không nhuận -> nil, nhưng entry vẫn có.
        #expect(r.entries.count == 1)
        #expect(r.entries[0].modified == nil)
    }

    @Test func garbageLinesAreCounted() {
        let text = """
            sftp> ls -la
            -rw-r--r--    ? u        g               1 Oct 21 13:40 ok
            this is not a listing line
            -rw-r--r--    ? u        g               1 Oct 21 13:40 broken
            name-continues-after-newline
            Connection to x closed
            """
        let r = SftpListingParser.parse(text, now: Self.now, calendar: Self.calendar)
        #expect(r.entries.map(\.name) == ["ok", "broken"])
        #expect(r.unparsedLines == 3)
    }

    @Test func nameWithNewlineBreaksIntoUnparsed() {
        // Giới hạn đã biết (ADR-013): tên chứa newline vỡ thành dòng rác, không có entry sai.
        let text = "-rw-r--r--    ? u        g               1 Oct 21 13:40 a\nb\n"
        let r = SftpListingParser.parse(text, now: Self.now, calendar: Self.calendar)
        #expect(r.entries.map(\.name) == ["a"])
        #expect(r.unparsedLines == 1)
    }

    @Test func handlesCRLFAndEmpty() {
        let r = SftpListingParser.parse(
            "\r\n-rw-r--r--    ? u        g               5 Oct 21 13:40 f\r\n", now: Self.now,
            calendar: Self.calendar)
        #expect(r.entries.map(\.name) == ["f"])
        #expect(SftpListingParser.parse("").entries.isEmpty)
    }

    @Test func entrySupportedName() {
        let e = RemoteEntry(
            name: "a\tb", kind: .file, size: 0, permissions: "-rw-------", owner: "u", group: "g",
            modified: nil, rawDate: "")
        #expect(!e.hasSupportedName)
    }
}

struct SocketDirectoryTests {
    static func tmp() -> String {
        var t = Array("/tmp/sdtXXXXXX".utf8CString)
        let p = mkdtemp(&t)!
        return String(cString: p)
    }

    @Test func createsWith0700AndReuses() throws {
        let base = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let d = try SocketDirectory.ensure(base: base, uid: getuid())
        var st = stat()
        #expect(lstat(d.path, &st) == 0)
        #expect(st.st_mode & 0o7777 == 0o700)
        #expect(try SocketDirectory.ensure(base: base, uid: getuid()) == d)
        let id = UUID()
        let sp = d.socketPath(hostID: id)
        #expect(sp.hasSuffix("/" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        #expect(sp.utf8.count < 86)
    }

    @Test func rejectsWrongModeSymlinkAndFile() throws {
        let base = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let name = "\(base)/sshdesk-\(getuid())"
        // Sai mode.
        try FileManager.default.createDirectory(
            atPath: name, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: SocketDirectory.Failure.wrongMode(path: name, mode: 0o755)) {
            try SocketDirectory.ensure(base: base)
        }
        try FileManager.default.removeItem(atPath: name)
        // Symlink tới thư mục 0700 hợp lệ vẫn bị từ chối.
        let target = "\(base)/real"
        try FileManager.default.createDirectory(
            atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: name, withDestinationPath: target)
        #expect(throws: SocketDirectory.Failure.notDirectory(name)) {
            try SocketDirectory.ensure(base: base)
        }
        try FileManager.default.removeItem(atPath: name)
        // File thường.
        FileManager.default.createFile(atPath: name, contents: Data())
        #expect(throws: SocketDirectory.Failure.notDirectory(name)) {
            try SocketDirectory.ensure(base: base)
        }
    }

    @Test func rejectsWrongOwnerAndLongPath() throws {
        let base = Self.tmp()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // uid giả: thư mục "sshdesk-<uid giả>" do ta tạo nên owner là ta, không phải uid giả.
        let fake = getuid() &+ 1
        try FileManager.default.createDirectory(
            atPath: "\(base)/sshdesk-\(fake)", withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        #expect(throws: SocketDirectory.Failure.self) { try SocketDirectory.ensure(base: base, uid: fake) }
        let long = "/tmp/" + String(repeating: "x", count: 60)
        #expect(throws: SocketDirectory.Failure.self) { try SocketDirectory.ensure(base: long) }
    }
}
