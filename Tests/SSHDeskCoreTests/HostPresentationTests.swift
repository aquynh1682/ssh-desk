import Foundation
import Testing

@testable import SSHDeskCore

struct HostPresentationTests {
    private func host(
        _ name: String, env: HostEnvironment = .other, launched: Date? = nil,
        mode: HostConnectionMode = .managed
    ) -> HostProfile {
        HostProfile(
            displayName: name, environment: env, connectionMode: mode, hostName: "10.0.0.1",
            user: "u", lastLaunchRequestedAt: launched)
    }

    @Test func environmentCountsOrderedAndOnlyNonEmpty() {
        let hosts = [
            host("a", env: .other), host("b", env: .prod), host("c", env: .prod),
            host("d", env: .stg),
        ]
        let counts = HostPresentation.environmentCounts(hosts)
        #expect(counts.map(\.environment) == [.prod, .stg, .other])
        #expect(counts.map(\.count) == [2, 1, 1])
        #expect(HostPresentation.environmentCounts([]).isEmpty)
    }

    @Test func filterByEnvironment() {
        let hosts = [host("a", env: .dev), host("b", env: .prod)]
        #expect(HostPresentation.filter(hosts, environment: nil).count == 2)
        #expect(HostPresentation.filter(hosts, environment: .prod).map(\.displayName) == ["b"])
    }

    @Test func recentOnlyLaunchedNewestFirst() {
        let t = Date(timeIntervalSince1970: 1000)
        let hosts = [
            host("never"), host("old", launched: t),
            host("new", launched: t.addingTimeInterval(50)),
            host("mid", launched: t.addingTimeInterval(10)),
        ]
        #expect(HostPresentation.recent(hosts).map(\.displayName) == ["new", "mid", "old"])
        #expect(HostPresentation.recent(hosts, limit: 2).map(\.displayName) == ["new", "mid"])
    }

    @Test func sortByName() {
        let hosts = [host("b2"), host("a"), host("b10")]
        #expect(
            HostPresentation.sortedByName(hosts, ascending: true).map(\.displayName)
                == ["a", "b2", "b10"])
        #expect(
            HostPresentation.sortedByName(hosts, ascending: false).map(\.displayName)
                == ["b10", "b2", "a"])
    }

    @Test func subtitleAndAddress() {
        var h = host("x")
        h.project = "Proj"
        #expect(HostPresentation.subtitle(h) == "Proj")
        h.notes = "\n  Dòng đầu \nDòng hai"
        #expect(HostPresentation.subtitle(h) == "Dòng đầu")
        #expect(HostPresentation.addressText(h) == "10.0.0.1")
        var i = host("i", mode: .existingSSHConfigAlias)
        i.sshConfigAlias = "web"
        #expect(HostPresentation.addressText(i) == "web")
    }

    @Test func connectionRowsManagedKeyAndJump() {
        var h = host("x")
        h.authMethod = .keyFile
        h.identityFile = "/Users/me/.ssh/id_ed25519"
        let rows = HostPresentation.connectionRows(h, jumpHostName: "bastion")
        #expect(rows.map(\.label) == ["Địa chỉ", "Port", "User", "Xác thực", "Key", "Jump host"])
        #expect(rows.first { $0.label == "Key" }?.value == "id_ed25519")
        #expect(rows.first { $0.label == "Xác thực" }?.copyable == false)
        let none = HostPresentation.connectionRows(host("y"), jumpHostName: nil)
        #expect(!none.contains { $0.label == "Key" || $0.label == "Jump host" })
    }

    @Test func connectionRowsImported() {
        var i = host("i", mode: .existingSSHConfigAlias)
        i.sshConfigAlias = "web"
        i.sshConfigPath = "/Users/me/.ssh/config"
        let rows = HostPresentation.connectionRows(i, jumpHostName: nil)
        #expect(rows.map(\.label) == ["Alias", "File nguồn"])
        #expect(rows[1].value == "/Users/me/.ssh/config")
    }

    @Test func badgeCodes() {
        #expect(HostPresentation.badgeCode(for: .prod) == "PROD")
        #expect(HostPresentation.badgeCode(for: .other) == "KHÁC")
        #expect(HostPresentation.title(for: .stg) == "Staging")
    }
}

struct TransferPanelTests {
    private let t = Date(timeIntervalSince1970: 0)

    private func job(_ state: TransferState, _ n: Double) -> TransferJob {
        var j = sampleJob()
        j.state = state
        j.createdAt = t.addingTimeInterval(n)
        j.finishedAt = state.isTerminal ? t.addingTimeInterval(n) : nil
        return j
    }

    @Test func panelJobsRunningFirstThenRecentFillToLimit() {
        let running = job(.transferring, 100)
        let jobs = [
            job(.completed, 1), job(.failed, 2), job(.completed, 3), running,
            job(.cancelled, 4), job(.completed, 5),
        ]
        let panel = TransferPresentation.panelJobs(jobs, limit: 4)
        #expect(panel.count == 4)
        #expect(panel.first?.id == running.id)
        #expect(panel.dropFirst().map(\.createdAt) == [5, 4, 3].map { t.addingTimeInterval($0) })
        let many = (0..<5).map { job(.queued, Double($0)) } + [job(.completed, 9)]
        #expect(TransferPresentation.panelJobs(many, limit: 4).count == 5)
        #expect(TransferPresentation.panelJobs([], limit: 4).isEmpty)
    }

    @Test func routeAndNames() {
        let up = sampleJob(
            direction: .upload, source: "/Users/me/nginx.conf", destination: "/etc/nginx.conf")
        #expect(TransferPresentation.fileName(for: up) == "nginx.conf")
        #expect(TransferPresentation.route(for: up).from == "Máy này")
        #expect(TransferPresentation.route(for: up).to == "Web")
        let down = sampleJob()
        #expect(TransferPresentation.route(for: down).from == "Web")
        #expect(TransferPresentation.route(for: down).to == "Downloads")
    }

    @Test func percentOnlyWithRealFraction() {
        var j = sampleJob()
        j.state = .transferring
        #expect(TransferPresentation.percentText(for: j) == nil)
        j.progress.fraction = 0.684
        #expect(TransferPresentation.percentText(for: j) == "68%")
    }
}
