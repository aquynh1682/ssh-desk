import Foundation

/// Cài đặt của app (ADR-021). Thuần giá trị: mọi giá trị đi qua `init(values:)` đều được kẹp vào phạm vi
/// hợp lệ; khoá lạ bị bỏ qua, giá trị không đọc được → mặc định. Không bao giờ chứa bí mật.
public struct AppSettings: Equatable, Sendable {
    public enum CloseBehavior: String, Sendable, CaseIterable {
        /// Đóng cửa sổ chính = thoát app (mặc định).
        case quit
        /// Đóng cửa sổ chính, app chạy nền (mở lại bằng Dock).
        case keepRunning
    }

    public enum WarpOpenMode: String, Sendable, CaseIterable {
        case tab
        case window
        /// `?new_window=true` trong URI Warp.
        public var opensNewWindow: Bool { self == .window }
    }

    // MARK: Chung
    /// Thư mục local mặc định; rỗng = `~/Downloads`.
    public var defaultLocalDirectory = ""
    public var closeBehavior: CloseBehavior = .quit
    // MARK: Warp
    public var warpOpenMode: WarpOpenMode = .tab
    // MARK: Truyền file
    public var transferConcurrency = AppSettings.defaultTransferConcurrency
    /// Số bản ghi lịch sử giữ lại; 0 = không giới hạn.
    public var transferHistoryLimit = AppSettings.defaultTransferHistoryLimit
    // MARK: SSH config
    /// Đường dẫn config người dùng được `Include`; rỗng = `~/.ssh/config`.
    public var userSSHConfigPath = ""
    /// Mặc định `IdentityAgent` cho host managed (ADR-024); rỗng = không ghi directive.
    public var defaultIdentityAgent = ""
    // MARK: Bảo mật
    public var autofillEnabled = true
    /// Hỏi mật khẩu khi máy chưa lưu (ADR-029). Chỉ có tác dụng khi `autofillEnabled` bật.
    public var promptMissingPassword = true
    public var clipboardClearSeconds = AppSettings.defaultClipboardSeconds
    // MARK: Project Analyst
    public var analystRetention = AppSettings.defaultAnalystRetention
    public var analystProbeTimeout = ProbeTimeout.default
    // MARK: Monitor
    public var monitorIntervalSeconds = AppSettings.defaultMonitorInterval
    public var monitorThresholds = MonitorThresholds.default
    // MARK: Windows App (máy mới)
    public var rdpFullScreen = true
    public var rdpMultiMonitor = false
    public var rdpRedirectClipboard = true

    public static let defaultTransferConcurrency = 1
    public static let transferConcurrencyRange = 1...4
    public static let defaultTransferHistoryLimit = 500
    /// 0 = không giới hạn.
    public static let transferHistoryChoices = [100, 500, 1000, 0]
    public static let clipboardChoices = [10, 30, 60, 90]
    public static let defaultClipboardSeconds = 30
    public static let analystRetentionRange = 10...200
    public static let defaultAnalystRetention = 50
    public static let monitorIntervalChoices = [5, 10, 30]
    public static let defaultMonitorInterval = 5

    public static let `default` = AppSettings()

    public init() {}

    // MARK: - Khoá lưu trữ

    enum Key {
        static let defaultLocalDirectory = "general.default_local_directory"
        static let closeBehavior = "general.close_behavior"
        static let warpOpenMode = "warp.open_mode"
        static let transferConcurrency = "transfer.concurrency"
        static let transferHistoryLimit = "transfer.history_limit"
        static let userSSHConfigPath = "ssh.user_config_path"
        static let defaultIdentityAgent = "ssh.default_identity_agent"
        static let autofillEnabled = "security.autofill_enabled"
        static let promptMissingPassword = "security.prompt_missing_password"
        static let clipboardClearSeconds = "security.clipboard_clear_seconds"
        static let analystRetention = "analyst.retention"
        static let analystProbeTimeout = "analyst.probe_timeout"
        static let monitorInterval = "monitor.interval"
        static let monitorWarning = "monitor.warning"
        static let monitorDanger = "monitor.danger"
        static let rdpFullScreen = "rdp.full_screen"
        static let rdpMultiMonitor = "rdp.multi_monitor"
        static let rdpRedirectClipboard = "rdp.redirect_clipboard"
    }

