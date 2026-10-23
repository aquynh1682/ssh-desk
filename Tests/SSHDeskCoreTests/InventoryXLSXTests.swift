import Foundation
import Testing

@testable import SSHDeskCore

private func tempFile(_ dir: HostTempDir, _ name: String = "t.xlsx") -> URL {
    try? FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
    return dir.url.appendingPathComponent(name)
}

private func row(_ sheet: TableSheet, _ number: Int) -> [String] {
    sheet.rows.first { $0.number == number }?.cells ?? []
}

@Suite struct InventoryXLSXTests {
    // MARK: - Round trip với template writer

    @Test func templateRoundTripThroughRealZipAndReader() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        try InventoryTemplate.write(to: url)
        let wb = try XLSXReader.read(url: url)
        #expect(wb.sheets.map(\.name) == ["Máy chủ", "Hướng dẫn"])
        let data = wb.sheets[0]
        #expect(row(data, 1) == InventoryTemplateFormat.headers)
        #expect(data.dataRows.isEmpty)
        #expect(row(wb.sheets[1], 1) == [InventoryTemplateFormat.versionMarker])
        let recognized = try #require(InventoryTemplateFormat.recognize(wb))
        #expect(
            recognized.sheet.name == "Máy chủ" && recognized.mapping.isTemplate && recognized.mapping.headerRow == 1)
        #expect(recognized.mapping.keyField == .name)
        // Có hướng dẫn và dòng ví dụ nhưng KHÔNG có cột mật khẩu.
        let guide = wb.sheets[1].rows.flatMap(\.cells).joined(separator: "\n")
        #expect(guide.contains("web-01") && guide.contains("Windows"))
        #expect(wb.sheets[1].passwordColumns.isEmpty)
    }

    @Test func templateXMLHasDropdownValidationsAndNoPasswordColumn() throws {
        let entries = InventoryTemplate.entries()
        let sheet1 = try #require(entries.first { $0.path == "xl/worksheets/sheet1.xml" })
        let xml = String(decoding: sheet1.data, as: UTF8.self)
        #expect(xml.contains(#"type="list""#))
        #expect(xml.contains("<formula1>\"DEV,UAT,STG,PROD\"</formula1>"))
        #expect(xml.contains("<formula1>\"SSH,Windows\"</formula1>"))
        #expect(xml.contains(#"sqref="E2:E5001""#) && xml.contains(#"sqref="G2:G5001""#))
        #expect(xml.firstRange(of: "<sheetData>")!.lowerBound < xml.firstRange(of: "<dataValidations")!.lowerBound)
        #expect(xml.firstRange(of: "<dataValidations")!.lowerBound < xml.firstRange(of: "<pageMargins")!.lowerBound)
        for h in InventoryTemplateFormat.headers { #expect(!PasswordHeader.matches(h)) }
        #expect(InventoryTemplateFormat.headers.count == 10)
        // Mọi entry là XML đúng cú pháp.
        for e in entries {
            let p = XMLParser(data: e.data)
            #expect(p.parse(), "\(e.path)")
        }
    }

    @Test func templateWriterRefusesToOverwriteAndChecksExtension() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        try Data("giữ nguyên".utf8).write(to: url)
        #expect(throws: InventoryTemplateError.self) { try InventoryTemplate.write(to: url) }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "giữ nguyên")
        #expect(throws: InventoryTemplateError.badExtension) {
            try InventoryTemplate.write(to: tempFile(dir, "t.xlsm"))
        }
        let missingParent = dir.url.appendingPathComponent("nope/t.xlsx")
        #expect(throws: InventoryTemplateError.self) { try InventoryTemplate.write(to: missingParent) }
        // Thư mục tạm của writer được dọn.
        let root = dir.url.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try InventoryTemplate.write(to: tempFile(dir, "ok.xlsx"), temporaryRoot: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    // MARK: - Reader thủ công

    @Test func readsSharedStringsFormulasMissingCellsAndAbsoluteTargets() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let shared =
            #"<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Tên</t></si><si><t>IP</t></si><si><r><t>web</t></r><r><t>-01</t></r><rPh><t>PHONETIC</t></rPh></si><si><t>10.0.0.5</t></si></sst>"#
        let rows =
            #"<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>"#
            // Ô B bị thiếu (định vị theo r), ô công thức có <v>, công thức không <v>, boolean, lỗi, ngày.
            + #"<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2" t="s"><v>3</v></c><c r="D2"><v>22</v></c></row>"#
            + #"<row r="3"><c r="A3" t="str"><f>"x"&amp;"y"</f><v>xy</v></c><c r="C3"><f>SUM(1,2)</f></c><c r="D3" t="b"><v>1</v></c><c r="E3" t="e"><v>#REF!</v></c><c r="F3" t="d"><v>2026-01-02</v></c></row>"#
        let url = tempFile(dir)
        try TestXLSX(
            sheets: [.init(name: "Dữ liệu", xml: TestXLSX.sheetXML(rows), target: "/xl/worksheets/sheet1.xml")],
            sharedStrings: shared
        ).write(to: url)
        let wb = try XLSXReader.read(url: url)
        let s = wb.sheets[0]
        #expect(row(s, 1) == ["Tên", "", "IP"])
        #expect(row(s, 2) == ["web-01", "", "10.0.0.5", "22"])
        #expect(row(s, 3) == ["xy", "", "", "TRUE", "", "2026-01-02"])
        #expect(s.warnings.contains { $0.contains("2 ô có công thức") })
        #expect(s.warnings.contains { $0.contains("1 ô lỗi") })
    }

    @Test func sharedStringsFileMayBeMissingAndHiddenSheetsAreNotListed() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        let visible = TestXLSX.sheetXML(
            TestXLSX.inlineRow(1, ["Tên", "IP"]) + TestXLSX.inlineRow(2, ["a", "1.1.1.1"]))
        let hidden = TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["bí mật"]))
        try TestXLSX(sheets: [
            .init(name: "Ẩn", xml: hidden, hidden: true), .init(name: "Hiện", xml: visible),
        ]).write(to: url)
        let wb = try XLSXReader.read(url: url)
        #expect(wb.sheets.map(\.name) == ["Hiện"])
        #expect(row(wb.sheets[0], 2) == ["a", "1.1.1.1"])
    }

    @Test func rejectsExternalRelationship() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        try TestXLSX(
            sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))],
            relsExtra:
                #"<Relationship Id="rId9" Type="http://x/externalLink" Target="file:///etc/passwd" TargetMode="External"/>"#
        ).write(to: url)
        #expect(throws: SpreadsheetError.externalRelationship) { try XLSXReader.read(url: url) }
    }

    @Test func rejectsDoctypeAndEntityInAnyPart() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let evil =
            #"<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY x SYSTEM "file:///etc/passwd">]><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>&x;</t></is></c></row></sheetData></worksheet>"#
        let url = tempFile(dir)
        try TestXLSX(sheets: [.init(name: "S", xml: evil)]).write(to: url)
        #expect(throws: SpreadsheetError.forbiddenXML) { try XLSXReader.read(url: url) }
        // Chỉ ENTITY (không DOCTYPE viết hoa), chữ thường cũng bị từ chối; và trong sharedStrings.
        let sneaky =
            #"<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><!eNtItY a "b"><si><t>x</t></si></sst>"#
        try TestXLSX(
            sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))], sharedStrings: sneaky
        ).write(to: url)
        #expect(throws: SpreadsheetError.forbiddenXML) { try XLSXReader.read(url: url) }
    }

    @Test func rejectsNonUTF8XML() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        let utf16 = #"<?xml version="1.0" encoding="UTF-16"?><worksheet><sheetData/></worksheet>"#
        try TestXLSX(sheets: [.init(name: "S", xml: utf16)]).write(to: url)
        #expect(throws: SpreadsheetError.notUTF8) { try XLSXReader.read(url: url) }
    }

    @Test func rejectsDuplicateTraversalAndAbsoluteEntryNames() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        let base = TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))])
        var entries = base.entries()
        // Trùng tên: `unzip -p` sẽ nối hai entry, nên phải bị từ chối trước.
        entries.append(("xl/worksheets/sheet1.xml", Data(TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["evil"])).utf8)))
        try base.write(to: url, entries: entries)
        #expect(throws: SpreadsheetError.duplicateEntry) { try XLSXReader.read(url: url) }

        for bad in ["../evil.xml", "xl/../../evil.xml", "/etc/evil.xml"] {
            var e = base.entries()
            e.append((bad, Data("x".utf8)))
            try base.write(to: url, entries: e)
            #expect(throws: SpreadsheetError.unsafeEntryName, "\(bad)") { try XLSXReader.read(url: url) }
        }
        #expect(throws: SpreadsheetError.self) { try XLSXReader.validateEntryNames(["a", "A"]) }
        #expect(throws: SpreadsheetError.self) { try XLSXReader.validateEntryNames([""]) }
    }

    @Test func rejectsSheetTargetOutsideAllowedPattern() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        try TestXLSX(sheets: [
            .init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])), target: "../secret/s[1].xml")
        ]).write(to: url)
        #expect(throws: SpreadsheetError.unsafeEntryName) { try XLSXReader.read(url: url) }
    }

    @Test func zipBombOverEntryCapIsRejectedAndProcessStopped() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        // Dùng zip thật (nén mạnh): 300 KB số 0 nén còn rất nhỏ; cap test = 64 KB.
        let pkg = dir.url.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pkg.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        let base = TestXLSX(sheets: [.init(name: "S", xml: "")])
        for e in base.entries() where e.name != "xl/worksheets/sheet1.xml" {
            try e.data.write(to: pkg.appendingPathComponent(e.name))
        }
        let filler = String(repeating: " ", count: 300_000)
        let big = TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])) + filler
        try Data(big.utf8).write(to: pkg.appendingPathComponent("xl/worksheets/sheet1.xml"))
        let zipped = dir.url.appendingPathComponent("bomb.xlsx")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-X", "-r", zipped.path, "."]
        p.currentDirectoryURL = pkg
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(try Data(contentsOf: zipped).count < 20_000)

        var limits = XLSXLimits()
        limits.maxEntryBytes = 64 * 1024
        #expect(throws: SpreadsheetError.entryTooLarge) { try XLSXReader.read(url: zipped, limits: limits) }
        // Tổng vượt trần.
        limits = XLSXLimits()
        limits.maxTotalBytes = 64 * 1024
        #expect(throws: SpreadsheetError.totalTooLarge) { try XLSXReader.read(url: zipped, limits: limits) }
        // Cap mặc định cho đọc bình thường.
        let ok = try XLSXReader.read(url: zipped)
        #expect(row(ok.sheets[0], 1) == ["a"])
    }

    @Test func rejectsNonZipWrongExtensionTooLargeAndCorruptFiles() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let notZip = tempFile(dir, "fake.xlsx")
        try Data("đây không phải zip".utf8).write(to: notZip)
        #expect(throws: SpreadsheetError.notZip) { try XLSXReader.read(url: notZip) }

        let xlsm = tempFile(dir, "macro.xlsm")
        try TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))]).write(to: xlsm)
        #expect(throws: SpreadsheetError.self) { try XLSXReader.read(url: xlsm) }
        #expect(InventoryFile.kind(for: xlsm) == nil)
        #expect(InventoryFile.kind(for: tempFile(dir, "old.xls")) == nil)

        let valid = tempFile(dir, "ok.xlsx")
        try TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))]).write(to: valid)
        var limits = XLSXLimits()
        limits.maxFileBytes = 100
        #expect(throws: SpreadsheetError.self) { try XLSXReader.read(url: valid, limits: limits) }

        // CRC hỏng -> unzip exit ≠ 0 -> bỏ toàn bộ.
        var bytes = try Data(contentsOf: valid)
        let marker = Data("<worksheet".utf8)
        let at = try #require(bytes.range(of: marker)).lowerBound
        bytes[at + 2] = bytes[at + 2] ^ 0x01
        let corrupt = tempFile(dir, "corrupt.xlsx")
        try bytes.write(to: corrupt)
        #expect(throws: SpreadsheetError.self) { try XLSXReader.read(url: corrupt) }
    }

    @Test func columnAndRowLimits() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        var limits = XLSXLimits()
        limits.maxColumns = 3
        let wide = TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a", "b", "c", "d"]))
        try TestXLSX(sheets: [.init(name: "S", xml: wide)]).write(to: url)
        #expect(throws: SpreadsheetError.tooManyColumns(limit: 3)) { try XLSXReader.read(url: url, limits: limits) }

        limits = XLSXLimits()
        limits.maxRows = 2
        var rows = ""
        for i in 1...200 { rows += TestXLSX.inlineRow(i, ["x\(i)"]) }
        try TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(rows))]).write(to: url)
        #expect(throws: SpreadsheetError.tooManyRows(limit: 2)) { try XLSXReader.read(url: url, limits: limits) }
    }

    @Test func fileNameWithWildcardsOrDashReadsExactlyTheChosenFile() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        func make(_ name: String, _ value: String) throws -> URL {
            let u = dir.url.appendingPathComponent(name)
            try TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, [value])))]).write(
                to: u)
            return u
        }
        // File anh em khớp wildcard để dụ unzip đọc nhầm.
        _ = try make("a1.xlsx", "SIBLING")
        _ = try make("ab.xlsx", "SIBLING")
        _ = try make("zz.xlsx", "SIBLING")
        for name in ["a[1].xlsx", "a?.xlsx", "a*.xlsx", "a[!x].xlsx", "-v.xlsx"] {
            let u = try make(name, "CHOSEN-\(name)")
            let wb = try XLSXReader.read(url: u)
            #expect(row(wb.sheets[0], 1) == ["CHOSEN-\(name)"], "\(name)")
        }
    }

    @Test func columnReferenceParsing() {
        #expect(XLSXReader.columnIndex(ofReference: "A1") == 0)
        #expect(XLSXReader.columnIndex(ofReference: "Z9") == 25)
        #expect(XLSXReader.columnIndex(ofReference: "AA10") == 26)
        #expect(XLSXReader.columnIndex(ofReference: "1") == nil)
    }

    @Test func unzipRunsWithEmptyEnvironment() throws {
        // Biến UNZIP của môi trường gọi không được ảnh hưởng (env của tiến trình con là rỗng).
        setenv("UNZIP", "-v", 1)
        defer { unsetenv("UNZIP") }
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = tempFile(dir)
        try TestXLSX(sheets: [.init(name: "S", xml: TestXLSX.sheetXML(TestXLSX.inlineRow(1, ["a"])))]).write(to: url)
        let wb = try XLSXReader.read(url: url)
        #expect(row(wb.sheets[0], 1) == ["a"])
    }
}
