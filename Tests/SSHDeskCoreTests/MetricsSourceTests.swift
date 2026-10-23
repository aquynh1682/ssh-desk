import Foundation
import Testing

@testable import SSHDeskCore

private func prom(
    url: String = "https://prom.example.com", auth: MetricsAuthKind = .none, user: String? = nil,
    template: String? = nil, allowHTTP: Bool = false, kind: MetricsSourceKind = .prometheus
) -> MetricsSource {
    MetricsSource(
        name: "Prod", kind: kind, baseURL: url, authKind: auth, basicUser: user,
        instanceTemplate: template, allowInsecureHTTP: allowHTTP)
}

// MARK: - URL

@Suite struct MetricsURLValidationTests {
    @Test func acceptsHttpsAndNormalizes() throws {
        let s = try prom(url: " HTTPS://Prom.Example.com:9090/prometheus/ ").validated()
        #expect(s.baseURL == "https://Prom.Example.com:9090/prometheus")
        #expect(try prom(url: "http://10.0.0.5:9090").validated().baseURL == "http://10.0.0.5:9090")
    }

    @Test(arguments: [
        "", "ftp://x.example.com", "file:///etc/passwd", "javascript:alert(1)", "prom.example.com",
        "https://user:pw@prom.example.com", "https://user@prom.example.com", "https://prom.example.com/?q=1",
        "https://prom.example.com?x", "https://prom.example.com/#frag", "https://prom.example.com#",
        "https:///path", "https://", "https://prom.example.com/a b", "https://prom.example.com/\u{0}",
        "https://prom.example.com/a\nb", "https://prom.example.com/\u{7F}", "https://prom.example.com/a\u{85}b",
    ])
    func rejectsBadURLs(_ url: String) {
        #expect(throws: MetricsSourceError.self) { try prom(url: url).validated() }
    }

    @Test func rejectsTooLongURL() {
        let long = "https://prom.example.com/" + String(repeating: "a", count: 2100)
        #expect(throws: MetricsSourceError.self) { try prom(url: long).validated() }
        let ok = "https://prom.example.com/" + String(repeating: "a", count: 100)
        #expect((try? prom(url: ok).validated()) != nil)
    }

    @Test func rejectsBadNameAndBasicUser() {
        var s = prom()
        s.name = "  "
        #expect(throws: MetricsSourceError.emptyName) { try s.validated() }
        s.name = "a\nb"
        #expect(throws: MetricsSourceError.nameInvalid) { try s.validated() }
        #expect(throws: MetricsSourceError.basicUserInvalid) { try prom(auth: .basic, user: "").validated() }
        #expect(throws: MetricsSourceError.basicUserInvalid) { try prom(auth: .basic, user: "a:b").validated() }
        #expect(throws: MetricsSourceError.zabbixBasicUnsupported) {
            try prom(auth: .basic, user: "u", kind: .zabbix).validated()
        }
    }
}

// MARK: - http

@Suite struct MetricsInsecureHTTPTests {
    @Test func httpWithTokenToRemoteNeedsAcknowledgement() throws {
        #expect(throws: MetricsSourceError.insecureHTTPNotAcknowledged) {
            try prom(url: "http://10.1.2.3:9090", auth: .bearer).validated()
        }
        #expect(throws: MetricsSourceError.insecureHTTPNotAcknowledged) {
            try prom(url: "http://prom.corp.example.com", auth: .basic, user: "u").validated()
        }
        let ok = try prom(url: "http://10.1.2.3:9090", auth: .bearer, allowHTTP: true).validated()
        #expect(ok.allowInsecureHTTP && ok.sendsSecretOverInsecureHTTP)
    }

    @Test func loopbackHttpDoesNotNeedAcknowledgement() throws {
        for url in ["http://localhost:9090", "http://127.0.0.1:9090", "http://[::1]:9090", "http://127.5.5.5"] {
            let s = try prom(url: url, auth: .bearer).validated()
            #expect(!s.sendsSecretOverInsecureHTTP, "\(url)")
        }
    }

    @Test func httpWithoutSecretAndHttpsNeedNothing() throws {
        _ = try prom(url: "http://10.1.2.3:9090", auth: .none).validated()
        _ = try prom(url: "https://10.1.2.3", auth: .bearer).validated()
        #expect(!prom(url: "http://10.1.2.3", auth: .none).sendsSecretOverInsecureHTTP)
    }

    @Test func loopbackRangesAndLookalikes() {
        #expect(MetricsURLRules.isLoopback(host: "127.0.0.2"))
        #expect(MetricsURLRules.isLoopback(host: "[::1]"))
        #expect(!MetricsURLRules.isLoopback(host: "127.0.0.1.nip.io"))
        #expect(throws: MetricsSourceError.insecureHTTPNotAcknowledged) {
            try prom(url: "http://127.0.0.1.nip.io:9090", auth: .bearer).validated()
        }
        #expect((try? prom(url: "http://127.0.0.2:9090", auth: .bearer).validated()) != nil)
        #expect((try? prom(url: "http://[::1]:9090", auth: .bearer).validated()) != nil)
    }

    @Test func loopbackRules() {
        #expect(MetricsURLRules.isLoopback(host: "LOCALHOST"))
        #expect(MetricsURLRules.isLoopback(host: "::1"))
        #expect(!MetricsURLRules.isLoopback(host: "localhost.evil.com"))
        #expect(!MetricsURLRules.isLoopback(host: "128.0.0.1"))
        #expect(!MetricsURLRules.isLoopback(host: nil))
    }
}

