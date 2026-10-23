import Foundation
import Testing

@testable import SSHDeskCore

private func sheetOf(_ wb: TableWorkbook) -> TableSheet { wb.sheets[0] }

private func cells(_ s: TableSheet, _ n: Int) -> [String] { s.rows.first { $0.number == n }?.cells ?? [] }

// MARK: - CSV

@Suite struct InventoryCSVTests {
    @Test func utf8WithAndWithoutBOM() throws {
        let body = "Tên,IP\nweb-01,10.0.0.5\n"
        let plain = try CSVReader.parse(data: Data(body.utf8))
        #expect(cells(sheetOf(plain), 2) == ["web-01", "10.0.0.5"])
        let bom = try CSVReader.parse(data: Data([0xEF, 0xBB, 0xBF] + Array(body.utf8)))
        #expect(cells(sheetOf(bom), 1) == ["Tên", "IP"])
    }

    @Test func utf16LittleEndianWithBOMAndRejectsOthers() throws {
        let body = "Tên;IP\nmáy-1;1.1.1.1\n"
        var data = Data([0xFF, 0xFE])
        data.append(body.data(using: .utf16LittleEndian)!)
        let wb = try CSVReader.parse(data: data)
        #expect(cells(sheetOf(wb), 2) == ["máy-1", "1.1.1.1"])
        var be = Data([0xFE, 0xFF])
        be.append(body.data(using: .utf16BigEndian)!)
        #expect(throws: SpreadsheetError.unsupportedEncoding) { try CSVReader.parse(data: be) }
        #expect(throws: SpreadsheetError.unsupportedEncoding) {
            try CSVReader.parse(data: Data([0x41, 0xFF, 0xFE, 0x42]))
        }
    }

    @Test func detectsSemicolonTabAndComma() throws {
        let semi = try CSVReader.parse(data: Data("a;b;c\n1;2;3\n".utf8))
        #expect(cells(sheetOf(semi), 2) == ["1", "2", "3"])
        let tab = try CSVReader.parse(data: Data("a\tb\n1\t2,5\n".utf8))
        #expect(cells(sheetOf(tab), 2) == ["1", "2,5"])
        let comma = try CSVReader.parse(data: Data("a,b;x\n1,2;3\n".utf8))
        #expect(cells(sheetOf(comma), 2) == ["1", "2;3"])
    }

    @Test func rfc4180QuotesEmbeddedDelimitersNewlinesAndCRLF() throws {
        let text = "Tên,Ghi chú\r\n\"a, b\",\"dòng 1\ndòng 2 \"\"trích\"\"\"\r\nc,d"
        let wb = try CSVReader.parse(data: Data(text.utf8))
        let s = sheetOf(wb)
        #expect(cells(s, 2) == ["a, b", "dòng 1\ndòng 2 \"trích\""])
        #expect(cells(s, 3) == ["c", "d"])
    }

    @Test func blankLinesKeepRowNumbersAndLimits() throws {
        let wb = try CSVReader.parse(data: Data("h1,h2\n\nx,y\n".utf8))
        #expect(cells(sheetOf(wb), 3) == ["x", "y"])
        #expect(sheetOf(wb).dataRows.map(\.number) == [3])
        #expect(throws: SpreadsheetError.emptyFile) { try CSVReader.parse(data: Data("\n\n".utf8)) }
        #expect(throws: SpreadsheetError.self) { try CSVReader.parse(data: Data(count: 200), maxBytes: 100) }
        let wide = (0..<201).map(String.init).joined(separator: ",")
        #expect(throws: SpreadsheetError.tooManyColumns(limit: 200)) { try CSVReader.parse(data: Data(wide.utf8)) }
    }

    @Test func fileSizeLimitAndPasswordColumnNeverEntersModel() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let url = dir.url.appendingPathComponent("a.csv")
        try Data("Tên,IP,User,Password\nweb,10.0.0.1,root,Sup3r-Secret-Pw\n".utf8).write(to: url)
        let wb = try CSVReader.read(url: url)
        let dump = "\(wb)"
        #expect(!dump.contains("Sup3r-Secret-Pw"))
        #expect(sheetOf(wb).passwordColumns == [3: "Password"])
        #expect(cells(sheetOf(wb), 2) == ["web", "10.0.0.1", "root", ""])
        #expect(sheetOf(wb).warnings.contains("Phát hiện cột mật khẩu — sẽ bỏ qua"))
        #expect(throws: SpreadsheetError.self) { try CSVReader.read(url: url, maxBytes: 10) }
    }
}

