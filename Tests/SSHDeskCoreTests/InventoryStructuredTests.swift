import Foundation
import Testing

@testable import SSHDeskCore

private func ini(_ text: String) throws -> InventoryParseResult {
    try AnsibleInventory.parse(text: text, format: .ini, defaultUser: "tester")
}
private func yaml(_ text: String) throws -> InventoryParseResult {
    try AnsibleInventory.parse(text: text, format: .yaml, defaultUser: "tester")
}

private func rec(_ r: InventoryParseResult, _ name: String) throws -> InventoryRecord {
    try #require(r.records.first { $0.externalID == name })
}

private func tempFile(_ name: String, _ data: Data, dir: HostTempDir) throws -> URL {
    let url = dir.url.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - JSON

@Suite struct InventoryJSONSourceTests {
    private func export(_ hosts: [HostProfile], setNames: [UUID: String] = [:]) throws -> Data {
        try HostExchange.export(hosts: hosts, forwards: [], folders: [], setNames: setNames)
    }

    @Test func roundTripWithJumpAndCredentialSetHold() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let bastion = managedHost("bastion", hostName: "bastion.example.com", project: "Khách A", tags: ["edge"])
        var app = managedHost("app", hostName: "10.0.0.5", jump: bastion.id)
        app.environment = .prod
        app.credentialSetID = UUID()
        let data = try export([bastion, app], setNames: [app.credentialSetID!: "Bộ Khách A"])

        let parsed = try InventoryStructured.parseJSON(data)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.records.count == 2)
        let a = try rec(parsed, app.id.uuidString.lowercased())
        #expect(a.name == "app" && a.environment == .prod && a.credentialSetName == "Bộ Khách A")
        #expect(a.jumpRef == bastion.id.uuidString.lowercased())
        let b = try rec(parsed, bastion.id.uuidString.lowercased())
        #expect(b.folder == "Khách A" && b.tags == ["edge"])

        let src = InventorySource(name: "J", kind: .json, path: "/tmp/x.sshdesk.json")
        let plan = try InventorySync.plan(
            source: src, records: parsed.records, managesJump: true, existingHosts: [], credentialSets: [])
        #expect(plan.additions.count == 2 && plan.setsToCreate == ["Bộ Khách A"])
        let addApp = try #require(plan.additions.first { $0.host.displayName == "app" })
        let addBastion = try #require(plan.additions.first { $0.host.displayName == "bastion" })
        #expect(addApp.jumpHostID == addBastion.host.id)
        #expect(addApp.credentialSetName == "Bộ Khách A" && plan.holdCount == 1)

        let db = try Database(url: dir.dbURL)
        let repo = HostRepository(database: db)
        try await repo.applyInventory(plan)
        let stored = try #require(try await repo.all().first { $0.displayName == "app" })
        #expect(stored.autofillHold && stored.jumpHostID == addBastion.host.id && stored.externalID == a.externalID)
    }

    @Test func loadFromFileGivesFingerprintAndDetectsChange() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let url = try tempFile("a.sshdesk.json", try export([managedHost("w")]), dir: dir)
        let loaded = try InventoryStructured.load(url: url, kind: .json)
        #expect(loaded.result.records.count == 1)
        #expect(
            InventoryFile.detectChange(path: url.path, kind: .json, lastFingerprint: loaded.fingerprint) == .unchanged)
        try export([managedHost("w"), managedHost("x", hostName: "x.example.com")]).write(to: url)
        #expect(
            InventoryFile.detectChange(path: url.path, kind: .json, lastFingerprint: loaded.fingerprint) == .changed)
    }

    @Test func rejectsOversizeAndUnknownVersion() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let big = Data(repeating: 0x20, count: HostExchange.maxFileBytes + 1)
        #expect(throws: HostExchangeError.fileTooLarge(limit: HostExchange.maxFileBytes)) {
            try InventoryStructured.parseJSON(big)
        }
        let url = try tempFile("big.json", big, dir: dir)
        #expect(throws: SpreadsheetError.fileTooLarge(limitMB: 5)) {
            try InventoryStructured.load(url: url, kind: .json)
        }
        let v2 = Data(#"{"format":"sshdesk-hosts","version":2,"exportedAt":"x","folders":[],"hosts":[]}"#.utf8)
        #expect(throws: HostExchangeError.unsupportedVersion(2)) { try InventoryStructured.parseJSON(v2) }
        #expect(throws: HostExchangeError.wrongFormat) { try InventoryStructured.parseJSON(Data(#"{"a":1}"#.utf8)) }
    }

    @Test func badHostIsRowErrorOthersStillRead() throws {
        let good = managedHost("good", hostName: "good.example.com")
        var bad = managedHost("bad", hostName: "bad.example.com")
        bad.displayName = "line1\nline2"
        let parsed = try InventoryStructured.parseJSON(try export([good, bad]))
        #expect(parsed.records.map(\.name) == ["good"])
        #expect(parsed.errorCount == 1 && parsed.failedKeys == [bad.id.uuidString.lowercased()])
    }

    @Test func aliasHostsAreSkippedWithWarningNotMissing() throws {
        let parsed = try InventoryStructured.parseJSON(try export([importedHost("legacy"), managedHost("w")]))
        #expect(parsed.records.count == 1)
        #expect(parsed.issues.contains { $0.severity == .warning } && parsed.failedKeys.count == 1)
    }
}

