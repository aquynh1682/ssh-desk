import Darwin
import Foundation
import Testing

@testable import SSHDeskCore

@Suite struct HostExchangeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rows(_ data: Data) throws -> [[String: Any]] {
        try #require(try json(data)["hosts"] as? [[String: Any]])
    }

    private func fullHost() -> HostProfile {
        HostProfile(
            displayName: "Web 1", project: "Alpha", environment: .prod, tags: ["a", "b"],
            notes: "dòng 1\ndòng 2", isFavorite: true, hostName: "web1.example.com", port: 2222,
            user: "deploy", authMethod: .keyFile, identityFile: "/Users/me/.ssh/id_ed25519",
            credentialReference: "SECRETREF-123",
            remoteBookmarks: [RemoteBookmark(name: "logs", path: "/var/log")],
            defaultLocalDirectory: "/Users/me/Downloads", defaultRemoteDirectory: "/srv",
            lastLaunchRequestedAt: Date(timeIntervalSince1970: 1))
    }

    private func export(
        _ hosts: [HostProfile], forwards: [PortForward] = [], folders: [String] = [],
        reauth: Set<UUID> = []
    ) throws -> Data {
        try HostExchange.export(
            hosts: hosts, forwards: forwards, folders: folders, needsReauth: reauth, now: now)
    }

    private func plan(
        _ data: Data, existing: [HostProfile] = [], folders: [String] = [],
        forwards: [PortForward] = [], dup: DuplicateHandling = .skip
    ) throws -> HostExchange.Plan {
        HostExchange.plan(
            file: try HostExchange.decode(data), existingHosts: existing, existingFolders: folders,
            existingForwards: forwards, duplicates: dup, now: now)
    }

    /// Sửa một trường của host đầu tiên trong JSON rồi đóng gói lại.
    private func tampered(_ data: Data, _ mutate: (inout [[String: Any]]) -> Void) throws -> Data {
        var root = try json(data)
        var hosts = try #require(root["hosts"] as? [[String: Any]])
        mutate(&hosts)
        root["hosts"] = hosts
        return try JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - Không lộ credential

    @Test func outputNeverContainsCredentialsOrPasswordFields() throws {
        let h = fullHost()
        let data = try export([h], reauth: [h.id])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("SECRETREF-123"))
        #expect(!text.lowercased().contains("credential"))
        #expect(!text.lowercased().contains("password"))
        #expect(!text.contains("keychain"))
        for row in try rows(data) {
            #expect(row["credentialReference"] == nil && row["password"] == nil)
        }
        #expect(try rows(data)[0]["needsReauth"] as? Bool == true)
    }

    @Test func importedPlanNeverCarriesCredentialReferenceEvenIfFileHasOne() throws {
        let data = try tampered(try export([fullHost()])) { rows in
            rows[0]["credentialReference"] = "INJECTED-REF"
            rows[0]["password"] = "hunter2"
        }
        let p = try plan(data)
        #expect(p.hosts.count == 1 && p.hosts[0].credentialReference == nil)
    }

    // MARK: - Round-trip

    @Test func roundTripPreservesEverythingExceptIdsAndSecrets() throws {
        let h = fullHost()
        let win = HostProfile(
            displayName: "Win", project: "Alpha", environment: .uat, kind: .windowsRDP,
            rdpUsername: "CORP\\admin", rdpDomain: "CORP", rdpGateway: "gw.example.com:443",
            rdpScreenMode: .window, rdpMultiMonitor: true, rdpRedirectClipboard: false,
            rdpAdminSession: true, hostName: "10.0.0.9", port: 3389)
        let alias = importedHost("legacy", alias: "web-u")
        let fw = PortForward(hostID: h.id, name: "pg", localPort: 15432, remoteHost: "db.internal", remotePort: 5432)
        let data = try export([h, win, alias], forwards: [fw], folders: ["Alpha", "Rỗng"])
        let p = try plan(data)
        #expect(p.newCount == 3 && p.invalidCount == 0 && p.duplicateCount == 0)
        #expect(p.foldersToCreate == ["Alpha", "Rỗng"])

        func same(_ a: HostProfile, _ b: HostProfile) -> Bool {
            var x = a
            var y = b
            for i in 0..<2 {
                var h = i == 0 ? x : y
                h.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                h.createdAt = now
                h.updatedAt = now
                h.credentialReference = nil
                h.lastLaunchRequestedAt = nil
                h.jumpHostID = nil
                if i == 0 { x = h } else { y = h }
            }
            return x == y
        }
        let byName = Dictionary(uniqueKeysWithValues: p.hosts.map { ($0.displayName, $0) })
        #expect(same(byName["Web 1"]!, h))
        #expect(same(byName["Win"]!, win))
        #expect(same(byName["legacy"]!, alias))
        #expect(byName["Web 1"]!.notes == "dòng 1\ndòng 2")
        #expect(p.hosts.allSatisfy { $0.id != h.id && $0.id != win.id && $0.id != alias.id })
        #expect(Set(p.hosts.map(\.id)).count == 3)
        #expect(p.forwards.count == 1)
        let f = p.forwards[0]
        #expect(
            f.hostID == byName["Web 1"]!.id && f.localPort == 15432 && f.remoteHost == "db.internal" && f.name == "pg")
        #expect(f.id != fw.id)
    }

    @Test func exportIsDeterministicSortedJSONWithHeader() throws {
        let h = fullHost()
        let a = try export([h])
        let b = try export([h])
        #expect(a == b)
        let root = try json(a)
        #expect(root["format"] as? String == "sshdesk-hosts" && root["version"] as? Int == 1)
        #expect((root["exportedAt"] as? String)?.hasSuffix("Z") == true)
    }

    @Test func exportSetIncludesBastionsTransitively() {
        let c = managedHost("c", hostName: "c.example.com")
        let b = managedHost("b", hostName: "b.example.com", jump: c.id)
        let a = managedHost("a", hostName: "a.example.com", jump: b.id)
        let other = managedHost("o", hostName: "o.example.com")
        let set = HostExchange.exportSet(selected: [a], all: [a, b, c, other])
        #expect(Set(set.map(\.id)) == [a.id, b.id, c.id])
    }

    // MARK: - File lạ / lớn / hỏng

    @Test func rejectsUnknownVersionAndWrongFormatAndGarbage() throws {
        let good = try export([fullHost()])
        var root = try json(good)
        root["version"] = 2
        #expect(throws: HostExchangeError.unsupportedVersion(2)) {
            try HostExchange.decode(try JSONSerialization.data(withJSONObject: root))
        }
        root["version"] = 1
        root["format"] = "other"
        #expect(throws: HostExchangeError.wrongFormat) {
            try HostExchange.decode(try JSONSerialization.data(withJSONObject: root))
        }
        #expect(throws: HostExchangeError.notJSON) { try HostExchange.decode(Data("không phải json".utf8)) }
        #expect(throws: HostExchangeError.wrongFormat) { try HostExchange.decode(Data("{}".utf8)) }
        // JSON đúng format/version nhưng thiếu `hosts`.
        #expect(throws: HostExchangeError.notJSON) {
            try HostExchange.decode(Data(#"{"format":"sshdesk-hosts","version":1}"#.utf8))
        }
    }

    @Test func rejectsFilesOverFiveMegabytes() throws {
        let big = Data(repeating: 0x20, count: HostExchange.maxFileBytes + 1)
        #expect(throws: HostExchangeError.fileTooLarge(limit: HostExchange.maxFileBytes)) {
            try HostExchange.decode(big)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.sshdesk.json")
        try big.write(to: url)
        #expect(throws: HostExchangeError.fileTooLarge(limit: HostExchange.maxFileBytes)) {
            try HostExchange.read(from: url)
        }
        #expect(throws: HostExchangeError.notRegularFile) { try HostExchange.read(from: dir) }
        #expect(throws: HostExchangeError.self) { try HostExchange.read(from: dir.appendingPathComponent("nope")) }
    }

    @Test func rejectsTooManyHosts() throws {
        let host = #"{"id":"%d","displayName":"h","hostName":"h.example.com","user":"u"}"#
        let list = (0...HostExchange.maxHosts).map { String(format: host, $0) }.joined(separator: ",")
        let text = #"{"format":"sshdesk-hosts","version":1,"exportedAt":"","folders":[],"hosts":[\#(list)]}"#
        #expect(throws: HostExchangeError.tooManyHosts(limit: HostExchange.maxHosts)) {
            try HostExchange.decode(Data(text.utf8))
        }
    }

    @Test func readsBackWhatWriteProduced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.sshdesk.json")
        try HostExchange.write(try export([fullHost()]), to: url)
        #expect(try HostExchange.read(from: url).hostCount == 1)
    }

    // MARK: - Ghi file

    @Test func writeIsAtomicWith0600AndOverwritesLooseFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.sshdesk.json")
        try Data("cũ".utf8).write(to: url)
        chmod(url.path, 0o644)
        let data = try export([fullHost()])
        try HostExchange.write(data, to: url)
        #expect(try Data(contentsOf: url) == data)
        var st = stat()
        #expect(stat(url.path, &st) == 0 && (st.st_mode & 0o777) == 0o600)
        // Không để file tạm.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["out.sshdesk.json"])
    }

    @Test func writeFailureLeavesNoTempFileAndKeepsOriginal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Đích là một thư mục → rename thất bại.
        let target = dir.appendingPathComponent("isdir")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(throws: HostExchangeError.self) { try HostExchange.write(Data("x".utf8), to: target) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["isdir"])
        // Thư mục đích không tồn tại.
        #expect(throws: HostExchangeError.self) {
            try HostExchange.write(Data("x".utf8), to: dir.appendingPathComponent("no/such/f.json"))
        }
    }

    // MARK: - Validate từng máy

    @Test func newlineAndControlCharsInFieldsMakeOnlyThatHostInvalid() throws {
        let good = managedHost("ok", hostName: "ok.example.com")
        let victims: [(String, (inout [String: Any]) -> Void)] = [
            ("displayName", { $0["displayName"] = "a\nb" }),
            ("hostName", { $0["hostName"] = "h.example.com\nProxyCommand evil" }),
            ("user", { $0["user"] = "root\n" }),
            ("folder", { $0["folder"] = "x\ny" }),
            ("tag", { $0["tags"] = ["ok", "a\rb"] }),
            ("bookmark", { $0["bookmarks"] = [["name": "n", "path": "/a\nb"]] }),
            (
                "identityFile",
                {
                    $0["authMethod"] = "keyFile"
                    $0["identityFile"] = "/k\n/etc"
                }
            ),
            ("defaultRemote", { $0["defaultRemoteDirectory"] = "/a\u{0}b" }),
            ("notes", { $0["notes"] = "ghi chú\u{1B}[31m" }),
            ("port", { $0["port"] = 70000 }),
            ("envEnum", { $0["environment"] = "STAGING" }),
            ("kindEnum", { $0["kind"] = "ftp" }),
            ("auth", { $0["authMethod"] = "magic" }),
        ]
        for (label, mutate) in victims {
            let base = try export([fullHost(), good])
            let data = try tampered(base) { rows in
                let i = rows.firstIndex { ($0["displayName"] as? String) == "Web 1" }!
                mutate(&rows[i])
            }
            let p = try plan(data)
            #expect(p.invalidCount == 1, "\(label)")
            #expect(p.hosts.map(\.displayName) == ["ok"], "\(label)")
            let bad = p.entries.first { if case .invalid = $0.outcome { return true } else { return false } }
            #expect(bad != nil && bad?.willImport == false, "\(label)")
        }
    }

    @Test func windowsHostRulesAreValidatedToo() throws {
        let win = HostProfile(
            displayName: "Win", kind: .windowsRDP, rdpUsername: "u", hostName: "10.0.0.9", port: 3389)
        let data = try tampered(try export([win])) { rows in
            rows[0]["rdp"] = [
                "username": "u\nadmin", "screenMode": "fullScreen", "multiMonitor": false,
                "redirectClipboard": true, "adminSession": false,
            ]
        }
        #expect(try plan(data).invalidCount == 1)
        let bad = try tampered(try export([win])) { rows in
            rows[0]["rdp"] = [
                "username": "u", "screenMode": "huge", "multiMonitor": false,
                "redirectClipboard": true, "adminSession": false,
            ]
        }
        #expect(try plan(bad).invalidCount == 1)
    }

    @Test func duplicateIDsInsideFileAreRejectedAfterFirst() throws {
        let a = managedHost("a", hostName: "a.example.com")
        let data = try tampered(try export([a, managedHost("b", hostName: "b.example.com")])) { rows in
            rows[1]["id"] = rows[0]["id"]
        }
        let p = try plan(data)
        #expect(p.hosts.count == 1 && p.invalidCount == 1)
    }

    // MARK: - Trùng

    @Test func duplicatesAreSkippedByDefaultAndCopiedOnRequest() throws {
        let existing = managedHost("Web", hostName: "WEB.example.com", user: "deploy")
        var incoming = managedHost("Web mới", hostName: "web.example.com", user: "deploy")
        incoming.port = 22
        let fresh = managedHost("Khác", hostName: "other.example.com")
        let data = try export([incoming, fresh])

        let skip = try plan(data, existing: [existing])
        #expect(skip.newCount == 1 && skip.duplicateCount == 1)
        #expect(skip.hosts.map(\.displayName) == ["Khác"])
        let dupEntry = try #require(skip.entries.first { $0.displayName == "Web mới" })
        #expect(dupEntry.outcome == .duplicate(existingID: existing.id) && !dupEntry.willImport)

        let copy = try plan(data, existing: [existing], dup: .copy)
        #expect(copy.hosts.count == 2)
        #expect(copy.hosts.map(\.displayName).contains("Web mới (bản sao)"))
        #expect(copy.hosts.allSatisfy { $0.id != existing.id })
        // Khác port/user/loại thì KHÔNG trùng.
        var p2 = incoming
        p2.id = UUID()
        p2.port = 2222
        var p3 = incoming
        p3.id = UUID()
        p3.user = "root"
        let notDup = try plan(try export([p2, p3]), existing: [existing])
        #expect(notDup.duplicateCount == 0 && notDup.newCount == 2)
    }

    @Test func duplicateInsideTheFileCountsAsDuplicate() throws {
        let a = managedHost("A", hostName: "a.example.com")
        var b = a
        b.id = UUID()
        b.displayName = "A copy"
        let data = try export([a, b])
        let skip = try plan(data)
        #expect(skip.hosts.count == 1 && skip.duplicateCount == 1)
        let entry = skip.entries.first { $0.displayName == "A copy" }
        #expect(entry?.outcome == .duplicate(existingID: nil))
        #expect(try plan(data, dup: .copy).hosts.count == 2)
    }

    @Test func importedAliasDuplicateUsesAliasAndConfigPath() throws {
        let existing = importedHost("legacy", alias: "web-u")
        let data = try export([importedHost("legacy", alias: "web-u"), importedHost("l2", alias: "db-u")])
        let p = try plan(data, existing: [existing])
        #expect(p.duplicateCount == 1 && p.newCount == 1)
    }

    @Test func windowsDuplicateIgnoresSSHUser() throws {
        let existing = HostProfile(
            displayName: "W", kind: .windowsRDP, rdpUsername: "admin", hostName: "10.0.0.9", port: 3389)
        var other = existing
        other.id = UUID()
        other.rdpUsername = "someone-else"
        var same = existing
        same.id = UUID()
        let p = try plan(try export([other, same]), existing: [existing])
        #expect(p.duplicateCount == 1 && p.newCount == 1)
    }

    // MARK: - Jump host

    @Test func jumpHostIsRemappedToNewIDsAndOrderedBastionFirst() throws {
        let bastion = managedHost("bastion", hostName: "b.example.com")
        let app = managedHost("app", hostName: "a.example.com", jump: bastion.id)
        let data = try export([app, bastion])  // cố ý để máy dùng bastion đứng trước
        let p = try plan(data)
        let newBastion = try #require(p.hosts.first { $0.displayName == "bastion" })
        let newApp = try #require(p.hosts.first { $0.displayName == "app" })
        #expect(newApp.jumpHostID == newBastion.id)
        #expect(newApp.jumpHostID != bastion.id)
        let order = p.hosts.map(\.displayName)
        #expect(order.firstIndex(of: "bastion")! < order.firstIndex(of: "app")!)
    }

    @Test func missingJumpHostBecomesEmptyWithWarning() throws {
        let ghost = UUID()
        var app = managedHost("app", hostName: "a.example.com", jump: ghost)
        app.jumpHostID = ghost
        let data = try HostExchange.export(
            hosts: [app], forwards: [], folders: [], now: now)
        // export() cắt jump ngoài tập; chèn lại bằng tay như file bị sửa/xuất từ bản khác.
        let withRef = try tampered(data) { $0[0]["jumpHostId"] = ghost.uuidString.lowercased() }
        let p = try plan(withRef)
        #expect(p.hosts.count == 1 && p.hosts[0].jumpHostID == nil)
        #expect(p.entries[0].warnings.contains { $0.contains("Bastion") })
        // Không có tham chiếu bastion treo trong host nào.
        let dangling = try plan(withRef).hosts.compactMap(\.jumpHostID)
        #expect(dangling.isEmpty)
    }

    @Test func jumpToSkippedDuplicateMapsToExistingHost() throws {
        let existingBastion = managedHost("Bastion cũ", hostName: "b.example.com")
        let fileBastion = managedHost("bastion trong file", hostName: "B.example.com")
        let app = managedHost("app", hostName: "a.example.com", jump: fileBastion.id)
        let data = try export([fileBastion, app])
        let p = try plan(data, existing: [existingBastion])
        #expect(p.hosts.count == 1 && p.hosts[0].jumpHostID == existingBastion.id)
    }

    @Test func jumpCycleInFileIsBroken() throws {
        var a = managedHost("a", hostName: "a.example.com")
        var b = managedHost("b", hostName: "b.example.com")
        a.jumpHostID = b.id
        b.jumpHostID = a.id
        let p = try plan(try export([a, b]))
        #expect(p.hosts.count == 2)
        #expect(p.hosts.contains { $0.jumpHostID == nil })
        // Không còn vòng nào trong kết quả.
        let byID = Dictionary(uniqueKeysWithValues: p.hosts.map { ($0.id, $0) })
        for h in p.hosts {
            var seen = Set<UUID>([h.id])
            var cur = h.jumpHostID
            while let c = cur {
                #expect(seen.insert(c).inserted)
                cur = byID[c]?.jumpHostID
            }
        }
    }

    @Test func importedAliasHostDropsJumpHost() throws {
        let bastion = managedHost("bastion", hostName: "b.example.com")
        var alias = importedHost("legacy", alias: "web-u")
        alias.jumpHostID = bastion.id
        let data = try tampered(try export([bastion, importedHost("legacy", alias: "web-u")])) { rows in
            let i = rows.firstIndex { ($0["displayName"] as? String) == "legacy" }!
            rows[i]["jumpHostId"] = bastion.id.uuidString.lowercased()
        }
        let p = try plan(data)
        let imported = try #require(p.hosts.first { $0.displayName == "legacy" })
        #expect(imported.jumpHostID == nil)
    }

    // MARK: - Port forward

    @Test func forwardsFollowHostAndConflictsAreDroppedWithWarning() throws {
        let h = managedHost("db", hostName: "db.example.com")
        let ok = PortForward(hostID: h.id, name: "ok", localPort: 15432, remotePort: 5432)
        let taken = PortForward(hostID: h.id, name: "taken", localPort: 15433, remotePort: 5432)
        let bad = PortForward(hostID: h.id, name: "bad", localPort: 15434, remoteHost: "a b", remotePort: 1)
        let dupInFile = PortForward(hostID: h.id, name: "dup", localPort: 15432, remotePort: 80)
        let data = try tampered(try export([h], forwards: [ok, taken, dupInFile])) { rows in
            var f = rows[0]["portForwards"] as! [[String: Any]]
            f.append(["name": "bad", "localPort": bad.localPort, "remoteHost": "a b", "remotePort": 1])
            f.append(["name": "low", "localPort": 80, "remoteHost": "localhost", "remotePort": 80])
            rows[0]["portForwards"] = f
        }
        let existing = PortForward(hostID: UUID(), localPort: 15433, remotePort: 1)
        let p = try plan(data, forwards: [existing])
        #expect(p.forwards.map(\.localPort) == [15432])
        #expect(p.entries[0].warnings.count == 4)
        #expect(p.forwards.allSatisfy { $0.hostID == p.hosts[0].id })
    }

    @Test func forwardsOfSkippedDuplicateAreNotImportedAndWindowsForwardsDropped() throws {
        let existing = managedHost("db", hostName: "db.example.com")
        var dupe = existing
        dupe.id = UUID()
        let fw = PortForward(hostID: dupe.id, localPort: 15432, remotePort: 5432)
        let win = HostProfile(displayName: "W", kind: .windowsRDP, hostName: "10.0.0.9", port: 3389)
        let data = try tampered(try export([dupe, win], forwards: [fw])) { rows in
            let i = rows.firstIndex { ($0["displayName"] as? String) == "W" }!
            rows[i]["portForwards"] = [["name": "x", "localPort": 15999, "remoteHost": "localhost", "remotePort": 1]]
        }
        let p = try plan(data, existing: [existing])
        #expect(p.forwards.isEmpty)
        let w = try #require(p.entries.first { $0.displayName == "W" })
        #expect(w.warnings.contains { $0.contains("Windows") })
    }

    // MARK: - Thư mục, mật khẩu

    @Test func foldersMatchExistingSpellingAndKeepEmptyOnes() throws {
        let h = managedHost("x", hostName: "x.example.com", project: "ALPHA")
        let data = try export([h], folders: ["Trống", "alpha"])
        let p = try plan(data, folders: ["Alpha"])
        #expect(p.foldersToCreate == ["Trống"])
        #expect(p.hosts[0].project == "Alpha")
    }

    @Test func needsReauthProducesWarningAndKeepsAuthMethod() throws {
        var h = managedHost("pw", hostName: "pw.example.com")
        h.authMethod = .interactive
        h.credentialReference = "REF"
        let p = try plan(try export([h], reauth: [h.id]))
        #expect(p.hosts[0].authMethod == .interactive && p.hosts[0].credentialReference == nil)
        #expect(p.entries[0].warnings.contains { $0.contains("nhập lại mật khẩu") })
    }

    // MARK: - Transaction + DB

    @Test func applyImportWritesEverythingInOneTransactionAndRollsBackOnError() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        let repo = HostRepository(database: db)
        let forwards = PortForwardRepository(database: db)

        let bastion = managedHost("bastion", hostName: "b.example.com", project: "Alpha")
        let app = managedHost("app", hostName: "a.example.com", project: "Alpha", jump: bastion.id)
        let fw = PortForward(hostID: app.id, name: "pg", localPort: 15432, remotePort: 5432)
        let data = try export([app, bastion], forwards: [fw], folders: ["Alpha", "Trống"])

        // Lỗi giữa chừng: cổng 15432 đã bị forward khác chiếm mà kế hoạch (cũ) không biết.
        let other = managedHost("other", hostName: "o.example.com")
        try await repo.insert(other)
        try await forwards.add(PortForward(hostID: other.id, localPort: 15432, remotePort: 1))
        let stale = try plan(data)
        await #expect(throws: PortForwardError.self) { try await repo.applyImport(stale) }
        #expect(try await repo.all().map(\.displayName) == ["other"])
        #expect(try await repo.folders().isEmpty)
        #expect(try await forwards.all().count == 1)

        // Kế hoạch đúng: ghi hết, bastion trước.
        let good = try plan(data, existing: [other], forwards: try await forwards.all())
        #expect(good.forwards.isEmpty)  // cổng đụng → bỏ forward, vẫn nhập máy
        try await repo.applyImport(good)
        let all = try await repo.all()
        #expect(all.count == 3)
        let newApp = try #require(all.first { $0.displayName == "app" })
        let newBastion = try #require(all.first { $0.displayName == "bastion" })
        #expect(newApp.jumpHostID == newBastion.id)
        #expect(newApp.credentialReference == nil)
        #expect(try await repo.folders() == ["Alpha", "Trống"])
        #expect(try await repo.sshSpecs().contains { $0.jumpAlias == newBastion.sshAlias })
    }

    @Test func endToEndExportFromOneDatabaseImportIntoAnother() async throws {
        let t1 = HostTempDir()
        let t2 = HostTempDir()
        defer {
            t1.cleanup()
            t2.cleanup()
        }
        let db1 = try Database(url: t1.dbURL)
        let r1 = HostRepository(database: db1)
        let f1 = PortForwardRepository(database: db1)
        let bastion = managedHost("bastion", hostName: "b.example.com", project: "Alpha")
        var app = managedHost("app", hostName: "a.example.com", project: "Alpha", jump: bastion.id)
        app.credentialReference = "KEYCHAIN-REF-XYZ"
        try await r1.insert(bastion)
        try await r1.insert(app)
        try await f1.add(PortForward(hostID: app.id, name: "pg", localPort: 15432, remoteHost: "db", remotePort: 5432))
        let all = try await r1.all()
        let selected = HostExchange.exportSet(selected: [app], all: all)
        let data = try HostExchange.export(
            hosts: selected, forwards: try await f1.all(), folders: try await r1.folders(),
            needsReauth: [], now: now)
        #expect(!String(decoding: data, as: UTF8.self).contains("KEYCHAIN-REF-XYZ"))

        let db2 = try Database(url: t2.dbURL)
        let r2 = HostRepository(database: db2)
        let f2 = PortForwardRepository(database: db2)
        let p = try plan(data)
        try await r2.applyImport(p)
        #expect(try await r2.all().count == 2)
        #expect(try await f2.all().map(\.localPort) == [15432])
        // Nhập lần hai: toàn bộ là trùng → bỏ qua, không ghi thêm.
        let again = HostExchange.plan(
            file: try HostExchange.decode(data), existingHosts: try await r2.all(),
            existingFolders: try await r2.folders(), existingForwards: try await f2.all(), now: now)
        #expect(again.duplicateCount == 2 && again.hosts.isEmpty)
        try await r2.applyImport(again)
        #expect(try await r2.all().count == 2)
    }
}

