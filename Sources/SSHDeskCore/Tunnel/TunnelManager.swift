import Darwin
import Foundation

/// Trạng thái một tunnel (ADR-011): Dừng / Đang kết nối / Đang chạy / Lỗi (kèm lý do đã làm sạch).
public enum TunnelStatus: Sendable, Equatable {
    case stopped
    case connecting
    case running
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .connecting, .running: return true
        case .stopped, .failed: return false
        }
    }
}

public enum TunnelEvent: Sendable, Equatable {
    case statusChanged(forwardID: UUID, hostID: UUID, status: TunnelStatus)
    /// ssh cần người dùng trả lời (host key, passphrase, OTP...). Trả lời bằng `TunnelManager.respond`.
    case authPrompt(forwardID: UUID, hostID: UUID, kind: PromptKind)
}

/// Dựng argv của phiên tunnel. Không shell; mọi giá trị là một phần tử argv riêng.
public enum TunnelCommand {
    /// `-F <cfg> -N -o ExitOnForwardFailure=yes -o ControlMaster=no -o ControlPath=none
    ///  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 127.0.0.1:<lp>:<rh>:<rp> -- <alias>` (đúng ADR-011).
    /// Không `BatchMode`: prompt xác thực đi qua PTY. Bind luôn `127.0.0.1` (không mở ra LAN).
    public static func arguments(configPath: String, alias: String, forward: PortForward) throws
        -> [String]
    {
        let f = try forward.validated()
        try SSHConfigWriter.validatePath(configPath, field: "configPath")
        try SSHConfigWriter.validateAlias(alias)
        return [
            "-F", configPath, "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(f.localPort):\(f.remoteHost):\(f.remotePort)",
            "--", alias,
        ]
    }
}

/// Kiểm tra cổng local bằng cách thử bind.
public enum PortProbe {
    /// true nếu KHÔNG bind được `127.0.0.1:<port>` (đang có chương trình khác giữ cổng).
    /// Cố ý không đặt SO_REUSEADDR: listener trên 0.0.0.0 cũng bị coi là bận.
    public static func isBusy(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return true }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return r != 0
    }
}

