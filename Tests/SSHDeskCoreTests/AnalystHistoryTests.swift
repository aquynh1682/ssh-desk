import Foundation
import Testing

@testable import SSHDeskCore

struct AnalystHistoryTests {
    typealias F = AnalystFixtures

    static func sampleRun(
        folder: String = "Payment / UAT", start: TimeInterval = 1_000
    ) -> StoredAnalystRun {
        let topo = TopologyBuilder.build(F.mockup())
        var results: [FlowTestResult] = []
        for tf in topo.flows {
            if tf.flow.port == 5432 {
                results.append(
                    FlowTestResult(
                        flow: tf.flow, outcome: .failed(.timeout),
                        destinationCheck: .listening(
                            bind: "0.0.0.0", processes: [ProcessRef(name: "postgres", pid: 812)]),
                        evidence: [
                            Evidence(title: "Đích thử", detail: "10.0.0.4:5432"),
                            Evidence(title: "stderr", detail: "SECRET-RAW", raw: true),
                        ], cause: FlowTestResult.unconfirmedCause))
            } else {
                results.append(
                    FlowTestResult(
                        flow: tf.flow, outcome: .passed(milliseconds: 4), destinationCheck: .notListening,
                        evidence: [], cause: nil))
            }
        }
        return StoredAnalystRun(
            folderName: folder, startedAt: Date(timeIntervalSince1970: start),
            finishedAt: Date(timeIntervalSince1970: start + 5), status: .partial,
            warnings: [AnalystWarning(kind: .toolMissing, hostID: F.db, hostName: "db-01", detail: "ss")],
            topology: topo, results: results)
    }

    func makeRepo(retention: Int = 50) throws -> (AnalystRunRepository, Database, HostTempDir) {
        let t = HostTempDir()
        let db = try Database(url: t.dbURL)
        return (AnalystRunRepository(database: db, retention: retention), db, t)
    }

    @Test func roundTrip() async throws {
        let (repo, _, t) = try makeRepo()
        defer { t.cleanup() }
        let run = Self.sampleRun()
        try await repo.save(run)
        let loaded = try #require(try await repo.load(id: run.id))
        #expect(loaded.folderName == run.folderName)
        #expect(loaded.startedAt == run.startedAt && loaded.status == .partial)
        #expect(loaded.warnings == run.warnings)
        #expect(loaded.topology.servers == run.topology.servers)
        #expect(loaded.topology.flows.map(\.flow) == run.topology.flows.map(\.flow))
        let db = try #require(loaded.results.first { $0.flow.port == 5432 })
        #expect(db.outcome == .failed(.timeout))
        #expect(db.cause == "Chưa xác nhận")
        #expect(
            db.destinationCheck
                == .listening(bind: "0.0.0.0", processes: [ProcessRef(name: "postgres", pid: 812)]))
        #expect(db.evidence.map(\.title) == ["Đích thử"])  // bằng chứng raw không được lưu
        let ok = try #require(loaded.results.first { $0.flow.port == 8080 })
        #expect(ok.outcome == .passed(milliseconds: 4) && ok.cause == nil)
        let tf = try #require(loaded.topology.flows.first { $0.flow.port == 8080 })
        #expect(tf.observedConnections == 2 && tf.destinationVerified)
        #expect(tf.destinationListen?.processes == [ProcessRef(name: "java", pid: 20)])
    }

    @Test func noRawTextInDatabase() async throws {
        let (repo, db, t) = try makeRepo()
        defer { t.cleanup() }
        try await repo.save(Self.sampleRun())
        let rows = try db.query("SELECT evidence_json FROM analyst_flows")
        for r in rows {
            if case .text(let s) = r[0] { #expect(!s.contains("SECRET-RAW")) }
        }
    }

    @Test func listNewestFirstWithCounts() async throws {
        let (repo, _, t) = try makeRepo()
        defer { t.cleanup() }
        let a = Self.sampleRun(start: 1_000)
        let b = Self.sampleRun(start: 2_000)
        let other = Self.sampleRun(folder: "Khác", start: 3_000)
        for r in [a, b, other] { try await repo.save(r) }
        let list = try await repo.list(folder: "Payment / UAT")
        #expect(list.map(\.id) == [b.id, a.id])
        #expect(list[0].passed == 3 && list[0].failed == 1 && list[0].flowCount == 4)
        #expect(list[0].serverCount == 5)
        #expect(try await repo.list(folder: "Khác").count == 1)
    }

    @Test func retentionKeepsNewestPerFolder() async throws {
        let (repo, db, t) = try makeRepo(retention: 3)
        defer { t.cleanup() }
        var ids: [UUID] = []
        for i in 0..<5 {
            let r = Self.sampleRun(start: Double(1_000 + i))
            ids.append(r.id)
            try await repo.save(r)
        }
        try await repo.save(Self.sampleRun(folder: "Khác", start: 1))
        let list = try await repo.list(folder: "Payment / UAT")
        #expect(list.map(\.id) == [ids[4], ids[3], ids[2]])
        #expect(try await repo.list(folder: "Khác").count == 1)
        // dòng con của run bị cắt cũng bị xoá
        let n = try db.query("SELECT COUNT(DISTINCT run_id) FROM analyst_flows")
        #expect(n.first?.first == .int(4))
    }

    @Test func deleteCascadesAndMissingLoadIsNil() async throws {
        let (repo, db, t) = try makeRepo()
        defer { t.cleanup() }
        let r = Self.sampleRun()
        try await repo.save(r)
        try await repo.delete(id: r.id)
        #expect(try await repo.load(id: r.id) == nil)
        #expect(try db.query("SELECT COUNT(*) FROM analyst_flows").first?.first == .int(0))
        #expect(try db.query("SELECT COUNT(*) FROM analyst_servers").first?.first == .int(0))
    }

    @Test func historySurvivesHostDeletion() async throws {
        // Không có FK tới hosts: run tham chiếu host_id không tồn tại vẫn đọc được.
        let (repo, _, t) = try makeRepo()
        defer { t.cleanup() }
        let r = Self.sampleRun()
        try await repo.save(r)
        #expect(try await repo.load(id: r.id)?.topology.servers.count == 5)
    }

    @Test func untestableOutcomesDoNotStoreServerText() async throws {
        let (repo, db, t) = try makeRepo()
        defer { t.cleanup() }
        var r = Self.sampleRun()
        r.results[0].outcome = .untestable(.connectionFailed("stderr của server"))
        try await repo.save(r)
        let rows = try db.query("SELECT outcome, outcome_detail FROM analyst_flows WHERE outcome LIKE 'untestable%'")
        #expect(rows.count == 1)
        #expect(rows[0][1] == .null)
        let loaded = try #require(try await repo.load(id: r.id))
        #expect(loaded.results[0].outcome == .untestable(.connectionFailed("")))
    }
}
