import Foundation
import Testing

@testable import SSHDeskCore

struct MonitorParserTests {
    static let proc = """
        cpu  1000 50 300 8000 200 10 20 30 0 0
        cpu0 500 25 150 4000 100 5 10 15 0 0
        cpu1 500 25 150 4000 100 5 10 15 0 0
        intr 12345 1 2 3
        ctxt 999
        btime 1700000000
        processes 4321
        MemTotal:       16384000 kB
        MemFree:         1000000 kB
        MemAvailable:    8192000 kB
        Buffers:          100000 kB
        Cached:          2000000 kB
        SwapTotal:       2048000 kB
        SwapFree:        1024000 kB
        0.52 0.40 0.30 2/345 6789
        123456.78 234567.89

        """

    @Test func parsesProcBundle() {
        let s = MonitorParser.parseProc(Self.proc)
        // total = 1000+50+300+8000+200+10+20+30 = 9610; idle = 8000+200
        #expect(s.cpu == CPUCounters(total: 9610, idle: 8200))
        #expect(s.coreLines == 2)
        #expect(s.memory?.totalKB == 16_384_000)
        #expect(s.memory?.availableKB == 8_192_000)
        #expect(s.memory?.usedKB == 8_192_000)
        #expect(s.memory?.swapUsedKB == 1_024_000)
        #expect(s.load == LoadAverage(one: 0.52, five: 0.40, fifteen: 0.30))
        #expect(s.uptimeSeconds == 123456.78)
    }

    @Test func memAvailableFallback() {
        let s = MonitorParser.parseProc(
            "MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 150 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
        #expect(s.memory?.availableKB == 300)
        #expect(s.memory?.swapTotalKB == 0)
    }

    @Test func oldKernelShortCPULine() {
        let s = MonitorParser.parseProc("cpu  10 0 5 100\n")
        #expect(s.cpu == CPUCounters(total: 115, idle: 100))
    }

    @Test func garbageIsIgnored() {
        let s = MonitorParser.parseProc("cat: /proc/stat: No such file or directory\nxyz abc\ncpu a b c d\n")
        #expect(s.cpu == nil)
        #expect(s.memory == nil)
        #expect(s.load == nil)
        #expect(s.uptimeSeconds == nil)
        #expect(MonitorParser.parseProc("").cpu == nil)
    }

    @Test func nproc() {
        #expect(MonitorParser.parseCPUCount("8\n") == 8)
        #expect(MonitorParser.parseCPUCount("0\n") == nil)
        #expect(MonitorParser.parseCPUCount("nproc: command not found") == nil)
    }

    static let df = """
        Filesystem     1024-blocks      Used Available Capacity Mounted on
        tmpfs               800000      1000    799000       1% /run
        /dev/sdb1         20000000  10000000  10000000      50% /data
        /dev/sda1        100000000  91000000   9000000      91% /
        udev                400000         0    400000       0% /dev
        overlay           50000000   1000000  49000000       2% /var/lib/docker/overlay2/x/merged
        /dev/loop0            1000      1000         0     100% /snap/core/123
        /dev/sdc1          5000000   1000000   4000000      20% /mnt/with space
        /dev/sda1        100000000  91000000   9000000      91% /var/lib/docker
        /dev/sdd1          5000000   1000000   4000000      20% /mnt/d
        /dev/sde1          5000000   1000000   4000000      20% /mnt/e
        """

    @Test func dfFiltersAndOrders() {
        let d = MonitorParser.parseDf(Self.df)
        #expect(d.map(\.mount) == ["/", "/data", "/mnt/with space", "/mnt/d"])
        #expect(d[0].filesystem == "/dev/sda1")
        #expect(d[0].percent.rounded() == 91)
        #expect(d[1].percent == 50)
        #expect(d[2].totalKB == 5_000_000)
    }

    @Test func dfHeaderOnlyAndGarbage() {
        #expect(MonitorParser.parseDf("Filesystem 1024-blocks Used Available Capacity Mounted on\n").isEmpty)
        #expect(MonitorParser.parseDf("df: command not found").isEmpty)
        #expect(MonitorParser.parseDf("").isEmpty)
    }

    @Test func dfFilesystemWithSpaceAndZeroTotal() {
        let text = """
            Filesystem 1024-blocks Used Available Capacity Mounted on
            my nas share 1000 500 500 50% /mnt/nas
            /dev/zero0 0 0 0 0% /mnt/zero
            """
        let d = MonitorParser.parseDf(text)
        #expect(d.count == 1)
        #expect(d[0].filesystem == "my nas share")
        #expect(d[0].mount == "/mnt/nas")
    }
}

struct MonitorMathTests {
    @Test func cpuPercent() {
        let a = CPUCounters(total: 1000, idle: 800)
        let b = CPUCounters(total: 1200, idle: 900)
        #expect(MonitorMath.cpuPercent(previous: a, current: b) == 50)
        #expect(MonitorMath.cpuPercent(previous: nil, current: b) == nil)
        // reset / reboot: counter giảm
        #expect(MonitorMath.cpuPercent(previous: b, current: a) == nil)
        // không trôi qua thời gian
        #expect(MonitorMath.cpuPercent(previous: a, current: a) == nil)
        // idle tăng nhiều hơn total: dữ liệu vô lý
        #expect(MonitorMath.cpuPercent(previous: a, current: CPUCounters(total: 1010, idle: 900)) == nil)
        // idle giảm
        #expect(MonitorMath.cpuPercent(previous: a, current: CPUCounters(total: 1100, idle: 700)) == nil)
    }

