import Foundation

public enum AnalystEdgeStyle: Sendable, Equatable {
    /// Xanh, nét liền.
    case passed
    /// Đỏ, nét liền.
    case failed
    /// Xám, nét đứt: chưa thử / không kiểm tra được.
    case notTested
    /// Chế độ "Kết nối quan sát": chỉ cạnh phát hiện, chưa thử.
    case observed
}

public enum AnalystMapMode: String, Sendable, CaseIterable {
    case tests
    case observed

    public var title: String {
        switch self {
        case .tests: return "Kiểm tra kết nối"
        case .observed: return "Kết nối quan sát"
        }
    }
}

public struct AnalystResultRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var flow: Flow
    public var source: String
    public var destination: String
    /// `8080/TCP`
    public var port: String
    public var resultText: String
    public var style: AnalystEdgeStyle
    public var timeText: String
    public var isFailure: Bool
}

public struct AnalystCheckLine: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case good, bad, neutral }
    public var title: String
    public var headline: String
    public var detail: String?
    public var tone: Tone
}

public struct AnalystCauseLine: Sendable, Equatable {
    public var headline: String
    /// Chỉ có khi cạnh lỗi; trung tính, không khẳng định nguyên nhân.
    public var hint: String?
}

public enum AnalystEmptyState: Sendable, Equatable {
    case noHosts
    case notRunYet
    case noEdges
    case hasData

    public var title: String {
        switch self {
        case .noHosts: return "Thư mục chưa có máy chủ"
        case .notRunYet: return "Chưa chạy lần nào"
        case .noEdges: return "Không phát hiện kết nối nào giữa các server"
        case .hasData: return ""
        }
    }

    public var message: String {
        switch self {
        case .noHosts: return "Thêm máy chủ vào thư mục này để quét kết nối giữa chúng."
        case .notRunYet: return "Bấm “Chạy kiểm tra” để quét kết nối."
        case .noEdges:
            return
                "App chỉ thấy các kết nối TCP đang mở vào lúc quét. Kết nối ngắt quãng (job định kỳ, kết nối chưa phát sinh) sẽ không hiện. Hãy thử quét lại khi hệ thống đang hoạt động."
        case .hasData: return ""
        }
    }
}

/// Logic trình bày của Project Analyst (nhãn, màu theo kết quả, tóm tắt). Thuần, có test.
public enum AnalystPresentation {
    public static let hint = "Kiểm tra firewall và định tuyến"
    public static let sourceNote = "Kiểm tra chạy trên server nguồn"

    // MARK: Kiểu cạnh và nhãn

    public static func style(_ result: FlowTestResult?, mode: AnalystMapMode = .tests)
        -> AnalystEdgeStyle
    {
        if mode == .observed { return .observed }
        guard let result else { return .notTested }
        switch result.outcome {
        case .passed: return .passed
        case .failed: return .failed
        case .untestable: return .notTested
        }
    }

    /// Nhãn trên cạnh: `TCP :8080 · 4 ms`, `TCP :5432 · TIMEOUT`, `TCP :5432 · REFUSED`.
    public static func edgeLabel(
        _ flow: TopologyFlow, result: FlowTestResult?, mode: AnalystMapMode = .tests
    ) -> String {
        let base = "TCP :\(flow.flow.port)"
        if mode == .observed { return base + " · \(flow.observedConnections) kết nối" }
        guard let result else { return base }
        switch result.outcome {
        case .passed(let ms): return base + " · " + millisText(ms)
        case .failed(.timeout): return base + " · TIMEOUT"
        case .failed(.refused): return base + " · REFUSED"
        case .failed(.other): return base + " · LỖI"
        case .untestable: return base + " · không kiểm tra được"
        }
    }

    public static func millisText(_ ms: Int) -> String { "\(ms) ms" }

    // MARK: Kết quả