// MARK: - Ansible INI

@Suite struct AnsibleINITests {
    @Test func varsLayeredHostOverGroupOverParentOverAll() throws {
        let r = try ini(
            """
            [all:vars]
            ansible_user=root
            ansible_port=2200

            [web]
            web1 ansible_host=10.0.0.1
            web2 ansible_host=10.0.0.2 ansible_user=deploy

            [web:vars]
            ansible_user=www
            ansible_port=2222

            [prod:children]
            web

            [prod:vars]
            ansible_user=prod
            ansible_ssh_port=2300
            ansible_host=1.1.1.1
            """)
        #expect(r.issues.isEmpty)
        let w1 = try rec(r, "web1")
        #expect(w1.user == "www" && w1.port == 2222 && w1.hostName == "10.0.0.1" && w1.tags == ["prod", "web"])
        let w2 = try rec(r, "web2")
        #expect(w2.user == "deploy" && w2.name == "web2")
    }

    @Test func missingAnsibleHostFallsBackToNameAndUngroupedIsNotTag() throws {
        let r = try ini("lone.example.com\n[db]\ndb1\n")
        let lone = try rec(r, "lone.example.com")
        #expect(lone.hostName == "lone.example.com" && lone.tags == [] && lone.port == 22 && lone.user == "tester")
        #expect(try rec(r, "db1").tags == ["db"])
    }

    @Test func nestedChildrenInheritFromGrandparent() throws {
        let r = try ini(
            """
            [a]
            h1
            [b:children]
            a
            [c:children]
            b
            [c:vars]
            ansible_user=cuser
            [b:vars]
            ansible_user=buser
            [a:vars]
            ansible_port=2022
            """)
        let h = try rec(r, "h1")
        #expect(h.user == "buser" && h.port == 2022 && h.tags == ["a", "b", "c"])
    }

    @Test func childrenCycleIsReportedAndDoesNotHang() throws {
        let r = try ini(
            """
            [a]
            h1
            [a:children]
            b
            [b:children]
            a
            [c:children]
            c
            """)
        #expect(r.issues.filter { $0.message.contains("vòng") }.count == 2)
        #expect(try rec(r, "h1").name == "h1")
    }

