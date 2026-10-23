import Foundation

/// Nơi cấp snapshot Monitor từ một nguồn số liệu (Prometheus/Zabbix).
public protocol MetricsSnapshotProviding: Sendable {
    func snapshot(for host: HostProfile, at date: Date) async throws -> MonitorSnapshot
    /// Thử kết nối nguồn; trả mô tả ngắn (phiên bản).
    func testConnection() async throws -> String
}

/// Một mẫu của vector Prometheus.
struct PromSample: Equatable {
    var labels: [String: String]
    var value: Double
}

/// Bộ truy vấn node_exporter CỐ ĐỊNH (ADR-028). Chỉ giá trị nhãn `instance` (đã escape) được ghép vào.
enum PromQuery: CaseIterable {
    case cpu, cores, memory, load, disks, uptime

    /// Filesystem bỏ qua (ảo/tạm). Hằng số cố định, không nhận input.
    static let ignoredFSTypes =
        "tmpfs|devtmpfs|overlay|squashfs|ramfs|nsfs|proc|sysfs|cgroup2fs|autofs|iso9660|fuse.lxcfs"

    func expression(escapedInstance i: String) -> String {
        switch self {
        case .cpu:
            return "100 * (1 - avg(rate(node_cpu_seconds_total{instance=\"\(i)\",mode=\"idle\"}[2m])))"
        case .cores:
            return "count(count by (cpu) (node_cpu_seconds_total{instance=\"\(i)\",mode=\"idle\"}))"
        case .memory:
            return
                "{__name__=~\"node_memory_(MemTotal|MemAvailable|SwapTotal|SwapFree)_bytes\",instance=\"\(i)\"}"
        case .load:
            return "{__name__=~\"node_load(1|5|15)\",instance=\"\(i)\"}"
        case .disks:
            return
                "{__name__=~\"node_filesystem_(size|avail)_bytes\",instance=\"\(i)\",fstype!~\"\(Self.ignoredFSTypes)\"}"
        case .uptime:
            return "time() - node_boot_time_seconds{instance=\"\(i)\"}"
        }
    }
}

/// Client Prometheus: chỉ `GET /api/v1/query` (và `/api/v1/status/buildinfo` để thử kết nối).
public struct PrometheusClient: MetricsSnapshotProviding {
    let source: MetricsSource
    let credentials: (any CredentialStore)?
    let transport: any MetricsTransport

    public init(
        source: MetricsSource, credentials: (any CredentialStore)?, transport: any MetricsTransport
    ) {
        self.source = source
        self.credentials = credentials
        self.transport = transport
    }

    // MARK: - URL

    /// `<base>/api/v1/<endpoint>` + query dựng bằng URLComponents; giá trị được percent-encode nghiêm
    /// (chỉ giữ `A-Za-z0-9-._~`) nên `&`, `+`, `#` trong nhãn không thể tách tham số.
    static func url(base: String, endpoint: String, query: String?) throws -> URL {
        guard var c = URLComponents(string: base) else { throw MetricsError.invalidResponse }
        c.percentEncodedPath += "/api/v1/" + endpoint
        if let query {
            c.percentEncodedQuery = "query=" + strictEncode(query)
        }
        guard let url = c.url else { throw MetricsError.invalidResponse }
        return url
    }

    static func strictEncode(_ s: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try MetricsAuth.apply(to: &request, source: source, credentials: credentials)
        return try await transport.send(request).body
    }

    // MARK: - Truy vấn

    func instant(_ expression: String) async throws -> [PromSample] {
        let url = try Self.url(base: source.baseURL, endpoint: "query", query: expression)
        return try PromParser.parseVector(try await get(url))
    }

    public func snapshot(for host: HostProfile, at date: Date) async throws -> MonitorSnapshot {
        let raw = try InstanceTemplate.render(
            source.instanceTemplate, hostName: host.hostName, port: host.port)
        let instance = PromQL.escapeLabelValue(raw)
        let results = try await withThrowingTaskGroup(of: (PromQuery, [PromSample]).self) { group in
            for q in PromQuery.allCases {
                group.addTask { (q, try await instant(q.expression(escapedInstance: instance))) }
            }
            var out: [PromQuery: [PromSample]] = [:]
            for try await (q, samples) in group { out[q] = samples }
            return out
        }
        return try PromParser.snapshot(results: results, at: date)
    }

    /// `/api/v1/status/buildinfo`; máy chủ không có endpoint này (404) thì thử `query=up`.
    public func testConnection() async throws -> String {
        do {
            let url = try Self.url(base: source.baseURL, endpoint: "status/buildinfo", query: nil)
            let data = try await get(url)
            return "Prometheus " + (PromParser.parseBuildVersion(data) ?? "(không rõ phiên bản)")
        } catch MetricsError.httpStatus(404) {
            let samples = try await instant("up")
            return "Prometheus API hoạt động (\(samples.count) target)"
        }
    }
}

enum PromParser {
    private struct Envelope: Decodable {
        var status: String
        var errorType: String?
        var data: DataPart?
        struct DataPart: Decodable {
            var resultType: String?
            var result: [Item]?
            var version: String?
        }
        struct Item: Decodable {
            var metric: [String: String]
            var value: [JSONScalar]?
        }
    }