    public static func resultText(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .passed: return "Thông"
        case .failed(.timeout): return "Timeout"
        case .failed(.refused): return "Bị từ chối"
        case .failed(.other): return "Lỗi"
        case .untestable: return "Không kiểm tra được"
        }
    }

    /// `timeout`: timeout probe đang cài đặt (ADR-021); chỉ dùng để hiện khi probe hết giờ.
    public static func timeText(_ outcome: ProbeOutcome, timeout: ProbeTimeout = .default) -> String {
        switch outcome {
        case .passed(let ms): return millisText(ms)
        case .failed(.timeout): return "\(timeout.seconds).0 s"
        default: return "—"
        }
    }

    public static func passedCount(_ results: [FlowTestResult]) -> Int {
        results.filter { if case .passed = $0.outcome { return true } else { return false } }.count
    }

    public static func failedCount(_ results: [FlowTestResult]) -> Int {
        results.filter { $0.outcome.isFailed }.count
    }

    public static func untestableCount(_ results: [FlowTestResult]) -> Int {
        results.count - passedCount(results) - failedCount(results)
    }

    /// `3 thông · 1 lỗi` (thêm `· 1 không kiểm tra được` khi có).
    public static func summary(_ results: [FlowTestResult]) -> String {
        summary(
            passed: passedCount(results), failed: failedCount(results),
            untestable: untestableCount(results))
    }

    public static func summary(passed: Int, failed: Int, untestable: Int = 0) -> String {
        var s = "\(passed) thông · \(failed) lỗi"
        if untestable > 0 { s += " · \(untestable) không kiểm tra được" }
        return s
    }

    public static func rows(_ run: StoredAnalystRun, timeout: ProbeTimeout = .default)
        -> [AnalystResultRow]
    {
        run.topology.flows.map { tf in
            let r = run.results.first { $0.flow == tf.flow }
            let name = { (id: UUID) in run.topology.node(id)?.displayName ?? "?" }
            return AnalystResultRow(
                id: "\(tf.flow.source)>\(tf.flow.destination):\(tf.flow.port)", flow: tf.flow,
                source: name(tf.flow.source), destination: name(tf.flow.destination),
                port: "\(tf.flow.port)/TCP",
                resultText: r.map { resultText($0.outcome) } ?? "Chưa thử",
                style: style(r), timeText: r.map { timeText($0.outcome, timeout: timeout) } ?? "—",
                isFailure: r?.outcome.isFailed ?? false)
        }
    }

    // MARK: Panel chi tiết kết nối

    public static func badge(_ result: FlowTestResult?) -> String {
        guard let result else { return "CHƯA THỬ" }
        switch result.outcome {
        case .passed: return "PASSED"
        case .failed: return "FAILED"
        case .untestable: return "KHÔNG THỬ ĐƯỢC"
        }
    }

    public static func sourceCheck(_ result: FlowTestResult?, timeout: ProbeTimeout = .default)
        -> AnalystCheckLine
    {
        let title = "KIỂM TRA TỪ NGUỒN"
        guard let result else {
            return AnalystCheckLine(title: title, headline: "Chưa thử", detail: nil, tone: .neutral)
        }
        switch result.outcome {
        case .passed(let ms):
            return AnalystCheckLine(
                title: title, headline: "Kết nối thành công", detail: "\(ms) ms (xấp xỉ, gồm overhead SSH)",
                tone: .good)
        case .failed(.timeout):
            return AnalystCheckLine(
                title: title, headline: "Hết thời gian chờ", detail: "Quá thời gian chờ", tone: .bad)
        case .failed(.refused):
            return AnalystCheckLine(
                title: title, headline: "Kết nối bị từ chối", detail: "Cổng đóng hoặc bị chặn", tone: .bad)
        case .failed(.other(let m)):
            return AnalystCheckLine(title: title, headline: "Kết nối thất bại", detail: m, tone: .bad)
        case .untestable(let reason):
            return AnalystCheckLine(
                title: title, headline: "Không kiểm tra được", detail: reasonText(reason), tone: .neutral)
        }
    }

    public static func reasonText(_ r: UntestableReason) -> String {
        switch r {
        case .toolMissing(let t): return "Server nguồn thiếu công cụ \(t)"
        case .sessionLost: return "Mất phiên SSH tới server nguồn"
        case .connectionFailed: return "Lỗi kênh SSH tới server nguồn"
        case .noExecutor: return "Không có phiên SSH tới server nguồn"
        case .noDestinationIP: return "Không có IP đích"
        }
    }

    public static func destinationCheck(_ result: FlowTestResult?, flow: TopologyFlow)
        -> AnalystCheckLine
    {
        let title = "KIỂM TRA TỪ ĐÍCH"
        let check: DestinationCheck
        if let result {
            check = result.destinationCheck
        } else if let l = flow.destinationListen {
            check = .listening(bind: l.bindDisplay, processes: l.processes)
        } else {
            check = .unknown
        }
        switch check {
        case .listening(let bind, let procs):
            let p = procs.map { $0.map(\.name).joined(separator: ", ") }
            return AnalystCheckLine(
                title: title, headline: "LISTEN \(bind):\(flow.flow.port)",
                detail: p ?? "Không rõ tiến trình (cần quyền đọc)", tone: .good)
        case .notListening:
            return AnalystCheckLine(
                title: title, headline: "Không thấy LISTEN",
                detail: "Cổng \(flow.flow.port) không có socket LISTEN khớp lúc kiểm tra", tone: .bad)
        case .unknown:
            return AnalystCheckLine(
                title: title, headline: "Không rõ",
                detail: "Không đọc được bảng socket của đích", tone: .neutral)
        }
    }

    /// NGUYÊN NHÂN luôn "Chưa xác nhận"; gợi ý trung tính chỉ khi lỗi.
    public static func cause(_ result: FlowTestResult?) -> AnalystCauseLine {
        AnalystCauseLine(
            headline: FlowTestResult.unconfirmedCause,
            hint: (result?.outcome.isFailed ?? false) ? hint : nil)
    }

    public static func evidence(_ result: FlowTestResult?) -> [Evidence] {
        (result?.evidence ?? []).filter { !$0.raw }
    }

    public static func originText(_ sourceName: String) -> String { "\(sourceName) qua SSH" }

    // MARK: Server

    /// `LISTEN :443` chính (khử trùng cổng, tối đa `limit`).
    public static func listenLabels(_ node: ServerNode, limit: Int = 3) -> [String] {
        var seen = Set<Int>()
        var out: [String] = []
        for e in node.listening where seen.insert(e.port).inserted { out.append(e.label) }
        return Array(out.prefix(limit))
    }

    /// `443 (nginx), 8080 (java)` cho bảng Servers.
    public static func listenSummary(_ node: ServerNode) -> String {
        guard node.collected else { return "—" }
        var seen = Set<Int>()
        var parts: [String] = []
        for e in node.listening where seen.insert(e.port).inserted {
            let procs = node.listening.filter { $0.port == e.port }.compactMap(\.processes).flatMap { $0 }
            var names: [String] = []
            for p in procs where !names.contains(p.name) { names.append(p.name) }
            parts.append(names.isEmpty ? ":\(e.port)" : ":\(e.port) (\(names.joined(separator: ", ")))")
        }
        return parts.isEmpty ? "Không có cổng LISTEN" : parts.joined(separator: ", ")
    }

    public static func collectionStatus(_ node: ServerNode?, warnings: [AnalystWarning]) -> String {
        guard let node else { return "Chưa quét" }
        if node.collected { return "Đã thu thập" }
        return "Không thu thập được"
    }

    public static func issues(for hostID: UUID, in warnings: [AnalystWarning]) -> [String] {
        warnings.filter { $0.hostID == hostID }.map(\.text)
    }

    public static func externalText(_ node: ServerNode) -> String {
        node.collected ? "\(node.externalConnections)" : "—"
    }

    // MARK: Trạng thái màn hình

    public static func emptyState(hostCount: Int, run: StoredAnalystRun?) -> AnalystEmptyState {
        if hostCount == 0 { return .noHosts }
        guard let run else { return .notRunYet }
        return run.topology.flows.isEmpty ? .noEdges : .hasData
    }

    /// `● 5 kết nối SSH sẵn sàng`
    public static func readyText(_ count: Int) -> String { "\(count) kết nối SSH sẵn sàng" }

    public static func progressText(_ p: AnalystProgress) -> String {
        switch p {
        case .connecting(let host, let i, let n): return "Đang mở phiên \(i)/\(n): \(host)…"
        case .collecting(let done, let total, _): return "Đang thu thập \(done)/\(total) server…"
        case .testing(let done, let total): return "Đã thử \(done)/\(total) kết nối…"
        case .saving: return "Đang lưu…"
        }
    }

    // MARK: Xuất báo cáo

    public enum ExportFormat: Sendable { case markdown, csv }

    public static func exportFileName(
        folder: String, date: Date, format: ExportFormat, timeZone: TimeZone = .current
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        let safe = String(
            folder.unicodeScalars.map { c -> Character in
                CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" ? Character(c) : "-"
            }
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "project-analyst-\(safe.isEmpty ? "thu-muc" : safe)-\(f.string(from: date))."
            + (format == .markdown ? "md" : "csv")
    }
}
