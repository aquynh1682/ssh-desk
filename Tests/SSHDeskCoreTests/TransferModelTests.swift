import Foundation
import Testing

@testable import SSHDeskCore

func sampleJob(
    direction: TransferDirection = .download, source: String = "/srv/a.txt",
    destination: String = "/Users/me/Downloads/a.txt", kind: TransferItemKind = .file,
    policy: OverwritePolicy = .overwrite, state: TransferState = .queued, id: UUID = UUID(),
    alias: String = "sshdesk-abc", config: String = "/Users/me/ssh/config"
) -> TransferJob {
    TransferJob(
        id: id, hostID: UUID(), hostDisplayNameSnapshot: "Web", targetSnapshot: "deploy@web:22",
        sshAliasSnapshot: alias, configPathSnapshot: config, direction: direction,
        sourcePath: source, destinationPath: destination, itemKind: kind, overwritePolicy: policy,
        state: state)
}

struct TransferStateMachineTests {
    static let valid: Set<[TransferState]> = [
        [.queued, .connecting], [.queued, .cancelled],
        [.connecting, .awaitingUserInput], [.awaitingUserInput, .connecting],
        [.connecting, .transferring], [.transferring, .finalizing], [.finalizing, .completed],
        [.connecting, .failed], [.awaitingUserInput, .failed], [.transferring, .failed],
        [.finalizing, .failed], [.connecting, .cancelling], [.awaitingUserInput, .cancelling],
        [.transferring, .cancelling], [.cancelling, .cancelled],
        // recovery
        [.queued, .interrupted], [.connecting, .interrupted], [.awaitingUserInput, .interrupted],
        [.transferring, .interrupted], [.finalizing, .interrupted], [.cancelling, .interrupted],
    ]

    @Test func everyPairMatchesTable() {
        for from in TransferState.allCases {
            for to in TransferState.allCases {
                let expected = Self.valid.contains([from, to])
                #expect(
                    TransferStateMachine.isValid(from: from, to: to) == expected,
                    "\(from) -> \(to)")
                if expected {
                    #expect((try? TransferStateMachine.transition(from: from, to: to)) == to)
                } else {
                    #expect(throws: TransferStateError.invalidTransition(from: from, to: to)) {
                        try TransferStateMachine.transition(from: from, to: to)
                    }
                }
            }
        }
    }

    @Test func namedInvalidEdges() {
        #expect(!TransferStateMachine.isValid(from: .completed, to: .transferring))
        #expect(!TransferStateMachine.isValid(from: .cancelled, to: .queued))
        #expect(!TransferStateMachine.isValid(from: .completed, to: .interrupted))
        #expect(!TransferStateMachine.isValid(from: .finalizing, to: .cancelling))
    }

    @Test func sanitizeReason() {
        let r = TransferJob.sanitizeReason("lỗi\n\u{1B}[31m  x\t y " + String(repeating: "a", count: 500))
        #expect(!r.contains("\n") && !r.contains("\u{1B}") && !r.contains("\t"))
        #expect(r.count <= 200)
    }
}

struct TransferRepositoryTests {
    func makeRepo(_ t: HostTempDir, retention: Int = 500) throws -> TransferRepository {
        TransferRepository(database: try Database(url: t.dbURL), retention: retention)
    }

