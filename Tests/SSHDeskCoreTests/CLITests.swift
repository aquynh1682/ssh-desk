import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

// MARK: - Parser argv

@Suite struct CLIArgumentsTests {
    @Test func validCommands() throws {
        #expect(try CLIArguments.parse([]) == .help)
        #expect(try CLIArguments.parse(["help"]) == .help)
        #expect(try CLIArguments.parse(["list"]) == .list(folder: nil, json: false))
        #expect(try CLIArguments.parse(["list", "--json"]) == .list(folder: nil, json: true))
        #expect(
            try CLIArguments.parse(["list", "--json", "--folder", "Alpha"])
                == .list(folder: "Alpha", json: true))
        #expect(
            try CLIArguments.parse(["list", "--folder", "A B"]) == .list(folder: "A B", json: false))
        #expect(try CLIArguments.parse(["open", "web 1"]) == .open(query: "web 1"))
    }

    @Test func rejectsEverythingElse() {
        let bad: [[String]] = [
            ["frob"], ["help", "x"], ["list", "x"], ["list", "--folder"], ["list", "--json", "--json"],
            ["list", "--folder", "a", "--folder", "b"], ["list", "--password", "x"],
            ["open"], ["open", "a", "b"], ["open", "-o"], ["open", "--", "x"], ["open", ""],
            ["open", "a\u{1b}[31m"], ["open", String(repeating: "a", count: 257)],
            ["open", "a", "--", "rm"], ["template"], ["template", "a", "b"], ["template", "-x.xlsx"],
            ["template", "/tmp/x.txt"], ["--password=x"],
            ["list", "--folder", "x\nrm"],
        ]
        for argv in bad {
            #expect(throws: CLIParseError.self, "\(argv)") { try CLIArguments.parse(argv) }
        }
    }
}

// MARK: - Resolver

@Suite struct HostResolverTests {
    private func win(_ name: String) -> HostProfile {
        var h = managedHost(name)
        h.kind = .windowsRDP
        return h
    }

    @Test func uuidFirstThenAliasThenName() throws {
        let a = managedHost("Alpha")
        let b = importedHost("Legacy", alias: "web-u")
        let c = managedHost("web-u")  // tên trùng alias của b: alias thắng
        let hosts = [a, b, c]
        #expect(try HostResolver.resolve(a.id.uuidString, in: hosts).id == a.id)
        #expect(try HostResolver.resolve(a.id.uuidString.lowercased(), in: hosts).id == a.id)
        #expect(try HostResolver.resolve("web-u", in: hosts).id == b.id)
        #expect(try HostResolver.resolve("alpha", in: hosts).id == a.id)
    }

    @Test func nameIgnoresCaseAndDiacritics() throws {
        let h = managedHost("Máy Chủ Hà Nội")
        #expect(try HostResolver.resolve("may chu ha noi", in: [h]).id == h.id)
        #expect(try HostResolver.resolve("  MÁY CHỦ HÀ NỘI ", in: [h]).id == h.id)
    }

