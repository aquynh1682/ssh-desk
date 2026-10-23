import Foundation

/// Sự kiện cho UI. Không bao giờ chứa password/OTP: `PromptKind` chỉ là câu hỏi của ssh.
public enum TransferEvent: Sendable, Equatable {
    case jobUpdated(TransferJob)
    /// Job đang ở `awaitingUserInput`; UI hỏi người dùng rồi gọi `respond`.
    case authPrompt(jobID: UUID, PromptKind)
    /// Job đã sang trạng thái kết thúc (phát sau `jobUpdated` cuối).
    case jobFinished(TransferJob)
}

public enum TransferManagerError: Error, Equatable {
    case hostNotFound(UUID)
    /// Alias hiện tại của host khác alias trong snapshot của job.
    case hostChanged(String)
    case localSourceMissing(String)
    /// Upload: nguồn là symlink hoặc cây chứa symlink (danh sách tương đối, `"."` = chính nguồn).
    case symlinksNotSupported([String])
    /// Download: đích đổi tên đã tồn tại.
    case localConflict(String)
    case jobNotFound(UUID)
    case notAwaitingInput(UUID)
    case notCancellable(TransferState)
}

/// Hàng đợi truyền file chạy thật (ADR-008): `scp` qua PTY, một job một process.
///
/// Heuristic `connecting → transferring`: dòng progress đầu tiên parse được bằng `ScpProgressParser`.
/// Không dùng "output đầu tiên" vì banner/`Permission denied, please try again` cũng là output.
/// Nếu scp thoát 0 mà chưa từng có dòng progress (file rỗng...), job đi qua `transferring` rồi mới
/// `finalizing` để đúng máy trạng thái. Chỉ nhận diện prompt khi đang `connecting`.
public actor TransferManager {
    private final class Run: @unchecked Sendable {
        let job: TransferJob
        var state: TransferState = .queued
        var process: PTYProcess?
        var task: Task<Void, Never>?
        var chain: Task<Void, Never> = Task {}
        var cancelRequested = false
        var fatalReason: String?
        var detector = PromptDetector()
        var lineBuffer = ""
        var tail: [String] = []
        var secrets: [String] = []
        /// Hồ sơ host hiện tại (để áp `PasswordAutofillPolicy`); nil = không tự điền.
        var autoFillHost: HostProfile?
        /// ControlPath của master còn sống lúc bắt đầu chạy (nil = scp tự kết nối).
        var controlPath: String?
        /// Đã tự điền (hoặc thử điền) password một lần: lần sau luôn hỏi người dùng.
        var autoFilled = false
        var progress = TransferProgress()
        var lastProgressWrite = Date.distantPast
        var progressDirty = false
        init(job: TransferJob) { self.job = job }
    }

    public nonisolated let events: AsyncStream<TransferEvent>
    private let continuation: AsyncStream<TransferEvent>.Continuation

    private let repository: TransferRepository
    private let hosts: HostRepository
    private var concurrency: Int
    private let extraSSHProgram: URL?
    private let environment: [String: String]
    private let progressInterval: TimeInterval
    private let ctty: URL?
    private let credentials: (any CredentialStore)?
    private let hostAdjuster: (@Sendable (HostProfile) -> HostProfile)?

    private var queue: [TransferJob] = []
    private var running: [UUID: Run] = [:]
    private var shuttingDown = false
    /// jobID → ControlPath mong muốn (trong bộ nhớ).
    private var controlPaths: [UUID: String] = [:]

    /// `extraSSHProgram`: CHỈ để test (thêm `-S <program>` cho scp). Production luôn nil.
    public init(
        repository: TransferRepository, hosts: HostRepository, concurrency: Int = 1,
        extraSSHProgram: URL? = nil,
        environment: [String: String] = ProcessEnvironment.inherited(),
        progressInterval: TimeInterval = 0.5,
        controllingTTYHelper: URL? = nil,
        credentials: (any CredentialStore)? = nil,
        hostAdjuster: (@Sendable (HostProfile) -> HostProfile)? = nil
    ) {
        self.hostAdjuster = hostAdjuster
        self.credentials = credentials
        self.ctty = controllingTTYHelper
        self.repository = repository
        self.hosts = hosts
        self.concurrency = max(1, concurrency)
        self.extraSSHProgram = extraSSHProgram
        self.environment = environment
        self.progressInterval = progressInterval
        (events, continuation) = AsyncStream<TransferEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Đổi số tác vụ chạy song song (1–4 ở Cài đặt). Tăng → chạy thêm job đang chờ ngay; giảm → job đang chạy
    /// không bị ngắt, chỉ không khởi động thêm cho tới khi số job đang chạy xuống dưới mức mới.
    public func setConcurrency(_ n: Int) {
        concurrency = max(1, n)
        pump()
    }

    public var hasActiveJobs: Bool { !running.isEmpty || !queue.isEmpty }

    // MARK: - API

    /// Kiểm tra lại rồi lưu job (queued) và đưa vào hàng đợi.
    ///
    /// `controlPath`: socket ControlMaster của tab duyệt file; scp dùng lại master đó nếu lúc chạy nó còn sống.
    /// Chỉ giữ trong bộ nhớ (không lưu DB): job khôi phục sau khi mở lại app luôn chạy không ControlPath.
    @discardableResult
    public func enqueue(_ job: TransferJob, controlPath: String? = nil) async throws -> TransferJob {
        var job = job
        job.state = .queued
        if let controlPath { try ScpCommandBuilder.validateControlPath(controlPath) }
        try await validate(job)
        try await repository.insert(job)
        if let controlPath { controlPaths[job.id] = controlPath }
        schedule(job)
        return job
    }

    /// Tạo job mới từ job lỗi/huỷ/gián đoạn (job cũ giữ nguyên), kiểm tra lại rồi xếp hàng.
    @discardableResult
    public func retry(jobID: UUID) async throws -> TransferJob {
        guard let old = try await repository.job(id: jobID) else {
            throw TransferManagerError.jobNotFound(jobID)
        }
        var probe = old
        probe.state = .queued
        try await validate(probe)
        let new = try await repository.retry(jobID: jobID)
        // Retry kiểm tra lại master lúc chạy: chết rồi thì tự bỏ ControlPath.
        if let cp = controlPaths[jobID] { controlPaths[new.id] = cp }
        schedule(new)
        return new
    }

    public func cancel(jobID: UUID) async throws {
        if let i = queue.firstIndex(where: { $0.id == jobID }) {
            queue.remove(at: i)
            let j = try await repository.transition(id: jobID, to: .cancelled, exit: .cancelled)
            publish(j)
            return
        }
        guard let run = running[jobID] else {
            guard let j = try await repository.job(id: jobID) else {
                throw TransferManagerError.jobNotFound(jobID)
            }
            throw TransferManagerError.notCancellable(j.state)
        }
        switch run.state {
        case .cancelling: return
        case .connecting, .awaitingUserInput, .transferring:
            run.cancelRequested = true
            apply(run, to: .cancelling)
            run.process?.cancel()
        default:
            throw TransferManagerError.notCancellable(run.state)
        }
    }

    /// Trả lời prompt đang chờ. `isSecret`: che chuỗi này nếu con in lại. Không lưu `text` ở đâu cả
    /// (trừ danh sách che trong bộ nhớ, bị xoá khi job kết thúc).
    public func respond(jobID: UUID, text: String, isSecret: Bool) async throws {
        guard let run = running[jobID], run.state == .awaitingUserInput, let p = run.process else {
            throw TransferManagerError.notAwaitingInput(jobID)
        }
        apply(run, to: .connecting)
        if isSecret, !text.isEmpty { run.secrets.append(text) }
        p.send(text, redact: isSecret)
    }

    /// Khởi động app: job dở dang → `interrupted`, dọn `.part` của chúng.
    @discardableResult
    public func recoverInterrupted() async throws -> [TransferJob] {
        var out: [TransferJob] = []
        for var job in try await repository.recoverInterrupted() {
            if let p = job.tempPartialPath, LocalFinalizer.localConflict(p) {
                if !LocalFinalizer.cleanupPartial(path: p, jobID: job.id) {
                    job.failureReason = TransferJob.sanitizeReason(
                        (job.failureReason ?? "") + " (không xoá được file tạm)")
                }
            }
            publish(job)
            out.append(job)
        }
        return out
    }

    /// Vòng đời app. Luôn ngừng khởi động job mới. `cancelRunning`: huỷ job đang chạy và chờ
    /// chúng dọn xong (job còn chờ thành `interrupted` ngay).
    public func shutdown(cancelRunning: Bool) async {
        shuttingDown = true
        guard cancelRunning else { return }
        let runs = Array(running.values)
        for run in runs {
            switch run.state {
            case .connecting, .awaitingUserInput, .transferring:
                run.cancelRequested = true
                apply(run, to: .cancelling)
                run.process?.cancel()
            default: break
            }
        }
        for run in runs { await run.task?.value }
        // Job còn chờ (chưa chạy) không thể chạy nữa: đánh dấu "Bị gián đoạn" ngay (ADR-022), dọn .part.
        queue.removeAll()
        _ = try? await recoverInterrupted()
        continuation.finish()
    }

    // MARK: - Kiểm tra trước khi xếp hàng

    private func validate(_ job: TransferJob) async throws {
        guard let host = try await hosts.host(id: job.hostID) else {
            throw TransferManagerError.hostNotFound(job.hostID)
        }
        guard let alias = host.sshAlias, alias == job.sshAliasSnapshot else {
            throw TransferManagerError.hostChanged(job.sshAliasSnapshot)
        }
        // Chặn đường dẫn/alias/config hỏng sớm (cùng bộ kiểm tra lúc chạy).
        _ = try ScpCommandBuilder.build(for: job)

        switch job.direction {
        case .upload:
            guard LocalFinalizer.localConflict(job.sourcePath) else {
                throw TransferManagerError.localSourceMissing(job.sourcePath)
            }
            let links = LocalTreeInspector.symlinks(at: job.sourcePath)
            if !links.isEmpty { throw TransferManagerError.symlinksNotSupported(links) }
        case .download:
            if case .rename(let name) = job.overwritePolicy {
                guard LocalFinalizer.validName(name) else {
                    throw LocalFinalizeError.invalidNewName(name)
                }
                let target = URL(fileURLWithPath: job.destinationPath)
                    .deletingLastPathComponent().appendingPathComponent(name).path
                if LocalFinalizer.localConflict(target) {
                    throw TransferManagerError.localConflict(target)
                }
            }
        }
    }

    // MARK: - Hàng đợi

    private func schedule(_ job: TransferJob) {
        queue.append(job)
        publish(job)
        pump()
    }

    private func pump() {
        guard !shuttingDown else { return }
        while running.count < concurrency, !queue.isEmpty {
            let job = queue.removeFirst()
            let run = Run(job: job)
            running[job.id] = run
            apply(run, to: .connecting)
            run.task = Task { await self.execute(run) }
        }
    }

    private func publish(_ job: TransferJob) {
        continuation.yield(.jobUpdated(job))
        if job.state.isTerminal { continuation.yield(.jobFinished(job)) }
    }

    /// Đổi state trong bộ nhớ ngay (đồng bộ), ghi DB theo đúng thứ tự qua `chain`.
    @discardableResult
    private func apply(
        _ run: Run, to new: TransferState, exit: TransferExitStatus? = nil,
        reason: String? = nil
    ) -> Bool {
        guard run.state != new, TransferStateMachine.isValid(from: run.state, to: new) else {
            return false
        }
        run.state = new
        let id = run.job.id
        let prev = run.chain
        run.chain = Task {
            await prev.value
            if let j = try? await self.repository.transition(
                id: id, to: new, exit: exit, failureReason: reason)
            {
                self.publish(j)
            }
        }
        return true
    }

    private func chainOp(
        _ run: Run, _ op: @escaping @Sendable (isolated TransferManager) async -> Void
    ) {
        let prev = run.chain
        run.chain = Task {
            await prev.value
            await op(self)
        }
    }

    // MARK: - Chạy một job

    /// `ssh -O check` đúng master của tab. Lỗi/hết giờ = coi như chết.
    private func masterIsAlive(controlPath: String, job: TransferJob) async -> Bool {
        let ssh = "/usr/bin/ssh"
        let out = try? await SimpleProcess.run(
            executable: ssh,
            arguments: [
                "-F", job.configPathSnapshot, "-o", "ControlPath=\(controlPath)", "-O", "check",
                "--", job.sshAliasSnapshot,
            ], environment: environment, timeout: 5)
        guard let out else { return false }
        return out.status == 0 && !out.timedOut
    }

    private func execute(_ run: Run) async {
        await runProcess(run)
        await run.chain.value
        run.secrets.removeAll()
        running[run.job.id] = nil
        pump()
    }

    private func runProcess(_ run: Run) async {
        let job = run.job
        if run.cancelRequested { return finishCancelled(run, partial: nil) }

        // Dùng lại master của tab nếu còn sống; chết rồi thì chạy không ControlPath (xác thực lại).
        if let wanted = controlPaths[job.id] {
            run.controlPath = await masterIsAlive(controlPath: wanted, job: job) ? wanted : nil
            if run.cancelRequested { return finishCancelled(run, partial: nil) }
        }
        let inv: ScpInvocation
        do { inv = try ScpCommandBuilder.build(for: job, controlPath: run.controlPath) } catch {
            return finishFailed(run, reason: "Tham số không hợp lệ: \(error)", partial: nil)
        }
        let partial = inv.tempPartialPath

        if job.direction == .download, job.overwritePolicy == .skip,
            LocalFinalizer.localConflict(job.destinationPath)
        {
            // Người dùng chọn bỏ qua và đích đã tồn tại: không cần tải.
            apply(run, to: .transferring)
            apply(run, to: .finalizing)
            apply(run, to: .completed, exit: .exited(0), reason: TransferJob.skippedReason)
            return
        }

        if credentials != nil {
            run.autoFillHost = (try? await hosts.host(id: job.hostID)).map { hostAdjuster?($0) ?? $0 }
        }

        if let partial { try? await repository.setTempPartialPath(id: job.id, partial) }
        if run.cancelRequested { return finishCancelled(run, partial: partial) }

        let process: PTYProcess
        do {
            let args = (extraSSHProgram.map { ["-S", $0.path] } ?? []) + inv.arguments
            process = try PTYProcess.start(
                executable: URL(fileURLWithPath: inv.executable), arguments: args,
                environment: environment, helper: ctty)
        } catch {
            return finishFailed(run, reason: "Không chạy được scp: \(error)", partial: partial)
        }
        run.process = process
        if run.cancelRequested { process.cancel() }

        var exit: ProcessExit = .exited(-1)
        for await ev in process.events {
            switch ev {
            case .output(let text): handleOutput(run, text)
            case .exit(let e): exit = e
            }
        }
        run.process = nil
        flushRemainder(run)

        // Thứ tự ưu tiên: huỷ > lỗi dứt khoát (host key đổi) > mã thoát.
        if run.cancelRequested || run.state == .cancelling {
            return finishCancelled(run, partial: partial)
        }
        if let fatal = run.fatalReason {
            return finishFailed(run, reason: fatal, partial: partial, exit: exit)
        }
        guard case .exited(0) = exit else {
            return finishFailed(
                run, reason: failureReason(run, exit: exit), partial: partial, exit: exit)
        }

        // scp báo thành công.
        apply(run, to: .transferring)
        if job.itemKind == .file { run.progress.fraction = 1 }
        run.progressDirty = true
        writeProgress(run, force: true)
        apply(run, to: .finalizing)
        if let partial {
            do {
                var policy = job.overwritePolicy
                if policy == .skip {
                    // Không có xung đột lúc bắt đầu: vẫn đặt file vào đích, nhưng không ghi đè.
                    policy = .rename(URL(fileURLWithPath: job.destinationPath).lastPathComponent)
                }
                try LocalFinalizer.finalize(
                    partialPath: partial, destination: job.destinationPath, policy: policy,
                    jobID: job.id)
            } catch {
                return finishFailed(
                    run, reason: "Không hoàn tất được file đã tải: \(error)", partial: partial,
                    exit: exit)
            }
        }
        apply(run, to: .completed, exit: TransferExitStatus(exit))
    }

    private func finishFailed(
        _ run: Run, reason: String, partial: String?, exit: ProcessExit? = nil
    ) {
        let text = scrub(run, reason + cleanup(run, partial))
        apply(run, to: .failed, exit: exit.map(TransferExitStatus.init), reason: text)
    }

    private func finishCancelled(_ run: Run, partial: String?) {
        let note = cleanup(run, partial)
        apply(run, to: .cancelling)  // no-op nếu đã ở cancelling
        apply(
            run, to: .cancelled, exit: .cancelled,
            reason: note.isEmpty ? nil : TransferJob.sanitizeReason(note))
    }

    /// Dọn `.part`; trả ghi chú nếu còn sót.
    private func cleanup(_ run: Run, _ partial: String?) -> String {
        guard let partial, LocalFinalizer.localConflict(partial) else { return "" }
        if LocalFinalizer.cleanupPartial(path: partial, jobID: run.job.id) { return "" }
        let name = URL(fileURLWithPath: partial).lastPathComponent
        return " (Không xoá được file tạm: \(name))"
    }

    // MARK: - Output

    private func handleOutput(_ run: Run, _ text: String) {
        guard
            run.state == .connecting || run.state == .awaitingUserInput
                || run.state == .transferring
        else { return }

        run.lineBuffer += text
        while let nl = run.lineBuffer.firstIndex(of: "\n") {
            let line = String(run.lineBuffer[..<nl])
            run.lineBuffer.removeSubrange(...nl)
            handleLine(run, line)
        }
        // scp vẽ progress bằng "\r" và dòng cuối chưa có "\n" → thử parse cả phần dở.
        if let p = ScpProgressParser.parse(run.lineBuffer) { noteProgress(run, p) }

        guard run.state == .connecting else {
            run.detector.reset()
            return
        }
        guard let kind = run.detector.feed(text) else { return }
        if case .hostKeyChanged = kind {
            // Không bao giờ trả lời; dừng process, job thành failed khi process thoát.
            run.fatalReason = "Host key đã thay đổi — dừng lại; kiểm tra known_hosts thủ công"
            run.process?.cancel()
            return
        }
        // Password lần ĐẦU, khớp `PasswordAutofillPolicy` (không bastion, đúng user@host): tự điền,
        // không hiện prompt. Lần sau (sai) hoặc prompt của bastion hỏi UI. Passphrase / MFA / host key luôn hỏi UI.
        if let host = run.autoFillHost, let ref = host.autofillCredentialReference,
            PasswordAutofillPolicy.shouldAutofill(
                prompt: kind, host: host, alreadyFilled: run.autoFilled)
        {
            run.autoFilled = true
            Task { self.autoFillPassword(run, ref: ref, fallback: kind) }
            return
        }
        presentPrompt(run, kind)
    }

    private func presentPrompt(_ run: Run, _ kind: PromptKind) {
        if apply(run, to: .awaitingUserInput) {
            let id = run.job.id
            chainOp(run) { m in m.continuation.yield(.authPrompt(jobID: id, kind)) }
        }
    }

    private func autoFillPassword(_ run: Run, ref: String, fallback: PromptKind) {
        guard run.state == .connecting, let p = run.process else { return }
        guard let password = credentials?.read(ref: ref), !password.isEmpty else {
            presentPrompt(run, fallback)  // Không đọc được Keychain: hỏi người dùng.
            return
        }
        run.secrets.append(password)
        p.send(password, redact: true)
    }

    private func handleLine(_ run: Run, _ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        if let p = ScpProgressParser.parse(t) {
            noteProgress(run, p)
            return
        }
        run.tail.append(t)
        if run.tail.count > 30 { run.tail.removeFirst() }
    }

    private func flushRemainder(_ run: Run) {
        let rest = run.lineBuffer
        run.lineBuffer = ""
        handleLine(run, rest)
    }

    private func noteProgress(_ run: Run, _ p: ScpProgress) {
        if run.state == .connecting { apply(run, to: .transferring) }
        guard run.state == .transferring else { return }
        if run.job.itemKind == .directory {
            // scp -r báo % theo từng file: không có tổng → indeterminate.
            run.progress = TransferProgress(bytesPerSecond: p.bytesPerSecond)
        } else {
            run.progress = TransferProgress(
                bytes: p.bytes, fraction: p.fraction, bytesPerSecond: p.bytesPerSecond)
        }
        run.progressDirty = true
        writeProgress(run, force: false)
    }

    /// Throttle: tối đa một lần ghi DB mỗi `progressInterval` giây (trừ khi `force`).
    private func writeProgress(_ run: Run, force: Bool) {
        guard run.progressDirty else { return }
        let now = Date()
        guard force || now.timeIntervalSince(run.lastProgressWrite) >= progressInterval else {
            return
        }
        run.lastProgressWrite = now
        run.progressDirty = false
        let id = run.job.id
        let progress = run.progress
        chainOp(run) { m in
            try? await m.repository.updateProgress(id: id, progress)
            if let j = try? await m.repository.job(id: id) { m.publish(j) }
        }
    }

    // MARK: - Lý do lỗi

    /// Theo thứ tự ưu tiên: lỗi cụ thể trước, "Connection closed" (scp luôn in sau cùng) để sau.
    private static let knownErrors = [
        "permission denied", "host key verification failed", "no such file",
        "connection refused", "could not resolve hostname", "connection timed out",
        "operation timed out", "no route to host", "network is unreachable", "not a regular file",
        "is a directory", "too many authentication failures", "disk quota", "no space left",
        "read-only file system", "connection reset", "connection closed",
    ]

    private func failureReason(_ run: Run, exit: ProcessExit) -> String {
        let lines = run.tail
        for pattern in Self.knownErrors {
            if let l = lines.last(where: { $0.lowercased().contains(pattern) }) { return l }
        }
        if let l = lines.last(where: { !$0.hasSuffix(":") }) { return l }
        switch exit {
        case .exited(let c): return "scp thoát với mã \(c)"
        case .signaled(let s): return "scp bị dừng bởi tín hiệu \(s)"
        case .cancelled: return "Đã huỷ"
        }
    }

    /// Che bất kỳ thứ gì người dùng đã nhập có thể lọt vào lý do lỗi, rồi làm sạch.
    private func scrub(_ run: Run, _ reason: String) -> String {
        var s = reason
        for secret in run.secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            s = s.replacingOccurrences(of: secret, with: "•••")
        }
        return TransferJob.sanitizeReason(s)
    }
}