// MARK: - Đoán cột & chặn cột mật khẩu

@Suite struct InventoryMappingTests {
    @Test func guessesVietnameseWithDiacritics() {
        let s = testSheet([
            ["STT", "Tên server", "Địa chỉ IP", "Cổng", "Tài khoản", "Môi trường", "Dự án", "Ghi chú", "Mật khẩu"],
            ["1", "a", "1.1.1.1", "22", "root", "PROD", "X", "n", "pw-1"],
        ])
        let m = TableMapping.guess(sheet: s)
        #expect(m.header(for: .name) == "Tên server")
        #expect(m.header(for: .hostName) == "Địa chỉ IP")
        #expect(m.header(for: .port) == "Cổng")
        #expect(m.header(for: .user) == "Tài khoản")
        #expect(m.header(for: .environment) == "Môi trường")
        #expect(m.header(for: .folder) == "Dự án")
        #expect(m.header(for: .notes) == "Ghi chú")
        #expect(m.keyField == .name)
        #expect(!m.columns.values.contains("Mật khẩu") && !m.columns.values.contains("STT"))
    }

    @Test func guessesWithoutDiacriticsAndEnglish() {
        let vn = testSheet([
            ["Ten may chu", "Dia chi", "Cong", "Tai khoan", "Moi truong", "Thu muc", "Mo ta", "mat khau"]
        ])
        let m1 = TableMapping.guess(sheet: vn)
        #expect(m1.columns.count == 7)
        #expect(m1.header(for: .name) == "Ten may chu" && m1.header(for: .hostName) == "Dia chi")
        #expect(m1.header(for: .notes) == "Mo ta" && m1.header(for: .folder) == "Thu muc")
        let en = testSheet([
            ["SERVER NAME", "ip address", "Port", "Username", "Env", "Project", "Description", "Passwd"]
        ])
        let m2 = TableMapping.guess(sheet: en)
        #expect(m2.header(for: .name) == "SERVER NAME" && m2.header(for: .hostName) == "ip address")
        #expect(m2.header(for: .user) == "Username" && m2.header(for: .environment) == "Env")
        #expect(m2.header(for: .folder) == "Project" && m2.header(for: .notes) == "Description")
        #expect(!m2.columns.values.contains("Passwd"))
        let hostOnly = testSheet([["Address", "Login"]])
        let m3 = TableMapping.guess(sheet: hostOnly)
        #expect(m3.keyField == .hostName && m3.header(for: .user) == "Login")
    }

    @Test func loginNameColumnIsUserNotName() {
        let s = testSheet([["Tên đăng nhập", "Tên", "IP"]])
        let m = TableMapping.guess(sheet: s)
        #expect(m.header(for: .user) == "Tên đăng nhập")
        #expect(m.header(for: .name) == "Tên")
    }

    @Test func passwordLikeHeadersAreDetected() {
        for h in [
            "Password", "PASS", "pwd", "passwd", "Mật khẩu", "mat khau", "MK", "Secret", "passphrase", "OTP",
            "ssh_password", "Mật khẩu root", "Root Password (tạm)", "Mật_khẩu", "mat-khau", "MẬT_KHẨU_ROOT", "matkhau",
            "mat ma", "API-Key", "api_key", "Token", "access_token", "Credential", "rootPassword",
        ] {
            #expect(PasswordHeader.matches(h), "\(h)")
        }
        for h in [
            "Tên", "IP", "Bypass", "Compass", "Ghi chú", "Môi trường", "User", "Notes", "Passenger", "Bộ đăng nhập",
            "bo dang nhap",
        ] {
            #expect(!PasswordHeader.matches(h), "\(h)")
        }
    }

