import Foundation

/// Bộ đếm CPU từ dòng `cpu ` của `/proc/stat`.
public struct CPUCounters: Sendable, Equatable {
    /// user + nice + system + idle + iowait + irq + softirq + steal (guest đã nằm trong user/nice).
    public var total: UInt64
    /// idle + iowait.
    public var idle: UInt64

    public init(total: UInt64, idle: UInt64) {
        self.total = total
        self.idle = idle
    }
}

public struct MemoryInfo: Sendable, Equatable {
    public var totalKB: UInt64
    /// `MemAvailable`; kernel cũ không có thì lấy `MemFree + Buffers + Cached`.
    public var availableKB: UInt64
    public var swapTotalKB: UInt64
    public var swapFreeKB: UInt64

    public init(totalKB: UInt64, availableKB: UInt64, swapTotalKB: UInt64, swapFreeKB: UInt64) {
        self.totalKB = totalKB
        self.availableKB = availableKB
        self.swapTotalKB = swapTotalKB
        self.swapFreeKB = swapFreeKB
    }

    public var usedKB: UInt64 { totalKB > availableKB ? totalKB - availableKB : 0 }
    public var swapUsedKB: UInt64 { swapTotalKB > swapFreeKB ? swapTotalKB - swapFreeKB : 0 }
}

public struct LoadAverage: Sendable, Equatable {
    public var one: Double
    public var five: Double
    public var fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

public struct DiskUsage: Sendable, Equatable {
    public var filesystem: String
    public var mount: String
    public var totalKB: UInt64
    public var usedKB: UInt64
    public var availableKB: UInt64

    public init(filesystem: String, mount: String, totalKB: UInt64, usedKB: UInt64, availableKB: UInt64) {
        self.filesystem = filesystem
        self.mount = mount
        self.totalKB = totalKB
        self.usedKB = usedKB
        self.availableKB = availableKB
    }

    /// % đã dùng theo cách `df` tính (used / (used + avail)).
    public var percent: Double {
        let denom = usedKB + availableKB
        guard denom > 0 else { return 0 }
        return min(100, Double(usedKB) / Double(denom) * 100)
    }
}

/// Kết quả phân tích đầu ra `cat /proc/stat /proc/meminfo /proc/loadavg /proc/uptime`.
public struct ProcSample: Sendable, Equatable {
    public var cpu: CPUCounters?
    /// Số dòng `cpuN` trong `/proc/stat` (dự phòng khi `nproc` lỗi).
    public var coreLines: Int
    public var memory: MemoryInfo?
    public var load: LoadAverage?
    public var uptimeSeconds: Double?

    public init(
        cpu: CPUCounters? = nil, coreLines: Int = 0, memory: MemoryInfo? = nil,
        load: LoadAverage? = nil, uptimeSeconds: Double? = nil
    ) {
        self.cpu = cpu
        self.coreLines = coreLines
        self.memory = memory
        self.load = load
        self.uptimeSeconds = uptimeSeconds
    }
}

/// Parser thuần cho đầu ra lệnh Monitor. Dòng lạ bị bỏ qua, không bao giờ crash.
public enum MonitorParser {
    public static func parseProc(_ text: String) -> ProcSample {
        var sample = ProcSample()
        var mem: [String: UInt64] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = fields.first else { continue }

            if first == "cpu" {
                sample.cpu = parseCPU(Array(fields.dropFirst()))
            } else if first.hasPrefix("cpu"), first.dropFirst(3).allSatisfy(\.isNumber),
                first.count > 3
            {
                sample.coreLines += 1
            } else if first.hasSuffix(":") {
                // /proc/meminfo: "MemTotal:  16384 kB"
                let key = String(first.dropLast())
                if ["MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached", "SwapTotal", "SwapFree"]
                    .contains(key), fields.count >= 2, let v = UInt64(fields[1])
                {
                    mem[key] = v
                }
            } else if fields.count == 5, fields[3].contains("/"), let l = parseLoad(fields) {
                sample.load = l
            } else if fields.count == 2, let up = parseDecimal(fields[0]), parseDecimal(fields[1]) != nil {
                sample.uptimeSeconds = up
            }
        }
        if let total = mem["MemTotal"], total > 0 {
            let available =
                mem["MemAvailable"] ?? ((mem["MemFree"] ?? 0) + (mem["Buffers"] ?? 0) + (mem["Cached"] ?? 0))
            sample.memory = MemoryInfo(
                totalKB: total, availableKB: min(available, total), swapTotalKB: mem["SwapTotal"] ?? 0,
                swapFreeKB: mem["SwapFree"] ?? 0)
        }
        return sample
    }

