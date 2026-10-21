import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable {
    /// File không phải SQLite hợp lệ hoặc dữ liệu hỏng. File được giữ nguyên.
    case corrupt(String)
    /// schema_version trong file cao hơn phiên bản app biết. File được giữ nguyên.
    case newerSchema(found: Int, supported: Int)
    case sqlite(code: Int32, message: String)
    case cannotCreate(String)
}

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
}

/// Bọc một kết nối SQLite. Mọi truy cập đi qua khoá đệ quy nên an toàn khi dùng từ nhiều luồng.
public final class Database: @unchecked Sendable {
    struct Migration {
        let statements: [String]
    }

    /// Migration tuần tự: phần tử i đưa DB từ version i lên i+1.
    static let migrations: [Migration] = [
        Migration(statements: [
            """
            CREATE TABLE hosts (
                id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                project TEXT NOT NULL,
                environment TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                notes TEXT NOT NULL,
                is_favorite INTEGER NOT NULL,
                connection_mode TEXT NOT NULL,
                host_name TEXT NOT NULL,
                port INTEGER NOT NULL,
                user TEXT NOT NULL,
                auth_method TEXT NOT NULL,
                identity_file TEXT,
                jump_host_id TEXT REFERENCES hosts(id) ON DELETE RESTRICT,
                ssh_config_path TEXT,
                ssh_config_alias TEXT,
                credential_reference TEXT,
                bookmarks_json TEXT NOT NULL,
                default_local_directory TEXT NOT NULL,
                default_remote_directory TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_launch_requested_at REAL
            )
            """,
            "CREATE INDEX idx_hosts_jump ON hosts(jump_host_id)",
        ]),
        // v2: lịch sử/queue truyền file. Không có FK tới hosts để lịch sử sống sau khi xoá host.
        // Tuyệt đối không có cột password/passphrase/otp/transcript.
        Migration(statements: [
            """
            CREATE TABLE transfer_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                host_id TEXT NOT NULL,
                host_display_name TEXT NOT NULL,
                target_snapshot TEXT NOT NULL,
                ssh_alias_snapshot TEXT NOT NULL,
                config_path_snapshot TEXT NOT NULL,
                direction TEXT NOT NULL,
                source_path TEXT NOT NULL,
                destination_path TEXT NOT NULL,
                item_kind TEXT NOT NULL,
                overwrite_policy TEXT NOT NULL,
                overwrite_new_name TEXT,
                state TEXT NOT NULL,
                created_at REAL NOT NULL,
                started_at REAL,
                finished_at REAL,
                progress_bytes INTEGER,
                progress_fraction REAL,
                progress_bytes_per_second REAL,
                exit_kind TEXT,
                exit_value INTEGER,
                failure_reason TEXT,
                previous_attempt_id TEXT,
                temp_partial_path TEXT,
                seq INTEGER NOT NULL
            )
            """,
            "CREATE INDEX idx_transfer_jobs_seq ON transfer_jobs(seq)",
        ]),
        // v3: thư mục rỗng (chưa có host nào). Thư mục có host suy ra từ hosts.project.
        Migration(statements: [
            "CREATE TABLE host_folders (name TEXT PRIMARY KEY NOT NULL)"
        ]),
    ]

    private static let sqliteMagic = Data("SQLite format 3\0".utf8)

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    public convenience init(url: URL) throws {
        try self.init(url: url, migrations: Database.migrations)
    }

    init(url: URL, migrations: [Migration]) throws {
        let fm = FileManager.default
        let path = url.path

        if fm.fileExists(atPath: path) {
            // Kiểm tra header trước khi mở: tránh SQLite coi file rác ngắn là DB rỗng rồi ghi đè.
            try Self.requireSQLiteHeader(path: path)
        } else {
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(
                        at: dir, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                } catch { throw DatabaseError.cannotCreate("\(error)") }
            }
            guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw DatabaseError.cannotCreate(path) }
        }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw DatabaseError.sqlite(code: rc, message: msg)
        }
        self.handle = db
        do {
            try prepareAndMigrate(migrations)
        } catch {
            sqlite3_close(db)
            self.handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    private static func requireSQLiteHeader(path: String) throws {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw DatabaseError.cannotCreate("không đọc được \(path)")
        }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 16)) ?? Data()
        // File rỗng là DB SQLite hợp lệ (chưa có gì).
        if head.isEmpty { return }
        if head != sqliteMagic { throw DatabaseError.corrupt("không phải file SQLite") }
    }

    private func prepareAndMigrate(_ migrations: [Migration]) throws {
        // Kiểm tra đọc được và schema_version TRƯỚC khi bật WAL hay ghi bất cứ gì.
        let version: Int
        let tables = try query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'")
        if tables.isEmpty {
            version = 0
        } else {
            version = try schemaVersion()
        }
        if version > migrations.count {
            throw DatabaseError.newerSchema(found: version, supported: migrations.count)
        }

        try execute("PRAGMA foreign_keys=ON")
        _ = try query("PRAGMA journal_mode=WAL")

        if version == migrations.count { return }
        for target in version..<migrations.count {
            try transaction {
                if target == 0 {
                    try execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
                    try execute("INSERT INTO schema_version(version) VALUES (0)")
                }
                for sql in migrations[target].statements { try execute(sql) }
                try execute("UPDATE schema_version SET version = ?", [.int(Int64(target + 1))])
            }
        }
    }

    // MARK: - Truy cập

    func schemaVersion() throws -> Int {
        let rows = try query("SELECT MAX(version) FROM schema_version")
        if case .int(let v)? = rows.first?.first { return Int(v) }
        return 0
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        _ = try run(sql, params)
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        try run(sql, params)
    }

    private func run(_ sql: String, _ params: [SQLValue]) throws -> [[SQLValue]] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.sqlite(code: SQLITE_MISUSE, message: "closed") }
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            }
            guard rc == SQLITE_OK else { throw error(rc) }
        }

        var rows: [[SQLValue]] = []
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func error(_ code: Int32) -> DatabaseError {
        let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? ""
        if code == SQLITE_NOTADB || code == SQLITE_CORRUPT { return .corrupt(msg) }
        return .sqlite(code: code, message: msg)
    }
}