@Test func connectionServiceApplyImportRegeneratesSSHConfigWithProxyJump() async throws {
    let dir = HostTempDir()
    defer { dir.cleanup() }
    let paths = AppPaths(baseDirectory: dir.url.appendingPathComponent("SSHDesk"))
    try paths.prepareDirectories()
    let repo = HostRepository(database: try Database(url: paths.databaseURL))
    let service = ConnectionService(
        repository: repo, appConfigURL: paths.sshConfigURL, userConfigPath: nil,
        launcher: WarpLauncher(tabConfigsDirectory: dir.url.appendingPathComponent("tabs")))
    let bastion = managedHost("bastion", hostName: "b.example.com")
    let app = managedHost("app", hostName: "a.example.com", jump: bastion.id)
    let data = try HostExchange.export(hosts: [app, bastion], forwards: [], folders: [])
    let plan = HostExchange.plan(
        file: try HostExchange.decode(data), existingHosts: [], existingFolders: [],
        existingForwards: [])
    try await service.applyImport(plan)
    let config = try String(contentsOf: paths.sshConfigURL, encoding: .utf8)
    let newApp = try #require(try await repo.all().first { $0.displayName == "app" })
    let newBastion = try #require(try await repo.all().first { $0.displayName == "bastion" })
    #expect(config.contains("Host \(newApp.sshAlias!)"))
    #expect(config.contains("ProxyJump \(newBastion.sshAlias!)"))
    #expect(!config.contains(bastion.id.uuidString.lowercased()))
}
