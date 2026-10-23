import Foundation

/// Method JSON-RPC duy nhất app được gọi (ADR-028). Không có `user.login` hay method tuỳ ý:
/// client chỉ nhận enum này nên không thể gửi method khác.
public enum ZabbixMethod: String, Sendable, CaseIterable {
    case apiinfoVersion = "apiinfo.version"
    case hostGet = "host.get"
    case itemGet = "item.get"
}

/// Khoá item cố định (Zabbix agent template Linux). Disk: `vfs.fs.size[<mount>,pused|total]` tìm theo tiền tố.
enum ZabbixKeys {
    static let cpuUtil = "system.cpu.util"
    static let memUtil = "vm.memory.utilization"
    static let memTotal = "vm.memory.size[total]"
    static let load1 = "system.cpu.load[all,avg1]"
    static let load5 = "system.cpu.load[all,avg5]"
    static let load15 = "system.cpu.load[all,avg15]"
    static let uptime = "system.uptime"
    static let cpuNum = "system.cpu.num"
    static let fsPrefix = "vfs.fs.size["

    /// Chuỗi dùng với `search` + `searchByAny` (khớp chuỗi con); khớp chính xác làm ở phía client.
    static let searchTerms = [
        cpuUtil, memUtil, memTotal, "system.cpu.load[all,avg", uptime, cpuNum, fsPrefix,
    ]
}

public struct ZabbixVersion: Equatable, Sendable {
    public var major: Int
    public var text: String

    public init?(_ text: String) {
        let head = text.split(separator: ".").first.map(String.init) ?? ""
        guard let m = Int(head), m > 0, m < 1000 else { return nil }
        major = m
        self.text = String(
            text.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F }.prefix(20).map(Character.init))
    }

    /// Zabbix ≥ 7.0: token API qua header `Authorization: Bearer`; cũ hơn: trường `auth` trong body.
    public var usesBearerHeader: Bool { major >= 7 }
}

