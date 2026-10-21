import Foundation

/// Một lần chạy Analyst (để xuất báo cáo / lưu lịch sử).
public struct AnalystRun: Sendable {
    public var projectName: String
    public var startedAt: Date
    public var topology: Topology
    public var results: [FlowTestResult]

    public init(projectName: String, startedAt: Date, topology: Topology, results: [FlowTestResult]) {
        self.projectName = projectName
        self.startedAt = startedAt
        self.topology = topology
        self.results = results
    }
}

/// Xuất Markdown/CSV chỉ từ các trường đã parse. KHÔNG có output thô (bằng chứng `raw` bị loại).
public enum AnalystReport {
    static func name(_ run: AnalystRun, _ id: UUID) -> String {
        run.topology.node(id)?.displayName ?? id.uuidString
    }

    public static func outcomeText(_ o: ProbeOutcome) -> String {
        switch o {
        case .passed: return "Passed"
        case .failed(.timeout): return "Failed (timeout)"
        case .failed(.refused): return "Failed (refused)"
        case .failed(.other(let m)): return "Failed (\(m))"
        case .untestable(let r): return "Không kiểm tra được (\(reasonText(r)))"
        }
    }

    static func reasonText(_ r: UntestableReason) -> String {
        switch r {
        case .toolMissing(let t): return "thiếu công cụ \(t)"
        case .sessionLost: return "mất phiên"
        case .connectionFailed(let m): return "lỗi kết nối \(m)"
        case .noExecutor: return "không có phiên"
        case .noDestinationIP: return "không có IP đích"
        }
    }

    static func checkText(_ c: DestinationCheck) -> String {
        switch c {
        case .listening(let bind, let procs):
            let p = procs.map { " " + $0.map { "\($0.name)[\($0.pid)]" }.joined(separator: ",") } ?? ""
            return "LISTEN \(bind)\(p)"
        case .notListening: return "Không LISTEN"
        case .unknown: return "Không rõ"
        }
    }

    static func latency(_ o: ProbeOutcome) -> Int? {
        if case .passed(let ms) = o { return ms }
        return nil
    }

    // MARK: Markdown

    public static func markdown(_ run: AnalystRun, dateFormatter: (Date) -> String = isoString) -> String {
        var out = "# Project Analyst: \(mdText(run.projectName))\n\n"
        out += "Thời điểm quét: \(dateFormatter(run.startedAt))\n\n"
        out +=
            "Chỉ thấy các kết nối đang mở lúc quét. Thời gian là số xấp xỉ đo ở máy này (gồm overhead SSH).\n\n"

        out += "## Server\n\n| Server | LISTEN | Kết nối ra ngoài project |\n| --- | --- | --- |\n"
        for s in run.topology.servers {
            let listen =
                s.collected
                ? (s.listening.isEmpty
                    ? "-"
                    : s.listening.map { ":\($0.port) (\($0.bindDisplay))" }.joined(separator: ", "))
                : "Không thu thập được"
            out +=
                "| \(mdCell(s.displayName)) | \(mdCell(listen)) | \(s.collected ? String(s.externalConnections) : "-") |\n"
        }

        out += "\n## Luồng kết nối\n\n"
        if run.topology.flows.isEmpty {
            out += "Không có luồng nào.\n"
        } else {
            out +=
                "| Nguồn | Đích | Cổng | Kết nối quan sát | Kết quả | ms (xấp xỉ) | Đích | Nguyên nhân |\n"
                + "| --- | --- | --- | --- | --- | --- | --- | --- |\n"
            for tf in run.topology.flows {
                let r = run.results.first { $0.flow == tf.flow }
                out +=
                    "| \(mdCell(name(run, tf.flow.source))) | \(mdCell(name(run, tf.flow.destination))) | \(tf.flow.port) | \(tf.observedConnections) | "
                    + "\(r.map { mdCell(outcomeText($0.outcome)) } ?? "Chưa chạy") | "
                    + "\(r.flatMap { latency($0.outcome) }.map(String.init) ?? "-") | "
                    + "\(r.map { mdCell(checkText($0.destinationCheck)) } ?? "-") | "
                    + "\(mdCell(r?.cause ?? "-")) |\n"
            }
        }

        if !run.topology.warnings.isEmpty {
            out += "\n## Cảnh báo\n\n"
            for w in run.topology.warnings { out += "- \(mdText(warningText(run, w)))\n" }
        }
        return out
    }

    static func warningText(_ run: AnalystRun, _ w: TopologyWarning) -> String {
        switch w {
        case .duplicateIP(let ip, let ids):
            return "IP \(ip) thuộc nhiều server (\(ids.map { name(run, $0) }.joined(separator: ", "))), không ánh xạ"
        case .socketsNotCollected(let id): return "\(name(run, id)): không thu thập được bảng socket"
        case .unparsedLines(let id, let n): return "\(name(run, id)): \(n) dòng không parse được"
        }
    }

    static func mdText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func mdCell(_ s: String) -> String {
        mdText(s).replacingOccurrences(of: "|", with: "\\|")
    }

    public static func isoString(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    // MARK: CSV

    public static let csvHeader = [
        "source", "destination", "port", "observed_connections", "result", "latency_ms_approx",
        "destination_check", "cause",
    ]

    public static func csv(_ run: AnalystRun) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for tf in run.topology.flows {
            let r = run.results.first { $0.flow == tf.flow }
            let fields: [String] = [
                name(run, tf.flow.source), name(run, tf.flow.destination), String(tf.flow.port),
                String(tf.observedConnections), r.map { outcomeText($0.outcome) } ?? "not_run",
                r.flatMap { latency($0.outcome) }.map(String.init) ?? "",
                r.map { checkText($0.destinationCheck) } ?? "", r?.cause ?? "",
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 + chặn CSV injection (ô bắt đầu bằng `= + - @` hoặc tab/CR được thêm `'` phía trước).
    static func csvField(_ raw: String) -> String {
        var s = raw
        if let f = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(f) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