    @Test func rangesNumericPaddedAlphaAndStride() throws {
        let r = try ini("[g]\nweb[01:03]\ndb-[a:c]\nodd[1:7:2]\n")
        #expect(
            r.records.map(\.name) == [
                "web01", "web02", "web03", "db-a", "db-b", "db-c", "odd1", "odd3", "odd5", "odd7",
            ])
        let two = try ini("[g]\nn[1:2]-[a:b]\n")
        #expect(two.records.map(\.name) == ["n1-a", "n1-b", "n2-a", "n2-b"])
    }

    @Test func rangeLimitsAndInvalidRanges() throws {
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) { try ini("[g]\nh[1:5001]\n") }
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) { try ini("[g]\nh[1:100]-[1:100]\n") }
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) { try ini("[g]\nh[1:999999999]\n") }
        let ok = try ini("[g]\nh[1:5000]\n")
        #expect(ok.records.count == 5000)
        #expect(throws: InventoryError.tooManyRecords(limit: 5000)) { try ini("[g]\nh[1:5000]\nextra\n") }
        let reversed = try ini("[g]\nh[5:1]\n")
        #expect(reversed.records.isEmpty && reversed.errorCount == 1)
        // [::1] không phải khoảng: giữ nguyên văn bản.
        #expect(try AnsibleInventory.expand("a[::1]") == ["a[::1]"])
    }

    @Test func quotesCommentsAndHostPort() throws {
        let r = try ini(
            """
            # comment
            ; another
            [g]
            h1 ansible_host='10.1.1.1' ansible_user="bob" ansible_port=2201 # trailing
            h2:2022
            h3 ansible_ssh_common_args="-o X=Y # not a comment"
            """)
        #expect(r.issues.isEmpty)
        let h1 = try rec(r, "h1")
        #expect(h1.hostName == "10.1.1.1" && h1.user == "bob" && h1.port == 2201)
        #expect(try rec(r, "h2").port == 2022)
        #expect(r.records.count == 3)
    }

    @Test func passwordVariablesAreDroppedWarnedAndNeverStored() throws {
        let secret1 = "hunter2-ZZ"
        let r = try ini(
            """
            [all:vars]
            ansible_become_password=\(secret1)bp
            [g]
            h1 ansible_host=10.0.0.1 ansible_password=\(secret1)a ansible_ssh_pass="\(secret1)b" ansible_become_pass=\(secret1)c ansible_ssh_private_key_file=/Users/me/.ssh/id_rsa db_password=\(secret1)d
            """)
        #expect(r.records.count == 1)
        let dump = "\(r)"
        #expect(!dump.contains(secret1) && !dump.contains("id_rsa"))
        let warning = r.warnings.joined(separator: "\n")
        for k in [
            "ansible_password", "ansible_ssh_pass", "ansible_become_pass", "ansible_become_password", "db_password",
        ] {
            #expect(warning.contains(k))
        }
        #expect(warning.contains("ansible_ssh_private_key_file"))
    }

    @Test func controlCharsAndTemplatesAreRowErrors() throws {
        let r = try ini(
            "[g]\nbad ansible_user=\"a\u{07}b\"\nj ansible_host=\"{{ foo }}\"\nj2 ansible_host={{ foo }}\nport ansible_port=abc\nok ansible_host=10.0.0.9\n"
        )
        #expect(r.records.map(\.name) == ["ok"])
        #expect(r.failedKeys == ["bad", "j", "j2", "port"], "\(r.issues)")
        #expect(r.errorCount == 4)
    }

    @Test func syntaxProblemsAreIssuesWithLineNumbers() throws {
        let r = try ini("[g\nh1\n[x:weird]\nh2\n[ok]\nh3 broken\nh4 \"unterminated\n")
        #expect(r.issues.map(\.row) == [1, 3, 6, 7])
        #expect(r.records.isEmpty)
    }
}

// MARK: - Ansible YAML