    @Test func noFuzzyMatching() {
        let h = managedHost("Alpha Server")
        #expect(throws: HostResolveError.notFound(query: "alpha")) {
            try HostResolver.resolve("alpha", in: [h])
        }
        #expect(throws: HostResolveError.self) { try HostResolver.resolve("", in: [h]) }
    }

    @Test func aliasIsCaseSensitiveAndOnlyForImported() {
        let b = importedHost("Legacy", alias: "Web-U")
        #expect(throws: HostResolveError.self) { try HostResolver.resolve("web-u", in: [b]) }
        var m = managedHost("x")
        m.sshConfigAlias = "zzz"  // managed: alias này không dùng để khớp
        #expect(throws: HostResolveError.self) { try HostResolver.resolve("zzz", in: [m]) }
    }

    @Test func ambiguousListsIDs() throws {
        let a = managedHost("Web")
        let b = managedHost("WEB")
        do {
            _ = try HostResolver.resolve("web", in: [a, b])
            Issue.record("phải lỗi")
        } catch let e as HostResolveError {
            guard case .ambiguous(_, let ms) = e else {
                Issue.record("sai lỗi")
                return
            }
            #expect(Set(ms.map(\.id)) == [a.id, b.id])
            #expect(e.description.contains(a.id.uuidString.lowercased()))
        }
    }

    @Test func windowsUnsupported() {
        let w = win("Win")
        #expect(throws: HostResolveError.windowsUnsupported(name: "Win")) {
            try HostResolver.resolve("win", in: [w])
        }
        #expect(throws: HostResolveError.windowsUnsupported(name: "Win")) {
            try HostResolver.resolve(id: w.id, in: [w])
        }
    }

    @Test func idLookupIsStrict() {
        var h = managedHost("x")
        let other = UUID()
        h.sshConfigAlias = other.uuidString
        h.connectionMode = .existingSSHConfigAlias
        #expect(throws: HostResolveError.self) { try HostResolver.resolve(id: other, in: [h]) }
    }
}

// MARK: - DB chỉ đọc

@Suite struct ReadOnlyDatabaseTests {
    @Test func readsButCannotWrite() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let writer = try Database(url: t.dbURL)  // giữ mở: WAL đang bật bởi kết nối ghi
        let repo = HostRepository(database: writer)
        let h = managedHost("Web", project: "Alpha")
        try await repo.insert(h)

        let ro = try Database.openReadOnly(url: t.dbURL)
        let hosts = try await HostRepository(database: ro).all()
        #expect(hosts.map(\.id) == [h.id])
        #expect(throws: DatabaseError.self) {
            try ro.execute("UPDATE hosts SET display_name = 'hack'")
        }
        #expect(throws: DatabaseError.self) { try ro.execute("DELETE FROM hosts") }
        #expect(try await repo.host(id: h.id)?.displayName == "Web")

        // Ghi thêm ở kết nối ghi, kết nối đọc thấy dữ liệu mới.
        let h2 = managedHost("Db")
        try await repo.insert(h2)
        #expect(try await HostRepository(database: ro).all().count == 2)
    }

    @Test func readsWalDatabaseAfterWriterClosed() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let h = managedHost("Web")
        do {
            let writer = try Database(url: t.dbURL)
            try await HostRepository(database: writer).insert(h)
        }  // writer đóng: -wal/-shm bị dọn
        let before = try FileManager.default.contentsOfDirectory(atPath: t.dbURL.deletingLastPathComponent().path)
            .sorted()
        let ro = try Database.openReadOnly(url: t.dbURL)
        #expect(try await HostRepository(database: ro).all().map(\.id) == [h.id])
        let after = try FileManager.default.contentsOfDirectory(atPath: t.dbURL.deletingLastPathComponent().path)
            .sorted()
        #expect(before == after)  // không tạo file mới
    }

    @Test func missingFileIsClearErrorAndNotCreated() {
        let t = HostTempDir()
        defer { t.cleanup() }
        #expect(throws: DatabaseError.notFound(t.dbURL.path)) { try Database.openReadOnly(url: t.dbURL) }
        #expect(!FileManager.default.fileExists(atPath: t.dbURL.path))
    }

    @Test func schemaMismatchIsRejected() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let writer = try Database(url: t.dbURL)
        try writer.execute("UPDATE schema_version SET version = 99")
        #expect(
            throws: DatabaseError.schemaMismatch(found: 99, expected: Database.currentSchemaVersion)
        ) { try Database.openReadOnly(url: t.dbURL) }
        try writer.execute("UPDATE schema_version SET version = 1")
        #expect(
            throws: DatabaseError.schemaMismatch(found: 1, expected: Database.currentSchemaVersion)
        ) { try Database.openReadOnly(url: t.dbURL) }
    }

    @Test func emptyOrGarbageFileUntouched() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        try FileManager.default.createDirectory(
            at: t.dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data("not sqlite at all".utf8)
        try junk.write(to: t.dbURL)
        #expect(throws: DatabaseError.self) { try Database.openReadOnly(url: t.dbURL) }
        #expect(try Data(contentsOf: t.dbURL) == junk)
        try Data().write(to: t.dbURL)
        #expect(throws: DatabaseError.schemaMismatch(found: 0, expected: Database.currentSchemaVersion)) {
            try Database.openReadOnly(url: t.dbURL)
        }
        #expect(try Data(contentsOf: t.dbURL).isEmpty)
    }
}