// MARK: - Mẫu instance + PromQL

@Suite struct MetricsTemplateTests {
    @Test func defaultsAndRendering() throws {
        #expect(MetricsSourceKind.prometheus.defaultInstanceTemplate == "{{hostName}}:9100")
        #expect(try InstanceTemplate.render("{{hostName}}:9100", hostName: "web1", port: 22) == "web1:9100")
        #expect(try InstanceTemplate.render("{{hostName}}:{{port}}", hostName: "web1", port: 2222) == "web1:2222")
    }

    @Test(arguments: [
        "{{other}}", "{{hostName}", "{{ hostName }}", "}}", "{{}}", "{{hostName}}{{", "", "a\u{0}b", "{{host\nName}}",
    ])
    func rejectsBadTemplates(_ t: String) {
        #expect(throws: MetricsSourceError.self) { try InstanceTemplate.validate(t) }
    }

    @Test func rejectsControlCharsAfterSubstitution() {
        #expect(throws: MetricsSourceError.self) {
            try InstanceTemplate.render("{{hostName}}:9100", hostName: "web\nup", port: 22)
        }
        #expect(throws: MetricsSourceError.self) {
            try InstanceTemplate.render("{{hostName}}", hostName: "  ", port: 22)
        }
    }

    @Test func escapeFollowsPromQLStrings() {
        #expect(PromQL.escapeLabelValue(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(PromQL.escapeLabelValue("a\nb") == #"a\nb"#)
    }

    @Test func injectionStaysInsideTheLabelString() throws {
        let evil = #""} or vector(1) #"#
        let rendered = try InstanceTemplate.render("{{hostName}}:9100", hostName: evil, port: 22)
        let escaped = PromQL.escapeLabelValue(rendered)
        for q in PromQuery.allCases {
            let expr = q.expression(escapedInstance: escaped)
            #expect(expr.contains(#"instance="\"} or vector(1) #:9100""#))
            #expect(!expr.contains(#"instance=""} or"#))
        }
        // Qua URL: `&`, `#`, `+` trong nhãn không thể tách tham số hay cắt query.
        let nasty = try InstanceTemplate.render("{{hostName}}", hostName: "a&query=up#x+y", port: 22)
        let expr = PromQuery.cpu.expression(escapedInstance: PromQL.escapeLabelValue(nasty))
        let url = try PrometheusClient.url(base: "https://p.example.com/pre", endpoint: "query", query: expr)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(comps?.path == "/pre/api/v1/query")
        #expect(comps?.queryItems?.count == 1)
        #expect(comps?.queryItems?.first?.name == "query")
        #expect(comps?.queryItems?.first?.value == expr)
        #expect(comps?.fragment == nil)
    }
}

// MARK: - DB v11

private struct MetricsEnv {
    let dir = HostTempDir()
    let db: Database
    let repo: MetricSourceRepository
    let store = InMemoryCredentialStore()
    let service: MetricSourceService
    init() throws {
        db = try Database(url: dir.dbURL)
        repo = MetricSourceRepository(database: db)
        service = MetricSourceService(repository: repo, credentials: store)
    }
}

