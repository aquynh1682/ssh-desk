import Darwin
import Foundation

/// Chạy một executable (argv, không shell) trên PTY với slave là controlling terminal của con.
///
/// - `posix_spawn` + `POSIX_SPAWN_SETSID`: con là leader của session/process group mới (pgid == pid).
///   Trên Darwin file action `addopen` chạy trước setsid nên slave KHÔNG thành controlling tty. Vì vậy
///   ta spawn helper `sshdesk-ctty` (không phải shell): nó mở slave, `TIOCSCTTY`, dup2 lên 0/1/2 rồi
///   `execv` chương trình đích. exec giữ pid => pid/pgid trả về vẫn là của chương trình đích.
/// - ECHO tắt trên slave: thứ ta `send` không bị tty echo lại.
/// - Một thread đọc riêng (poll) nên không chặn UI/actor; đọc cạn output cuối trước khi báo exit.
/// - Password/passphrase chỉ đi qua `send`; không bao giờ vào argv/env.
public final class PTYProcess: @unchecked Sendable {
    public let pid: pid_t
    public let events: AsyncStream<ProcessEvent>

    private let continuation: AsyncStream<ProcessEvent>.Continuation
    private let lock = NSLock()
    private var master: Int32
    private var cancelled = false
    private var reaped = false
    private var secrets: [String] = []

    /// Thời gian chờ SIGTERM trước khi SIGKILL cả process group.
    public static let killGrace: TimeInterval = 3

    private init(
        pid: pid_t, master: Int32, events: AsyncStream<ProcessEvent>,
        continuation: AsyncStream<ProcessEvent>.Continuation
    ) {
        self.pid = pid
        self.master = master
        self.events = events
        self.continuation = continuation
    }