// MARK: - Danh sách

@Suite struct CLIHostListTests {
    @Test func jsonHasExactKeysAndNoSecrets() throws {
        var h = managedHost("Web", project: "Alpha")
        h.environment = .prod
        h.notes = "BÍ-MẬT-GHI-CHÚ"
        h.credentialReference = "keychain:SECRET-REF"
        h.identityFile = "/Users/me/.ssh/KEYFILE"
        let imp = importedHost("Legacy", alias: "web-u")
        let json = try CLIHostList.json(CLIHostList.entries([h, imp], folder: nil))
        #expect(!json.contains("SECRET-REF"))
        #expect(!json.contains("BÍ-MẬT"))
        #expect(!json.contains("KEYFILE"))
        #expect(!json.contains("credential"))
        #expect(!json.contains("notes"))
        let arr = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(arr.count == 2)
        let keys: Set<String> = [
            "id", "name", "alias", "folder", "environment", "kind", "hostName", "port", "user",
        ]
        for o in arr { #expect(Set(o.keys) == keys) }
        #expect(arr[0]["environment"] as? String == "PROD")
        #expect(arr[0]["folder"] as? String == "Alpha")
        #expect(arr[0]["alias"] is NSNull)
        #expect(arr[1]["alias"] as? String == "web-u")
        #expect(arr[1]["folder"] is NSNull)
    }

    @Test func folderFilterIgnoresCaseAndDiacritics() {
        let a = managedHost("A", project: "Dự án")
        let b = managedHost("B", project: "Khác")
        #expect(CLIHostList.entries([a, b], folder: "du an").map(\.name) == ["A"])
        #expect(CLIHostList.entries([a, b], folder: nil).count == 2)
    }

    @Test func tableStripsControlCharacters() {
        let h = managedHost("Evil\u{1b}[31m\nName")
        let text = CLIHostList.table(CLIHostList.entries([h], folder: nil))
        #expect(!text.contains("\u{1b}"))
        #expect(text.split(separator: "\n").count == 2)  // tiêu đề + 1 dòng
        #expect(CLIHostList.table([]).contains("không có"))
    }
}

// MARK: - File yêu cầu

@Suite struct CLIOpenRequestTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdesk-req-\(UUID().uuidString)/requests")
    }

    private func mode(_ url: URL) throws -> Int {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        return Int(st.st_mode & 0o777)
    }

    @Test func permissionsContentAndConsumeDeletes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let host = UUID()
        let now = Date()
        let rid = try CLIOpenRequest.write(hostID: host, in: dir, now: now)
        let file = dir.appendingPathComponent(rid.uuidString.lowercased() + ".json")
        #expect(try mode(dir) == 0o700)
        #expect(try mode(file) == 0o600)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(obj.keys) == ["hostID", "createdAt"])
        // Không còn file tạm.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [file.lastPathComponent])

        #expect(CLIOpenRequest.consume(id: rid, in: dir, now: now) == .valid(hostID: host))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(CLIOpenRequest.consume(id: rid, in: dir, now: now) == .missing)
    }

    @Test func expiresAfter30Seconds() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let t0 = Date()
        let a = try CLIOpenRequest.write(hostID: UUID(), in: dir, now: t0)
        #expect(CLIOpenRequest.consume(id: a, in: dir, now: t0.addingTimeInterval(29)) != .expired)
        let b = try CLIOpenRequest.write(hostID: UUID(), in: dir, now: t0)
        #expect(CLIOpenRequest.consume(id: b, in: dir, now: t0.addingTimeInterval(31)) == .expired)
        // Hết hạn cũng bị xoá.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        // createdAt ở tương lai xa -> không hợp lệ.
        let c = try CLIOpenRequest.write(hostID: UUID(), in: dir, now: t0.addingTimeInterval(3600))
        #expect(CLIOpenRequest.consume(id: c, in: dir, now: t0) == .expired)
    }

    @Test func rejectsWrongPermissionsGarbageAndSymlink() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let rid = try CLIOpenRequest.write(hostID: UUID(), in: dir)
        let file = dir.appendingPathComponent(rid.uuidString.lowercased() + ".json")
        chmod(file.path, 0o644)
        #expect(CLIOpenRequest.consume(id: rid, in: dir) == .invalid)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let g = UUID()
        let gf = dir.appendingPathComponent(g.uuidString.lowercased() + ".json")
        FileManager.default.createFile(
            atPath: gf.path, contents: Data("{nope".utf8), attributes: [.posixPermissions: 0o600])
        #expect(CLIOpenRequest.consume(id: g, in: dir) == .invalid)

        // Symlink tới file hợp lệ nằm ngoài thư mục -> không theo, và không xoá file đích.
        let real = try CLIOpenRequest.write(hostID: UUID(), in: dir)
        let realFile = dir.appendingPathComponent(real.uuidString.lowercased() + ".json")
        let target = dir.deletingLastPathComponent().appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: realFile, to: target)
        let s = UUID()
        let sf = dir.appendingPathComponent(s.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: sf, withDestinationURL: target)
        #expect(CLIOpenRequest.consume(id: s, in: dir) == .invalid)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func rejectsLooseDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let rid = try CLIOpenRequest.write(hostID: UUID(), in: dir)
        chmod(dir.path, 0o755)
        #expect(CLIOpenRequest.consume(id: rid, in: dir) == .invalid)
    }

    @Test func unknownIDIsMissingAndPathTraversalImpossible() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(CLIOpenRequest.consume(id: UUID(), in: dir) == .missing)
        // id đi vào qua URL luôn là UUID; chuỗi traversal không parse được.
        #expect(UUID(uuidString: "../../etc/passwd") == nil)
        let url = URL(string: "sshdesk://cli?request=../../x")!
        #expect(throws: AppURLRequest.ParseError.self) { try AppURLRequest.parse(url) }
    }
}