/// Client Zabbix JSON-RPC. Chỉ `apiinfo.version`, `host.get`, `item.get`. Không đăng nhập bằng password.
public actor ZabbixClient: MetricsSnapshotProviding {
    private let source: MetricsSource
    private let credentials: (any CredentialStore)?
    private let transport: any MetricsTransport
    private var version: ZabbixVersion?

    public init(
        source: MetricsSource, credentials: (any CredentialStore)?, transport: any MetricsTransport
    ) {
        self.source = source
        self.credentials = credentials
        self.transport = transport
    }

    // MARK: - Dựng request (thuần, test được)

    static func endpoint(base: String) throws -> URL {
        guard var c = URLComponents(string: base) else { throw MetricsError.invalidResponse }
        c.percentEncodedPath += "/api_jsonrpc.php"
        guard let url = c.url else { throw MetricsError.invalidResponse }
        return url
    }

    /// Thân JSON-RPC. `auth` != nil chỉ cho Zabbix < 7.0.
    static func body(method: ZabbixMethod, params: Any, auth: String?) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method.rawValue, "params": params, "id": 1]
        if let auth { object["auth"] = auth }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func hostGetParams(filterField: String, value: String) -> [String: Any] {
        ["output": ["hostid", "host", "name"], "filter": [filterField: [value]], "limit": 2]
    }

    static func hostProbeParams() -> [String: Any] {
        ["output": ["hostid"], "limit": 1]
    }

    static func itemGetParams(hostID: String) -> [String: Any] {
        [
            "output": ["itemid", "key_", "lastvalue"], "hostids": hostID, "searchByAny": true,
            "search": ["key_": ZabbixKeys.searchTerms], "limit": 500,
        ]
    }

    /// Gọi một method trong whitelist. `apiinfo.version` KHÔNG kèm xác thực (Zabbix không cho phép).
    private func call(_ method: ZabbixMethod, params: Any) async throws -> Any {
        let token = try await tokenIfNeeded(for: method)
        var request = URLRequest(url: try Self.endpoint(base: source.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var bodyAuth: String?
        if let token {
            if version?.usesBearerHeader ?? true {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            } else {
                bodyAuth = token
            }
        }
        request.httpBody = try Self.body(method: method, params: params, auth: bodyAuth)
        let response = try await transport.send(request)
        return try ZabbixParser.result(response.body)
    }

    private func tokenIfNeeded(for method: ZabbixMethod) async throws -> String? {
        guard method != .apiinfoVersion, source.authKind == .bearer else { return nil }
        return try MetricsAuth.secret(for: source, credentials: credentials)
    }

    private func detectVersion() async throws -> ZabbixVersion {
        if let version { return version }
        let raw = try await call(.apiinfoVersion, params: [String: Any]())
        guard let text = raw as? String, let v = ZabbixVersion(text) else {
            throw MetricsError.unsupportedVersion
        }
        version = v
        return v
    }

    // MARK: - API

    /// `apiinfo.version` không cần token nên không chứng minh token đúng: có token thì gọi thêm
    /// `host.get` (limit 1) để xác thực.
    public func testConnection() async throws -> String {
        let text = try await detectVersion().text
        if source.authKind == .bearer {
            _ = try await call(.hostGet, params: Self.hostProbeParams())
        }
        return "Zabbix " + text
    }

    public func snapshot(for host: HostProfile, at date: Date) async throws -> MonitorSnapshot {
        _ = try await detectVersion()
        let name = try InstanceTemplate.render(source.instanceTemplate, hostName: host.hostName, port: host.port)
        var hostID = try await findHost(field: "host", value: name)
        if hostID == nil { hostID = try await findHost(field: "name", value: name) }
        guard let hostID else { throw MetricsError.noData }
        let raw = try await call(.itemGet, params: Self.itemGetParams(hostID: hostID))
        return try ZabbixParser.snapshot(items: raw, at: date)
    }

    private func findHost(field: String, value: String) async throws -> String? {
        let raw = try await call(.hostGet, params: Self.hostGetParams(filterField: field, value: value))
        return ZabbixParser.firstHostID(raw)
    }
}

enum ZabbixParser {
    /// Lấy `result`; có `error` -> chỉ báo mã lỗi (không chép message/data của server).
    static func result(_ data: Data) throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetricsError.invalidResponse
        }
        if let err = obj["error"] as? [String: Any] {
            // Lỗi xác thực của Zabbix đi kèm HTTP 200: coi như bị từ chối (không chép nội dung lỗi).
            let text = "\(err["message"] ?? "") \(err["data"] ?? "")".lowercased()
            if ["not authorized", "not authorised", "session terminated", "re-login", "no permissions"]
                .contains(where: text.contains)
            {
                throw MetricsError.unauthorized(status: 200)
            }
            let code = (err["code"] as? Int).map(String.init) ?? "?"
            throw MetricsError.apiError(code)
        }
        guard let result = obj["result"] else { throw MetricsError.invalidResponse }
        return result
    }

    static func firstHostID(_ raw: Any) -> String? {
        guard let list = raw as? [[String: Any]], let id = list.first?["hostid"] as? String,
            !id.isEmpty, id.allSatisfy(\.isNumber)
        else { return nil }
        return id
    }

    static func snapshot(items raw: Any, at date: Date) throws -> MonitorSnapshot {
        guard let list = raw as? [[String: Any]] else { throw MetricsError.invalidResponse }
        var values: [String: Double] = [:]
        for item in list {
            guard let key = item["key_"] as? String, let text = item["lastvalue"] as? String,
                let v = Double(text), v.isFinite
            else { continue }
            values[key] = v
        }
        let cpu = values[ZabbixKeys.cpuUtil].map { min(100, max(0, $0)) }
        let cores = values[ZabbixKeys.cpuNum].flatMap { $0 >= 1 && $0 < 100_000 ? Int($0) : nil }

        var memory: MemoryInfo?
        var memPercent: Double?
        if let pct = values[ZabbixKeys.memUtil].map({ min(100, max(0, $0)) }) {
            if let total = values[ZabbixKeys.memTotal], total > 0 {
                let totalKB = UInt64(min(total / 1024, Double(UInt64.max / 2)))
                let usedKB = min(totalKB, UInt64((Double(totalKB) * pct / 100).rounded()))
                memory = MemoryInfo(
                    totalKB: totalKB, availableKB: totalKB - usedKB, swapTotalKB: 0, swapFreeKB: 0)
            } else {
                memPercent = pct
            }
        }

        var load: LoadAverage?
        if let a = values[ZabbixKeys.load1], let b = values[ZabbixKeys.load5], let c = values[ZabbixKeys.load15] {
            load = LoadAverage(one: a, five: b, fifteen: c)
        }
        let uptime = values[ZabbixKeys.uptime].flatMap { $0 >= 0 ? $0 : nil }
        let disks = parseDisks(values)

        if cpu == nil, memory == nil, memPercent == nil, load == nil, disks.isEmpty, uptime == nil {
            throw MetricsError.noData
        }
        return MonitorSnapshot(
            takenAt: date, cpuPercent: cpu, load: load, cores: cores, memory: memory, disks: disks,
            uptimeSeconds: uptime, reportedMemoryPercent: memPercent)
    }

    /// `vfs.fs.size[/,pused]` + `vfs.fs.size[/,total]` -> DiskUsage (cần cả hai). Tối đa 4, "/" lên đầu.
    static func parseDisks(_ values: [String: Double]) -> [DiskUsage] {
        var mounts: Set<String> = []
        for key in values.keys where key.hasPrefix(ZabbixKeys.fsPrefix) && key.hasSuffix(",pused]") {
            let inner = key.dropFirst(ZabbixKeys.fsPrefix.count).dropLast(",pused]".count)
            var mount = String(inner)
            if mount.count >= 2, mount.hasPrefix("\""), mount.hasSuffix("\"") {
                mount = String(mount.dropFirst().dropLast())
            }
            if !mount.isEmpty { mounts.insert(mount) }
        }
        let ordered = mounts.sorted { a, b in
            if (a == "/") != (b == "/") { return a == "/" }
            return a < b
        }
        var out: [DiskUsage] = []
        for mount in ordered {
            guard let pused = values["\(ZabbixKeys.fsPrefix)\(mount),pused]"],
                let total = values["\(ZabbixKeys.fsPrefix)\(mount),total]"], total > 0
            else { continue }
            let totalKB = UInt64(min(total / 1024, Double(UInt64.max / 2)))
            let usedKB = UInt64((Double(totalKB) * min(100, max(0, pused)) / 100).rounded())
            out.append(
                DiskUsage(filesystem: "", mount: mount, totalKB: totalKB, usedKB: usedKB, availableKB: totalKB - usedKB)
            )
            if out.count == 4 { break }
        }
        return out
    }
}
