import Foundation

/// Mức cảnh báo theo % sử dụng (ADR-019/021): mặc định ≥ 80 vàng, ≥ 90 đỏ; ngưỡng chỉnh được ở Cài đặt.
public enum MonitorLevel: Sendable, Equatable {
    case unknown, normal, warning, danger

    public static let warningThreshold = 80.0
    public static let dangerThreshold = 90.0

    public static func level(forPercent p: Double?, thresholds: MonitorThresholds = .default)
        -> MonitorLevel
    {
        guard let p, p.isFinite else { return .unknown }
        if p >= Double(thresholds.danger) { return .danger }
        if p >= Double(thresholds.warning) { return .warning }
        return .normal
    }
}

/// Lịch sử các mẫu gần nhất (giữ tối đa `capacity`, mẫu cũ nhất rơi trước). Chỉ trong bộ nhớ.
public struct MonitorHistory: Sendable, Equatable {
    public static let defaultCapacity = 60

    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int = MonitorHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ v: Double) {
        guard v.isFinite else { return }
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

public enum MonitorMath {
    /// CPU % từ hai lần đọc `/proc/stat`. `nil` nếu thiếu mẫu trước, counter giảm (reset/reboot) hoặc
    /// không có thời gian trôi qua.
    public static func cpuPercent(previous: CPUCounters?, current: CPUCounters) -> Double? {
        guard let previous else { return nil }
        guard current.total >= previous.total, current.idle >= previous.idle else { return nil }
        let dTotal = current.total - previous.total
        let dIdle = current.idle - previous.idle
        guard dTotal > 0, dIdle <= dTotal else { return nil }
        return Double(dTotal - dIdle) / Double(dTotal) * 100
    }
}

public struct MonitorSnapshot: Sendable, Equatable {
    public var takenAt: Date
    /// `nil` ở lần đọc đầu (hiện "—").
    public var cpuPercent: Double?
    public var load: LoadAverage?
    public var cores: Int?
    public var memory: MemoryInfo?
    public var disks: [DiskUsage]
    public var uptimeSeconds: Double?
    /// Nguồn Zabbix không có tổng RAM: chỉ có %. Dùng khi `memory == nil`.
    public var reportedMemoryPercent: Double?

    public init(
        takenAt: Date, cpuPercent: Double?, load: LoadAverage?, cores: Int?, memory: MemoryInfo?,
        disks: [DiskUsage], uptimeSeconds: Double?, reportedMemoryPercent: Double? = nil
    ) {
        self.reportedMemoryPercent = reportedMemoryPercent
        self.takenAt = takenAt
        self.cpuPercent = cpuPercent
        self.load = load
        self.cores = cores
        self.memory = memory
        self.disks = disks
        self.uptimeSeconds = uptimeSeconds
    }

    public var memoryPercent: Double? {
        guard let m = memory, m.totalKB > 0 else { return reportedMemoryPercent }
        return Double(m.usedKB) / Double(m.totalKB) * 100
    }

    public var swapPercent: Double? {
        guard let m = memory, m.swapTotalKB > 0 else { return nil }
        return Double(m.swapUsedKB) / Double(m.swapTotalKB) * 100
    }

    public var cpuLevel: MonitorLevel { cpuLevel(using: .default) }
    public func cpuLevel(using t: MonitorThresholds) -> MonitorLevel {
        .level(forPercent: cpuPercent, thresholds: t)
    }
    public var memoryLevel: MonitorLevel { memoryLevel(using: .default) }
    public func memoryLevel(using t: MonitorThresholds) -> MonitorLevel {
        .level(forPercent: memoryPercent, thresholds: t)
    }
    public var swapLevel: MonitorLevel { swapLevel(using: .default) }
    public func swapLevel(using t: MonitorThresholds) -> MonitorLevel {
        .level(forPercent: swapPercent, thresholds: t)
    }

    /// Dựng snapshot từ đầu ra các lệnh. Trả về cả bộ đếm CPU mới để lần sau tính %.
    public static func make(
        proc: ProcSample, cores: Int?, disks: [DiskUsage], previousCPU: CPUCounters?, at date: Date
    ) -> MonitorSnapshot {
        let cpu = proc.cpu.flatMap { MonitorMath.cpuPercent(previous: previousCPU, current: $0) }
        let coreCount = cores ?? (proc.coreLines > 0 ? proc.coreLines : nil)
        return MonitorSnapshot(
            takenAt: date, cpuPercent: cpu, load: proc.load, cores: coreCount, memory: proc.memory,
            disks: disks, uptimeSeconds: proc.uptimeSeconds)
    }
}

/// Định dạng hiển thị (thuần, có test).
public enum MonitorFormat {
    public static func percent(_ p: Double?) -> String {
        guard let p, p.isFinite else { return "—" }
        return String(format: "%.0f%%", p)
    }

    /// KB → "512 MB", "3.2 GB", "1.5 TB".
    public static func size(kb: UInt64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(kb)
        var i = 0
        while value >= 1024, i < units.count - 1 {
            value /= 1024
            i += 1
        }
        return i == 0 || value >= 100
            ? String(format: "%.0f %@", value, units[i])
            : String(format: "%.1f %@", value, units[i])
    }

    public static func uptime(seconds: Double?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
        let total = Int(s)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) ngày \(hours) giờ" }
        if hours > 0 { return "\(hours) giờ \(minutes) phút" }
        return "\(minutes) phút"
    }

    public static func load(_ l: LoadAverage?, cores: Int?) -> String {
        guard let l else { return "—" }
        let text = String(format: "%.2f · %.2f · %.2f", l.one, l.five, l.fifteen)
        return cores.map { "\(text) · \($0) nhân" } ?? text
    }
}

public enum MonitorProdGuard {
    /// Nội dung hộp xác nhận khi thư mục có server PROD (liệt kê đúng các lệnh sẽ chạy, mỗi chu kỳ).
    public static func message(hosts: [HostProfile], intervalSeconds: Int) -> String {
        let prod = hosts.filter { $0.environment == .prod }.map(\.displayName)
        var lines = [
            "Thư mục có server PROD: \(prod.joined(separator: ", ")).",
            "Cứ mỗi \(intervalSeconds) giây, trên MỖI server sau sẽ chạy các lệnh chỉ-xem:",
        ]
        for h in hosts {
            lines.append("  \(h.displayName) [\(h.environment.rawValue)]")
        }
        lines.append("")
        for c in MonitorCommand.allCommandStrings { lines.append("  \(c)") }
        lines.append("")
        lines.append("Dừng khi bấm Dừng, rời màn Monitor hoặc đổi thư mục.")
        return lines.joined(separator: "\n")
    }
}