// MARK: - URL

@Suite struct AppURLRequestTests {
    private let id = UUID()

    private func parse(_ s: String) throws -> AppURLRequest {
        try AppURLRequest.parse(URL(string: s)!)
    }

    @Test func validForms() throws {
        #expect(try parse("sshdesk://open?id=\(id.uuidString)") == .external(.id(id)))
        #expect(try parse("sshdesk://open?name=Web%20Server") == .external(.name("Web Server")))
        #expect(try parse("sshdesk://cli?request=\(id.uuidString)") == .fromCLI(requestID: id))
        #expect(try parse("SSHDESK://OPEN?name=x") == .external(.name("x")))
    }

    @Test func rejects() {
        let long = String(repeating: "a", count: 257)
        let bad = [
            "sshdesk://open?id=\(id.uuidString)&cmd=rm",
            "sshdesk://open?id=\(id.uuidString)&id=\(id.uuidString)",
            "sshdesk://open?cmd=ls",
            "sshdesk://open?name=x&cmd=ls",
            "sshdesk://open",
            "sshdesk://open?name=",
            "sshdesk://open?name=%20%20",
            "sshdesk://open?name",
            "sshdesk://open?id=notauuid",
            "sshdesk://open?request=\(id.uuidString)",
            "sshdesk://cli?id=\(id.uuidString)",
            "sshdesk://cli?request=zzz",
            "sshdesk://open?name=\(long)",
            "sshdesk://open?name=a%00b",
            "sshdesk://open?name=a%0Ab",
            "sshdesk://open?name=a%1Bb",
            "sshdesk://open?name=a%E2%80%A8b",  // U+2028
            "sshdesk://exec?name=x",
            "sshdesk://localhost?name=x",
            "sshdesk:///open?name=x",
            "sshdesk://open/extra?name=x",
            "sshdesk://open:99?name=x",
            "sshdesk://user@open?name=x",
            "sshdesk://open?name=x#frag",
            "https://open?name=x",
            "warp://open?name=x",
        ]
        for s in bad {
            #expect(throws: AppURLRequest.ParseError.self, "\(s)") { try parse(s) }
        }
        // đúng 256 ký tự thì được
        let ok = String(repeating: "a", count: 256)
        #expect((try? parse("sshdesk://open?name=\(ok)")) != nil)
    }
}