@Suite struct AnsibleYAMLTests {
    @Test func standardInventoryStructure() throws {
        let r = try yaml(
            """
            ---
            # inventory
            all:
              hosts:
                lone:
                  ansible_host: 10.9.9.9
              vars:
                ansible_user: root
              children:
                web:
                  hosts:
                    web1:
                      ansible_host: 10.0.0.1
                      ansible_port: 2222   # comment
                    web[2:3]: ~
                  vars:
                    ansible_user: "www"
                db:
                  children:
                    db_primary:
                      hosts:
                        db1: {}
                        db2: null
                      vars:
                        ansible_ssh_user: 'dbadm'
            """)
        #expect(r.issues.isEmpty)
        #expect(r.records.map(\.name) == ["lone", "web1", "web2", "web3", "db1", "db2"])
        let lone = try rec(r, "lone")
        #expect(lone.hostName == "10.9.9.9" && lone.user == "root" && lone.tags == [])
        let w1 = try rec(r, "web1")
        #expect(w1.user == "www" && w1.port == 2222 && w1.tags == ["web"])
        #expect(try rec(r, "web3").user == "www")
        let d = try rec(r, "db1")
        #expect(d.user == "dbadm" && d.tags == ["db", "db_primary"] && d.hostName == "db1")
    }

    @Test func topLevelGroupsWithoutAllAndGroupReferencedBeforeDefinition() throws {
        let r = try yaml(
            """
            prod:
              children:
                web:
            web:
              hosts:
                w1:
            """)
        #expect(try rec(r, "w1").tags == ["prod", "web"])
    }

    @Test func vaultValuesAreDroppedAndParsingContinues() throws {
        let r = try yaml(
            """
            all:
              hosts:
                h1:
                  ansible_host: 10.0.0.1
                  ansible_password: !vault |
                      $ANSIBLE_VAULT;1.1;AES256
                      6162636465666768
                  ansible_user: bob
                  ansible_port: !vault inline-secret
                h2:
                  ansible_host: 10.0.0.2
              vars:
                ansible_become_pass: plain-secret-123
                ansible_ssh_private_key_file: /keys/id
            """)
        let h1 = try rec(r, "h1")
        #expect(h1.user == "bob" && h1.hostName == "10.0.0.1" && h1.port == 22)
        let dump = "\(r)"
        for leak in ["ANSIBLE_VAULT", "6162636465666768", "inline-secret", "plain-secret-123", "/keys/id"] {
            #expect(!dump.contains(leak))
        }
        #expect(r.warnings.contains { $0.contains("!vault") })
        #expect(r.warnings.contains { $0.contains("ansible_become_pass") })
        #expect(r.warnings.contains { $0.contains("ansible_ssh_private_key_file") })
    }

    private func syntaxLine(_ text: String) -> Int? {
        do {
            _ = try AnsibleInventory.parse(text: text, format: .yaml, defaultUser: "tester")
            return nil
        } catch let e as InventorySyntaxError { return e.line } catch { return -1 }
    }

    @Test func unsupportedFeaturesAreErrorsWithLineNumbers() {
        #expect(syntaxLine("all:\n  hosts:\n    h1: &anchor\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: *alias\n") == 3)
        #expect(syntaxLine("all:\n  hosts:\n    <<: base\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: !!str x\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: !custom x\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: |\n      text\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: >-\n      text\n") == 3)
        #expect(syntaxLine("all:\n  hosts:\n    - h1\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: {x: 1}\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: [1, 2]\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: 1\n    a: 2\n") == 4)
        #expect(syntaxLine("all:\n  hosts:\n    h1:\n   bad: 1\n") == 4)
        #expect(syntaxLine("all:\n  vars:\n    a: 'unterminated\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: b: c\n") == 3)
        #expect(syntaxLine("all:\n  vars:\n    a: b\n      continued\n") == 4)
        #expect(syntaxLine("a:\n---\nb:\n") == 2)
    }

    @Test func tabIndentIsAnErrorWithLine() {
        #expect(syntaxLine("all:\n\thosts:\n") == 2)
        #expect(syntaxLine("all:\n  hosts:\n  \tbad:\n") == 3)
    }

