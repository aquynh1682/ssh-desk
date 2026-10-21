import Foundation

public enum TransferRepositoryError: Error, Equatable {
    case notFound(UUID)
    case duplicateID(UUID)
    case notRetryable(TransferState)
}

public actor TransferRepository {
    public static let defaultRetention = 500

    private let db: Database
    private let retention: Int
    private let now: @Sendable () -> Date

    public init(
        database: Database, retention: Int = TransferRepository.defaultRetention,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = database
        self.retention = max(1, retention)
        self.now = now
    }

    private static let columns = """
        id, host_id, host_display_name, target_snapshot, ssh_alias_snapshot, config_path_snapshot, \
        direction, source_path, destination_path, item_kind, overwrite_policy, overwrite_new_name, \
        state, created_at, started_at, finished_at, progress_bytes, progress_fraction, \
        progress_bytes_per_second, exit_kind, exit_value, failure_reason, previous_attempt_id, \
        temp_partial_path
        """

    private static let terminalList = "('completed','failed','cancelled','interrupted')"

    // MARK: - Đọc

    public func job(id: UUID) throws -> TransferJob? {
        try db.query(
            "SELECT \(Self.columns) FROM transfer_jobs WHERE id = ?", [.text(id.uuidString)]
        ).first.map(Self.decode)
    }

    /// Mới nhất trước.
    public func history(limit: Int = TransferRepository.defaultRetention) throws -> [TransferJob] {
        try db.query(
            "SELECT \(Self.columns) FROM transfer_jobs ORDER BY seq DESC LIMIT ?",
            [.int(Int64(max(0, limit)))]
        ).map(Self.decode)
    }

    // MARK: - Ghi

    public func insert(_ job: TransferJob) throws {
        try db.transaction { try insertLocked(job) }
    }

    /// Phải gọi trong transaction.
    private func insertLocked(_ job: TransferJob) throws {
        do {
            if try db.query(
                "SELECT 1 FROM transfer_jobs WHERE id = ?", [.text(job.id.uuidString)]
            ).first != nil {
                throw TransferRepositoryError.duplicateID(job.id)
            }
            let seq = try nextSeq()
            let p = Self.encode(job)
            try db.execute(
                """
                INSERT INTO transfer_jobs (\(Self.columns), seq)
                VALUES (\(Array(repeating: "?", count: p.count + 1).joined(separator: ",")))
                """, p + [.int(seq)])
            try prune()
        }
    }

    /// Chuyển state theo máy trạng thái. Tự đặt `startedAt` (lần đầu vào connecting) và
    /// `finishedAt` (khi vào trạng thái kết thúc). `failureReason` luôn được làm sạch.
    @discardableResult
    public func transition(
        id: UUID, to new: TransferState, exit: TransferExitStatus? = nil,
        failureReason: String? = nil
    ) throws -> TransferJob {
        try db.transaction {
            guard var job = try self.job(id: id) else { throw TransferRepositoryError.notFound(id) }
            job.state = try TransferStateMachine.transition(from: job.state, to: new)
            let t = now()
            if new == .connecting, job.startedAt == nil { job.startedAt = t }
            if new.isTerminal { job.finishedAt = t }
            if let exit { job.exitStatus = exit }
            if let failureReason { job.failureReason = TransferJob.sanitizeReason(failureReason) }
            try write(job)
            return job
        }
    }

    public func updateProgress(id: UUID, _ progress: TransferProgress) throws {
        try db.transaction {
            try requireExists(id)
            try db.execute(
                """
                UPDATE transfer_jobs SET progress_bytes = ?, progress_fraction = ?,
                  progress_bytes_per_second = ? WHERE id = ?
                """,
                [
                    progress.bytes.map { .int($0) } ?? .null,
                    progress.fraction.map { .real($0) } ?? .null,
                    progress.bytesPerSecond.map { .real($0) } ?? .null,
                    .text(id.uuidString),
                ])
        }
    }

    public func setTempPartialPath(id: UUID, _ path: String?) throws {
        try db.transaction {
            try requireExists(id)
            try db.execute(
                "UPDATE transfer_jobs SET temp_partial_path = ? WHERE id = ?",
                [path.map { .text($0) } ?? .null, .text(id.uuidString)])
        }
    }

    /// Chỉ xoá BẢN GHI đã kết thúc; không đụng job đang chạy, không đụng file nào trên đĩa.
    @discardableResult
    public func clearHistory() throws -> Int {
        try db.transaction {
            let n = try db.query(
                "SELECT COUNT(*) FROM transfer_jobs WHERE state IN \(Self.terminalList)")
            try db.execute("DELETE FROM transfer_jobs WHERE state IN \(Self.terminalList)")
            if case .int(let c)? = n.first?.first { return Int(c) }
            return 0
        }
    }

    /// Sau crash/restart: MỌI job chưa kết thúc, kể cả `queued`, chuyển sang `interrupted`.
    /// Quyết định: `queued` cũng bị gián đoạn để app không tự chạy lại (và ghi lên server)
    /// sau khi khởi động; người dùng bấm thử lại thủ công. Trả về các job đã đổi để
    /// caller dọn `.part` (qua `LocalFinalizer.cleanupPartial`).
    @discardableResult
    public func recoverInterrupted() throws -> [TransferJob] {
        try db.transaction {
            let rows = try db.query(
                """
                SELECT \(Self.columns) FROM transfer_jobs
                WHERE state NOT IN \(Self.terminalList) ORDER BY seq
                """
            ).map(Self.decode)
            let t = now()
            var result: [TransferJob] = []
            for var job in rows {
                job.state = try TransferStateMachine.transition(from: job.state, to: .interrupted)
                job.finishedAt = t
                job.failureReason = "Bị gián đoạn do app thoát hoặc gặp sự cố"
                try write(job)
                result.append(job)
            }
            return result
        }
    }

    /// Tạo job MỚI (id mới, queued, `previousAttemptID` = job cũ). Job cũ giữ nguyên.
    /// Chỉ cho job failed/cancelled/interrupted. Giữ nguyên `overwritePolicy` đã xác nhận —
    /// UI nên kiểm tra lại xung đột local trước khi đưa vào queue.
    @discardableResult
    public func retry(jobID: UUID, newID: UUID = UUID()) throws -> TransferJob {
        try db.transaction {
            guard let old = try job(id: jobID) else { throw TransferRepositoryError.notFound(jobID) }
            switch old.state {
            case .failed, .cancelled, .interrupted: break
            default: throw TransferRepositoryError.notRetryable(old.state)
            }
            var new = old
            new.id = newID
            new.state = .queued
            new.createdAt = now()
            new.startedAt = nil
            new.finishedAt = nil
            new.progress = TransferProgress()
            new.exitStatus = nil
            new.failureReason = nil
            new.previousAttemptID = old.id
            new.tempPartialPath = nil
            try insertLocked(new)
            return new
        }
    }

    // MARK: - Nội bộ

    private func requireExists(_ id: UUID) throws {
        if try db.query("SELECT 1 FROM transfer_jobs WHERE id = ?", [.text(id.uuidString)]).first
            == nil
        {
            throw TransferRepositoryError.notFound(id)
        }
    }

    private func nextSeq() throws -> Int64 {
        if case .int(let m)? = try db.query("SELECT MAX(seq) FROM transfer_jobs").first?.first {
            return m + 1
        }
        return 1
    }

    /// Giữ N bản ghi mới nhất; chỉ xoá bản ghi đã kết thúc.
    private func prune() throws {
        try db.execute(
            """
            DELETE FROM transfer_jobs WHERE state IN \(Self.terminalList) AND id NOT IN
              (SELECT id FROM transfer_jobs ORDER BY seq DESC LIMIT ?)
            """, [.int(Int64(retention))])
    }

    private func write(_ job: TransferJob) throws {
        let p = Self.encode(job)
        let cols = Self.columns.replacingOccurrences(of: "\\\n", with: "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let sets = cols.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
        try db.execute(
            "UPDATE transfer_jobs SET \(sets) WHERE id = ?", Array(p.dropFirst()) + [p[0]])
    }

    private static func encode(_ j: TransferJob) -> [SQLValue] {
        func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
        func date(_ d: Date?) -> SQLValue { d.map { .real($0.timeIntervalSince1970) } ?? .null }
        let policy: String
        var newName: String?
        switch j.overwritePolicy {
        case .overwrite: policy = "overwrite"
        case .skip: policy = "skip"
        case .rename(let n):
            policy = "rename"
            newName = n
        }
        var exitKind: String?
        var exitValue: Int64?
        switch j.exitStatus {
        case .exited(let c)?: (exitKind, exitValue) = ("exited", Int64(c))
        case .signaled(let s)?: (exitKind, exitValue) = ("signaled", Int64(s))
        case .cancelled?: exitKind = "cancelled"
        case nil: break
        }
        return [
            .text(j.id.uuidString), .text(j.hostID.uuidString), .text(j.hostDisplayNameSnapshot),
            .text(j.targetSnapshot), .text(j.sshAliasSnapshot), .text(j.configPathSnapshot),
            .text(j.direction.rawValue), .text(j.sourcePath), .text(j.destinationPath),
            .text(j.itemKind.rawValue), .text(policy), opt(newName), .text(j.state.rawValue),
            .real(j.createdAt.timeIntervalSince1970), date(j.startedAt), date(j.finishedAt),
            j.progress.bytes.map { .int($0) } ?? .null,
            j.progress.fraction.map { .real($0) } ?? .null,
            j.progress.bytesPerSecond.map { .real($0) } ?? .null,
            opt(exitKind), exitValue.map { .int($0) } ?? .null,
            opt(j.failureReason.map(TransferJob.sanitizeReason)),
            opt(j.previousAttemptID?.uuidString), opt(j.tempPartialPath),
        ]
    }

    private static func decode(_ r: [SQLValue]) throws -> TransferJob {
        func text(_ i: Int) throws -> String {
            guard case .text(let s) = r[i] else { throw DatabaseError.corrupt("transfer_jobs[\(i)]") }
            return s
        }
        func optText(_ i: Int) -> String? { if case .text(let s) = r[i] { return s } else { return nil } }
        func real(_ i: Int) -> Double? {
            switch r[i] {
            case .real(let v): return v
            case .int(let v): return Double(v)
            default: return nil
            }
        }
        func int(_ i: Int) -> Int64? { if case .int(let v) = r[i] { return v } else { return nil } }
        func uuid(_ s: String) throws -> UUID {
            guard let u = UUID(uuidString: s) else { throw DatabaseError.corrupt("uuid \(s)") }
            return u
        }
        guard let direction = TransferDirection(rawValue: try text(6)),
            let kind = TransferItemKind(rawValue: try text(9)),
            let state = TransferState(rawValue: try text(12)),
            let created = real(13)
        else { throw DatabaseError.corrupt("transfer_jobs enum") }
        let policy: OverwritePolicy
        switch try text(10) {
        case "overwrite": policy = .overwrite
        case "skip": policy = .skip
        case "rename": policy = .rename(optText(11) ?? "")
        default: throw DatabaseError.corrupt("overwrite_policy")
        }
        var exit: TransferExitStatus?
        switch optText(19) {
        case "exited": exit = .exited(Int32(truncatingIfNeeded: int(20) ?? 0))
        case "signaled": exit = .signaled(Int32(truncatingIfNeeded: int(20) ?? 0))
        case "cancelled": exit = .cancelled
        default: exit = nil
        }
        return TransferJob(
            id: try uuid(try text(0)), hostID: try uuid(try text(1)),
            hostDisplayNameSnapshot: try text(2), targetSnapshot: try text(3),
            sshAliasSnapshot: try text(4), configPathSnapshot: try text(5), direction: direction,
            sourcePath: try text(7), destinationPath: try text(8), itemKind: kind,
            overwritePolicy: policy, state: state, createdAt: Date(timeIntervalSince1970: created),
            startedAt: real(14).map { Date(timeIntervalSince1970: $0) },
            finishedAt: real(15).map { Date(timeIntervalSince1970: $0) },
            progress: TransferProgress(bytes: int(16), fraction: real(17), bytesPerSecond: real(18)),
            exitStatus: exit, failureReason: optText(21),
            previousAttemptID: try optText(22).map(uuid), tempPartialPath: optText(23))
    }
}