    /// Phần tử của `value: [ts, "string"]`.
    private enum JSONScalar: Decodable {
        case number(Double)
        case string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) {
                self = .number(d)
            } else {
                self = .string(try c.decode(String.self))
            }
        }
    }

    static func parseVector(_ data: Data) throws -> [PromSample] {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw MetricsError.invalidResponse
        }
        guard env.status == "success" else {
            throw MetricsError.apiError(sanitizeToken(env.errorType ?? "error"))
        }
        guard env.data?.resultType == "vector", let items = env.data?.result else {
            throw MetricsError.invalidResponse
        }
        var out: [PromSample] = []
        for item in items {
            guard let v = item.value, v.count == 2, case .string(let text) = v[1],
                let d = Double(text), d.isFinite
            else { continue }  // NaN/Inf/mẫu hỏng bị bỏ
            out.append(PromSample(labels: item.metric, value: d))
        }
        return out
    }

    static func parseBuildVersion(_ data: Data) -> String? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.status == "success"
        else { return nil }
        return env.data?.version.map(sanitizeToken)
    }

    /// Chỉ giữ ký tự chữ-số/`_.-`, tối đa 40 — chuỗi lấy từ server chỉ dùng để hiển thị.
    private static func sanitizeToken(_ s: String) -> String {
        String(
            s.unicodeScalars.filter {
                ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0))
            }.prefix(40).map(Character.init))
    }

    static func snapshot(results: [PromQuery: [PromSample]], at date: Date) throws -> MonitorSnapshot {
        func scalar(_ q: PromQuery) -> Double? { results[q]?.first?.value }
        func named(_ q: PromQuery) -> [String: Double] {
            var m: [String: Double] = [:]
            for s in results[q] ?? [] { if let n = s.labels["__name__"] { m[n] = s.value } }
            return m
        }
        let cpu = scalar(.cpu).map { min(100, max(0, $0)) }
        let cores = scalar(.cores).flatMap { $0 >= 1 && $0 < 100_000 ? Int($0) : nil }

        let mem = named(.memory)
        var memory: MemoryInfo?
        if let total = mem["node_memory_MemTotal_bytes"], total > 0,
            let avail = mem["node_memory_MemAvailable_bytes"]
        {
            memory = MemoryInfo(
                totalKB: kb(total), availableKB: kb(avail),
                swapTotalKB: kb(mem["node_memory_SwapTotal_bytes"] ?? 0),
                swapFreeKB: kb(mem["node_memory_SwapFree_bytes"] ?? 0))
        }

        let l = named(.load)
        var load: LoadAverage?
        if let one = l["node_load1"], let five = l["node_load5"], let fifteen = l["node_load15"] {
            load = LoadAverage(one: one, five: five, fifteen: fifteen)
        }

        let disks = parseDisks(results[.disks] ?? [])
        let uptime = scalar(.uptime).flatMap { $0 >= 0 ? $0 : nil }

        if cpu == nil, memory == nil, load == nil, disks.isEmpty, uptime == nil { throw MetricsError.noData }
        return MonitorSnapshot(
            takenAt: date, cpuPercent: cpu, load: load, cores: cores, memory: memory, disks: disks,
            uptimeSeconds: uptime)
    }

    private static func kb(_ bytes: Double) -> UInt64 {
        guard bytes.isFinite, bytes > 0 else { return 0 }
        return UInt64(min(bytes / 1024, Double(UInt64.max / 2)))
    }

    /// Ghép size + avail theo (mountpoint, device); bỏ trùng device; tối đa 4, "/" lên đầu.
    static func parseDisks(_ samples: [PromSample]) -> [DiskUsage] {
        struct Key: Hashable {
            var mount: String
            var device: String
        }
        var sizes: [Key: Double] = [:]
        var avails: [Key: Double] = [:]
        var fstypes: [Key: String] = [:]
        for s in samples {
            guard let mount = s.labels["mountpoint"], !mount.isEmpty, let name = s.labels["__name__"]
            else { continue }
            let key = Key(mount: mount, device: s.labels["device"] ?? "")
            fstypes[key] = s.labels["fstype"]
            if name == "node_filesystem_size_bytes" { sizes[key] = s.value }
            if name == "node_filesystem_avail_bytes" { avails[key] = s.value }
        }
        var list: [DiskUsage] = []
        var seenDevices: Set<String> = []
        let keys = sizes.keys.sorted { a, b in
            if (a.mount == "/") != (b.mount == "/") { return a.mount == "/" }
            return a.mount < b.mount
        }
        for key in keys {
            guard let size = sizes[key], size > 0, let avail = avails[key] else { continue }
            if !key.device.isEmpty, !seenDevices.insert(key.device).inserted { continue }
            let total = kb(size)
            let available = min(kb(avail), total)
            list.append(
                DiskUsage(
                    filesystem: key.device.isEmpty ? (fstypes[key] ?? "") : key.device, mount: key.mount,
                    totalKB: total, usedKB: total - available, availableKB: available))
            if list.count == 4 { break }
        }
        return list
    }
}