    @Test func escapesAndControlCharactersFlowToValidator() throws {
        let r = try yaml(
            """
            all:
              hosts:
                ok:
                  ansible_user: "a\\tb"
                nl:
                  ansible_user: "a\\nb"
                ok2:
                  ansible_user: "bob\\u0041"
            """)
        #expect(r.records.map(\.name) == ["ok2"])
        #expect(try rec(r, "ok2").user == "bobA")
        #expect(r.errorCount == 2 && r.failedKeys == ["ok", "nl"])
    }

    @Test func detectFormatByExtensionAndContent() {
        #expect(AnsibleInventory.detectFormat(text: "[a]\nh\n", fileName: "hosts") == .ini)
        #expect(AnsibleInventory.detectFormat(text: "all:\n  hosts:\n", fileName: "hosts") == .yaml)
        #expect(AnsibleInventory.detectFormat(text: "---\nall:\n", fileName: nil) == .yaml)
        #expect(AnsibleInventory.detectFormat(text: "h1 ansible_host=1.1.1.1\n", fileName: "inv") == .ini)
        #expect(AnsibleInventory.detectFormat(text: "[a]\n", fileName: "x.yml") == .yaml)
    }

    @Test func fileSizeLimitAndEncoding() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let big = try tempFile("inv", Data(repeating: 0x23, count: 5 * 1_048_576 + 1), dir: dir)
        #expect(throws: SpreadsheetError.fileTooLarge(limitMB: 5)) {
            try InventoryStructured.load(url: big, kind: .ansible)
        }
        let ok = try tempFile("inv2.ini", Data("[a]\nh1 ansible_host=10.0.0.1\n".utf8), dir: dir)
        let loaded = try InventoryStructured.load(url: ok, kind: .ansible)
        #expect(loaded.result.records.count == 1 && loaded.fingerprint.split(separator: "|").count == 3)
    }
}

// MARK: - Đồng bộ + cấu trúc

@Suite struct AnsibleSyncTests {
    @Test func changingAnsibleHostHoldsAutofillAndTagsMerge() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let db = try Database(url: dir.dbURL)
        let repo = HostRepository(database: db)
        let src = InventorySource(
            name: "Ansible", kind: .ansible, path: "/tmp/inv", folder: "AN", defaultEnvironment: .uat)

        func run(_ text: String) async throws -> InventorySyncPlan {
            let r = try ini(text)
            let plan = try InventorySync.plan(
                source: src, records: r.records, issues: r.issues, warnings: r.warnings, failedKeys: r.failedKeys,
                managesJump: false, existingHosts: try await repo.all(), credentialSets: [])
            try await repo.applyInventory(plan)
            return plan
        }
        let first = try await run("[web]\nw1 ansible_host=10.0.0.1\n")
        #expect(first.additions.count == 1 && first.holdCount == 0)
        var h = try #require(try await repo.all().first { $0.displayName == "w1" })
        #expect(h.tags == ["web"] && h.project == "AN" && h.environment == .uat && !h.autofillHold)
        h.tags.append("mine")
        try await repo.update(h)

        let same = try await run("[web]\nw1 ansible_host=10.0.0.1\n")
        #expect(!same.hasChanges && same.unchangedCount == 1)

        let second = try await run("[web]\n[db]\nw1 ansible_host=10.0.0.9\n")
        #expect(second.updates.count == 1 && second.updates[0].holdReason != nil)
        let after = try #require(try await repo.all().first { $0.displayName == "w1" })
        #expect(after.hostName == "10.0.0.9" && after.autofillHold)
        #expect(after.tags.contains("mine") && after.tags.contains("web") && after.tags.contains("db"))
    }
}

// MARK: - Không có process

