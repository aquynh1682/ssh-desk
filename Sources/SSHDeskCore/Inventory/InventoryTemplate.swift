import Darwin
import Foundation

public enum InventoryTemplateError: Error, Equatable, CustomStringConvertible {
    case alreadyExists(String)
    case badExtension
    case parentMissing(String)
    case zipFailed(String)

    public var description: String {
        switch self {
        case .alreadyExists(let p): return "File đã tồn tại, không ghi đè: \(p)"
        case .badExtension: return "Tên file mẫu phải có đuôi .xlsx."
        case .parentMissing(let p): return "Thư mục đích không tồn tại: \(p)"
        case .zipFailed(let s): return "Không nén được file mẫu: \(s)"
        }
    }
}

/// Sinh file Excel mẫu (ADR-026) — XML tối thiểu (đã kiểm chứng Spotlight/QuickLook), chuỗi `inlineStr`,
/// nén bằng `/usr/bin/zip -X -D -r` qua argv (cwd = thư mục tạm), chuyển tới đích (không ghi đè) rồi xoá tạm.
public enum InventoryTemplate {
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let data: Data
    }

    static let maxRowsValidated = 5001

    // MARK: - Nội dung

    public static func entries() -> [Entry] {
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        func entry(_ path: String, _ body: String) -> Entry { Entry(path: path, data: Data((header + body).utf8)) }
        let ns = #"xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main""#
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let ct = "application/vnd.openxmlformats-officedocument.spreadsheetml"
        return [
            entry(
                "[Content_Types].xml",
                #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="\#(ct).sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="\#(ct).worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="\#(ct).worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="\#(ct).styles+xml"/></Types>"#
            ),
            entry(
                "_rels/.rels",
                #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
            ),
            entry(
                "xl/workbook.xml",
                #"<workbook \#(ns) xmlns:r="\#(rel)"><sheets><sheet name="\#(escape(InventoryTemplateFormat.dataSheetName))" sheetId="1" r:id="rId1"/><sheet name="\#(escape(InventoryTemplateFormat.guideSheetName))" sheetId="2" r:id="rId2"/></sheets></workbook>"#
            ),
            entry(
                "xl/_rels/workbook.xml.rels",
                #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\#(rel)/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="\#(rel)/styles" Target="styles.xml"/></Relationships>"#
            ),
            entry(
                "xl/styles.xml",
                #"<styleSheet \#(ns)><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#
            ),
            entry("xl/worksheets/sheet1.xml", dataSheetXML(ns: ns)),
            entry("xl/worksheets/sheet2.xml", guideSheetXML(ns: ns)),
        ]
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Bỏ ký tự điều khiển không hợp lệ trong XML 1.0 (giữ tab, xuống dòng).
                if u.value >= 0x20 || u == "\t" || u == "\n" { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    private static func columnLetter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index)))
    }

    private static func cell(_ column: Int, _ row: Int, _ text: String, style: Int = 0) -> String {
        let s = style == 0 ? "" : #" s="\#(style)""#
        return
            #"<c r="\#(columnLetter(column))\#(row)"\#(s) t="inlineStr"><is><t xml:space="preserve">\#(escape(text))</t></is></c>"#
    }

    private static func row(_ number: Int, _ cells: [String]) -> String {
        #"<row r="\#(number)">\#(cells.joined())</row>"#
    }

    private static let margins =
        #"<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>"#

    static func dataSheetXML(ns: String) -> String {
        let headers = InventoryTemplateFormat.headers
        let widths = [22, 24, 8, 16, 14, 22, 10, 20, 20, 40]
        let cols = widths.enumerated().map {
            #"<col min="\#($0.offset + 1)" max="\#($0.offset + 1)" width="\#($0.element)" customWidth="1"/>"#
        }.joined()
        let head = row(1, headers.enumerated().map { cell($0.offset, 1, $0.element, style: 1) })
        let last = maxRowsValidated
        // Cột: A Tên, B IP, C Port, D User, E Môi trường, F Thư mục, G Loại, H Jump, I Bộ, J Ghi chú.
        let validations =
            #"<dataValidations count="3"><dataValidation type="whole" operator="between" allowBlank="1" showErrorMessage="1" errorTitle="Port" error="Port là số từ 1 đến 65535." sqref="C2:C\#(last)"><formula1>1</formula1><formula2>65535</formula2></dataValidation><dataValidation type="list" allowBlank="1" showErrorMessage="1" errorTitle="Môi trường" error="Chọn DEV, UAT, STG hoặc PROD (để trống = OTHER)." sqref="E2:E\#(last)"><formula1>"DEV,UAT,STG,PROD"</formula1></dataValidation><dataValidation type="list" allowBlank="1" showErrorMessage="1" errorTitle="Loại" error="Chọn SSH hoặc Windows (để trống = SSH)." sqref="G2:G\#(last)"><formula1>"SSH,Windows"</formula1></dataValidation></dataValidations>"#
        return
            #"<worksheet \#(ns)><cols>\#(cols)</cols><sheetData>\#(head)</sheetData>\#(validations)\#(margins)</worksheet>"#
    }

    static func guideSheetXML(ns: String) -> String {
        var rows: [String] = []
        var n = 1
        func add(_ cells: [String]) {
            rows.append(row(n, cells))
            n += 1
        }
        add([cell(0, 1, InventoryTemplateFormat.versionMarker)])
        add([
            cell(
                0, 2,
                "Hướng dẫn điền sheet “\(InventoryTemplateFormat.dataSheetName)”: mỗi dòng là một máy chủ, bắt đầu từ dòng 2."
            )
        ])
        add([
            cell(
                0, 3,
                "KHÔNG nhập mật khẩu vào file này. Cột “Bộ đăng nhập” chỉ là TÊN bộ; mật khẩu nhập sau trong SSH Desk.")
        ])
        n = 5
        add(
            ["Cột", "Bắt buộc", "Giá trị hợp lệ", "Ví dụ"].enumerated().map { cell($0.offset, 5, $0.element, style: 1) }
        )
        let guide: [(String, String, String, String)] = [
            ("Tên", "Có", "Tên hiển thị, duy nhất trong file. Dùng làm khoá để đồng bộ lại.", "web-01"),
            ("IP/Hostname", "Có", "Địa chỉ IP hoặc tên máy (chữ, số, dấu chấm, gạch).", "10.0.0.5"),
            ("Port", "Không", "Số từ 1 đến 65535. Trống = 22 (SSH) / 3389 (Windows).", "22"),
            ("User", "Có với SSH", "Tên đăng nhập. Với máy Windows là tên đăng nhập RDP (có thể trống).", "deploy"),
            ("Môi trường", "Không", "DEV, UAT, STG, PROD. Trống = OTHER.", "PROD"),
            ("Thư mục/Dự án", "Không", "Tên thư mục để gom máy chủ.", "Khách hàng A"),
            ("Loại", "Không", "SSH hoặc Windows. Trống = SSH.", "SSH"),
            (
                "Jump host", "Không",
                "TÊN của máy khác (trong file này hoặc đã có trong app). Máy Windows không có jump host.", "bastion-01"
            ),
            (
                "Bộ đăng nhập", "Không",
                "TÊN bộ đăng nhập đã có trong app. Chưa có thì app tạo bộ rỗng; máy sẽ tạm tắt tự điền mật khẩu tới khi bạn xác nhận.",
                "Khách hàng A - root"
            ),
            ("Ghi chú", "Không", "Văn bản tự do (không nhập mật khẩu).", "Máy chạy web"),
        ]
        for g in guide {
            add([cell(0, n, g.0), cell(1, n, g.1), cell(2, n, g.2, style: 2), cell(3, n, g.3)])
        }
        n += 1
        add([cell(0, n, "Dòng ví dụ (không nằm trong sheet dữ liệu — chép sang nếu cần):", style: 1)])
        let examples: [[String]] = [
            ["web-01", "10.0.0.5", "22", "deploy", "PROD", "Khách hàng A", "SSH", "bastion-01", "", "Máy chạy web"],
            ["bastion-01", "203.0.113.10", "", "admin", "PROD", "Khách hàng A", "SSH", "", "", "Cổng vào mạng nội bộ"],
            ["rdp-01", "10.0.0.20", "", "Administrator", "UAT", "Khách hàng A", "Windows", "", "", ""],
        ]
        for ex in examples {
            add(ex.enumerated().map { cell($0.offset, n, $0.element) })
        }
        let widths = [20, 14, 70, 22, 14, 18, 10, 14, 18, 24]
        let cols = widths.enumerated().map {
            #"<col min="\#($0.offset + 1)" max="\#($0.offset + 1)" width="\#($0.element)" customWidth="1"/>"#
        }.joined()
        return
            #"<worksheet \#(ns)><cols>\#(cols)</cols><sheetData>\#(rows.joined())</sheetData>\#(margins)</worksheet>"#
    }

    // MARK: - Ghi file

    /// Ghi file mẫu mới tới `destination` (đuôi `.xlsx`). KHÔNG ghi đè file đã có.
    /// - Parameter temporaryRoot: thư mục chứa thư mục làm việc tạm (mặc định thư mục tạm của hệ thống).
    public static func write(to destination: URL, temporaryRoot: URL? = nil) throws {
        guard destination.pathExtension.lowercased() == "xlsx" else { throw InventoryTemplateError.badExtension }
        let dest = destination.standardizedFileURL
        let parent = dest.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw InventoryTemplateError.parentMissing(parent.path)
        }
        var st = stat()
        if lstat(dest.path, &st) == 0 { throw InventoryTemplateError.alreadyExists(dest.path) }

        let fm = FileManager.default
        let work = (temporaryRoot ?? fm.temporaryDirectory).appendingPathComponent(
            "sshdesk-template-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let pkg = work.appendingPathComponent("pkg", isDirectory: true)
        for e in entries() {
            let url = pkg.appendingPathComponent(e.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.data.write(to: url)
        }
        let out = work.appendingPathComponent("template.xlsx")
        let result: BoundedProcess.Result
        do {
            result = try BoundedProcess.run(
                executable: "/usr/bin/zip", arguments: ["-X", "-D", "-r", "-q", out.path, "."], currentDirectory: pkg,
                maxBytes: 1_048_576, timeout: 30, exceeded: .entryTooLarge)
        } catch { throw InventoryTemplateError.zipFailed("\(error)") }
        guard result.status == 0, fm.fileExists(atPath: out.path) else {
            throw InventoryTemplateError.zipFailed("mã thoát \(result.status)")
        }
        // moveItem ném lỗi nếu đích đã có (kể cả tạo ngay lúc này) -> không bao giờ ghi đè.
        do { try fm.moveItem(at: out, to: dest) } catch {
            if lstat(dest.path, &st) == 0 { throw InventoryTemplateError.alreadyExists(dest.path) }
            throw error
        }
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
    }
}