    @Test func coreRefusesToMapPasswordColumnToAnyField() throws {
        for header in ["Password", "Mật khẩu", "mk", "OTP", "Passphrase", "mat khau server"] {
            for field in InventoryField.allCases {
                var m = TableMapping()
                #expect(throws: ColumnMappingError.self, "\(header) → \(field)") {
                    try m.set(field, header: header)
                }
                #expect(m.columns.isEmpty)
            }
        }
        var ok = TableMapping()
        try ok.set(.notes, header: "Ghi chú")
        #expect(ok.header(for: .notes) == "Ghi chú")
        try ok.set(.notes, header: nil)
        #expect(ok.columns.isEmpty)
    }

    @Test func storedMappingToPasswordHeaderIsBlockedAtResolveAndParse() throws {
        let sheet = testSheet([
            ["Tên", "IP", "User", "Mật khẩu"], ["web", "10.0.0.1", "root", "Sup3r-Secret-Pw"],
        ])
        // JSON cấu hình bị sửa tay: ghép "Mật khẩu" vào ghi chú.
        let mapping = TableMapping(
            sheet: "S", headerRow: 1,
            columns: ["name": "Tên", "hostName": "IP", "user": "User", "notes": "Mật khẩu"])
        let resolved = mapping.resolve(in: sheet)
        #expect(resolved.blocked[.notes] == "Mật khẩu" && resolved.columns[.notes] == nil)
        let result = try InventoryTableParser.parse(sheet: sheet, mapping: mapping)
        #expect(result.records.count == 1 && result.records[0].notes == nil)
        #expect("\(result)".contains("Sup3r-Secret-Pw") == false)
        #expect("\(sheet)".contains("Sup3r-Secret-Pw") == false)
        #expect(result.warnings.contains { $0.contains("Phát hiện cột mật khẩu") })
        #expect(result.warnings.contains { $0.contains("giống mật khẩu") })
    }

    @Test func passwordColumnValuesAreRemovedEvenWithOddHeaderRow() {
        let sheet = testSheet(
            [["Báo cáo", ""], ["Tên", "OTP"], ["a", "123456"], ["b", "654321"]], headerRow: 2)
        #expect(sheet.passwordColumns == [1: "OTP"])
        #expect(!"\(sheet)".contains("123456") && !"\(sheet)".contains("654321"))
    }

    @Test func templateRecognizedByHeadersOrVersionMarker() {
        func wb(_ sheets: [TableSheet]) -> TableWorkbook { TableWorkbook(sheets: sheets) }
        let headers = InventoryTemplateFormat.headers
        let loose = testSheet([headers.map { " " + $0.uppercased() + "  " }], name: "Bất kỳ")
        let a = InventoryTemplateFormat.recognize(wb([loose]))
        #expect(a?.mapping.isTemplate == true && a?.mapping.keyField == .name)
        #expect(a?.mapping.columns.count == 10)
        // Chỉ có dấu phiên bản + vài tiêu đề.
        let guide = testSheet([["sshdesk-template v1"]], name: "Hướng dẫn")
        let data = testSheet([["Tên", "IP/Hostname", "Ghi chú tuỳ ý"]], name: "Máy chủ")
        let b = InventoryTemplateFormat.recognize(wb([guide, data]))
        #expect(b?.sheet.name == "Máy chủ" && b?.mapping.columns.count == 2)
        // File thường không bị nhận nhầm.
        #expect(InventoryTemplateFormat.recognize(wb([testSheet([["Tên", "IP", "Port"]])])) == nil)
        // Thiếu một tiêu đề của mẫu và không có dấu phiên bản -> không nhận.
        #expect(InventoryTemplateFormat.recognize(wb([testSheet([Array(headers.dropLast())])])) == nil)
    }

    @Test func mappingRoundTripsThroughConfigJSONAndReportsRenamedHeader() throws {
        let sheet = testSheet([["Tên", "IP", "User"], ["a", "1.1.1.1", "u"]], name: "Sheet 1")
        let mapping = TableMapping.guess(sheet: sheet)
        let source = InventorySource(
            name: "x", kind: .excel, path: "/tmp/x.xlsx", configJSON: InventorySource.encodeConfig(mapping))
        #expect(source.tableMapping == mapping)
        #expect(!mapping.resolve(in: sheet).needsRemap)
        let renamed = testSheet([["Tên", "Địa chỉ máy", "User"], ["a", "1.1.1.1", "u"]], name: "Sheet 1")
        let r = mapping.resolve(in: renamed)
        #expect(r.needsRemap && r.missing[.hostName] == "IP")
        // Cột đổi chỗ nhưng tiêu đề vẫn còn -> vẫn ghép đúng (theo văn bản tiêu đề).
        let moved = testSheet([["User", "IP", "Tên"], ["u", "1.1.1.1", "a"]], name: "Sheet 1")
        let rm = mapping.resolve(in: moved)
        #expect(!rm.needsRemap && rm.columns[.name] == 2 && rm.columns[.hostName] == 1)
    }
}

