import Foundation

// ADR-018b: tự gõ mật khẩu vào Windows App bằng Trợ năng. File này chỉ có logic thuần + protocol + vòng chờ;
// cài đặt AX/CGEvent thật nằm ở `WindowsAutotypeSystem.swift`. Không log, không lưu mật khẩu.

/// Ảnh chụp trạng thái giao diện lúc kiểm tra. Không chứa giá trị ô mật khẩu (chỉ độ dài nếu đọc được).
public struct WindowsUISnapshot: Sendable, Equatable {
    /// App đang ở trước (`frontmostApplication`).
    public var frontmostBundleID: String?
    public var frontmostPID: Int32?
    /// Subrole của phần tử đang focus CỦA CHÍNH pid trước (vd `AXSecureTextField`).
    public var focusedSubrole: String?
    /// Số ký tự của ô đang focus nếu đọc được; nil = không biết.
    public var fieldLength: Int?

    public init(
        frontmostBundleID: String? = nil, frontmostPID: Int32? = nil, focusedSubrole: String? = nil,
        fieldLength: Int? = nil
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostPID = frontmostPID
        self.focusedSubrole = focusedSubrole
        self.fieldLength = fieldLength
    }
}

/// Đọc quyền Trợ năng và trạng thái giao diện (cài đặt thật: AX; test: bản giả).
public protocol WindowsAutotypeProbe: Sendable {
    func isTrusted() -> Bool
    /// Hiện hộp thoại xin quyền của hệ thống (người dùng tự bật trong Cài đặt hệ thống).
    func requestTrust()
    func snapshot() -> WindowsUISnapshot
}

/// Gửi phím tới đúng một tiến trình (cài đặt thật: CGEvent `postToPid`).
public protocol WindowsKeyTyper: Sendable {
    /// Gõ một đoạn Unicode ngắn vào `pid`. false nếu không gửi được.
    func type(_ chunk: String, toPID pid: Int32) -> Bool
    func pressReturn(toPID pid: Int32) -> Bool
}

/// Lý do rơi về clipboard (ADR-018).
public enum WindowsAutotypeFallback: Sendable, Equatable {
    /// Cài đặt "Tự gõ mật khẩu" đang tắt.
    case autotypeDisabled
    /// Chưa cấp quyền Trợ năng.
    case noPermission
    /// Hết 30 giây không thấy ô mật khẩu.
    case timedOut
    /// Mật khẩu chứa ký tự điều khiển (Tab/Enter...) — gõ tự động không an toàn.
    case unsupportedCharacters
}

/// Lý do dừng hẳn (KHÔNG copy clipboard).
public enum WindowsAutotypeAbort: Sendable, Equatable {
    case notWindowsHost
    case autofillDisabled
    /// Mất điều kiện giữa lúc đang gõ (đổi cửa sổ / ô khác).
    case focusChanged
    case permissionLost
    case sendFailed
    case cancelled
}

public enum WindowsAutotypeOutcome: Sendable, Equatable {
    case typed
    case fallbackClipboard(WindowsAutotypeFallback)
    case aborted(WindowsAutotypeAbort)
    /// Bị huỷ khi còn đang chờ (bấm Mở lần nữa); chưa gõ gì.
    case cancelled

    /// Thông báo cho người dùng; nil = không cần báo (đã huỷ).
    public func message(clearSeconds: Int) -> String? {
        let paste = "dán (⌘V) vào Windows App. Tự xoá sau \(clearSeconds) giây."
        switch self {
        case .typed: return "Đã tự gõ mật khẩu vào Windows App."
        case .cancelled: return nil
        case .fallbackClipboard(let reason):
            switch reason {
            case .noPermission:
                return "Cấp quyền Trợ năng cho SSH Desk để tự gõ mật khẩu; lần này dùng clipboard — \(paste)"
            case .timedOut:
                return "Không thấy ô mật khẩu của Windows App sau 30 giây — đã copy mật khẩu, \(paste)"
            case .unsupportedCharacters:
                return "Mật khẩu có ký tự đặc biệt không tự gõ được — đã copy mật khẩu, \(paste)"
            case .autotypeDisabled:
                return "Đã copy mật khẩu — \(paste)"
            }
        case .aborted(let reason):
            switch reason {
            case .focusChanged, .permissionLost, .sendFailed, .cancelled:
                return "Đã dừng tự gõ vì cửa sổ đổi — hãy xoá ô mật khẩu và nhập lại."
            case .notWindowsHost, .autofillDisabled:
                return nil
            }
        }
    }
}

