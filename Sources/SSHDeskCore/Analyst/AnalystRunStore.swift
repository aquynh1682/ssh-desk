import Foundation

public enum AnalystRunStatus: String, Sendable, Equatable {
    /// Mọi server thu thập được.
    case completed
    /// Có cảnh báo (server mất phiên/thiếu công cụ...), phần còn lại vẫn có kết quả.
    case partial
}

/// Cảnh báo của một lần chạy (đã gộp cảnh báo topology). Không chứa output thô.
public struct AnalystWarning: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case noAlias, sessionFailed, sessionLost, toolMissing, collectFailed
        case unparsedLines, duplicateIP, addressesMissing
    }

    public var kind: Kind
    public var hostID: UUID?
    public var hostName: String
    /// Chuỗi đã chuẩn hoá (tên công cụ, số dòng, IP...) hoặc thông điệp lỗi phiên đã làm sạch.
    public var detail: String

    public init(kind: Kind, hostID: UUID? = nil, hostName: String = "", detail: String = "") {
        self.kind = kind
        self.hostID = hostID
        self.hostName = hostName
        self.detail = detail
    }

    public var text: String {
        switch kind {
        case .noAlias: return "\(hostName): hồ sơ thiếu alias SSH, bỏ qua."
        case .sessionFailed:
            return "\(hostName): không mở được phiên SSH" + (detail.isEmpty ? "." : " (\(detail)).")
        case .sessionLost: return "\(hostName): mất phiên SSH giữa chừng."
        case .toolMissing: return "\(hostName): thiếu công cụ \(detail) (chỉ hỗ trợ Linux có iproute2)."
        case .collectFailed: return "\(hostName): không thu thập được dữ liệu."
        case .unparsedLines: return "\(hostName): \(detail) dòng không phân tích được."
        case .duplicateIP: return "IP \(detail) thuộc nhiều server nên không ánh xạ."
        case .addressesMissing: return "\(hostName): không đọc được địa chỉ IP của máy."
        }
    }
}

/// Một lần chạy đã (hoặc sắp) lưu.
public struct StoredAnalystRun: Sendable {
    public var id: UUID
    public var folderName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var status: AnalystRunStatus
    public var warnings: [AnalystWarning]
    public var topology: Topology
    public var results: [FlowTestResult]

    public init(
        id: UUID = UUID(), folderName: String, startedAt: Date, finishedAt: Date,
        status: AnalystRunStatus, warnings: [AnalystWarning], topology: Topology,
        results: [FlowTestResult]
    ) {
        self.id = id
        self.folderName = folderName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.warnings = warnings
        self.topology = topology
        self.results = results
    }

    /// Dạng dùng cho xuất báo cáo.
    public var run: AnalystRun {
        AnalystRun(
            projectName: folderName, startedAt: startedAt, topology: topology, results: results)
    }
}

public struct AnalystRunSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var folderName: String
    public var startedAt: Date
    public var finishedAt: Date
    public var status: AnalystRunStatus
    public var serverCount: Int
    public var flowCount: Int
    public var passed: Int
    public var failed: Int
}

public enum AnalystRunStoreError: Error, Equatable {
    case corruptRow(String)
}

