import Foundation
import Testing

@testable import SSHDeskCore

struct AnalystPresentationTests {
    typealias F = AnalystFixtures
    typealias P = AnalystPresentation

    var run: StoredAnalystRun { AnalystHistoryTests.sampleRun() }

    func flow(_ port: Int) -> TopologyFlow { run.topology.flows.first { $0.flow.port == port }! }
    func result(_ port: Int) -> FlowTestResult? { run.results.first { $0.flow.port == port } }

    @Test func edgeLabelsAndStyles() {
        #expect(P.edgeLabel(flow(8080), result: result(8080)) == "TCP :8080 · 4 ms")
        #expect(P.edgeLabel(flow(5432), result: result(5432)) == "TCP :5432 · TIMEOUT")
        #expect(P.edgeLabel(flow(5432), result: nil) == "TCP :5432")
        #expect(P.edgeLabel(flow(8080), result: nil, mode: .observed) == "TCP :8080 · 2 kết nối")
        #expect(P.style(result(8080)) == .passed)
        #expect(P.style(result(5432)) == .failed)
        #expect(P.style(nil) == .notTested)
        #expect(P.style(result(8080), mode: .observed) == .observed)
        var refused = result(5432)!
        refused.outcome = .failed(.refused)
        #expect(P.edgeLabel(flow(5432), result: refused) == "TCP :5432 · REFUSED")
        refused.outcome = .untestable(.sessionLost)
        #expect(P.style(refused) == .notTested)
    }

    @Test func summaryAndRows() {
        #expect(P.summary(run.results) == "3 thông · 1 lỗi")
        var rs = run.results
        rs[0].outcome = .untestable(.sessionLost)
        #expect(P.summary(rs).hasSuffix("1 không kiểm tra được"))
        let rows = P.rows(run)
        #expect(rows.count == 4)
        let bad = rows.first { $0.port == "5432/TCP" }!
        #expect(bad.isFailure && bad.resultText == "Timeout" && bad.timeText == "3.0 s")
        #expect(bad.source == "api-01" && bad.destination == "db-01")
        #expect(rows.filter(\.isFailure).count == 1)
    }

    @Test func causeIsNeverAssertedAndHintOnlyWhenFailed() {
        #expect(P.cause(result(5432)).headline == "Chưa xác nhận")
        #expect(P.cause(result(5432)).hint == "Kiểm tra firewall và định tuyến")
        #expect(P.cause(result(8080)).hint == nil)
        #expect(P.cause(nil).hint == nil)
        #expect(P.badge(result(5432)) == "FAILED" && P.badge(result(8080)) == "PASSED")
    }

    @Test func destinationAndSourceCheckLines() {
        let d = P.destinationCheck(result(5432), flow: flow(5432))
        #expect(d.headline == "LISTEN 0.0.0.0:5432" && d.detail == "postgres" && d.tone == .good)
        var r = result(5432)!
        r.destinationCheck = .listening(bind: "0.0.0.0", processes: nil)
        #expect(P.destinationCheck(r, flow: flow(5432)).detail?.contains("Không rõ") == true)
        r.destinationCheck = .unknown
        #expect(P.destinationCheck(r, flow: flow(5432)).headline == "Không rõ")
        let s = P.sourceCheck(result(5432))
        #expect(s.headline == "Hết thời gian chờ" && s.tone == .bad)
        #expect(P.sourceCheck(result(8080)).tone == .good)
        #expect(P.sourceCheck(nil).tone == .neutral)
    }

    @Test func serverTexts() throws {
        let fe = try #require(run.topology.node(F.fe))
        #expect(P.listenLabels(fe) == ["LISTEN :443"])
        let db = try #require(run.topology.node(F.db))
        #expect(P.listenLabels(db) == ["LISTEN :5432"])  // IPv4 + IPv6 gộp một nhãn
        #expect(P.listenSummary(db) == ":5432 (postgres)")
        #expect(P.externalText(fe) == "1")
        #expect(P.collectionStatus(fe, warnings: []) == "Đã thu thập")
        #expect(P.collectionStatus(nil, warnings: []) == "Chưa quét")
    }

    @Test func emptyStates() {
        #expect(P.emptyState(hostCount: 0, run: nil) == .noHosts)
        #expect(P.emptyState(hostCount: 2, run: nil) == .notRunYet)
        var empty = run
        empty.topology.flows = []
        #expect(P.emptyState(hostCount: 5, run: empty) == .noEdges)
        #expect(AnalystEmptyState.noEdges.message.contains("đang mở"))
        #expect(P.emptyState(hostCount: 5, run: run) == .hasData)
        #expect(AnalystEmptyState.notRunYet.message.contains("Chạy kiểm tra"))
    }

    @Test func exportFileNameIsSafe() {
        let n = P.exportFileName(
            folder: "Payment / UAT", date: Date(timeIntervalSince1970: 0), format: .csv,
            timeZone: TimeZone(identifier: "UTC")!)
        #expect(n == "project-analyst-Payment---UAT-19700101-0000.csv")
        #expect(!P.exportFileName(folder: "../x", date: Date(), format: .markdown).contains("/"))
        #expect(P.exportFileName(folder: "///", date: Date(), format: .markdown).contains("thu-muc"))
    }

    @Test func progressText() {
        #expect(P.progressText(.testing(done: 2, total: 4)) == "Đã thử 2/4 kết nối…")
        #expect(P.progressText(.collecting(done: 1, total: 3, host: "x")) == "Đang thu thập 1/3 server…")
    }
}
