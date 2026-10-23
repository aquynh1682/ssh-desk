import Foundation

/// Giới hạn đọc XLSX (ADR-026). Tham số hoá để test dùng giá trị nhỏ.
public struct XLSXLimits: Sendable {
    public var maxFileBytes = 20 * 1_048_576
    public var maxEntryBytes = 50 * 1_048_576
    public var maxTotalBytes = 100 * 1_048_576
    public var timeout: TimeInterval = 15
    public var maxRows = 5000
    public var maxColumns = 200
    public var maxEntries = 10_000

    public init() {}
}

/// Đọc `.xlsx` không dependency: `/usr/bin/unzip -p` qua executable + argv (env rỗng, không shell),
/// chỉ các thành phần tên cố định hoặc khớp `^xl/worksheets/[A-Za-z0-9_]+\.xml$`, parse bằng `XMLParser`.
/// Không tính công thức (chỉ lấy giá trị `<v>` đã tính sẵn).
public enum XLSXReader {
    static let unzip = "/usr/bin/unzip"
    static let workbookEntry = "xl/workbook.xml"
    static let relsEntry = "xl/_rels/workbook.xml.rels"
    static let sharedStringsEntry = "xl/sharedStrings.xml"
    static let sheetPattern = #"^xl/worksheets/[A-Za-z0-9_]+\.xml$"#