// MARK: - Lỗi theo dòng

@Suite struct InventoryRowErrorTests {
    private func templateSheet(_ rows: [(Int, [String])]) -> (TableSheet, TableMapping) {
        var b = TableBuilder()
        b.add(number: 1, cells: InventoryTemplateFormat.headers)
        for (n, r) in rows { b.add(number: n, cells: r) }
        let sheet = b.finish(name: "Máy chủ", headerRow: 1)
        return (sheet, InventoryTemplateFormat.recognize(TableWorkbook(sheets: [sheet]))!.mapping)
    }

    private func line(
        _ name: String, _ ip: String = "10.0.0.1", port: String = "", user: String = "deploy", env: String = "",
        folder: String = "", kind: String = "", jump: String = "", set: String = "", note: String = ""
    ) -> [String] {
        [name, ip, port, user, env, folder, kind, jump, set, note]
    }

    @Test func reportsExcelRowColumnAndReasonForEachProblem() throws {
        let (sheet, mapping) = templateSheet([
            (2, line("ok-1")),
            (3, line("bad-host", "bad host!")),
            (4, []),  // dòng trống: bỏ qua im lặng
            (5, line("bad-port", port: "70000")),
            (6, line("port-text", port: "abc")),
            (7, line("bad-env", env: "XYZ")),
            (8, line("bad-kind", kind: "Mac")),
            (9, line("", "10.0.0.2")),
            (10, line("no-ip", "")),
            (11, line("ok-1", "10.0.0.9")),
            (12, line("self", jump: "self")),
            (13, line("lost", jump: "không-có")),
            (14, line("no-user", user: "")),
            (15, line("win", kind: "Windows", jump: "ok-1")),
            (16, line("ok-2")),
        ])
        let result = try InventoryTableParser.parse(sheet: sheet, mapping: mapping)
        func issue(_ row: Int) -> InventoryIssue? { result.issues.first { $0.row == row } }
        #expect(issue(3)?.column == "IP/Hostname" && issue(3)?.severity == .error)
        #expect(issue(3)?.message.contains("không hợp lệ") == true)
        #expect(issue(4) == nil)
        #expect(issue(5)?.column == "Port" && issue(5)?.message.contains("1–65535") == true)
        #expect(issue(6)?.column == "Port")
        #expect(issue(7)?.column == "Môi trường")
        #expect(issue(8)?.column == "Loại")
        #expect(issue(9)?.column == "Tên" && issue(9)?.message == "Thiếu Tên.")
        #expect(issue(10)?.column == "IP/Hostname" && issue(10)?.message == "Thiếu IP/Hostname.")
        #expect(issue(11)?.message == "Trùng tên với dòng 2." && issue(11)?.severity == .error)
        #expect(issue(12)?.severity == .warning && issue(12)?.column == "Jump host")
        #expect(issue(14)?.column == "User")
        #expect(issue(15)?.severity == .warning && issue(15)?.message.contains("Windows") == true)
        #expect(issue(12)?.text == "Dòng 12, cột “Jump host”: Jump host trỏ chính nó — đã bỏ qua.")
        // Dòng lỗi không làm hỏng file: ok-1, self, lost, win, ok-2 vẫn vào.
        #expect(result.records.map(\.name) == ["ok-1", "self", "lost", "win", "ok-2"])
        #expect(result.records.first { $0.name == "self" }?.jumpRef == nil)
        #expect(result.records.first { $0.name == "win" }?.jumpRef == nil)
        // Khoá của dòng lỗi được ghi nhận để host cũ không bị coi là biến mất.
        #expect(result.failedKeys.contains("bad-host") && result.failedKeys.contains("no-user"))
    }