    private static func parseCPU(_ fields: [String]) -> CPUCounters? {
        guard fields.count >= 4 else { return nil }
        // user nice system idle iowait irq softirq steal (guest/guest_nice đã tính trong user/nice).
        var values: [UInt64] = []
        for f in fields.prefix(8) {
            guard let v = UInt64(f) else { return nil }
            values.append(v)
        }
        let idle = values[3] &+ (values.count > 4 ? values[4] : 0)
        let total = values.reduce(0) { $0 &+ $1 }
        return CPUCounters(total: total, idle: idle)
    }

    private static func parseLoad(_ f: [String]) -> LoadAverage? {
        guard let a = parseDecimal(f[0]), let b = parseDecimal(f[1]), let c = parseDecimal(f[2]) else {
            return nil
        }
        return LoadAverage(one: a, five: b, fifteen: c)
    }

    /// Số thập phân không âm, hữu hạn, chỉ gồm chữ số và tối đa một dấu chấm.
    private static func parseDecimal(_ s: String) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            s.filter({ $0 == "." }).count <= 1, let v = Double(s), v.isFinite
        else { return nil }
        return v
    }

    /// Số nhân từ `nproc`: một số nguyên dương.
    public static func parseCPUCount(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = Int(t), n > 0, n < 100_000 else { return nil }
        return n
    }

    // MARK: - df -P -k

    static let ignoredFilesystems: Set<String> = [
        "tmpfs", "devtmpfs", "overlay", "squashfs", "udev", "shm", "efivarfs", "ramfs", "none", "devfs",
        "cgroup", "cgroup2", "proc", "sysfs", "tracefs", "securityfs", "pstore", "bpf", "debugfs",
        "fusectl", "mqueue", "hugetlbfs", "configfs",
    ]
    static let ignoredMountPrefixes = ["/proc", "/sys", "/dev", "/run", "/snap"]
    public static let maxDisks = 4

    /// Phân tích `df -P -k`, lọc mount ảo, bỏ trùng thiết bị, `/` đầu tiên, tối đa `maxDisks`.
    /// Cột cuối (mount) có thể chứa dấu cách: tìm cột `Capacity` (số + `%`) đứng sau 3 cột số.
    public static func parseDf(_ text: String) -> [DiskUsage] {
        var disks: [DiskUsage] = []
        var seenFS = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let t = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 6 else { continue }
            guard
                let capIndex = (4..<t.count).first(where: {
                    t[$0].hasSuffix("%") && Int(t[$0].dropLast()) != nil && UInt64(t[$0 - 1]) != nil
                        && UInt64(t[$0 - 2]) != nil && UInt64(t[$0 - 3]) != nil
                }),
                capIndex + 1 < t.count
            else { continue }
            let fs = t[0..<(capIndex - 3)].joined(separator: " ")
            let mount = t[(capIndex + 1)...].joined(separator: " ")
            guard let total = UInt64(t[capIndex - 3]), let used = UInt64(t[capIndex - 2]),
                let avail = UInt64(t[capIndex - 1]), total > 0, mount.hasPrefix("/")
            else { continue }
            if ignoredFilesystems.contains(fs.lowercased()) { continue }
            if ignoredMountPrefixes.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) { continue }
            // Bind mount / subvolume cùng một thiết bị: chỉ lấy mount đầu tiên.
            if !seenFS.insert(fs).inserted { continue }
            disks.append(
                DiskUsage(filesystem: fs, mount: mount, totalKB: total, usedKB: used, availableKB: avail))
        }
        if let rootIndex = disks.firstIndex(where: { $0.mount == "/" }), rootIndex != 0 {
            let root = disks.remove(at: rootIndex)
            disks.insert(root, at: 0)
        }
        return Array(disks.prefix(maxDisks))
    }
}
