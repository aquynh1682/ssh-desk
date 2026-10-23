import Foundation

/// Đọc CSV (ADR-026): UTF-8 (có/không BOM), UTF-16 LE có BOM; tự nhận `,` `;` tab; RFC 4180; ≤ 5 MB.
public enum CSVReader {
    public static let maxBytes = 5 * 1_048_576
    public static let maxColumns = 200
    public static let maxRows = 5000

    public static func read(
        url: URL, headerRow: Int? = nil, maxBytes: Int = CSVReader.maxBytes
    ) throws -> TableWorkbook {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
            throw SpreadsheetError.unreadable(error.localizedDescription)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { throw SpreadsheetError.notRegularFile }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxBytes else {
            throw SpreadsheetError.fileTooLarge(limitMB: max(1, maxBytes / 1_048_576))
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw SpreadsheetError.unreadable(error.localizedDescription) }
        return try parse(data: data, name: "CSV", headerRow: headerRow, maxBytes: maxBytes)
    }

    public static func parse(
        data: Data, name: String = "CSV", headerRow: Int? = nil, maxBytes: Int = CSVReader.maxBytes
    ) throws -> TableWorkbook {
        guard data.count <= maxBytes else {
            throw SpreadsheetError.fileTooLarge(limitMB: max(1, maxBytes / 1_048_576))
        }
        let text = try decode(data)
        let records = try records(from: text)
        var builder = TableBuilder()
        for (i, cells) in records.enumerated() { builder.add(number: i + 1, cells: cells) }
        guard builder.nonEmptyRows > 0 else { throw SpreadsheetError.emptyFile }
        if builder.nonEmptyRows > maxRows + 100 { throw SpreadsheetError.tooManyRows(limit: maxRows) }
        return TableWorkbook(sheets: [builder.finish(name: name, headerRow: headerRow)])
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            guard let s = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw SpreadsheetError.unsupportedEncoding
            }
            return s
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            let body = data.dropFirst(2)
            guard body.count % 2 == 0, let s = String(data: body, encoding: .utf16LittleEndian) else {
                throw SpreadsheetError.unsupportedEncoding
            }
            return s
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { throw SpreadsheetError.unsupportedEncoding }
        guard let s = String(data: data, encoding: .utf8), !s.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw SpreadsheetError.unsupportedEncoding
        }
        return s
    }

    /// Dấu phân cách theo dòng không rỗng đầu tiên: ký tự nhiều nhất ngoài dấu nháy trong `, ; \t`.
    static func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        var seenContent = false
        for c in scalars {
            if c == "\"" {
                inQuotes.toggle()
                seenContent = true
                continue
            }
            if inQuotes { continue }
            if c == "\n" || c == "\r" {
                if seenContent { break }
                continue
            }
            seenContent = true
            if counts[c] != nil { counts[c]! += 1 }
        }
        let best = counts.max { a, b in a.value == b.value ? order(a.key) > order(b.key) : a.value < b.value }
        return (best?.value ?? 0) > 0 ? best!.key : ","
    }

    private static func order(_ c: Unicode.Scalar) -> Int { c == "," ? 0 : (c == ";" ? 1 : 2) }

    /// RFC 4180: trường có thể được bọc `"`, `""` là dấu nháy, xuống dòng được phép trong trường có nháy.
    static func records(from text: String) throws -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        let delimiter = detectDelimiter(scalars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldWasQuoted = false
        var i = 0

        func endField() throws {
            row.append(String(field))
            if row.count > maxColumns { throw SpreadsheetError.tooManyColumns(limit: maxColumns) }
            field = String.UnicodeScalarView()
            fieldWasQuoted = false
        }
        func endRow() throws {
            try endField()
            rows.append(row)
            row = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty && !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
            } else if c == delimiter {
                try endField()
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                try endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted { try endRow() }
        return rows
    }
}