/// Lưu lịch sử Project Analyst (migration v4). Chỉ lưu các trường đã parse; bằng chứng `raw` bị loại.
public actor AnalystRunRepository {
    public static let defaultRetention = 50

    private let db: Database
    private let retention: Int

    public init(database: Database, retention: Int = AnalystRunRepository.defaultRetention) {
        self.db = database
        self.retention = max(1, retention)
    }

    // MARK: - Ghi

    /// Lưu một lần chạy rồi cắt bớt để mỗi thư mục giữ tối đa `retention` lần mới nhất.
    public func save(_ run: StoredAnalystRun) throws {
        try db.transaction {
            let rid = Value.text(run.id.uuidString)
            try db.execute(
                """
                INSERT INTO analyst_runs (id, folder_name, started_at, finished_at, status, warnings_json)
                VALUES (?,?,?,?,?,?)
                """,
                [
                    rid, .text(run.folderName), .real(run.startedAt.timeIntervalSince1970),
                    .real(run.finishedAt.timeIntervalSince1970), .text(run.status.rawValue),
                    .text(Self.json(run.warnings)),
                ])
            for (i, s) in run.topology.servers.enumerated() {
                try db.execute(
                    """
                    INSERT INTO analyst_servers (run_id, seq, host_id, display_name, collected,
                        addresses_json, listening_json, external_connections) VALUES (?,?,?,?,?,?,?,?)
                    """,
                    [
                        rid, .int(Int64(i)), .text(s.hostID.uuidString), .text(s.displayName),
                        .int(s.collected ? 1 : 0), .text(Self.json(s.addresses.map(\.address))),
                        .text(Self.json(s.listening.map(ListenDTO.init))),
                        .int(Int64(s.externalConnections)),
                    ])
            }
            for (i, tf) in run.topology.flows.enumerated() {
                let result = run.results.first { $0.flow == tf.flow }
                let o = Self.encodeOutcome(result?.outcome)
                let dc = Self.encodeCheck(result?.destinationCheck)
                let envelope = EvidenceEnvelope(
                    evidence: (result?.evidence ?? []).filter { !$0.raw }.map(EvidenceDTO.init),
                    destProcesses: dc.processes.map { $0.map(ProcessDTO.init) })
                try db.execute(
                    """
                    INSERT INTO analyst_flows (run_id, seq, source_host_id, dest_host_id, port,
                        observed_connections, dest_ips_json, source_processes_json, outcome,
                        outcome_detail, latency_ms, dest_check, dest_bind, evidence_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [
                        rid, .int(Int64(i)), .text(tf.flow.source.uuidString),
                        .text(tf.flow.destination.uuidString), .int(Int64(tf.flow.port)),
                        .int(Int64(tf.observedConnections)),
                        .text(Self.json(tf.destinationIPs.map(\.address))),
                        .text(Self.json(tf.sourceProcesses.map(ProcessDTO.init))),
                        .text(o.kind), o.detail.map { .text($0) } ?? .null,
                        o.latency.map { .int(Int64($0)) } ?? .null,
                        dc.kind.map { .text($0) } ?? .null, dc.bind.map { .text($0) } ?? .null,
                        .text(Self.json(envelope)),
                    ])
            }
            try db.execute(
                """
                DELETE FROM analyst_runs WHERE folder_name = ? AND id NOT IN (
                    SELECT id FROM analyst_runs WHERE folder_name = ?
                    ORDER BY started_at DESC, rowid DESC LIMIT ?)
                """, [.text(run.folderName), .text(run.folderName), .int(Int64(retention))])
        }
    }

    public func delete(id: UUID) throws {
        try db.execute("DELETE FROM analyst_runs WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - Đọc

    /// Mới nhất trước.
    public func list(folder: String) throws -> [AnalystRunSummary] {
        let rows = try db.query(
            """
            SELECT r.id, r.folder_name, r.started_at, r.finished_at, r.status,
              (SELECT COUNT(*) FROM analyst_servers s WHERE s.run_id = r.id),
              (SELECT COUNT(*) FROM analyst_flows f WHERE f.run_id = r.id),
              (SELECT COUNT(*) FROM analyst_flows f WHERE f.run_id = r.id AND f.outcome = 'passed'),
              (SELECT COUNT(*) FROM analyst_flows f WHERE f.run_id = r.id AND f.outcome LIKE 'failed%')
            FROM analyst_runs r WHERE r.folder_name = ? ORDER BY r.started_at DESC, r.rowid DESC
            """, [.text(folder)])
        return try rows.map { row in
            guard case .text(let id) = row[0], let uuid = UUID(uuidString: id),
                case .text(let name) = row[1], case .real(let start) = row[2],
                case .real(let end) = row[3], case .text(let st) = row[4]
            else { throw AnalystRunStoreError.corruptRow("analyst_runs") }
            return AnalystRunSummary(
                id: uuid, folderName: name, startedAt: Date(timeIntervalSince1970: start),
                finishedAt: Date(timeIntervalSince1970: end),
                status: AnalystRunStatus(rawValue: st) ?? .partial,
                serverCount: Self.int(row[5]), flowCount: Self.int(row[6]), passed: Self.int(row[7]),
                failed: Self.int(row[8]))
        }
    }

    public func load(id: UUID) throws -> StoredAnalystRun? {
        guard
            let r = try db.query(
                """
                SELECT folder_name, started_at, finished_at, status, warnings_json
                FROM analyst_runs WHERE id = ?
                """, [.text(id.uuidString)]
            ).first
        else { return nil }
        guard case .text(let folder) = r[0], case .real(let start) = r[1], case .real(let end) = r[2],
            case .text(let st) = r[3], case .text(let wj) = r[4]
        else { throw AnalystRunStoreError.corruptRow("analyst_runs") }
        let warnings: [AnalystWarning] = Self.decode(wj) ?? []

        var servers: [ServerNode] = []
        for row in try db.query(
            """
            SELECT host_id, display_name, collected, addresses_json, listening_json, external_connections
            FROM analyst_servers WHERE run_id = ? ORDER BY seq
            """, [.text(id.uuidString)])
        {
            guard case .text(let hid) = row[0], let host = UUID(uuidString: hid),
                case .text(let name) = row[1], case .text(let aj) = row[3], case .text(let lj) = row[4]
            else { throw AnalystRunStoreError.corruptRow("analyst_servers") }
            let addrs = ((Self.decode(aj) as [String]?) ?? []).compactMap { IPLiteral($0) }
            let listens = ((Self.decode(lj) as [ListenDTO]?) ?? []).map(\.entry)
            servers.append(
                ServerNode(
                    hostID: host, displayName: name, collected: Self.int(row[2]) != 0,
                    addresses: addrs, listening: listens, externalConnections: Self.int(row[5])))
        }

        var flows: [TopologyFlow] = []
        var results: [FlowTestResult] = []
        for row in try db.query(
            """
            SELECT source_host_id, dest_host_id, port, observed_connections, dest_ips_json,
                source_processes_json, outcome, outcome_detail, latency_ms, dest_check, dest_bind,
                evidence_json
            FROM analyst_flows WHERE run_id = ? ORDER BY seq
            """, [.text(id.uuidString)])
        {
            guard case .text(let s) = row[0], let src = UUID(uuidString: s),
                case .text(let d) = row[1], let dst = UUID(uuidString: d),
                case .text(let ipj) = row[4], case .text(let spj) = row[5],
                case .text(let oc) = row[6], case .text(let ej) = row[11]
            else { throw AnalystRunStoreError.corruptRow("analyst_flows") }
            let port = Self.int(row[2])
            let flow = Flow(source: src, destination: dst, port: port)
            let destNode = servers.first { $0.hostID == dst }
            let listen = destNode?.listening.first { $0.port == port }
            let ips = ((Self.decode(ipj) as [String]?) ?? []).compactMap { IPLiteral($0) }
            let sp = ((Self.decode(spj) as [ProcessDTO]?) ?? []).map(\.ref)
            flows.append(
                TopologyFlow(
                    flow: flow, observedConnections: Self.int(row[3]), destinationIPs: ips,
                    sourceProcesses: sp, destinationListen: listen,
                    destinationVerified: destNode?.collected ?? false))
            if oc != "not_run" {
                var detail: String?
                if case .text(let t) = row[7] { detail = t }
                var latency: Int?
                if case .int(let l) = row[8] { latency = Int(l) }
                var ck: String?
                if case .text(let t) = row[9] { ck = t }
                var bind: String?
                if case .text(let t) = row[10] { bind = t }
                let env: EvidenceEnvelope? = Self.decode(ej)
                let outcome = Self.decodeOutcome(oc, detail: detail, latency: latency)
                results.append(
                    FlowTestResult(
                        flow: flow, outcome: outcome,
                        destinationCheck: Self.decodeCheck(
                            ck, bind: bind, processes: env?.destProcesses?.map(\.ref)),
                        evidence: (env?.evidence ?? []).map(\.evidence),
                        cause: outcome.isFailed ? FlowTestResult.unconfirmedCause : nil))
            }
        }
        return StoredAnalystRun(
            id: id, folderName: folder, startedAt: Date(timeIntervalSince1970: start),
            finishedAt: Date(timeIntervalSince1970: end),
            status: AnalystRunStatus(rawValue: st) ?? .partial, warnings: warnings,
            topology: Topology(servers: servers, flows: flows, warnings: []), results: results)
    }

    // MARK: - Mã hoá

    private typealias Value = SQLValue

    private static func int(_ v: SQLValue) -> Int {
        if case .int(let i) = v { return Int(i) }
        return 0
    }

    private static func json<T: Encodable>(_ v: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? String(decoding: enc.encode(v), as: UTF8.self)) ?? "[]"
    }

    private static func decode<T: Decodable>(_ s: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    static func encodeOutcome(_ o: ProbeOutcome?) -> (kind: String, detail: String?, latency: Int?) {
        guard let o else { return ("not_run", nil, nil) }
        switch o {
        case .passed(let ms): return ("passed", nil, ms)
        case .failed(.timeout): return ("failed_timeout", nil, nil)
        case .failed(.refused): return ("failed_refused", nil, nil)
        case .failed(.other(let m)): return ("failed_other", m, nil)
        case .untestable(.toolMissing(let t)): return ("untestable_tool_missing", t, nil)
        case .untestable(.sessionLost): return ("untestable_session_lost", nil, nil)
        // Thông điệp lỗi kênh có thể lấy từ stderr server: không lưu.
        case .untestable(.connectionFailed): return ("untestable_connection_failed", nil, nil)
        case .untestable(.noExecutor): return ("untestable_no_executor", nil, nil)
        case .untestable(.noDestinationIP): return ("untestable_no_destination_ip", nil, nil)
        }
    }

    static func decodeOutcome(_ kind: String, detail: String?, latency: Int?) -> ProbeOutcome {
        switch kind {
        case "passed": return .passed(milliseconds: latency ?? 0)
        case "failed_timeout": return .failed(.timeout)
        case "failed_refused": return .failed(.refused)
        case "failed_other": return .failed(.other(detail ?? ""))
        case "untestable_tool_missing": return .untestable(.toolMissing(detail ?? ""))
        case "untestable_session_lost": return .untestable(.sessionLost)
        case "untestable_connection_failed": return .untestable(.connectionFailed(""))
        case "untestable_no_destination_ip": return .untestable(.noDestinationIP)
        default: return .untestable(.noExecutor)
        }
    }

    static func encodeCheck(_ c: DestinationCheck?) -> (
        kind: String?, bind: String?, processes: [ProcessRef]?
    ) {
        guard let c else { return (nil, nil, nil) }
        switch c {
        case .listening(let bind, let procs): return ("listening", bind, procs)
        case .notListening: return ("not_listening", nil, nil)
        case .unknown: return ("unknown", nil, nil)
        }
    }

    static func decodeCheck(_ kind: String?, bind: String?, processes: [ProcessRef]?)
        -> DestinationCheck
    {
        switch kind {
        case "listening": return .listening(bind: bind ?? "", processes: processes)
        case "not_listening": return .notListening
        default: return .unknown
        }
    }

    private struct ProcessDTO: Codable {
        var name: String
        var pid: Int
        init(_ p: ProcessRef) {
            name = p.name
            pid = p.pid
        }
        var ref: ProcessRef { ProcessRef(name: name, pid: pid) }
    }

    private struct ListenDTO: Codable {
        var port: Int
        var bind: String?
        var wildcard: Bool
        var processes: [ProcessDTO]?
        init(_ e: ListenEntry) {
            port = e.port
            bind = e.bind?.address
            wildcard = e.isWildcard
            processes = e.processes?.map(ProcessDTO.init)
        }
        var entry: ListenEntry {
            ListenEntry(
                port: port, bind: bind.flatMap { IPLiteral($0) }, isWildcard: wildcard,
                processes: processes?.map(\.ref))
        }
    }

    private struct EvidenceDTO: Codable {
        var title: String
        var detail: String
        init(_ e: Evidence) {
            title = e.title
            detail = e.detail
        }
        var evidence: Evidence { Evidence(title: title, detail: detail) }
    }

    private struct EvidenceEnvelope: Codable {
        var evidence: [EvidenceDTO]
        var destProcesses: [ProcessDTO]?
    }
}

extension ProbeOutcome {
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