    /// Đọc từ cặp khoá/giá trị đã lưu. Không ném lỗi.
    public init(values: [String: String]) {
        func int(_ key: String) -> Int? { values[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            switch values[key] {
            case "1", "true": return true
            case "0", "false": return false
            default: return fallback
            }
        }
        func choice(_ key: String, _ allowed: [Int], _ fallback: Int) -> Int {
            if let v = int(key), allowed.contains(v) { return v }
            return fallback
        }

        if let p = values[Key.defaultLocalDirectory], Self.isPlausiblePath(p) { defaultLocalDirectory = p }
        closeBehavior = values[Key.closeBehavior].flatMap(CloseBehavior.init(rawValue:)) ?? .quit
        warpOpenMode = values[Key.warpOpenMode].flatMap(WarpOpenMode.init(rawValue:)) ?? .tab
        transferConcurrency = Self.clamp(
            int(Key.transferConcurrency), Self.transferConcurrencyRange, Self.defaultTransferConcurrency)
        transferHistoryLimit = choice(
            Key.transferHistoryLimit, Self.transferHistoryChoices, Self.defaultTransferHistoryLimit)
        if let p = values[Key.userSSHConfigPath], Self.isPlausiblePath(p) { userSSHConfigPath = p }
        if let a = values[Key.defaultIdentityAgent], IdentityAgentPath.isValid(a) { defaultIdentityAgent = a }
        autofillEnabled = bool(Key.autofillEnabled, true)
        promptMissingPassword = bool(Key.promptMissingPassword, true)
        clipboardClearSeconds = choice(
            Key.clipboardClearSeconds, Self.clipboardChoices, Self.defaultClipboardSeconds)
        analystRetention = Self.clamp(
            int(Key.analystRetention), Self.analystRetentionRange, Self.defaultAnalystRetention)
        analystProbeTimeout = int(Key.analystProbeTimeout).map(ProbeTimeout.init) ?? .default
        monitorIntervalSeconds = choice(
            Key.monitorInterval, Self.monitorIntervalChoices, Self.defaultMonitorInterval)
        monitorThresholds = MonitorThresholds(
            warning: int(Key.monitorWarning) ?? MonitorThresholds.defaultWarning,
            danger: int(Key.monitorDanger) ?? MonitorThresholds.defaultDanger)
        rdpFullScreen = bool(Key.rdpFullScreen, true)
        rdpMultiMonitor = bool(Key.rdpMultiMonitor, false)
        rdpRedirectClipboard = bool(Key.rdpRedirectClipboard, true)
    }

    /// Cặp khoá/giá trị để lưu (đã chuẩn hoá qua `normalized`).
    public var values: [String: String] {
        let s = normalized
        return [
            Key.defaultLocalDirectory: s.defaultLocalDirectory,
            Key.closeBehavior: s.closeBehavior.rawValue,
            Key.warpOpenMode: s.warpOpenMode.rawValue,
            Key.transferConcurrency: String(s.transferConcurrency),
            Key.transferHistoryLimit: String(s.transferHistoryLimit),
            Key.userSSHConfigPath: s.userSSHConfigPath,
            Key.defaultIdentityAgent: s.defaultIdentityAgent,
            Key.autofillEnabled: s.autofillEnabled ? "1" : "0",
            Key.promptMissingPassword: s.promptMissingPassword ? "1" : "0",
            Key.clipboardClearSeconds: String(s.clipboardClearSeconds),
            Key.analystRetention: String(s.analystRetention),
            Key.analystProbeTimeout: String(s.analystProbeTimeout.seconds),
            Key.monitorInterval: String(s.monitorIntervalSeconds),
            Key.monitorWarning: String(s.monitorThresholds.warning),
            Key.monitorDanger: String(s.monitorThresholds.danger),
            Key.rdpFullScreen: s.rdpFullScreen ? "1" : "0",
            Key.rdpMultiMonitor: s.rdpMultiMonitor ? "1" : "0",
            Key.rdpRedirectClipboard: s.rdpRedirectClipboard ? "1" : "0",
        ]
    }

    /// Đưa mọi trường về phạm vi hợp lệ (dùng khi UI gán giá trị tuỳ ý).
    public var normalized: AppSettings { AppSettings(values: rawValues) }

    private var rawValues: [String: String] {
        [
            Key.defaultLocalDirectory: defaultLocalDirectory,
            Key.closeBehavior: closeBehavior.rawValue,
            Key.warpOpenMode: warpOpenMode.rawValue,
            Key.transferConcurrency: String(transferConcurrency),
            Key.transferHistoryLimit: String(transferHistoryLimit),
            Key.userSSHConfigPath: userSSHConfigPath,
            Key.defaultIdentityAgent: defaultIdentityAgent,
            Key.autofillEnabled: autofillEnabled ? "1" : "0",
            Key.promptMissingPassword: promptMissingPassword ? "1" : "0",
            Key.clipboardClearSeconds: String(clipboardClearSeconds),
            Key.analystRetention: String(analystRetention),
            Key.analystProbeTimeout: String(analystProbeTimeout.seconds),
            Key.monitorInterval: String(monitorIntervalSeconds),
            Key.monitorWarning: String(monitorThresholds.warning),
            Key.monitorDanger: String(monitorThresholds.danger),
            Key.rdpFullScreen: rdpFullScreen ? "1" : "0",
            Key.rdpMultiMonitor: rdpMultiMonitor ? "1" : "0",
            Key.rdpRedirectClipboard: rdpRedirectClipboard ? "1" : "0",
        ]
    }

    private static func clamp(_ v: Int?, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        guard let v else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// Đường dẫn tuyệt đối, không ký tự điều khiển, không `%`, không rỗng. Chỉ kiểm tra cú pháp.
    static func isPlausiblePath(_ p: String) -> Bool {
        if p.isEmpty { return true }  // rỗng = mặc định
        return (try? SSHConfigWriter.validatePath(p, field: "path")) != nil
    }

    // MARK: - Đường dẫn config người dùng (Include)

    public enum ConfigPathError: Error, Equatable {
        case notAbsolute
        case controlCharacter
        case unsupportedCharacter
        case notFound
        case notAFile
    }

    /// Kiểm tra đường dẫn do người dùng nhập: tuyệt đối, không ký tự điều khiển, không `%`, tồn tại, là file.
    public static func validateUserConfigPath(
        _ path: String, fileManager: FileManager = .default
    ) throws {
        do { try SSHConfigWriter.validatePath(path, field: "userConfigPath") } catch let e as SSHConfigError {
            switch e {
            case .pathNotAbsolute: throw ConfigPathError.notAbsolute
            case .controlCharacter: throw ConfigPathError.controlCharacter
            default: throw ConfigPathError.unsupportedCharacter
            }
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            throw ConfigPathError.notFound
        }
        guard !isDir.boolValue else { throw ConfigPathError.notAFile }
    }

    /// Đường dẫn thật sự `Include`: cài đặt (nếu hợp lệ + tồn tại) hoặc `~/.ssh/config` (nếu tồn tại); nil = không Include.
    public func effectiveUserConfigPath(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileManager: FileManager = .default
    ) -> String? {
        let candidate = userSSHConfigPath.isEmpty ? home + "/.ssh/config" : userSSHConfigPath
        guard (try? Self.validateUserConfigPath(candidate, fileManager: fileManager)) != nil else {
            return nil
        }
        return candidate
    }

    // MARK: - Thư mục local mặc định

    /// Thư mục local dùng khi mở panel/sheet: cài đặt nếu là thư mục tồn tại, không thì `~/Downloads`.
    public func resolvedLocalDirectory(
        home: String = NSHomeDirectory(), fileManager: FileManager = .default
    ) -> String {
        if !defaultLocalDirectory.isEmpty {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: defaultLocalDirectory, isDirectory: &isDir), isDir.boolValue {
                return defaultLocalDirectory
            }
        }
        return home + "/Downloads"
    }
}

/// Timeout probe kết nối của Project Analyst, số nguyên giây đã kẹp 1–10. Chỉ giá trị này được ghép vào lệnh
/// whitelist (ADR-016/021): không có đường nào đưa chuỗi tuỳ ý vào.
public struct ProbeTimeout: Equatable, Hashable, Sendable {
    public static let range = 1...10
    public static let defaultSeconds = 3
    public static let `default` = ProbeTimeout(Self.defaultSeconds)

    public let seconds: Int

    public init(_ seconds: Int) {
        self.seconds = min(max(seconds, Self.range.lowerBound), Self.range.upperBound)
    }
}

/// Ngưỡng vàng/đỏ của Monitor (ADR-021): vàng 50–95, đỏ trong (vàng, 99].
public struct MonitorThresholds: Equatable, Hashable, Sendable {
    public static let warningRange = 50...95
    public static let maxDanger = 99
    public static let defaultWarning = 80
    public static let defaultDanger = 90
    public static let `default` = MonitorThresholds(
        warning: defaultWarning, danger: defaultDanger)

    public let warning: Int
    public let danger: Int

    public init(warning: Int, danger: Int) {
        let w = min(max(warning, Self.warningRange.lowerBound), Self.warningRange.upperBound)
        self.warning = w
        self.danger = min(max(danger, w + 1), Self.maxDanger)
    }
}