@Suite struct StructuredNoProcessTests {
    @Test func parsersDoNotReferenceAnyProcessAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SSHDeskCore/Inventory")
        let forbidden = [
            "Process(", "BoundedProcess", "posix_spawn", "NSTask", "execv", "system(", "popen", "/bin/", "/usr/bin/",
            "ansible-inventory\"",
        ]
        for file in ["AnsibleInventory.swift", "AnsibleYAML.swift", "InventoryStructured.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in forbidden { #expect(!text.contains(word), "\(file) chứa \(word)") }
        }
    }
}

// MARK: - Giới hạn, hold, user mặc định (QA K4b)

@Suite struct StructuredHardeningTests {
    private func elapsed(_ body: () throws -> Void) rethrows -> TimeInterval {
        let t = Date()
        try body()
        return Date().timeIntervalSince(t)
    }

    @Test func hugeRepeatedRangePatternsAreRejectedFastAndLinearly() throws {
        let pattern = "a" + String(repeating: "[1:1]", count: 200_000)  // ~1 MB
        var r: InventoryParseResult?
        let t1 = try elapsed { r = try ini("[g]\n\(pattern)\n") }
        #expect(t1 < 5 && r?.records.isEmpty == true && r?.errorCount == 1)
        let brackets = "[g]\nx" + String(repeating: "[", count: 5_000_000) + "\n"
        let t2 = try elapsed { r = try ini(brackets) }
        #expect(t2 < 5 && r?.records.isEmpty == true)
        let y = "all:\n  hosts:\n    \(pattern):\n"
        let t3 = try elapsed { r = try yaml(y) }
        #expect(t3 < 5 && r?.errorCount == 1)
        #expect(throws: AnsibleInventory.PatternError.self) {
            try AnsibleInventory.expand("a[1:1][1:1][1:1][1:1][1:1][1:1][1:1][1:1][1:1]")
        }
        #expect(try AnsibleInventory.expand("a[1:2][1:2][1:2][1:2][1:2][1:2][1:2][1:2]").count == 256)
    }

    @Test func errorMessagesStripControlCharacters() throws {
        let r = try ini("[g]\nh[5\u{1B}:1]\nx ansible_password=1 \u{07}ansible_ssh_pass=2\n")
        for text in r.issues.map(\.message) + r.warnings {
            #expect(!text.unicodeScalars.contains { InventoryValidator.isControl($0) })
        }
    }

    @Test func tagsAreCappedDedupedCaseInsensitivelyAndAncestryIsBounded() throws {
        var text = "[g]\nh1\n"
        for i in 0..<150 { text += "[t\(i):children]\ng\n" }
        text += "[Web:children]\ng\n[web:children]\ng\n"
        let r = try ini(text)
        let tags = try #require(try rec(r, "h1").tags)
        #expect(tags.count == 100)
        #expect(Set(tags.map { $0.lowercased() }).count == tags.count)
        #expect(r.warnings.contains { $0.contains("100 tag") })

        // Chuỗi group rất sâu + nhiều host: phải xong nhanh và báo cắt.
        var deep = ""
        for i in 0..<3000 { deep += "[c\(i + 1):children]\nc\(i)\n" }
        for i in 0..<3000 { deep += "[c\(i)]\nhost\(i)\n" }
        var d: InventoryParseResult?
        let t = try elapsed { d = try ini(deep) }
        #expect(t < 10 && d?.records.count == 3000)
        #expect(d?.warnings.contains { $0.contains("quá lớn/sâu") } == true)
    }

    @Test func yamlNestingBeyondLimitIsErrorWithMessage() {
        var text = ""
        for i in 0..<45 { text += String(repeating: " ", count: i * 2) + "k\(i):\n" }
        do {
            _ = try yaml(text)
            Issue.record("phải lỗi")
        } catch let e as InventorySyntaxError {
            #expect(e.message.contains("quá sâu") && e.line > 0)
        } catch { Issue.record("sai kiểu lỗi \(error)") }
    }

    @Test func missingAnsibleUserOnlyDefaultsForNewHosts() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let repo = HostRepository(database: try Database(url: dir.dbURL))
        let src = InventorySource(name: "A", kind: .ansible, path: "/tmp/i")
        func run(_ text: String, apply: Bool = true) async throws -> InventorySyncPlan {
            let r = try ini(text)
            let plan = try InventorySync.plan(
                source: src, records: r.records, managesJump: false, existingHosts: try await repo.all(),
                credentialSets: [])
            if apply { try await repo.applyInventory(plan) }
            return plan
        }
        _ = try await run("[g]\nh1 ansible_host=10.0.0.1 ansible_user=alice\nh2 ansible_host=10.0.0.2\n")
        let h2 = try #require(try await repo.all().first { $0.displayName == "h2" })
        #expect(h2.user == "tester")
        // File không còn khai báo user của h1 -> không đổi, không hold.
        let plan = try await run("[g]\nh1 ansible_host=10.0.0.1\nh2 ansible_host=10.0.0.2\n")
        #expect(!plan.hasChanges && plan.unchangedCount == 2)
        let h1 = try #require(try await repo.all().first { $0.displayName == "h1" })
        #expect(h1.user == "alice" && !h1.autofillHold)
        // Có khai báo user khác -> đổi + hold.
        let changed = try await run("[g]\nh1 ansible_host=10.0.0.1 ansible_user=bob\nh2 ansible_host=10.0.0.2\n")
        #expect(changed.updates.count == 1 && changed.updates[0].holdReason?.contains("User") == true)
    }

    @Test func ansiblePortChangeHolds() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let repo = HostRepository(database: try Database(url: dir.dbURL))
        let src = InventorySource(name: "A", kind: .ansible, path: "/tmp/i")
        func run(_ text: String) async throws -> InventorySyncPlan {
            let r = try ini(text)
            let plan = try InventorySync.plan(
                source: src, records: r.records, managesJump: false, existingHosts: try await repo.all(),
                credentialSets: [])
            try await repo.applyInventory(plan)
            return plan
        }
        _ = try await run("[g]\nh1 ansible_user=u\n")
        let p = try await run("[g]\nh1 ansible_user=u ansible_port=2222\n")
        #expect(p.updates.count == 1 && p.updates[0].holdReason?.contains("Port 22 → 2222") == true)
        let stored = try #require(try await repo.all().first { $0.displayName == "h1" })
        #expect(stored.autofillHold && stored.port == 2222)
    }

    @Test func jsonEachAddressFieldChangeHoldsButNotesDoNot() async throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let repo = HostRepository(database: try Database(url: dir.dbURL))
        let src = InventorySource(name: "J", kind: .json, path: "/tmp/x.sshdesk.json")
        let bastion = managedHost("bastion", hostName: "b.example.com")
        let other = managedHost("other", hostName: "o.example.com")
        let app = managedHost("app", hostName: "10.0.0.5", jump: bastion.id)
        func plan(_ hosts: [HostProfile], apply: Bool) async throws -> InventorySyncPlan {
            let data = try HostExchange.export(hosts: hosts, forwards: [], folders: [])
            let parsed = try InventoryStructured.parseJSON(data)
            let p = try InventorySync.plan(
                source: src, records: parsed.records, managesJump: true, existingHosts: try await repo.all(),
                credentialSets: [])
            if apply { try await repo.applyInventory(p) }
            return p
        }
        _ = try await plan([bastion, other, app], apply: true)
        var host = app
        host.hostName = "10.0.0.6"
        var port = app
        port.port = 2200
        var user = app
        user.user = "someone"
        var jump = app
        jump.jumpHostID = other.id
        var notes = app
        notes.notes = "ghi chú mới"
        for (label, changed, expectHold) in [
            ("hostName", host, true), ("port", port, true), ("user", user, true), ("jump", jump, true),
            ("notes", notes, false),
        ] {
            let p = try await plan([bastion, other, changed], apply: false)
            let u = try #require(p.updates.first, "\(label)")
            #expect((u.holdReason != nil) == expectHold, "\(label)")
        }
    }
}