/// Chạy và quản lý các phiên `ssh -N -L` (mỗi forward một tiến trình, qua PTY). ADR-011.
///
/// - Tự điền password đã lưu theo `PasswordAutofillPolicy`; prompt khác phát qua `events`.
/// - "Đang chạy" = cổng local đã bị ssh giữ (thử bind thất bại) — không nối thử vào forward để khỏi
///   kích hoạt kết nối tới dịch vụ phía server.
/// - Dừng = SIGTERM đúng process group của phiên đó (PTYProcess.cancel). Không tự chạy lại khi rớt.
public actor TunnelManager {
    public static let connectTimeout: TimeInterval = 60
    public static let pollInterval: TimeInterval = 0.15

    public nonisolated let events: AsyncStream<TunnelEvent>
    private let continuation: AsyncStream<TunnelEvent>.Continuation

    private let configPath: String
    private let credentials: any CredentialStore
    private let sshPath: String
    private let helper: URL?
    private let environment: [String: String]
    private let portBusy: @Sendable (Int) -> Bool

    private final class Entry {
        let runID = UUID()
        let forward: PortForward
        let host: HostProfile
        var status = TunnelStatus.connecting
        var pty: PTYProcess?
        var detector = PromptDetector()
        var filled = false
        var waitingUser = false
        var userStopped = false
        var tail = ""
        init(forward: PortForward, host: HostProfile) {
            self.forward = forward
            self.host = host
        }
    }

    private var entries: [UUID: Entry] = [:]
    /// Trạng thái cuối của tunnel đã kết thúc (Dừng / Lỗi) để UI hỏi lại.
    private var finished: [UUID: TunnelStatus] = [:]

    public init(
        configPath: String, credentials: any CredentialStore, helper: URL? = nil,
        sshPath: String = "/usr/bin/ssh",
        environment: [String: String] = ProcessEnvironment.inherited(),
        portBusy: @escaping @Sendable (Int) -> Bool = PortProbe.isBusy
    ) {
        self.configPath = configPath
        self.credentials = credentials
        self.helper = helper
        self.sshPath = sshPath
        self.environment = environment
        self.portBusy = portBusy
        let (stream, cont) = AsyncStream<TunnelEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    // MARK: - Truy vấn

    public func status(of forwardID: UUID) -> TunnelStatus {
        if let e = entries[forwardID] { return e.status }
        return finished[forwardID] ?? .stopped
    }

    public var activeCount: Int { entries.values.filter { $0.status.isActive }.count }

    // MARK: - Điều khiển

    /// Mở tunnel. Đang chạy/đang kết nối thì không làm gì. Lỗi (cổng bận, thiếu alias...) → trạng thái `.failed`.
    public func start(forward: PortForward, host: HostProfile) {
        if let e = entries[forward.id], e.status.isActive { return }
        entries[forward.id] = nil
        guard host.kind == .ssh, let alias = host.sshAlias, host.id == forward.hostID else {
            return fail(forward, host, "Hồ sơ không hợp lệ cho tunnel.")
        }
        let args: [String]
        do {
            args = try TunnelCommand.arguments(configPath: configPath, alias: alias, forward: forward)
        } catch {
            return fail(forward, host, "Cấu hình forward không hợp lệ.")
        }
        if portBusy(forward.localPort) {
            return fail(
                forward, host,
                "Cổng 127.0.0.1:\(forward.localPort) đang bận (một chương trình khác đang dùng). Hãy đổi cổng local hoặc tắt chương trình đó."
            )
        }
        let entry = Entry(forward: forward, host: host)
        let proc: PTYProcess
        do {
            proc = try PTYProcess.start(
                executable: URL(fileURLWithPath: sshPath), arguments: args,
                environment: environment, helper: helper)
        } catch {
            return fail(forward, host, "Không chạy được ssh (\(error)).")
        }
        entry.pty = proc
        finished[forward.id] = nil
        entries[forward.id] = entry
        emitStatus(entry)
        let runID = entry.runID
        let id = forward.id
        Task { [weak self] in
            for await event in proc.events { await self?.handle(event, forwardID: id, runID: runID) }
        }
        Task { [weak self] in await self?.pollUntilRunning(forwardID: id, runID: runID) }
    }

    /// Trả lời prompt đang chờ. `isSecret`: che chuỗi này nếu ssh in lại.
    public func respond(forwardID: UUID, text: String, isSecret: Bool) {
        guard let e = entries[forwardID], e.status == .connecting, let pty = e.pty else { return }
        e.waitingUser = false
        pty.send(text, redact: isSecret)
    }

    /// SIGTERM đúng process group của tunnel này. Trạng thái thành `.stopped` khi tiến trình đã thoát.
    public func stop(forwardID: UUID) {
        guard let e = entries[forwardID], e.status.isActive else { return }
        e.userStopped = true
        e.pty?.cancel()
    }

    /// Dừng mọi tunnel của một host (vd trước khi xoá host) và chờ tiến trình thoát.
    public func stopAll(hostID: UUID) async {
        let ids = entries.values.filter { $0.host.id == hostID && $0.status.isActive }.map(\.forward.id)
        for id in ids { stop(forwardID: id) }
        await waitUntilExited(ids)
    }

    /// Dừng mọi tunnel và chờ tiến trình thoát (dùng khi thoát app).
    public func stopAll() async {
        let ids = entries.values.filter { $0.status.isActive }.map(\.forward.id)
        for id in ids { stop(forwardID: id) }
        await waitUntilExited(ids)
    }

    // MARK: - Nội bộ

    private func fail(_ forward: PortForward, _ host: HostProfile, _ reason: String) {
        finished[forward.id] = .failed(reason)
        continuation.yield(
            .statusChanged(forwardID: forward.id, hostID: host.id, status: .failed(reason)))
    }

    private func emitStatus(_ e: Entry) {
        continuation.yield(
            .statusChanged(forwardID: e.forward.id, hostID: e.host.id, status: e.status))
    }

    private func handle(_ event: ProcessEvent, forwardID: UUID, runID: UUID) async {
        guard let e = entries[forwardID], e.runID == runID else { return }
        switch event {
        case .output(let text):
            e.tail = String((e.tail + text).suffix(2000))
            guard e.status == .connecting else { return }
            guard let kind = e.detector.feed(text) else { return }
            if case .hostKeyChanged(let line) = kind {
                e.status = .failed("Host key của máy chủ đã thay đổi: \(line)")
                emitStatus(e)
                e.pty?.cancel()
                return
            }
            if PasswordAutofillPolicy.shouldAutofill(prompt: kind, host: e.host, alreadyFilled: e.filled),
                let ref = e.host.credentialReference
            {
                e.filled = true
                let store = credentials
                let password = await Task.detached { store.read(ref: ref) }.value
                guard entries[forwardID]?.runID == runID, e.status == .connecting else { return }
                if let password, !password.isEmpty {
                    e.pty?.send(password, redact: true)
                    return
                }
            }
            e.waitingUser = true
            continuation.yield(.authPrompt(forwardID: forwardID, hostID: e.host.id, kind: kind))
        case .exit(let exit):
            if e.userStopped {
                e.status = .stopped
            } else if e.status.isActive {
                e.status = .failed(
                    Self.reason(exit: exit, tail: e.tail, wasRunning: e.status == .running))
            }
            // Nếu đã đặt `.failed` trước đó (host key đổi, hết giờ) thì giữ nguyên lý do đó.
            finished[forwardID] = e.status
            entries[forwardID] = nil
            emitStatus(e)
        }
    }

    private func pollUntilRunning(forwardID: UUID, runID: UUID) async {
        var elapsed: TimeInterval = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            guard let e = entries[forwardID], e.runID == runID, e.status == .connecting else {
                return
            }
            if e.waitingUser { continue }
            if portBusy(e.forward.localPort) {
                e.status = .running
                emitStatus(e)
                return
            }
            elapsed += Self.pollInterval
            if elapsed >= Self.connectTimeout {
                e.status = .failed("Hết thời gian chờ kết nối (\(Int(Self.connectTimeout)) giây).")
                emitStatus(e)
                e.pty?.cancel()
                return
            }
        }
    }

    private func waitUntilExited(_ ids: [UUID]) async {
        let deadline = Date().addingTimeInterval(PTYProcess.killGrace + 3)
        while Date() < deadline, ids.contains(where: { entries[$0] != nil }) {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Lý do lỗi từ dòng cuối của output (đã làm sạch bởi PTYProcess), tối đa 300 ký tự.
    static func reason(exit: ProcessExit, tail: String, wasRunning: Bool) -> String {
        let lines = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        let last = String((lines.last ?? "").prefix(300))
        let prefix = wasRunning ? "Tunnel bị ngắt" : "ssh không mở được tunnel"
        switch exit {
        case .exited(let code):
            return last.isEmpty ? "\(prefix) (mã \(code))." : "\(prefix): \(last)"
        case .signaled(let sig):
            return "\(prefix) (tín hiệu \(sig))."
        case .cancelled:
            return "Đã huỷ."
        }
    }
}
