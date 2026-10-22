import Testing

@testable import SSHDeskCore

@Suite struct QuitActivityTests {
    @Test func idleNeedsNoConfirmation() {
        let a = QuitActivity()
        #expect(!a.needsConfirmation && a.lines.isEmpty && a.message.isEmpty)
    }

    @Test func eachKindIsListedSeparatelyInFixedOrder() {
        let a = QuitActivity(
            transfers: 3, tunnels: 2, monitorRunning: true, analystRunning: true, keyTaskRunning: true)
        #expect(a.needsConfirmation)
        #expect(a.lines.count == 5)
        #expect(a.lines[0].hasPrefix("3 tác vụ truyền file"))
        #expect(a.lines[1].hasPrefix("2 tunnel"))
        #expect(a.lines[2].contains("Monitor") && a.lines[3].contains("Analyst"))
        #expect(a.lines[4].contains("SSH Keys"))
        #expect(a.message.contains("• 3 tác vụ truyền file"))
        #expect(a.message.contains("Bị gián đoạn"))
    }

    @Test func onlyRunningKindsAppear() {
        #expect(QuitActivity(tunnels: 1).lines == ["1 tunnel port forward đang chạy"])
        #expect(QuitActivity(monitorRunning: true).needsConfirmation)
        #expect(!QuitActivity(tunnels: 0).needsConfirmation)
        #expect(!QuitActivity(transfers: -4).needsConfirmation)
        #expect(!QuitActivity(tunnels: 1).message.contains("Bị gián đoạn"))
    }

    @Test func closePolicyFollowsSetting() {
        var s = AppSettings()
        #expect(WindowCloseDecision.quitsOnLastWindowClose(s))
        s.closeBehavior = .keepRunning
        #expect(!WindowCloseDecision.quitsOnLastWindowClose(s))
    }
}
