import Foundation
import Testing

@testable import SSHDeskCore

private let secretToken = "tok-SECRET-abc123"

private func source(
    host: String, kind: MetricsSourceKind = .prometheus, auth: MetricsAuthKind = .none, user: String? = nil
) -> MetricsSource {
    MetricsSource(
        name: "S", kind: kind, baseURL: "https://\(host)/base", authKind: auth, basicUser: user)
}

private func store(for s: MetricsSource, secret: String = secretToken) -> InMemoryCredentialStore {
    let st = InMemoryCredentialStore()
    if let ref = s.credentialRef { try? st.save(ref: ref, password: secret) }
    return st
}

private func linuxHost(_ name: String = "web1") -> HostProfile {
    HostProfile(displayName: name, hostName: name, user: "u")
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)

// Trả vector theo biểu thức truy vấn (chỉ dùng phần tên metric để phân loại).
private func nodeExporterReply(_ r: SeenRequest) -> StubReply {
    let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
    func vec(_ items: [([String: String], String)]) -> StubReply {
        .response(status: 200, headers: ["Content-Type": "application/json"], body: promVector(items))
    }
    if q.hasPrefix("100 * (1 - avg(") { return vec([([:], "37.5")]) }
    if q.hasPrefix("count(count by (cpu)") { return vec([([:], "8")]) }
    if q.contains("node_memory_") {
        return vec([
            (["__name__": "node_memory_MemTotal_bytes"], "8589934592"),
            (["__name__": "node_memory_MemAvailable_bytes"], "2147483648"),
            (["__name__": "node_memory_SwapTotal_bytes"], "2147483648"),
            (["__name__": "node_memory_SwapFree_bytes"], "1073741824"),
        ])
    }
    if q.contains("node_load") {
        return vec([
            (["__name__": "node_load1"], "0.5"), (["__name__": "node_load5"], "1.5"),
            (["__name__": "node_load15"], "NaN"),
        ])
    }
    if q.contains("node_filesystem_") {
        func fs(_ name: String, _ mount: String, _ dev: String, _ v: String) -> ([String: String], String) {
            (["__name__": name, "mountpoint": mount, "device": dev, "fstype": "ext4"], v)
        }
        return vec([
            fs("node_filesystem_size_bytes", "/", "/dev/sda1", "107374182400"),
            fs("node_filesystem_avail_bytes", "/", "/dev/sda1", "53687091200"),
            fs("node_filesystem_size_bytes", "/data", "/dev/sdb1", "1073741824"),
            fs("node_filesystem_avail_bytes", "/data", "/dev/sdb1", "268435456"),
            // Cùng device bind mount -> bỏ trùng.
            fs("node_filesystem_size_bytes", "/mnt/bind", "/dev/sdb1", "1073741824"),
            fs("node_filesystem_avail_bytes", "/mnt/bind", "/dev/sdb1", "268435456"),
        ])
    }
    if q.hasPrefix("time() - node_boot_time_seconds") { return vec([([:], "93784")]) }
    return .response(status: 400, body: Data())
}

// MARK: - Prometheus

@Suite struct PrometheusClientTests {
    @Test func mapsNodeExporterToSnapshot() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let s = source(host: host)
        let client = PrometheusClient(source: s, credentials: nil, transport: stubTransport())
        let snap = try await client.snapshot(for: linuxHost(), at: now)

        #expect(snap.cpuPercent == 37.5)
        #expect(snap.cores == 8)
        #expect(snap.memory?.totalKB == 8 * 1024 * 1024)
        #expect(snap.memory?.usedKB == 6 * 1024 * 1024)
        #expect(snap.memoryPercent == 75)
        #expect(snap.memory?.swapUsedKB == 1024 * 1024)
        #expect(snap.load == nil)  // load15 = NaN bị bỏ -> thiếu mẫu
        #expect(snap.uptimeSeconds == 93784)
        #expect(snap.disks.map(\.mount) == ["/", "/data"])
        #expect(snap.disks.first?.percent == 50)
        #expect(snap.takenAt == now)