/// Quyết định thuần + chia đoạn. Có test bảng.
public enum WindowsPasswordAutotype {
    public static let windowsAppBundleID = "com.microsoft.rdc.macos"
    public static let secureFieldSubrole = "AXSecureTextField"
    public static let defaultTimeout: TimeInterval = 30
    public static let defaultPollInterval: TimeInterval = 0.3
    /// Số UTF-16 unit tối đa mỗi đoạn gửi bằng `keyboardSetUnicodeString`.
    public static let maxChunkUnits = 20

    struct Input: Equatable {
        enum Phase: Equatable {
            case waiting
            /// Đã khoá pid của Windows App; mọi lần kiểm lại phải đúng pid này.
            case typing(pid: Int32)
        }
        var isWindowsHost = true
        var autofillEnabled = true
        var autotypeEnabled = true
        var accessibilityTrusted = true
        var snapshot = WindowsUISnapshot()
        var waited: TimeInterval = 0
        var timeout: TimeInterval = WindowsPasswordAutotype.defaultTimeout
        var phase: Phase = .waiting
    }

    enum Decision: Equatable {
        case wait
        case type(pid: Int32)
        case fallbackClipboard(WindowsAutotypeFallback)
        case abort(WindowsAutotypeAbort)
    }

    /// pid của Windows App nếu nó đang ở trước VÀ phần tử focus của chính pid đó là ô mật khẩu.
    static func secureFieldPID(_ s: WindowsUISnapshot) -> Int32? {
        guard s.frontmostBundleID == windowsAppBundleID, let pid = s.frontmostPID,
            s.focusedSubrole == secureFieldSubrole
        else { return nil }
        return pid
    }

    static func decide(_ i: Input) -> Decision {
        guard i.isWindowsHost else { return .abort(.notWindowsHost) }
        guard i.autofillEnabled else { return .abort(.autofillDisabled) }
        switch i.phase {
        case .waiting:
            guard i.autotypeEnabled else { return .fallbackClipboard(.autotypeDisabled) }
            guard i.accessibilityTrusted else { return .fallbackClipboard(.noPermission) }
            // Ô phải rỗng nếu đọc được độ dài (không biết = chấp nhận).
            if let pid = secureFieldPID(i.snapshot), (i.snapshot.fieldLength ?? 0) == 0 { return .type(pid: pid) }
            return i.waited >= i.timeout ? .fallbackClipboard(.timedOut) : .wait
        case .typing(let locked):
            guard i.accessibilityTrusted else { return .abort(.permissionLost) }
            if let pid = secureFieldPID(i.snapshot), pid == locked { return .type(pid: pid) }
            return .abort(.focusChanged)
        }
    }

    /// Chia theo scalar Unicode, mỗi đoạn tối đa `maxUnits` UTF-16 unit; không bao giờ tách cặp surrogate.
    public static func chunks(of text: String, maxUnits: Int = maxChunkUnits) -> [String] {
        let limit = max(maxUnits, 2)  // một scalar ngoài BMP cần 2 unit
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var units = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if units + width > limit {
                result.append(String(current))
                current = String.UnicodeScalarView()
                units = 0
            }
            current.append(scalar)
            units += width
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// Có gõ tự động an toàn không: không rỗng, không ký tự điều khiển (Tab/Enter sẽ đổi ô hoặc gửi form).
    public static func isTypable(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        for scalar in password.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029 { return false }
        }
        return true
    }
}