@Suite struct MetricsRepositoryTests {
    @Test func migrationV11UpgradesV10AndKeepsHosts() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        #expect(Database.currentSchemaVersion >= 11)
        do {
            let old = try Database(url: dir.dbURL, migrations: Array(Database.migrations.prefix(10)))
            #expect(try old.schemaVersion() == 10)
            try old.execute(
                """
                INSERT INTO hosts (id, display_name, project, environment, tags_json, notes, is_favorite,
                  connection_mode, host_name, port, user, auth_method, bookmarks_json,
                  default_local_directory, default_remote_directory, created_at, updated_at)
                VALUES (?, 'legacy', '', 'DEV', '[]', '', 0, 'managed', 'h.example.com', 22, 'u', 'interactive',
                  '[]', '', '', 1, 1)
                """, [.text(UUID().uuidString)])
        }
        let db = try Database(url: dir.dbURL)
        #expect(try db.schemaVersion() == Database.currentSchemaVersion)
        #expect(try await HostRepository(database: db).all().count == 1)
        #expect(try MetricSourceRepository(database: db).all().isEmpty)
        let columns = try db.query("PRAGMA table_info(metric_sources)").compactMap { row -> String? in
            if case .text(let n) = row[1] { return n } else { return nil }
        }
        #expect(
            columns == [
                "id", "name", "kind", "base_url", "auth_kind", "basic_user", "credential_ref",
                "instance_template", "allow_insecure_http", "created_at",
            ])
    }

    @Test func crudAndFolderAssignmentCascade() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let a = try env.repo.insert(prom())
        #expect(try env.repo.all().map(\.id) == [a.id])
        var edited = a
        edited.name = "Renamed"
        edited.instanceTemplate = "{{hostName}}:9101"
        try env.repo.update(edited)
        #expect(try env.repo.source(id: a.id)?.name == "Renamed")
        #expect(try env.repo.source(id: a.id)?.instanceTemplate == "{{hostName}}:9101")

        try env.repo.assign(folder: "Prod", sourceID: a.id)
        #expect(try env.repo.assignedSourceID(folder: "Prod") == a.id)
        #expect(try env.repo.assignedSourceID(folder: "Other") == nil)
        try env.repo.assign(folder: "Prod", sourceID: nil)
        #expect(try env.repo.assignedSourceID(folder: "Prod") == nil)

        try env.repo.assign(folder: "Prod", sourceID: a.id)
        try env.repo.delete(id: a.id)
        #expect(try env.repo.assignments().isEmpty)
        #expect(throws: MetricsSourceError.self) { try env.repo.assign(folder: "x", sourceID: UUID()) }
    }

    @Test func invalidSourcesAreNeverStored() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        #expect(throws: MetricsSourceError.self) { try env.repo.insert(prom(url: "https://u:p@x.com")) }
        #expect(throws: MetricsSourceError.insecureHTTPNotAcknowledged) {
            try env.repo.insert(prom(url: "http://10.0.0.1", auth: .bearer))
        }
        #expect(try env.repo.all().isEmpty)
    }
}

// MARK: - Service + secret

