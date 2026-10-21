import Darwin
import Foundation

public enum SessionEvent: Sendable, Equatable {
    case authPrompt(PromptKind)
    case connected
    case disconnected(String)
}

public enum RemoteSessionError: Error, Equatable {
    case alreadyStarted
    /// Đã có master khác sống trên đúng socket này (cùng host đã mở ở nơi khác).
    case socketInUse(String)
    case staleSocketNotRemovable(String)
    case spawnFailed(String)
}

/// Một ControlMaster cho một alias + config (ADR-013). Master chạy qua PTY để prompt xác thực
/// đi qua `PromptDetector`; việc tự điền password là của tầng trên (chỉ phát prompt, nhận `respond`).
public actor RemoteSession {
    public static let connectTimeout: TimeInterval = 60
    public static let pollInterval: TimeInterval = 0.2

    public nonisolated let alias: String
    public nonisolated let configPath: String
    public nonisolated let controlPath: String
    public nonisolated let events: AsyncStream<SessionEvent>

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let sshPath: String
    private let helper: URL?
    private let environment: [String: String]

    private enum State { case idle, connecting, connected, closed }
    private var state = State.idle
    private var pty: PTYProcess?
    private var detector = PromptDetector()
    private var waitingUser = false
    private var ptyExited = false
    private var outputTail = ""
    private var readerTask: Task<Void, Never>?
    private var pollerTask: Task<Void, Never>?
    private var terminalEventSent = false

    public init(
        alias: String, configPath: String, controlPath: String,
        sshPath: String = "/usr/bin/ssh", helper: URL? = nil,
        environment: [String: String] = ProcessEnvironment.inherited()
    ) {
        self.alias = alias
        self.configPath = configPath
        self.controlPath = controlPath
        self.sshPath = sshPath
        self.helper = helper
        self.environment = environment
        let (stream, cont) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    /// Thư mục socket + `hostID` → ControlPath cố định (không `%C`).
    public init(
        alias: String, configPath: String, hostID: UUID, socketDirectory: SocketDirectory,
        sshPath: String = "/usr/bin/ssh", helper: URL? = nil,
        environment: [String: String] = ProcessEnvironment.inherited()
    ) {
        self.init(
            alias: alias, configPath: configPath,
            controlPath: socketDirectory.socketPath(hostID: hostID), sshPath: sshPath, helper: helper,
            environment: environment)
    }

    // MARK: - API

    /// Khởi chạy master. Lỗi đồng bộ (socket bị chiếm, không spawn được) được throw; mọi thứ sau đó
    /// đi qua `events`.
    public func start() async throws {
        guard state == .idle else { throw RemoteSessionError.alreadyStarted }
        state = .connecting
        do {
            if await runCheck() { throw RemoteSessionError.socketInUse(controlPath) }
            try removeStaleSocket()
            let args = [
                "-F", configPath, "-M", "-N",
                "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=no",
                "-o", "ServerAliveInterval=30", "--", alias,
            ]
            do {
                pty = try PTYProcess.start(
                    executable: URL(fileURLWithPath: sshPath), arguments: args,
                    environment: environment, helper: helper)
            } catch {
                throw RemoteSessionError.spawnFailed("\(error)")
            }
        } catch {
            state = .idle
            throw error
        }
        let proc = pty!
        readerTask = Task { [weak self] in
            for await event in proc.events { await self?.handle(event) }
        }
        pollerTask = Task { [weak self] in await self?.pollUntilConnected() }
    }

    /// Trả lời prompt. `isSecret`: che chuỗi này nếu ssh in lại.
    public func respond(text: String, isSecret: Bool) {
        guard state == .connecting, let pty else { return }
        waitingUser = false
        pty.send(text, redact: isSecret)
    }

    public func checkAlive() async -> Bool { await runCheck() }

    /// `ssh -O exit`, đợi master thoát ≤ 3 s, còn sống thì SIGTERM đúng process group của master.
    public func close() async {
        if state == .closed {
            removeSocketFileIfPresent()
            return
        }
        let wasIdle = state == .idle
        state = .closed
        pollerTask?.cancel()
        if !wasIdle, pty != nil, !ptyExited {
            _ = await run(["-O", "exit"], timeout: 5)
            if !(await waitForExit(seconds: 3)) {
                pty?.cancel()
                _ = await waitForExit(seconds: PTYProcess.killGrace + 3)
            }
        }
        readerTask?.cancel()
        removeSocketFileIfPresent()
        sendTerminal("Đã đóng")
    }

    /// PID của master (nil nếu chưa/không chạy) — để test/diagnostics.
    public var masterPID: pid_t? { ptyExited ? nil : pty?.pid }

    // MARK: - Nội bộ

    private func handle(_ event: ProcessEvent) {
        switch event {
        case .output(let text):
            outputTail = String((outputTail + text).suffix(2000))
            guard state == .connecting else { return }
            guard let kind = detector.feed(text) else { return }
            if case .hostKeyChanged(let line) = kind {
                fail("Host key của máy chủ đã thay đổi: \(line)")
            } else {
                waitingUser = true
                continuation.yield(.authPrompt(kind))
            }
        case .exit(let exit):
            ptyExited = true
            guard state == .connecting || state == .connected else { return }
            let last = lastLine()
            let wasConnected = state == .connected
            state = .closed
            pollerTask?.cancel()
            removeSocketFileIfPresent()
            switch exit {
            case .exited(let code):
                sendTerminal(
                    wasConnected
                        ? "Master ssh đã thoát (mã \(code))."
                        : "ssh thoát với mã \(code)" + (last.isEmpty ? "." : ": \(last)"))
            case .signaled(let sig):
                sendTerminal("Master ssh bị dừng bởi tín hiệu \(sig).")
            case .cancelled:
                sendTerminal("Đã huỷ.")
            }
        }
    }

    private func lastLine() -> String {
        let lines = outputTail.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return String((lines.last ?? "").prefix(300))
    }

    private func fail(_ reason: String) {
        guard state == .connecting || state == .connected else { return }
        state = .closed
        pollerTask?.cancel()
        pty?.cancel()
        sendTerminal(reason)
    }

    private func sendTerminal(_ reason: String) {
        guard !terminalEventSent else { return }
        terminalEventSent = true
        continuation.yield(.disconnected(reason))
        continuation.finish()
    }

    private func pollUntilConnected() async {
        var elapsed: TimeInterval = 0
        while state == .connecting, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            guard state == .connecting, !Task.isCancelled else { return }
            if await runCheck() {
                guard state == .connecting else { return }
                state = .connected
                continuation.yield(.connected)
                return
            }
            // Thời gian chờ người dùng nhập không tính vào timeout.
            if !waitingUser { elapsed += Self.pollInterval }
            if elapsed >= Self.connectTimeout {
                fail("Hết thời gian chờ kết nối (\(Int(Self.connectTimeout)) giây).")
                return
            }
        }
    }

    private func waitForExit(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ptyExited, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return ptyExited
    }

    private func run(_ extra: [String], timeout: TimeInterval) async -> SimpleProcessOutput? {
        try? await SimpleProcess.run(
            executable: sshPath,
            arguments: ["-F", configPath, "-o", "ControlPath=\(controlPath)"] + extra + ["--", alias],
            environment: environment, timeout: timeout)
    }

    private func runCheck() async -> Bool {
        guard let out = await run(["-O", "check"], timeout: 5) else { return false }
        return out.status == 0 && !out.timedOut
    }

    /// Xoá đúng file ControlPath nếu là socket cũ (master đã chết).
    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(controlPath, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw RemoteSessionError.staleSocketNotRemovable(controlPath)
        }
        if unlink(controlPath) != 0, errno != ENOENT {
            throw RemoteSessionError.staleSocketNotRemovable(controlPath)
        }
    }

    private func removeSocketFileIfPresent() {
        var st = stat()
        if lstat(controlPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK { unlink(controlPath) }
    }
}