        // Chỉ GET /api/v1/query, instance mặc định {{hostName}}:9100.
        let seen = MetricsStubProtocol.seen(host: host)
        #expect(seen.count == PromQuery.allCases.count)
        for r in seen {
            #expect(r.method == "GET")
            #expect(r.url.path == "/base/api/v1/query")
            let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            #expect(q.contains(#"instance="web1:9100""#))
        }
    }

    @Test func injectionInHostNameIsEscapedOnTheWire() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let client = PrometheusClient(source: source(host: host), credentials: nil, transport: stubTransport())
        _ = try? await client.snapshot(for: linuxHost(#""} or vector(1) #"#), at: now)
        for r in MetricsStubProtocol.seen(host: host) {
            let q = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            #expect(q.contains(#"instance="\"} or vector(1) #:9100""#))
            #expect(!q.contains(#"instance=""}"#))
        }
    }

    @Test func controlCharsInHostNameSendNothing() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let client = PrometheusClient(source: source(host: host), credentials: nil, transport: stubTransport())
        await #expect(throws: MetricsSourceError.self) {
            try await client.snapshot(for: linuxHost("web\n1"), at: now)
        }
        #expect(MetricsStubProtocol.seen(host: host).isEmpty)
    }

    @Test func bearerAndBasicHeadersAreSetAndTokenIsNotInURL() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let bearer = source(host: host, auth: .bearer)
        _ = try await PrometheusClient(source: bearer, credentials: store(for: bearer), transport: stubTransport())
            .snapshot(for: linuxHost(), at: now)
        for r in MetricsStubProtocol.seen(host: host) {
            #expect(r.headers["Authorization"] == "Bearer \(secretToken)")
            #expect(!r.url.absoluteString.contains(secretToken))
            #expect(!r.url.absoluteString.contains("Bearer"))
        }

        let host2 = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host2, nodeExporterReply)
        let basic = source(host: host2, auth: .basic, user: "bob")
        _ = try await PrometheusClient(
            source: basic, credentials: store(for: basic, secret: "pw"), transport: stubTransport()
        )
        .snapshot(for: linuxHost(), at: now)
        let expected = "Basic " + Data("bob:pw".utf8).base64EncodedString()
        #expect(MetricsStubProtocol.seen(host: host2).allSatisfy { $0.headers["Authorization"] == expected })
    }

    @Test func missingSecretFailsBeforeAnyRequest() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let s = source(host: host, auth: .bearer)
        let client = PrometheusClient(source: s, credentials: InMemoryCredentialStore(), transport: stubTransport())
        await #expect(throws: MetricsError.secretMissing) { try await client.snapshot(for: linuxHost(), at: now) }
        #expect(MetricsStubProtocol.seen(host: host).isEmpty)
    }

    @Test func errorsNeverContainTokenHeaderOrBody() async throws {
        for status in [401, 403, 500, 502] {
            let host = MetricsStubProtocol.newHost()
            MetricsStubProtocol.register(host: host) { _ in
                .response(status: status, body: jsonData(#"{"error":"echo \#(secretToken) Authorization: Bearer"}"#))
            }
            let s = source(host: host, auth: .bearer)
            let client = PrometheusClient(source: s, credentials: store(for: s), transport: stubTransport())
            do {
                _ = try await client.snapshot(for: linuxHost(), at: now)
                Issue.record("phải lỗi")
            } catch {
                let text =
                    "\(error) \((error as? LocalizedError)?.errorDescription ?? "") \(MetricsMonitorCoordinator.message(error))"
                #expect(!text.contains(secretToken))
                #expect(!text.contains("Authorization"))
                #expect(!text.contains("Bearer"))
                if status == 401 || status == 403 { #expect(error as? MetricsError == .unauthorized(status: status)) }
            }
        }
    }

    @Test func apiErrorShowsOnlyTheErrorType() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host) { _ in
            .response(
                status: 200, body: jsonData(#"{"status":"error","errorType":"bad_data","error":"SECRET-DETAIL"}"#))
        }
        let client = PrometheusClient(source: source(host: host), credentials: nil, transport: stubTransport())
        do {
            _ = try await client.snapshot(for: linuxHost(), at: now)
            Issue.record("phải lỗi")
        } catch {
            #expect(error as? MetricsError == .apiError("bad_data"))
            #expect(!MetricsMonitorCoordinator.message(error).contains("SECRET-DETAIL"))
        }
    }

    @Test func emptyVectorsMeanNoData() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host) { _ in .response(status: 200, body: promVector([])) }
        let client = PrometheusClient(source: source(host: host), credentials: nil, transport: stubTransport())
        await #expect(throws: MetricsError.noData) { try await client.snapshot(for: linuxHost(), at: now) }
    }

    @Test func testConnectionReadsBuildInfoThenFallsBackToUp() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host) { r in
            r.url.path.hasSuffix("/status/buildinfo")
                ? .response(status: 200, body: jsonData(#"{"status":"success","data":{"version":"2.53.1"}}"#))
                : .response(status: 404)
        }
        let c = PrometheusClient(source: source(host: host), credentials: nil, transport: stubTransport())
        #expect(try await c.testConnection() == "Prometheus 2.53.1")

        let host2 = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host2) { r in
            r.url.path.hasSuffix("/status/buildinfo")
                ? .response(status: 404) : .response(status: 200, body: promVector([([:], "1")]))
        }
        let c2 = PrometheusClient(source: source(host: host2), credentials: nil, transport: stubTransport())
        #expect(try await c2.testConnection().contains("1 target"))
    }

    @Test func parserSkipsBadSamples() throws {
        let data = jsonData(
            #"{"status":"success","data":{"resultType":"vector","result":[{"metric":{"a":"1"},"value":[1,"+Inf"]},{"metric":{"a":"2"},"value":[1,"2.5"]},{"metric":{},"value":[1]}]}}"#
        )
        let samples = try PromParser.parseVector(data)
        #expect(samples == [PromSample(labels: ["a": "2"], value: 2.5)])
        #expect(throws: MetricsError.invalidResponse) {
            try PromParser.parseVector(jsonData(#"{"status":"success","data":{"resultType":"matrix","result":[]}}"#))
        }
        #expect(throws: MetricsError.invalidResponse) { try PromParser.parseVector(jsonData("not json")) }
    }
}