    /// `helper`: đường dẫn `sshdesk-ctty`; nil = tự tìm (`ControllingTTYHelper.defaultURL`).
    public static func start(
        executable: URL, arguments: [String], environment: [String: String],
        helper: URL? = nil
    ) throws -> PTYProcess {
        let path = executable.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw PTYProcessError.spawnFailed(ENOENT)
        }
        guard let helperURL = helper ?? ControllingTTYHelper.defaultURL() else {
            throw PTYProcessError.helperNotFound
        }
        let helperPath = helperURL.path
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw PTYProcessError.helperNotFound
        }
        let argv = [path] + arguments
        for s in argv where s.utf8.contains(0) { throw PTYProcessError.invalidArgument("NUL trong argv") }
        for (k, v) in environment {
            if k.isEmpty || k.contains("=") || k.utf8.contains(0) || v.utf8.contains(0) {
                throw PTYProcessError.invalidArgument("environment không hợp lệ: \(k)")
            }
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var nameBuf = [CChar](repeating: 0, count: 128)
        var ws = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, &nameBuf, nil, &ws) == 0 else {
            throw PTYProcessError.ptyFailed(errno)
        }
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slaveFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)

        // Tắt echo trước khi spawn.
        var tio = termios()
        if tcgetattr(slaveFD, &tio) == 0 {
            tio.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL | ECHOCTL | ECHOKE)
            _ = tcsetattr(slaveFD, TCSANOW, &tio)
        }

        var fa: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&fa)
            posix_spawnattr_destroy(&attr)
        }
        // Slave làm 0/1/2 cho helper; helper tự gán controlling tty. CLOEXEC_DEFAULT: con không
        // thừa kế bất kỳ fd nào ngoài 0/1/2.
        posix_spawn_file_actions_addopen(&fa, 0, nameBuf, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        let flags = Int32(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, Int16(flags))

        // helper argv: [helper, ttyPath, executable, args...]
        let ttyPath = String(cString: nameBuf)
        let helperArgv = [helperPath, ttyPath] + argv
        let cArgv: [UnsafeMutablePointer<CChar>?] = helperArgv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in cArgv { free(p) }
            for p in cEnv { free(p) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, helperPath, &fa, &attr, cArgv, cEnv)
        close(slaveFD)  // con đã có bản riêng; cha không giữ slave.
        guard rc == 0 else {
            close(masterFD)
            throw PTYProcessError.spawnFailed(rc)
        }

        let (stream, cont) = AsyncStream<ProcessEvent>.makeStream(bufferingPolicy: .unbounded)
        let fdForThread = masterFD
        let proc = PTYProcess(pid: childPID, master: fdForThread, events: stream, continuation: cont)
        let thread = Thread { proc.readLoop(fd: fdForThread) }
        thread.name = "PTYProcess.read.\(childPID)"
        thread.start()
        return proc
    }

    /// Ghi `input` + "\n" vào master. `redact`: che chuỗi này nếu con in lại trong output
    /// (đặt false cho phản hồi không bí mật như "yes").
    public func send(_ input: String, redact: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0 else { return }
        if redact, !input.isEmpty { secrets.append(input) }
        let bytes = Array((input + "\n").utf8)
        var offset = 0
        var stalls = 0
        while offset < bytes.count, stalls < 50 {
            let n = bytes[offset...].withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
                stalls = 0
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                stalls += 1
                var p = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 100)
            } else {
                return
            }
        }
    }

    /// SIGTERM tới process group của job; sau `killGrace` giây chưa xong thì SIGKILL group.
    /// Chỉ nhắm đúng `-pgid` của job này.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped, !cancelled else { return }
        cancelled = true
        kill(-pid, SIGTERM)
        let pgid = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            lock.lock()
            defer { lock.unlock() }
            // `reaped` chặn việc bắn vào một pgid đã được hệ thống tái sử dụng.
            if !reaped { kill(-pgid, SIGKILL) }
        }
    }

    // MARK: - Đọc

    private func readLoop(fd: Int32) {
        var sanitizer = OutputSanitizer()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var status: Int32 = 0
        var exited = false
        var eof = false

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            let redacted = redact(text)
            if !redacted.isEmpty { continuation.yield(.output(redacted)) }
        }

        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Đã thoát: chỉ đọc nốt phần còn trong buffer của pty (không chờ).
            // Sau EOF không poll nữa (POLLHUP sẽ trả về ngay mãi mãi).
            let r = eof ? 0 : poll(&p, 1, exited ? 0 : 50)
            if r > 0, p.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    emit(sanitizer.feed(Array(buffer[0..<n])))
                    continue
                }
                if n < 0, errno == EAGAIN || errno == EINTR { continue }
                eof = true  // 0 hoặc EIO: slave đã đóng hết.
                continue
            }
            if r < 0, errno == EINTR { continue }
            // Không còn dữ liệu sẵn sàng.
            if exited { break }
            var st: Int32 = 0
            let w = waitpid(pid, &st, WNOHANG)
            if w == pid {
                status = st
                exited = true
                lock.lock()
                reaped = true
                // Quét nốt thành viên còn sót của group (chỉ khi do cancel); pid vừa reap nên chưa tái sử dụng.
                if cancelled { kill(-pid, SIGKILL) }
                lock.unlock()
            } else if w < 0, errno != EINTR {
                exited = true  // mất dấu con (không nên xảy ra)
                lock.lock()
                reaped = true
                lock.unlock()
            } else if eof {
                usleep(20_000)
            }
        }

        emit(sanitizer.finish())
        lock.lock()
        close(master)
        master = -1
        let wasCancelled = cancelled
        secrets.removeAll()
        lock.unlock()

        let exit: ProcessExit
        if wasCancelled {
            exit = .cancelled
        } else if status & 0x7F == 0 {
            exit = .exited((status >> 8) & 0xFF)
        } else {
            exit = .signaled(status & 0x7F)
        }
        continuation.yield(.exit(exit))
        continuation.finish()
    }

    private func redact(_ text: String) -> String {
        lock.lock()
        let list = secrets.sorted { $0.count > $1.count }
        lock.unlock()
        var result = text
        for s in list where result.contains(s) {
            result = result.replacingOccurrences(of: s, with: "•••")
        }
        return result
    }
}
