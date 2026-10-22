import Foundation

/// Lưu forward trong SQLite (bảng `port_forwards`, migration v6). Mọi giá trị đi qua tham số bind.
public actor PortForwardRepository {
    private let db: Database
    private let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = database
        self.now = now
    }

    static let columns = "id, host_id, name, local_port, remote_host, remote_port, created_at"

    // MARK: - Đọc

    public func all() throws -> [PortForward] {
        try db.query("SELECT \(Self.columns) FROM port_forwards ORDER BY local_port").map(Self.decode)
    }

    public func forwards(hostID: UUID) throws -> [PortForward] {
        try db.query(
            "SELECT \(Self.columns) FROM port_forwards WHERE host_id = ? ORDER BY local_port",
            [.text(hostID.uuidString)]
        ).map(Self.decode)
    }

    public func forward(id: UUID) throws -> PortForward? {
        try db.query(
            "SELECT \(Self.columns) FROM port_forwards WHERE id = ?", [.text(id.uuidString)]
        ).first.map(Self.decode)
    }

    // MARK: - Ghi

    /// Thêm forward. Trả bản đã chuẩn hoá. `createdAt` do repository đặt.
    @discardableResult
    public func add(_ forward: PortForward) throws -> PortForward {
        var f = try forward.validated()
        f.createdAt = now()
        try db.transaction {
            try Self.checkHost(db, f.hostID)
            try Self.checkPortFree(db, f.localPort, excluding: nil)
            try Self.insertRow(db, f)
        }
        return f
    }

    /// Sửa forward (đổi tên, cổng, đích). Không đổi `hostID`/`createdAt`.
    @discardableResult
    public func update(_ forward: PortForward) throws -> PortForward {
        var f = try forward.validated()
        return try db.transaction {
            guard let stored = try self.forward(id: f.id) else {
                throw PortForwardError.notFound(f.id)
            }
            f.hostID = stored.hostID
            f.createdAt = stored.createdAt
            try Self.checkPortFree(db, f.localPort, excluding: f.id)
            try db.execute(
                """
                UPDATE port_forwards SET name = ?, local_port = ?, remote_host = ?, remote_port = ?
                WHERE id = ?
                """,
                [
                    .text(f.name), .int(Int64(f.localPort)), .text(f.remoteHost),
                    .int(Int64(f.remotePort)), .text(f.id.uuidString),
                ])
            return f
        }
    }

    public func delete(id: UUID) throws {
        try db.transaction {
            guard try forward(id: id) != nil else { throw PortForwardError.notFound(id) }
            try db.execute("DELETE FROM port_forwards WHERE id = ?", [.text(id.uuidString)])
        }
    }

    // MARK: - Dùng chung với import (cùng transaction của HostRepository)

    static func checkHost(_ db: Database, _ hostID: UUID) throws {
        let rows = try db.query("SELECT kind FROM hosts WHERE id = ?", [.text(hostID.uuidString)])
        guard case .text(let kind)? = rows.first?.first else {
            throw PortForwardError.hostNotFound(hostID)
        }
        guard kind == HostKind.ssh.rawValue else { throw PortForwardError.hostNotSupported(hostID) }
    }

    static func checkPortFree(_ db: Database, _ port: Int, excluding: UUID?) throws {
        let rows = try db.query(
            "SELECT id FROM port_forwards WHERE local_port = ?", [.int(Int64(port))])
        if case .text(let s)? = rows.first?.first, let other = UUID(uuidString: s), other != excluding {
            throw PortForwardError.localPortTaken(port: port, usedBy: other)
        }
    }

    /// `f` đã `validated()`.
    static func insertRow(_ db: Database, _ f: PortForward) throws {
        try db.execute(
            "INSERT INTO port_forwards (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                .text(f.id.uuidString), .text(f.hostID.uuidString), .text(f.name),
                .int(Int64(f.localPort)), .text(f.remoteHost), .int(Int64(f.remotePort)),
                .real(f.createdAt.timeIntervalSince1970),
            ])
    }

    private static func decode(_ row: [SQLValue]) throws -> PortForward {
        func bad() -> DatabaseError { .corrupt("hàng port_forwards không hợp lệ") }
        guard row.count == 7,
            case .text(let id) = row[0], let uuid = UUID(uuidString: id),
            case .text(let hid) = row[1], let hostID = UUID(uuidString: hid),
            case .text(let name) = row[2], case .int(let lp) = row[3],
            case .text(let rh) = row[4], case .int(let rp) = row[5]
        else { throw bad() }
        let created: Date
        switch row[6] {
        case .real(let v): created = Date(timeIntervalSince1970: v)
        case .int(let v): created = Date(timeIntervalSince1970: Double(v))
        default: throw bad()
        }
        return PortForward(
            id: uuid, hostID: hostID, name: name, localPort: Int(lp), remoteHost: rh,
            remotePort: Int(rp), createdAt: created)
    }
}