    @Test func defaultsPortsEnvironmentKindAndWindowsUserMapping() throws {
        let (sheet, mapping) = templateSheet([
            (2, line("linux")),
            (3, line("win", "10.0.0.7", user: "Administrator", env: "prod", kind: "windows")),
            (4, line("custom", port: "2222.0", env: "UAT", folder: "Khách A", note: "ghi chú")),
        ])
        let r = try InventoryTableParser.parse(sheet: sheet, mapping: mapping)
        #expect(r.issues.isEmpty)
        let linux = r.records[0]
        #expect(linux.port == 22 && linux.kind == .ssh && linux.environment == .other && linux.externalID == "linux")
        let win = r.records[1]
        #expect(win.port == 3389 && win.kind == .windowsRDP && win.user == "Administrator" && win.environment == .prod)
        let custom = r.records[2]
        #expect(
            custom.port == 2222 && custom.environment == .uat && custom.folder == "Khách A" && custom.notes == "ghi chú"
        )
        // Windows -> rdpUsername, không user ssh, không jump.
        let h = InventoryValidator.profile(from: win, folder: "")
        #expect(h.rdpUsername == "Administrator" && h.user.isEmpty && h.jumpHostID == nil)
    }

    @Test func freeMappingIsLenientForEnvironmentAndFallsBackToHostName() throws {
        let sheet = testSheet([
            ["Tên", "IP", "Port", "Môi trường"], ["", "10.0.0.1", "22.0", "Production"],
            ["b", "10.0.0.2", "", "weird"], ["c", "10.0.0.3", "", "staging"], ["d", "10.0.0.4", "", "Test"],
        ])
        var m = TableMapping.guess(sheet: sheet)
        try m.set(.user, header: nil)
        // Thiếu user bị lỗi ở SSH -> thêm cột user.
        let withUser = testSheet([
            ["Tên", "IP", "Port", "Môi trường", "User"], ["", "10.0.0.1", "22.0", "Production", "u"],
            ["b", "10.0.0.2", "", "weird", "u"], ["c", "10.0.0.3", "", "staging", "u"],
            ["d", "10.0.0.4", "", "Test", "u"],
        ])
        let mapping = TableMapping.guess(sheet: withUser)
        let r = try InventoryTableParser.parse(sheet: withUser, mapping: mapping)
        #expect(r.issues.isEmpty)
        #expect(r.records.map(\.name) == ["10.0.0.1", "b", "c", "d"])
        #expect(r.records.map(\.environment) == [.prod, .other, .stg, .dev])
        #expect(r.records[0].port == 22 && r.records[0].externalID == "10.0.0.1")
        let none = try InventoryTableParser.parse(sheet: sheet, mapping: m)
        #expect(none.issues.contains { $0.column == "User" })
    }

    @Test func rejectsControlCharactersAndHonoursRecordLimit() throws {
        let (sheet, mapping) = templateSheet([
            (2, line("a\u{07}b")), (3, line("ok", folder: "x\u{1b}")), (4, line("ok2", note: "dòng 1\ndòng 2")),
        ])
        let r = try InventoryTableParser.parse(sheet: sheet, mapping: mapping)
        #expect(r.issues.map(\.row) == [2, 3])
        #expect(r.records.map(\.name) == ["ok2"] && r.records[0].notes == "dòng 1\ndòng 2")

        var rows: [(Int, [String])] = []
        for i in 0..<5001 { rows.append((i + 2, line("h\(i)"))) }
        let (big, bigMapping) = templateSheet(rows)
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) {
            try InventoryTableParser.parse(sheet: big, mapping: bigMapping)
        }
    }

    @Test func missingMappedColumnAndMissingHostColumnAreFileLevelErrors() throws {
        let sheet = testSheet([["Tên", "User"], ["a", "u"]])
        let noHost = try InventoryTableParser.parse(sheet: sheet, mapping: TableMapping.guess(sheet: sheet))
        #expect(noHost.records.isEmpty && noHost.issues.first?.row == 0)
        let renamed = TableMapping(sheet: "S", headerRow: 1, columns: ["name": "Tên", "hostName": "IP cũ"])
        let r = try InventoryTableParser.parse(sheet: sheet, mapping: renamed)
        #expect(r.records.isEmpty && r.issues.contains { $0.message.contains("Không thấy cột") })
    }
}