// MARK: - Zabbix

@Suite struct ZabbixClientTests {
    private static let itemsJSON =
        #"""
        {"jsonrpc":"2.0","id":1,"result":[
          {"itemid":"1","key_":"system.cpu.util","lastvalue":"12.5"},
          {"itemid":"2","key_":"vm.memory.utilization","lastvalue":"60"},
          {"itemid":"3","key_":"vm.memory.size[total]","lastvalue":"4294967296"},
          {"itemid":"4","key_":"system.cpu.load[all,avg1]","lastvalue":"0.1"},
          {"itemid":"5","key_":"system.cpu.load[all,avg5]","lastvalue":"0.2"},
          {"itemid":"6","key_":"system.cpu.load[all,avg15]","lastvalue":"0.3"},
          {"itemid":"7","key_":"system.uptime","lastvalue":"3600"},
          {"itemid":"8","key_":"system.cpu.num","lastvalue":"4"},
          {"itemid":"9","key_":"vfs.fs.size[/,pused]","lastvalue":"25"},
          {"itemid":"10","key_":"vfs.fs.size[/,total]","lastvalue":"107374182400"},
          {"itemid":"11","key_":"vfs.fs.size[/orphan,pused]","lastvalue":"90"}
        ]}
        """#

    private func handler(version: String, hostFound: Bool = true) -> @Sendable (SeenRequest) -> StubReply {
        { r in
            let body = jsonBody(r)
            switch body["method"] as? String {
            case "apiinfo.version":
                return .response(status: 200, body: jsonData(#"{"jsonrpc":"2.0","result":"\#(version)","id":1}"#))
            case "host.get":
                return .response(
                    status: 200,
                    body: jsonData(
                        hostFound
                            ? #"{"jsonrpc":"2.0","result":[{"hostid":"10084","host":"web1"}],"id":1}"#
                            : #"{"jsonrpc":"2.0","result":[],"id":1}"#))
            case "item.get": return .response(status: 200, body: jsonData(Self.itemsJSON))
            default: return .response(status: 400)
            }
        }
    }

    @Test func whitelistHasOnlyThreeReadMethods() {
        #expect(Set(ZabbixMethod.allCases.map(\.rawValue)) == ["apiinfo.version", "host.get", "item.get"])
        #expect(ZabbixMethod(rawValue: "user.login") == nil)
        #expect(ZabbixMethod(rawValue: "host.delete") == nil)
    }

    @Test func v7UsesBearerHeaderAndNoAuthField() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, handler(version: "7.0.4"))
        let s = source(host: host, kind: .zabbix, auth: .bearer)
        let client = ZabbixClient(source: s, credentials: store(for: s), transport: stubTransport())
        let snap = try await client.snapshot(for: linuxHost(), at: now)

        let seen = MetricsStubProtocol.seen(host: host)
        #expect(seen.map { jsonBody($0)["method"] as? String } == ["apiinfo.version", "host.get", "item.get"])
        for r in seen {
            #expect(r.method == "POST")
            #expect(r.url.path == "/base/api_jsonrpc.php")
            #expect(jsonBody(r)["auth"] == nil)
            #expect(!String(decoding: r.body, as: UTF8.self).contains(secretToken))
            #expect(!r.url.absoluteString.contains(secretToken))
        }
        // apiinfo.version không kèm xác thực; các call sau có Bearer.
        #expect(seen[0].headers["Authorization"] == nil)
        #expect(seen[1].headers["Authorization"] == "Bearer \(secretToken)")
        #expect(seen[2].headers["Authorization"] == "Bearer \(secretToken)")

        #expect(snap.cpuPercent == 12.5)
        #expect(snap.cores == 4)
        #expect(snap.memory?.totalKB == 4 * 1024 * 1024)
        #expect(abs((snap.memoryPercent ?? 0) - 60) < 0.001)
        #expect(snap.load == LoadAverage(one: 0.1, five: 0.2, fifteen: 0.3))
        #expect(snap.uptimeSeconds == 3600)
        #expect(snap.disks.count == 1 && snap.disks[0].mount == "/" && snap.disks[0].percent == 25)
    }

    @Test func v6UsesAuthFieldAndNoAuthorizationHeader() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, handler(version: "6.0.30"))
        let s = source(host: host, kind: .zabbix, auth: .bearer)
        let client = ZabbixClient(source: s, credentials: store(for: s), transport: stubTransport())
        _ = try await client.snapshot(for: linuxHost(), at: now)
        let seen = MetricsStubProtocol.seen(host: host)
        #expect(seen.allSatisfy { $0.headers["Authorization"] == nil })
        #expect(jsonBody(seen[0])["auth"] == nil)  // apiinfo.version phải không có auth
        #expect(jsonBody(seen[1])["auth"] as? String == secretToken)
        #expect(jsonBody(seen[2])["auth"] as? String == secretToken)
        #expect(seen.allSatisfy { !$0.url.absoluteString.contains(secretToken) })
    }

    @Test func versionRuleAndBodyShape() throws {
        #expect(ZabbixVersion("7.0.4")?.usesBearerHeader == true)
        #expect(ZabbixVersion("7.2")?.usesBearerHeader == true)
        #expect(ZabbixVersion("6.4.18")?.usesBearerHeader == false)
        #expect(ZabbixVersion("garbage") == nil)
        let body = try ZabbixClient.body(
            method: .hostGet, params: ZabbixClient.hostGetParams(filterField: "host", value: "x\"y"), auth: nil)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["method"] as? String == "host.get")
        #expect(obj?["jsonrpc"] as? String == "2.0")
        #expect(obj?["auth"] == nil)
        let filter = (obj?["params"] as? [String: Any])?["filter"] as? [String: Any]
        #expect(filter?["host"] as? [String] == ["x\"y"])
    }

    @Test func hostNotFoundAndApiErrors() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, handler(version: "7.0.0", hostFound: false))
        let c = ZabbixClient(source: source(host: host, kind: .zabbix), credentials: nil, transport: stubTransport())
        await #expect(throws: MetricsError.noData) { try await c.snapshot(for: linuxHost(), at: now) }

        let host2 = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host2) { r in
            (jsonBody(r)["method"] as? String) == "apiinfo.version"
                ? .response(status: 200, body: jsonData(#"{"jsonrpc":"2.0","result":"7.0.0","id":1}"#))
                : .response(
                    status: 200,
                    body: jsonData(
                        #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params.","data":"TOP-SECRET-DATA"},"id":1}"#
                    ))
        }
        let c2 = ZabbixClient(source: source(host: host2, kind: .zabbix), credentials: nil, transport: stubTransport())
        do {
            _ = try await c2.snapshot(for: linuxHost(), at: now)
            Issue.record("phải lỗi")
        } catch {
            #expect(error as? MetricsError == .apiError("-32602"))
            #expect(!MetricsMonitorCoordinator.message(error).contains("TOP-SECRET-DATA"))
        }
    }

    @Test func testConnectionVerifiesTokenWithHostGetWhenBearer() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, handler(version: "7.0.4"))
        let s = source(host: host, kind: .zabbix, auth: .bearer)
        let c = ZabbixClient(source: s, credentials: store(for: s), transport: stubTransport())
        #expect(try await c.testConnection() == "Zabbix 7.0.4")
        let seen = MetricsStubProtocol.seen(host: host)
        #expect(seen.map { jsonBody($0)["method"] as? String } == ["apiinfo.version", "host.get"])
        #expect(seen[0].headers["Authorization"] == nil)
        #expect(seen[1].headers["Authorization"] == "Bearer \(secretToken)")
        #expect((jsonBody(seen[1])["params"] as? [String: Any])?["limit"] as? Int == 1)

        // Không token: chỉ apiinfo.version.
        let host2 = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host2, handler(version: "7.0.4"))
        let c2 = ZabbixClient(source: source(host: host2, kind: .zabbix), credentials: nil, transport: stubTransport())
        _ = try await c2.testConnection()
        #expect(MetricsStubProtocol.seen(host: host2).count == 1)
    }

    @Test func badTokenInHttp200ErrorCountsAsUnauthorized() async throws {
        for text in ["Not authorized.", "Session terminated, re-login, please.", "Not authorised"] {
            let body = jsonData(
                #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params.","data":"\#(text)"},"id":1}"#)
            #expect(throws: MetricsError.unauthorized(status: 200)) { try ZabbixParser.result(body) }
        }
        let other = jsonData(
            #"{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params.","data":"Incorrect value"},"id":1}"#)
        #expect(throws: MetricsError.apiError("-32602")) { try ZabbixParser.result(other) }
        #expect(!(MetricsError.unauthorized(status: 200).errorDescription ?? "").contains("HTTP"))
    }

    @Test func zabbixCannotUseBasicAuth() {
        let s = MetricsSource(
            name: "z", kind: .zabbix, baseURL: "https://z.example.com", authKind: .basic, basicUser: "u")
        #expect(throws: MetricsSourceError.zabbixBasicUnsupported) { try s.validated() }
    }
}

// MARK: - Transport: redirect, kích thước, TLS

@Suite struct MetricsTransportTests {
    @Test func redirectToAnotherHostIsBlockedAndNothingIsSentThere() async throws {
        let origin = MetricsStubProtocol.newHost()
        let evil = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: evil) { _ in .response(status: 200, body: promVector([([:], "1")])) }
        MetricsStubProtocol.register(host: origin) { _ in .redirect(status: 302, to: URL(string: "https://\(evil)/x")!)
        }
        var req = URLRequest(url: URL(string: "https://\(origin)/api/v1/query?query=up")!)
        req.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")
        await #expect(throws: MetricsError.redirectBlocked) { try await stubTransport().send(req) }
        #expect(MetricsStubProtocol.seen(host: evil).isEmpty)
    }

    @Test func httpsToHttpDowngradeIsBlocked() async throws {
        let origin = MetricsStubProtocol.newHost()
        let plain = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: plain) { _ in .response(status: 200) }
        MetricsStubProtocol.register(host: origin) { _ in .redirect(status: 301, to: URL(string: "http://\(plain)/")!) }
        await #expect(throws: MetricsError.redirectBlocked) {
            try await stubTransport().send(URLRequest(url: URL(string: "https://\(origin)/")!))
        }
        #expect(MetricsStubProtocol.seen(host: plain).isEmpty)
    }

    @Test func sameOriginRedirectIsAlsoNotFollowed() async throws {
        let origin = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: origin) { r in
            r.url.path == "/a"
                ? .redirect(status: 307, to: URL(string: "https://\(origin)/b")!) : .response(status: 200)
        }
        await #expect(throws: MetricsError.redirectBlocked) {
            try await stubTransport().send(URLRequest(url: URL(string: "https://\(origin)/a")!))
        }
        #expect(MetricsStubProtocol.seen(host: origin).map(\.url.path) == ["/a"])
    }

    @Test func declaredContentLengthOver5MBIsDropped() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host) { _ in
            .response(status: 200, headers: ["Content-Length": String(6 * 1024 * 1024)], body: Data("x".utf8))
        }
        await #expect(throws: MetricsError.tooLarge) {
            try await stubTransport().send(URLRequest(url: URL(string: "https://\(host)/")!))
        }
    }

    @Test func actualBytesOver5MBAreDroppedEvenWithoutContentLength() async throws {
        let host = MetricsStubProtocol.newHost()
        let big = Data(repeating: 0x41, count: URLSessionMetricsTransport.maxBytes + 1)
        MetricsStubProtocol.register(host: host) { _ in .response(status: 200, body: big) }
        await #expect(throws: MetricsError.tooLarge) {
            try await stubTransport().send(URLRequest(url: URL(string: "https://\(host)/")!))
        }
        // Đúng giới hạn thì qua.
        let host2 = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host2) { _ in
            .response(status: 200, body: Data(repeating: 0x41, count: 1000))
        }
        let r = try await stubTransport(maxBytes: 1000).send(URLRequest(url: URL(string: "https://\(host2)/")!))
        #expect(r.body.count == 1000)
    }

    @Test func networkErrorsMapToSafeMessages() async throws {
        let cases: [(URLError.Code, MetricsError)] = [
            (.timedOut, .timeout), (.serverCertificateUntrusted, .tlsUntrusted),
            (.appTransportSecurityRequiresSecureConnection, .atsBlocked), (.cannotConnectToHost, .cannotConnect),
        ]
        for (code, expected) in cases {
            let host = MetricsStubProtocol.newHost()
            MetricsStubProtocol.register(host: host) { _ in .failure(code) }
            await #expect(throws: expected) {
                try await stubTransport().send(URLRequest(url: URL(string: "https://\(host)/")!))
            }
        }
        #expect(MetricsError.atsBlocked.errorDescription?.contains("IP") == true)
    }

    @Test func allErrorTextsAreFreeOfSecretsAndHeaders() {
        let all: [MetricsError] = [
            .timeout, .tooLarge, .redirectBlocked, .unauthorized(status: 401), .httpStatus(500), .atsBlocked,
            .tlsUntrusted, .cannotConnect, .network(code: -1), .invalidResponse, .apiError("x"), .noData,
            .secretMissing, .unsupportedVersion,
        ]
        for e in all {
            let t = (e.errorDescription ?? "") + "\(e)"
            #expect(!t.contains("Authorization") && !t.contains(secretToken))
        }
    }
}

// MARK: - Coordinator

private final class FakeMetricsProvider: MetricsSnapshotProviding, @unchecked Sendable {
    private let state = Locked<(calls: Int, failure: MetricsError?)>((0, nil))
    var calls: Int { state.withLock { $0.calls } }
    func fail(with e: MetricsError?) { state.withLock { $0.failure = e } }
    func snapshot(for host: HostProfile, at date: Date) async throws -> MonitorSnapshot {
        let failure = state.withLock { s -> MetricsError? in
            s.calls += 1
            return s.failure
        }
        if let failure { throw failure }
        return MonitorSnapshot(
            takenAt: date, cpuPercent: 42, load: nil, cores: nil, memory: nil, disks: [], uptimeSeconds: 1)
    }
    func testConnection() async throws -> String { "ok" }
}

private func waitFor(_ cond: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite struct MetricsCoordinatorTests {
    @Test func publishesSnapshotsAndHistoryWithoutSSH() async throws {
        let provider = FakeMetricsProvider()
        let h = linuxHost()
        let coord = MetricsMonitorCoordinator(provider: provider)
        await coord.start(hosts: [h], interval: 3600)
        #expect(await waitFor { await coord.states[h.id]?.status == .ok })
        let st = await coord.states[h.id]
        #expect(st?.snapshot?.cpuPercent == 42)
        #expect(st?.cpuHistory.values == [42])
        await coord.stop()
        #expect(await coord.isRunning == false)
    }

    @Test func unauthorizedStopsRetryingUntilRetry() async throws {
        let provider = FakeMetricsProvider()
        provider.fail(with: .unauthorized(status: 401))
        let h = linuxHost()
        let coord = MetricsMonitorCoordinator(provider: provider)
        await coord.start(hosts: [h], interval: 3600)
        #expect(await waitFor { await coord.states[h.id]?.status != .connecting && provider.calls >= 1 })
        _ = await waitFor { await coord.refreshRoundIfIdle() }
        let before = provider.calls
        _ = await coord.refreshRoundIfIdle()
        #expect(provider.calls == before)  // host bị khoá thử lại
        provider.fail(with: nil)
        await coord.retry(hostID: h.id)
        #expect(await waitFor { await coord.states[h.id]?.status == .ok })
        await coord.stop()
    }

    @Test func intervalChoices() {
        #expect(MetricsMonitorCoordinator.intervalChoices == [15, 30, 60])
        #expect(MetricsMonitorCoordinator.normalizedInterval(30) == 30)
        #expect(MetricsMonitorCoordinator.normalizedInterval(7) == 30)
    }
}

@Suite struct MetricsSecretScopeTests {
    @Test func secretNotSentWhenStoredValueHasControlChars() async throws {
        let host = MetricsStubProtocol.newHost()
        MetricsStubProtocol.register(host: host, nodeExporterReply)
        let s = source(host: host, auth: .bearer)
        let bad = store(for: s, secret: "abc\r\nX-Evil: 1")
        let client = PrometheusClient(source: s, credentials: bad, transport: stubTransport())
        await #expect(throws: MetricsError.secretMissing) { try await client.snapshot(for: linuxHost(), at: now) }
        #expect(MetricsStubProtocol.seen(host: host).isEmpty)
    }
}