    @Test func insertAndRoundTrip() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        var job = sampleJob(policy: .rename("b (1).txt"))
        job.progress = TransferProgress(bytes: 10, fraction: nil, bytesPerSecond: 2.5)
        job.exitStatus = .signaled(15)
        job.tempPartialPath = "/x/.a.sshdesk-1.part"
        try await repo.insert(job)
        let got = try #require(try await repo.job(id: job.id))
        #expect(got.overwritePolicy == .rename("b (1).txt"))
        #expect(got.progress == job.progress)
        #expect(got.exitStatus == .signaled(15))
        #expect(got.tempPartialPath == job.tempPartialPath)
        #expect(abs(got.createdAt.timeIntervalSince(job.createdAt)) < 0.001)
        await #expect(throws: TransferRepositoryError.duplicateID(job.id)) {
            try await repo.insert(job)
        }
    }

    @Test func transitionsSetTimesAndRejectInvalid() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let job = sampleJob()
        try await repo.insert(job)
        let c = try await repo.transition(id: job.id, to: .connecting)
        #expect(c.startedAt != nil && c.finishedAt == nil)
        try await repo.transition(id: job.id, to: .transferring)
        try await repo.updateProgress(id: job.id, TransferProgress(bytes: 5))
        let f = try await repo.transition(
            id: job.id, to: .failed, exit: .exited(1), failureReason: "Permission\ndenied")
        #expect(f.finishedAt != nil && f.exitStatus == .exited(1))
        #expect(f.failureReason == "Permission denied")
        #expect(f.progress.bytes == 5 && f.progress.fraction == nil)
        await #expect(throws: TransferStateError.self) {
            try await repo.transition(id: job.id, to: .transferring)
        }
    }

    @Test func clearHistoryKeepsActiveAndFiles() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let partial = t.url.appendingPathComponent(".a.sshdesk-x.part")
        try Data("x".utf8).write(to: partial)
        var done = sampleJob(state: .completed)
        done.tempPartialPath = partial.path
        let running = sampleJob(state: .transferring)
        try await repo.insert(done)
        try await repo.insert(running)
        #expect(try await repo.clearHistory() == 1)
        let left = try await repo.history()
        #expect(left.map(\.id) == [running.id])
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func retentionKeepsNewest() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t, retention: 3)
        var ids: [UUID] = []
        for _ in 0..<5 {
            let j = sampleJob(state: .completed)
            ids.append(j.id)
            try await repo.insert(j)
        }
        let h = try await repo.history(limit: 10)
        #expect(h.map(\.id) == [ids[4], ids[3], ids[2]])
    }

    @Test func retentionNeverDropsActiveJobs() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t, retention: 1)
        let active = sampleJob(state: .transferring)
        try await repo.insert(active)
        try await repo.insert(sampleJob(state: .completed))
        try await repo.insert(sampleJob(state: .completed))
        let h = try await repo.history()
        #expect(h.contains { $0.id == active.id })
        #expect(h.count == 2)
    }

    @Test func recoverInterruptedMovesAllNonTerminal() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        let states: [TransferState] = [
            .queued, .connecting, .awaitingUserInput, .transferring, .finalizing, .cancelling,
            .completed, .failed, .cancelled,
        ]
        var byState: [TransferState: UUID] = [:]
        for s in states {
            let j = sampleJob(state: s)
            byState[s] = j.id
            try await repo.insert(j)
        }
        let changed = try await repo.recoverInterrupted()
        #expect(changed.count == 6)
        for s in states {
            let got = try #require(try await repo.job(id: byState[s]!))
            if s.isTerminal {
                #expect(got.state == s)
            } else {
                #expect(got.state == .interrupted && got.finishedAt != nil)
            }
        }
        #expect(try await repo.recoverInterrupted().isEmpty)
    }

    @Test func retryCreatesNewJobAndKeepsOld() async throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let repo = try makeRepo(t)
        var failed = sampleJob(state: .failed)
        failed.failureReason = "boom"
        failed.exitStatus = .exited(1)
        failed.tempPartialPath = "/x/.a.sshdesk-1.part"
        try await repo.insert(failed)
        let new = try await repo.retry(jobID: failed.id)
        #expect(new.id != failed.id && new.previousAttemptID == failed.id)
        #expect(new.state == .queued && new.failureReason == nil && new.exitStatus == nil)
        #expect(new.tempPartialPath == nil && new.startedAt == nil)
        let old = try #require(try await repo.job(id: failed.id))
        #expect(old.state == .failed && old.failureReason == "boom")
        #expect(try await repo.history().count == 2)
        await #expect(throws: TransferRepositoryError.notRetryable(.queued)) {
            try await repo.retry(jobID: new.id)
        }
        await #expect(throws: TransferRepositoryError.self) {
            try await repo.retry(jobID: UUID())
        }
    }

    @Test func schemaHasNoSecretColumns() throws {
        let t = HostTempDir()
        defer { t.cleanup() }
        let db = try Database(url: t.dbURL)
        let rows = try db.query("PRAGMA table_info(transfer_jobs)")
        #expect(rows.count > 10)
        for r in rows {
            guard case .text(let name) = r[1] else { continue }
            let n = name.lowercased()
            for bad in ["password", "passphrase", "otp", "transcript", "secret", "credential"] {
                #expect(!n.contains(bad), "cột \(name)")
            }
        }
    }
}