    public static func read(
        url: URL, headerRow: Int? = nil, limits: XLSXLimits = XLSXLimits(), keepSecret: SecretColumnValues? = nil
    ) throws -> TableWorkbook {
        // unzip hiểu tên file zip là wildcard (`a[1].xlsx` có thể đọc nhầm `a1.xlsx`): luôn chạy trên bản sao
        // trong thư mục tạm 0700 với tên cố định `in.xlsx`.
        let source = try validateFile(url, limits: limits)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sshdesk-xlsx-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw SpreadsheetError.unreadable(error.localizedDescription) }
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent("in.xlsx")
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            guard data.count <= limits.maxFileBytes else {
                throw SpreadsheetError.fileTooLarge(limitMB: max(1, limits.maxFileBytes / 1_048_576))
            }
            guard data.count >= 4, data[0] == 0x50, data[1] == 0x4B else { throw SpreadsheetError.notZip }
            try data.write(to: copy)
        } catch let e as SpreadsheetError {
            throw e
        } catch { throw SpreadsheetError.unreadable(error.localizedDescription) }
        let path = copy.path
        let names = try listEntries(path: path, limits: limits)
        var budget = Budget(limits: limits)

        let workbookData = try readEntry(
            path: path, entry: workbookEntry, names: names, budget: &budget, limits: limits)
        let sheetRefs = try parseWorkbook(workbookData)
        let relsData = try readEntry(path: path, entry: relsEntry, names: names, budget: &budget, limits: limits)
        let rels = try parseRelationships(relsData)

        var shared: [String] = []
        var warnings: [String] = []
        if names.contains(sharedStringsEntry) {
            let data = try readEntry(
                path: path, entry: sharedStringsEntry, names: names, budget: &budget, limits: limits)
            shared = try parseSharedStrings(data)
        }

        var sheets: [TableSheet] = []
        for ref in sheetRefs where !ref.hidden {
            guard let rid = ref.relationshipID, let rel = rels[rid], rel.isWorksheet else { continue }
            let entry = resolve(target: rel.target)
            guard entry.range(of: sheetPattern, options: .regularExpression) != nil else {
                throw SpreadsheetError.unsafeEntryName
            }
            let data = try readEntry(path: path, entry: entry, names: names, budget: &budget, limits: limits)
            sheets.append(
                try parseSheet(
                    data, name: ref.name, shared: shared, headerRow: headerRow, limits: limits, keep: keepSecret))
        }
        if sheets.isEmpty { throw SpreadsheetError.noSheets }
        if shared.isEmpty, names.contains(sharedStringsEntry) { warnings.append("Bảng chuỗi dùng chung trống.") }
        return TableWorkbook(sheets: sheets, warnings: warnings)
    }

    // MARK: - File & danh sách thành phần

    private static func validateFile(_ url: URL, limits: XLSXLimits) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard ext == "xlsx" else { throw SpreadsheetError.unsupportedExtension("." + ext) }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: resolved.path) } catch {
            throw SpreadsheetError.unreadable(error.localizedDescription)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw SpreadsheetError.notRegularFile }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= limits.maxFileBytes else {
            throw SpreadsheetError.fileTooLarge(limitMB: max(1, limits.maxFileBytes / 1_048_576))
        }
        guard let fh = FileHandle(forReadingAtPath: resolved.path) else {
            throw SpreadsheetError.unreadable(resolved.lastPathComponent)
        }
        defer { try? fh.close() }
        let magic = (try? fh.read(upToCount: 4)) ?? Data()
        guard magic.count == 4, magic[0] == 0x50, magic[1] == 0x4B else { throw SpreadsheetError.notZip }
        // Đường dẫn tuyệt đối nên không bao giờ bị unzip hiểu thành tuỳ chọn (bắt đầu bằng `-`).
        return resolved.path
    }

    private struct Budget {
        let limits: XLSXLimits
        var used = 0
        var remaining: Int { limits.maxTotalBytes - used }
    }

    static func listEntries(path: String, limits: XLSXLimits) throws -> Set<String> {
        let result = try BoundedProcess.run(
            executable: unzip, arguments: ["-Z1", path], maxBytes: 4 * 1_048_576, timeout: limits.timeout,
            exceeded: .tooManyEntries)
        guard result.status == 0 else {
            throw result.status == 9 ? SpreadsheetError.notZip : SpreadsheetError.unzipFailed(result.status)
        }
        guard let text = String(data: result.stdout, encoding: .utf8) else { throw SpreadsheetError.unsafeEntryName }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.count > limits.maxEntries { throw SpreadsheetError.tooManyEntries }
        return try validateEntryNames(lines)
    }

    /// Từ chối tên trùng (không phân biệt hoa thường), có `..`, đường dẫn tuyệt đối, rỗng hoặc ký tự điều khiển.
    static func validateEntryNames(_ names: [String]) throws -> Set<String> {
        var seen = Set<String>()
        var lowered = Set<String>()
        for name in names {
            guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("\\"),
                !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
                !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else { throw SpreadsheetError.unsafeEntryName }
            if !lowered.insert(name.lowercased()).inserted { throw SpreadsheetError.duplicateEntry }
            seen.insert(name)
        }
        return seen
    }

    private static func readEntry(
        path: String, entry: String, names: Set<String>, budget: inout Budget, limits: XLSXLimits
    ) throws -> Data {
        let allowed =
            [workbookEntry, relsEntry, sharedStringsEntry].contains(entry)
            || entry.range(of: sheetPattern, options: .regularExpression) != nil
        guard allowed else { throw SpreadsheetError.unsafeEntryName }
        guard names.contains(entry) else { throw SpreadsheetError.missingPart(entry) }
        let cap = min(limits.maxEntryBytes, budget.remaining)
        let exceeded: SpreadsheetError = budget.remaining < limits.maxEntryBytes ? .totalTooLarge : .entryTooLarge
        let result = try BoundedProcess.run(
            executable: unzip, arguments: ["-p", path, entry], maxBytes: max(0, cap), timeout: limits.timeout,
            exceeded: exceeded)
        guard result.status == 0 else {
            throw result.status == 11
                ? SpreadsheetError.missingPart(entry) : SpreadsheetError.unzipFailed(result.status)
        }
        budget.used += result.stdout.count
        return result.stdout
    }

    /// Target tương đối (gốc `xl/`) hoặc tuyệt đối (`/xl/...`).
    static func resolve(target: String) -> String {
        target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }

    // MARK: - XML

    /// Từ chối `<!DOCTYPE`/`<!ENTITY`, UTF-16 và mọi thứ không phải UTF-8 trước khi đưa vào XMLParser.
    static func guardXML(_ data: Data) throws {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) {
            throw SpreadsheetError.notUTF8
        }
        if b.count >= 4, b[0] == 0 || b[1] == 0 { throw SpreadsheetError.notUTF8 }
        let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        if let r = head.range(of: "encoding=") {
            let tail = head[r.upperBound...].prefix(20)
            if !tail.contains("utf-8") && !tail.contains("utf8") { throw SpreadsheetError.notUTF8 }
        }
        guard String(data: data, encoding: .utf8) != nil else { throw SpreadsheetError.notUTF8 }
        let doctype = Array("doctype".utf8)
        let entity = Array("entity".utf8)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i + 1 < n {
                if bytes[i] == 0x3C, bytes[i + 1] == 0x21 {
                    if matches(bytes, at: i + 2, doctype) || matches(bytes, at: i + 2, entity) {
                        throw SpreadsheetError.forbiddenXML
                    }
                }
                i += 1
            }
        }
    }

    private static func matches(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, _ word: [UInt8]) -> Bool {
        guard start + word.count <= bytes.count else { return false }
        for (k, w) in word.enumerated() {
            var c = bytes[start + k]
            if c >= 0x41 && c <= 0x5A { c += 0x20 }
            if c != w { return false }
        }
        return true
    }

    private static func runParser(_ data: Data, delegate: XMLParserDelegate & ErrorHolder) throws {
        try guardXML(data)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let e = delegate.failure { throw e }
        if !ok { throw SpreadsheetError.malformedXML(parser.parserError?.localizedDescription ?? "không rõ") }
    }

    struct SheetRef {
        var name: String
        var relationshipID: String?
        var hidden: Bool
    }

    static func parseWorkbook(_ data: Data) throws -> [SheetRef] {
        let d = WorkbookDelegate()
        try runParser(data, delegate: d)
        return d.sheets
    }

    struct Relationship {
        var target: String
        var isWorksheet: Bool
    }

    static func parseRelationships(_ data: Data) throws -> [String: Relationship] {
        let d = RelsDelegate()
        try runParser(data, delegate: d)
        return d.rels
    }

    static func parseSharedStrings(_ data: Data) throws -> [String] {
        let d = SharedStringsDelegate()
        try runParser(data, delegate: d)
        return d.strings
    }

    static func parseSheet(
        _ data: Data, name: String, shared: [String], headerRow: Int?, limits: XLSXLimits,
        keep: SecretColumnValues? = nil
    ) throws -> TableSheet {
        let d = SheetDelegate(shared: shared, limits: limits)
        try runParser(data, delegate: d)
        var warnings: [String] = []
        if d.formulaCount > 0 {
            warnings.append("\(d.formulaCount) ô có công thức: chỉ lấy giá trị đã tính sẵn, không tính lại.")
        }
        if d.errorCells > 0 { warnings.append("\(d.errorCells) ô lỗi (#REF!...): để trống.") }
        if d.badSharedRefs > 0 { warnings.append("\(d.badSharedRefs) ô tham chiếu chuỗi không tồn tại: để trống.") }
        return d.builder.finish(name: name, headerRow: headerRow, extraWarnings: warnings, keep: keep)
    }

    /// Chỉ số cột (0 = A) từ tham chiếu ô như `B3`; nil nếu sai dạng.
    static func columnIndex(ofReference ref: String) -> Int? {
        var value = 0
        var count = 0
        for u in ref.unicodeScalars {
            guard u.value >= 0x41 && u.value <= 0x5A || u.value >= 0x61 && u.value <= 0x7A else { break }
            value = value * 26 + Int(u.value & 0x1F)
            count += 1
            if count > 3 { return nil }
        }
        return count > 0 ? value - 1 : nil
    }
}

