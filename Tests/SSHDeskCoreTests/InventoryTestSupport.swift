import Foundation

@testable import SSHDeskCore

/// Ghi zip thủ công (method store) để dựng được cả file "xấu": tên trùng, `..`, đường dẫn tuyệt đối.
enum TestZip {
    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    static func build(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let crc = crc32(e.data)
            let offset = out.count
            out.append(contentsOf: le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21))
            out.append(contentsOf: le32(crc) + le32(UInt32(e.data.count)) + le32(UInt32(e.data.count)))
            out.append(contentsOf: le16(name.count) + le16(0))
            out.append(name)
            out.append(e.data)
            central.append(contentsOf: le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x0800) + le16(0))
            central.append(contentsOf: le16(0) + le16(0x21) + le32(crc) + le32(UInt32(e.data.count)))
            central.append(contentsOf: le32(UInt32(e.data.count)) + le16(name.count) + le16(0) + le16(0))
            central.append(contentsOf: le16(0) + le16(0) + le32(0) + le32(UInt32(offset)))
            central.append(name)
        }
        let cdOffset = out.count
        out.append(central)
        out.append(contentsOf: le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count))
        out.append(contentsOf: le32(UInt32(central.count)) + le32(UInt32(cdOffset)) + le16(0))
        return out
    }
}

/// Dựng .xlsx thủ công cho test reader.
struct TestXLSX {
    struct Sheet {
        var name: String
        var xml: String
        var hidden = false
        var target: String?
    }

    var sheets: [Sheet]
    var sharedStrings: String?
    var extraEntries: [(String, String)] = []
    var relsExtra = ""
    var workbookOverride: String?

    static func sheetXML(_ rows: String, extra: String = "") -> String {
        #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
            + rows + "</sheetData>" + extra + "</worksheet>"
    }

    /// Hàng chuỗi inline: `["a","b"]` ở dòng `n`.
    static func inlineRow(_ n: Int, _ values: [String?]) -> String {
        let cols = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var cells = ""
        for (i, v) in values.enumerated() {
            guard let v else { continue }
            cells += #"<c r="\#(cols[i])\#(n)" t="inlineStr"><is><t>\#(v)</t></is></c>"#
        }
        return #"<row r="\#(n)">\#(cells)</row>"#
    }

    func entries() -> [(name: String, data: Data)] {
        let ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var wb =
            #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\#(ns)"><sheets>"#
        var rels =
            #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        var out: [(String, Data)] = []
        for (i, s) in sheets.enumerated() {
            let state = s.hidden ? #" state="hidden""# : ""
            wb += #"<sheet name="\#(s.name)" sheetId="\#(i + 1)"\#(state) r:id="rId\#(i + 1)"/>"#
            rels +=
                #"<Relationship Id="rId\#(i + 1)" Type="\#(ns)/worksheet" Target="\#(s.target ?? "worksheets/sheet\(i + 1).xml")"/>"#
            out.append(("xl/worksheets/sheet\(i + 1).xml", Data(s.xml.utf8)))
        }
        wb += "</sheets></workbook>"
        rels += relsExtra + "</Relationships>"
        out.insert(("xl/workbook.xml", Data((workbookOverride ?? wb).utf8)), at: 0)
        out.insert(("xl/_rels/workbook.xml.rels", Data(rels.utf8)), at: 1)
        if let sharedStrings { out.append(("xl/sharedStrings.xml", Data(sharedStrings.utf8))) }
        for (n, x) in extraEntries { out.append((n, Data(x.utf8))) }
        return out
    }

    @discardableResult
    func write(to url: URL, entries override: [(name: String, data: Data)]? = nil) throws -> URL {
        try TestZip.build(override ?? entries()).write(to: url)
        return url
    }
}

func testRecord(
    _ name: String, host: String = "10.0.0.1", port: Int = 22, user: String = "deploy", env: HostEnvironment? = nil,
    folder: String? = nil, jump: String? = nil, set: String? = nil, notes: String? = nil, kind: HostKind = .ssh,
    row: Int = 2
) -> InventoryRecord {
    InventoryRecord(
        externalID: name, name: name, hostName: host, port: port, user: user, kind: kind, environment: env,
        folder: folder, jumpRef: jump, credentialSetName: set, notes: notes, sourceRow: row)
}

/// Bảng thô từ các dòng văn bản (dòng đầu là tiêu đề).
func testSheet(_ rows: [[String]], name: String = "S", headerRow: Int = 1) -> TableSheet {
    var b = TableBuilder()
    for (i, r) in rows.enumerated() { b.add(number: i + 1, cells: r) }
    return b.finish(name: name, headerRow: headerRow)
}