@Suite struct MetricsServiceTests {
    @Test func secretGoesToStoreNotDatabase() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let token = "tok-SECRET-123"
        let s = try env.service.create(prom(auth: .bearer), secret: token)
        #expect(env.store.read(ref: "metrics-" + s.id.uuidString.lowercased()) == token)
        #expect(s.credentialRef == "metrics-" + s.id.uuidString.lowercased())
        // Không dòng nào của DB chứa token.
        let rows = try env.db.query("SELECT * FROM metric_sources")
        for row in rows {
            for v in row { if case .text(let t) = v { #expect(!t.contains(token)) } }
        }
        let bytes = try Data(contentsOf: env.dir.dbURL)
        #expect(bytes.range(of: Data(token.utf8)) == nil)
    }

    @Test func httpWithTokenWithoutAckStoresNothing() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        #expect(throws: MetricsSourceError.insecureHTTPNotAcknowledged) {
            try env.service.create(prom(url: "http://10.1.1.1:9090", auth: .bearer), secret: "t")
        }
        #expect(try env.repo.all().isEmpty)
        #expect(env.store.description.contains("count: 0"))
        // Tick rồi thì lưu được; loopback không cần tick.
        _ = try env.service.create(prom(url: "http://10.1.1.1:9090", auth: .bearer, allowHTTP: true), secret: "t")
        _ = try env.service.create(prom(url: "http://127.0.0.1:9090", auth: .bearer), secret: "t")
        #expect(try env.repo.all().count == 2)
    }

    @Test func requiresValidSecret() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        #expect(throws: MetricsSourceError.secretRequired) { try env.service.create(prom(auth: .bearer), secret: nil) }
        #expect(throws: MetricsSourceError.secretInvalid) {
            try env.service.create(prom(auth: .bearer), secret: "abc\r\nX-Evil: 1")
        }
        #expect(throws: MetricsSourceError.secretInvalid) { try env.service.create(prom(auth: .bearer), secret: "a b") }
        #expect(try env.repo.all().isEmpty)
    }

    @Test func updateKeepsOrReplacesOrRemovesSecret() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let s = try env.service.create(prom(auth: .bearer), secret: "one")
        let ref = s.credentialRef ?? ""
        var edit = s
        edit.name = "New"
        try env.service.update(edit, secret: nil)
        #expect(env.store.read(ref: ref) == "one")
        try env.service.update(edit, secret: "two")
        #expect(env.store.read(ref: ref) == "two")
        edit.authKind = .none
        try env.service.update(edit, secret: nil)
        #expect(!env.store.exists(ref: ref))
    }

    @Test func changingUrlOrAuthRequiresNewSecret() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let s = try env.service.create(prom(auth: .bearer), secret: "one")
        var moved = s
        moved.baseURL = "https://evil.example.com"
        #expect(throws: MetricsSourceError.secretReenterRequired) { try env.service.update(moved, secret: nil) }
        var basic = s
        basic.authKind = .basic
        basic.basicUser = "u"
        #expect(throws: MetricsSourceError.secretReenterRequired) { try env.service.update(basic, secret: nil) }
        #expect(env.store.read(ref: s.credentialRef ?? "") == "one")
        #expect(try env.repo.source(id: s.id)?.baseURL == "https://prom.example.com")
        // Nhập secret mới thì được; đổi path cùng origin thì giữ secret.
        try env.service.update(moved, secret: "two")
        var samePath = moved
        samePath.baseURL = "https://evil.example.com/prom"
        try env.service.update(samePath, secret: nil)
        #expect(env.store.read(ref: s.credentialRef ?? "") == "two")
        #expect(s.sharesSecretScope(with: s))
        #expect(!s.sharesSecretScope(with: moved))
    }

    @Test func keptSecretIsRevalidated() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let s = try env.service.create(prom(auth: .bearer), secret: "one")
        try env.store.save(ref: s.credentialRef ?? "", password: "a\r\nb")
        #expect(throws: MetricsSourceError.secretInvalid) { try env.service.update(s, secret: nil) }
    }

    @Test func deletingSourceDeletesSecretAndAssignment() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let s = try env.service.create(prom(auth: .bearer), secret: "tok")
        try env.repo.assign(folder: "F", sourceID: s.id)
        try env.service.delete(id: s.id)
        #expect(!env.store.exists(ref: s.credentialRef ?? "?"))
        #expect(try env.repo.all().isEmpty)
        #expect(try env.repo.assignedSourceID(folder: "F") == nil)
    }

    @Test func purgeKeepsSourcesButDropsSecrets() throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let a = try env.service.create(prom(auth: .bearer), secret: "a")
        _ = try env.service.create(prom(auth: .none), secret: nil)
        #expect(env.service.savedSecretCount() == 1)
        let r = env.service.purgeSecrets()
        #expect(r.removed == 1 && r.failed == 0)
        #expect(!env.store.exists(ref: a.credentialRef ?? "?"))
        #expect(try env.repo.all().count == 2)
    }

    @Test func clearAllPasswordsIncludesMetricsItems() async throws {
        let env = try MetricsEnv()
        defer { env.dir.cleanup() }
        let s = try env.service.create(prom(auth: .basic, user: "u"), secret: "pw")
        let service = ConnectionService(
            repository: HostRepository(database: env.db), appConfigURL: env.dir.url.appendingPathComponent("c"),
            userConfigPath: nil, launcher: WarpLauncher(), credentials: env.store, metricSources: env.service)
        #expect(try await service.savedPasswordCount() == 1)
        let result = try await service.clearAllPasswords()
        #expect(result.metricsItemsRemoved == 1 && result.metricsItemsFailed == 0)
        #expect(!env.store.exists(ref: s.credentialRef ?? "?"))
        #expect(try await service.savedPasswordCount() == 0)
        #expect(try env.repo.all().count == 1)
    }

    @Test func migrationReferencesIncludeMetricsRefs() throws {
        let s = MetricsSource(name: "n", kind: .prometheus, baseURL: "https://x.com", authKind: .bearer)
        let none = MetricsSource(name: "n", kind: .prometheus, baseURL: "https://x.com")
        let refs = CredentialMigration.references(hosts: [], sets: [], metricSources: [s, none])
        #expect(refs == [s.credentialRef ?? ""])
    }
}

@Test func infoPlistAllowsArbitraryLoadsWithoutLocalNetworking() throws {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let script = try String(contentsOf: url.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
    // Chỉ xét phần tử plist thật (không tính chú thích XML nhắc tên khoá).
    let uncommented = script.replacingOccurrences(
        of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
    #expect(uncommented.contains("<key>NSAppTransportSecurity</key>"))
    #expect(uncommented.contains("<key>NSAllowsArbitraryLoads</key>"))
    // Có khoá này thì macOS bỏ qua NSAllowsArbitraryLoads (tài liệu Apple).
    #expect(!uncommented.contains("NSAllowsLocalNetworking"))
    #expect(!uncommented.contains("NSAllowsArbitraryLoadsInWebContent"))
    #expect(!uncommented.contains("NSAllowsArbitraryLoadsForMedia"))
    #expect(!uncommented.contains("NSExceptionDomains"))
}

@Test func metricsSessionRequiresTLS12AndKeepsDefaultTrust() {
    let t = URLSessionMetricsTransport()
    #expect(t.session.configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    // Không có challenge handler tuỳ biến: mã nguồn transport không chấp nhận chứng chỉ tuỳ ý.
}