protocol ErrorHolder: AnyObject {
    var failure: SpreadsheetError? { get }
}

private func localName(_ element: String) -> String {
    if let i = element.lastIndex(of: ":") { return String(element[element.index(after: i)...]) }
    return element
}

private func attribute(_ attrs: [String: String], _ name: String) -> String? {
    if let v = attrs[name] { return v }
    return attrs.first { $0.key.hasSuffix(":" + name) }?.value
}

private final class WorkbookDelegate: NSObject, XMLParserDelegate, ErrorHolder {
    var sheets: [XLSXReader.SheetRef] = []
    var failure: SpreadsheetError?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard localName(elementName) == "sheet", let name = attributeDict["name"] else { return }
        let state = (attributeDict["state"] ?? "visible").lowercased()
        sheets.append(
            XLSXReader.SheetRef(
                name: name, relationshipID: attribute(attributeDict, "id"), hidden: state != "visible"))
    }
}

private final class RelsDelegate: NSObject, XMLParserDelegate, ErrorHolder {
    var rels: [String: XLSXReader.Relationship] = [:]
    var failure: SpreadsheetError?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard localName(elementName) == "Relationship" else { return }
        if (attributeDict["TargetMode"] ?? "").lowercased() == "external" {
            failure = .externalRelationship
            parser.abortParsing()
            return
        }
        guard let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        let type = attributeDict["Type"] ?? ""
        rels[id] = XLSXReader.Relationship(target: target, isWorksheet: type.hasSuffix("/worksheet"))
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate, ErrorHolder {
    var strings: [String] = []
    var failure: SpreadsheetError?
    private var inSI = false
    private var inT = false
    private var inPhonetic = false
    private var current = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch localName(elementName) {
        case "si":
            inSI = true
            current = ""
        case "t": if inSI && !inPhonetic { inT = true }
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "t": inT = false
        case "rPh": inPhonetic = false
        case "si":
            inSI = false
            strings.append(current)
        default: break
        }
    }
}

