import Foundation
import Testing

@testable import SSHDeskCore

struct AnalystReportTests {
    typealias F = AnalystFixtures

    static func run(nameOverride: String? = nil) -> AnalystRun {
        var snaps = F.mockup()
        if let nameOverride { snaps[2].displayName = nameOverride }
        let topo = TopologyBuilder.build(snaps)
        let results = topo.flows.map { tf in
            FlowTestResult(
                flow: tf.flow,
                outcome: tf.flow.port == 6379 ? .failed(.refused) : .passed(milliseconds: 12),
                destinationCheck: .listening(bind: "0.0.0.0", processes: nil),
                evidence: [Evidence(title: "stderr", detail: "SECRET-RAW-OUTPUT", raw: true)],
                cause: tf.flow.port == 6379 ? FlowTestResult.unconfirmedCause : nil)
        }
        return AnalystRun(
            projectName: "Shop", startedAt: Date(timeIntervalSince1970: 0), topology: topo, results: results)
    }

    @Test func markdownHasParsedFieldsOnly() {
        let md = AnalystReport.markdown(Self.run())
        #expect(md.contains("# Project Analyst: Shop"))
        #expect(md.contains("1970-01-01T00:00:00Z"))
        #expect(md.contains("| fe-01 | be-01 | 8080 | 2 | Passed | 12 |"))
        #expect(md.contains("Failed (refused)"))
        #expect(md.contains("Chưa xác nhận"))
        #expect(!md.contains("SECRET-RAW-OUTPUT"))
    }

    @Test func markdownEscapesPipesAndNewlines() {
        let md = AnalystReport.markdown(Self.run(nameOverride: "a|b\nc"))
        #expect(md.contains("a\\|b c"))
    }

    @Test func csvBasicShape() {
        let csv = AnalystReport.csv(Self.run())
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 5)
        #expect(lines[0] == AnalystReport.csvHeader.joined(separator: ","))
        #expect(lines.contains("fe-01,be-01,8080,2,Passed,12,LISTEN 0.0.0.0,"))
        #expect(!csv.contains("SECRET-RAW-OUTPUT"))
    }

    @Test func csvEscapesCommaQuoteNewline() {
        let csv = AnalystReport.csv(Self.run(nameOverride: "api, \"main\"\nnode"))
        #expect(csv.contains("\"api, \"\"main\"\"\nnode\",db-01,5432"))
    }

    @Test func csvFieldRules() {
        #expect(AnalystReport.csvField("plain") == "plain")
        #expect(AnalystReport.csvField("a,b") == "\"a,b\"")
        #expect(AnalystReport.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(AnalystReport.csvField("l1\nl2") == "\"l1\nl2\"")
        #expect(AnalystReport.csvField("=SUM(A1)") == "'=SUM(A1)")
        #expect(AnalystReport.csvField("@x") == "'@x")
    }
}