/// Vòng chờ + gõ. Huỷ được (Task); không giữ mật khẩu sau khi `run` trả về.
public struct WindowsPasswordAutotyper: Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    public typealias Clock = @Sendable () -> TimeInterval

    public static let systemSleep: Sleep = { try await Task.sleep(for: .seconds($0)) }
    public static let systemClock: Clock = { ProcessInfo.processInfo.systemUptime }

    private let probe: any WindowsAutotypeProbe
    private let typer: any WindowsKeyTyper
    private let sleep: Sleep
    private let clock: Clock
    public var pollInterval = WindowsPasswordAutotype.defaultPollInterval
    public var timeout = WindowsPasswordAutotype.defaultTimeout
    /// Nghỉ ngắn giữa các đoạn để app đích kịp nhận.
    public var chunkDelay: TimeInterval = 0.02

    public init(
        probe: any WindowsAutotypeProbe, typer: any WindowsKeyTyper,
        sleep: @escaping Sleep = WindowsPasswordAutotyper.systemSleep,
        clock: @escaping Clock = WindowsPasswordAutotyper.systemClock
    ) {
        self.probe = probe
        self.typer = typer
        self.sleep = sleep
        self.clock = clock
    }

    /// Chờ ô mật khẩu của Windows App rồi gõ đúng một lần. Việc copy clipboard khi rơi về do bên gọi làm.
    /// `stillAllowed`: gọi mỗi vòng chờ và trước mỗi đoạn/Return (tự điền còn bật, host không bị hold...);
    /// false → `.aborted(.autofillDisabled)`, không gõ tiếp và không copy clipboard.
    public func run(
        password: String, isWindowsHost: Bool = true, autofillEnabled: Bool, autotypeEnabled: Bool,
        stillAllowed: @escaping @Sendable () -> Bool = { true }
    ) async -> WindowsAutotypeOutcome {
        var input = WindowsPasswordAutotype.Input(
            isWindowsHost: isWindowsHost, autofillEnabled: autofillEnabled, autotypeEnabled: autotypeEnabled,
            timeout: timeout)
        // Các điều kiện không cần chờ: trả ngay, không đụng AX.
        switch WindowsPasswordAutotype.decide(input) {
        case .abort(let reason): return .aborted(reason)
        case .fallbackClipboard(let reason): return .fallbackClipboard(reason)
        case .wait, .type: break
        }
        guard WindowsPasswordAutotype.isTypable(password) else { return .fallbackClipboard(.unsupportedCharacters) }

        let start = clock()
        var targetPID: Int32?
        while targetPID == nil {
            if Task.isCancelled { return .cancelled }
            if !stillAllowed() { return .aborted(.autofillDisabled) }
            input.accessibilityTrusted = probe.isTrusted()
            input.snapshot = input.accessibilityTrusted ? probe.snapshot() : WindowsUISnapshot()
            input.waited = clock() - start
            switch WindowsPasswordAutotype.decide(input) {
            case .wait:
                do { try await sleep(pollInterval) } catch { return .cancelled }
            case .fallbackClipboard(let reason):
                // Chưa có quyền: hỏi quyền một lần rồi dùng clipboard lần này.
                if reason == .noPermission { probe.requestTrust() }
                return .fallbackClipboard(reason)
            case .abort(let reason): return .aborted(reason)
            case .type(let pid): targetPID = pid
            }
        }
        guard let pid = targetPID else { return .cancelled }
        return await typeLocked(password, pid: pid, base: input, stillAllowed: stillAllowed)
    }

    /// Kiểm lại điều kiện trước MỖI đoạn và trước Return; mất điều kiện → dừng, không clipboard.
    private func typeLocked(
        _ password: String, pid: Int32, base: WindowsPasswordAutotype.Input,
        stillAllowed: @Sendable () -> Bool
    ) async -> WindowsAutotypeOutcome {
        var input = base
        input.phase = .typing(pid: pid)
        func recheck() -> WindowsAutotypeAbort? {
            if !stillAllowed() { return .autofillDisabled }
            input.accessibilityTrusted = probe.isTrusted()
            input.snapshot = input.accessibilityTrusted ? probe.snapshot() : WindowsUISnapshot()
            switch WindowsPasswordAutotype.decide(input) {
            case .type: return nil
            case .abort(let reason): return reason
            case .wait, .fallbackClipboard: return .focusChanged
            }
        }
        let chunks = WindowsPasswordAutotype.chunks(of: password)
        for (index, chunk) in chunks.enumerated() {
            if Task.isCancelled { return .aborted(.cancelled) }
            if let reason = recheck() { return .aborted(reason) }
            guard typer.type(chunk, toPID: pid) else { return .aborted(.sendFailed) }
            if index < chunks.count - 1 {
                do { try await sleep(chunkDelay) } catch { return .aborted(.cancelled) }
            }
        }
        if Task.isCancelled { return .aborted(.cancelled) }
        if let reason = recheck() { return .aborted(reason) }
        guard typer.pressReturn(toPID: pid) else { return .aborted(.sendFailed) }
        return .typed
    }
}