private final class SheetDelegate: NSObject, XMLParserDelegate, ErrorHolder {
    let shared: [String]
    let limits: XLSXLimits
    var builder = TableBuilder()
    var failure: SpreadsheetError?
    var formulaCount = 0
    var errorCells = 0
    var badSharedRefs = 0

    private var rowNumber = 0
    private var lastRow = 0
    private var lastColumn = -1
    private var cells: [Int: String] = [:]
    private var inCell = false
    private var column = 0
    private var cellType = ""
    private var vBuffer = ""
    private var textBuffer = ""
    private var inV = false
    private var inInline = false
    private var inT = false
    private var inPhonetic = false

    init(shared: [String], limits: XLSXLimits) {
        self.shared = shared
        self.limits = limits
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch localName(elementName) {
        case "row":
            rowNumber = attributeDict["r"].flatMap { Int($0) } ?? (lastRow + 1)
            lastRow = rowNumber
            lastColumn = -1
            cells = [:]
        case "c":
            inCell = true
            if let r = attributeDict["r"], let col = XLSXReader.columnIndex(ofReference: r) {
                column = col
            } else {
                column = lastColumn + 1
            }
            lastColumn = column
            cellType = attributeDict["t"] ?? ""
            vBuffer = ""
            textBuffer = ""
        case "v": if inCell { inV = true }
        case "is": if inCell { inInline = true }
        case "t": if inInline && !inPhonetic { inT = true }
        case "rPh": inPhonetic = true
        case "f": if inCell { formulaCount += 1 }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { vBuffer += string }
        if inT { textBuffer += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch localName(elementName) {
        case "v": inV = false
        case "t": inT = false
        case "rPh": inPhonetic = false
        case "is": inInline = false
        case "c":
            inCell = false
            finishCell(parser)
        case "row": finishRow(parser)
        default: break
        }
    }

    private func finishCell(_ parser: XMLParser) {
        let v = vBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        switch cellType {
        case "s":
            if let i = Int(v), i >= 0, i < shared.count {
                text = shared[i]
            } else {
                if !v.isEmpty { badSharedRefs += 1 }
                text = ""
            }
        case "inlineStr": text = textBuffer
        case "str": text = vBuffer
        case "b": text = v.isEmpty ? "" : (v == "1" ? "TRUE" : "FALSE")
        case "e":
            errorCells += 1
            text = ""
        default: text = v
        }
        if text.isEmpty { return }
        if column >= limits.maxColumns {
            failure = .tooManyColumns(limit: limits.maxColumns)
            parser.abortParsing()
            return
        }
        cells[column] = text
    }

    private func finishRow(_ parser: XMLParser) {
        guard let maxColumn = cells.keys.max() else { return }
        var dense = [String](repeating: "", count: maxColumn + 1)
        for (k, v) in cells { dense[k] = v }
        let row = TableRow(number: rowNumber, cells: dense)
        if row.isBlank { return }
        builder.add(number: rowNumber, cells: dense)
        if builder.nonEmptyRows > limits.maxRows + 100 {
            failure = .tooManyRows(limit: limits.maxRows)
            parser.abortParsing()
        }
    }
}