    @Test(arguments: [
        (nil as Double?, MonitorLevel.unknown), (0.0, .normal), (79.9, .normal), (80.0, .warning),
        (89.9, .warning), (90.0, .danger), (100.0, .danger),
    ])
    func levels(_ p: Double?, _ expected: MonitorLevel) {
        #expect(MonitorLevel.level(forPercent: p) == expected)
    }

    @Test func historyKeepsLast60() {
        var h = MonitorHistory()
        for i in 0..<100 { h.append(Double(i)) }
        #expect(h.values.count == 60)
        #expect(h.values.first == 40)
        #expect(h.values.last == 99)
        h.append(.nan)
        #expect(h.values.count == 60)
    }

    @Test func snapshotMakeUsesStatCoreLinesAsFallback() {
        let proc = MonitorParser.parseProc(MonitorParserTests.proc)
        let snap = MonitorSnapshot.make(
            proc: proc, cores: nil, disks: [], previousCPU: nil, at: Date(timeIntervalSince1970: 0))
        #expect(snap.cores == 2)
        #expect(snap.cpuPercent == nil)
        #expect(snap.memoryPercent == 50)
        #expect(snap.swapPercent == 50)
        #expect(snap.memoryLevel == .normal)
        let withN = MonitorSnapshot.make(
            proc: proc, cores: 4, disks: [], previousCPU: nil, at: Date())
        #expect(withN.cores == 4)
    }

    @Test func formatting() {
        #expect(MonitorFormat.percent(nil) == "—")
        #expect(MonitorFormat.percent(42.4) == "42%")
        #expect(MonitorFormat.size(kb: 512) == "512 KB")
        #expect(MonitorFormat.size(kb: 16_384_000) == "15.6 GB")
        #expect(MonitorFormat.uptime(seconds: 90061) == "1 ngày 1 giờ")
        #expect(MonitorFormat.uptime(seconds: 3700) == "1 giờ 1 phút")
        #expect(MonitorFormat.uptime(seconds: 120) == "2 phút")
        #expect(MonitorFormat.uptime(seconds: nil) == "—")
        #expect(
            MonitorFormat.load(LoadAverage(one: 1, five: 0.5, fifteen: 0.25), cores: 4) == "1.00 · 0.50 · 0.25 · 4 nhân"
        )
    }

    @Test func commandWhitelistIsFixed() {
        #expect(
            MonitorCommand.allCommandStrings == [
                "cat /proc/stat /proc/meminfo /proc/loadavg /proc/uptime", "nproc", "df -P -k",
            ])
    }
}

struct MonitorProdGuardTests {
    @Test func messageListsCommandsAndHosts() {
        let prod = MonitorCoordinatorTests.host("db", env: .prod)
        let dev = MonitorCoordinatorTests.host("web")
        let m = MonitorProdGuard.message(hosts: [prod, dev], intervalSeconds: 10)
        #expect(m.contains("db"))
        #expect(m.contains("df -P -k"))
        #expect(m.contains("cat /proc/stat"))
        #expect(m.contains("10 giây"))
    }
}
