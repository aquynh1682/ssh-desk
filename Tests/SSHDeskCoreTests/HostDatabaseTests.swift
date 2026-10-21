import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import SSHDeskCore

@Suite struct HostDatabaseTests {
    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func perms(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func freshDatabaseMigratesAndHasSecurePermissions() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        #expect(try db.schemaVersion() == Database.migrations.count)
        #expect(try perms(t.dbURL) == 0o600)
        #expect(try perms(t.dbURL.deletingLastPathComponent()) == 0o700)
        let fk = try db.query("PRAGMA foreign_keys")
        #expect(fk.first?.first == .int(1))
        let jm = try db.query("PRAGMA journal_mode")
        #expect(jm.first?.first == .text("wal"))
    }

    @Test func schemaHasNoSecretColumns() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        let rows = try db.query("PRAGMA table_info(hosts)")
        let names = rows.compactMap { r -> String? in
            if case .text(let s) = r[1] { return s.lowercased() } else { return nil }
        }
        #expect(names.count > 10)
        for n in names {
            #expect(!n.contains("password") && !n.contains("passphrase") && !n.contains("secret"))
        }
    }

    @Test func simulatedV1DatabaseOpensAndKeepsData() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        // Dựng DB v1 bằng đúng migration đầu tiên, chèn một hàng, đóng lại.
        let id = UUID()
        do {
            let db = try Database(url: t.dbURL)
            try db.execute(
                """
                INSERT INTO hosts (id, display_name, project, environment, tags_json, notes,
                  is_favorite, connection_mode, host_name, port, user, auth_method,
                  bookmarks_json, default_local_directory, default_remote_directory,
                  created_at, updated_at)
                VALUES (?, 'old', '', 'DEV', '[]', '', 0, 'managed', 'h.example.com', 22, 'u',
                  'agent', '[]', '', '', 1, 1)
                """, [.text(id.uuidString)])
        }
        let db2 = try Database(url: t.dbURL)
        #expect(try db2.schemaVersion() == Database.migrations.count)
        #expect(try db2.query("SELECT COUNT(*) FROM hosts").first?.first == .int(1))
    }

    @Test func sequentialMigrationRunsOnlyNewSteps() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        _ = try Database(url: t.dbURL)
        let v2 =
            Database.migrations + [
                Database.Migration(statements: ["ALTER TABLE hosts ADD COLUMN extra TEXT"])
            ]
        let db = try Database(url: t.dbURL, migrations: v2)
        #expect(try db.schemaVersion() == Database.migrations.count + 1)
        #expect(try db.query("SELECT extra FROM hosts").isEmpty)
    }

    @Test func failedMigrationRollsBack() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        _ = try Database(url: t.dbURL)
        let bad =
            Database.migrations + [
                Database.Migration(statements: [
                    "CREATE TABLE tmp_a (x INTEGER)", "THIS IS NOT SQL",
                ])
            ]
        #expect(throws: DatabaseError.self) { _ = try Database(url: t.dbURL, migrations: bad) }
        let db = try Database(url: t.dbURL)
        #expect(try db.schemaVersion() == Database.migrations.count)
        #expect(
            try db.query("SELECT name FROM sqlite_master WHERE name='tmp_a'").isEmpty)
    }

    @Test(arguments: [
        Data("this is definitely not sqlite, just some text".utf8),
        Data("x".utf8),
        Data(repeating: 0xAB, count: 4096),
    ])
    func garbageFileIsCorruptAndUntouched(content: Data) throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        try FileManager.default.createDirectory(
            at: t.dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: t.dbURL)
        let before = try hash(t.dbURL)
        do {
            _ = try Database(url: t.dbURL)
            Issue.record("phải ném lỗi")
        } catch let DatabaseError.corrupt(_) {
        }
        #expect(try hash(t.dbURL) == before)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: t.dbURL.deletingLastPathComponent().path)
        #expect(siblings == ["sshdesk.sqlite"])
    }

    @Test func newerSchemaIsRejectedAndUntouched() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        do {
            let db = try Database(url: t.dbURL)
            try db.execute("UPDATE schema_version SET version = 99")
        }
        // Checkpoint WAL xảy ra khi đóng kết nối cuối; hash sau khi đóng.
        let before = try hash(t.dbURL)
        do {
            _ = try Database(url: t.dbURL)
            Issue.record("phải ném lỗi")
        } catch let DatabaseError.newerSchema(found, supported) {
            #expect(found == 99 && supported == Database.migrations.count)
        }
        #expect(try hash(t.dbURL) == before)
    }
}