// MARK: - Quy tắc xác nhận + luồng URL

@Suite struct OpenConfirmationTests {
    @Test func confirmationTable() {
        let cases: [(OpenOrigin, HostEnvironment, Bool)] = [
            (.external, .dev, true), (.external, .uat, true), (.external, .stg, true),
            (.external, .prod, true), (.external, .other, true),
            (.cli, .dev, false), (.cli, .uat, false), (.cli, .stg, false),
            (.cli, .other, false), (.cli, .prod, true),
        ]
        for (o, e, want) in cases {
            #expect(o.requiresConfirmation(environment: e) == want, "\(o) \(e)")
        }
    }

    @Test func unknownOrExpiredRequestCountsAsExternal() {
        #expect(OpenOrigin(consumption: .valid(hostID: UUID())) == .cli)
        for o: CLIOpenRequest.Outcome in [.missing, .expired, .invalid] {
            #expect(OpenOrigin(consumption: o) == .external)
        }
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdesk-req-\(UUID().uuidString)/requests")
    }

    @Test func cliURLFlow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let host = managedHost("Web")
        let rid = try CLIOpenRequest.write(hostID: host.id, in: dir)
        let url = URL(string: "sshdesk://cli?request=\(rid.uuidString)")!
        let r = OpenURLHandler.intent(for: url, requestsDirectory: dir)
        #expect(try r.get() == OpenIntent(reference: .id(host.id), origin: .cli))
        // Dùng lại -> không còn hiệu lực.
        #expect(OpenURLHandler.intent(for: url, requestsDirectory: dir) == .failure(.unknownCLIRequest))
        // external không đụng tới thư mục request.
        let ext = URL(string: "sshdesk://open?name=Web")!
        #expect(
            try OpenURLHandler.intent(for: ext, requestsDirectory: dir).get()
                == OpenIntent(reference: .name("Web"), origin: .external))
        #expect(throws: Never.self) { try OpenURLHandler.host(for: try r0(host), in: [host]) }
    }

    private func r0(_ h: HostProfile) -> OpenIntent { OpenIntent(reference: .name(h.displayName), origin: .external) }

    @Test func badURLFails() {
        let dir = tempDir()
        let url = URL(string: "sshdesk://open?name=x&cmd=rm")!
        guard case .failure(.invalidURL) = OpenURLHandler.intent(for: url, requestsDirectory: dir)
        else {
            Issue.record("phải lỗi")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func confirmationTextShowsNameEnvTarget() {
        var h = managedHost("Web", hostName: "web.example.com", user: "deploy")
        h.environment = .prod
        let t = OpenURLHandler.confirmationText(for: h, origin: .external)
        #expect(t.title.contains("Web"))
        #expect(t.message.contains("PROD"))
        #expect(t.message.contains("deploy@web.example.com"))
    }
}
