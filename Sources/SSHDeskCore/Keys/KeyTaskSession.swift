import Darwin
import Foundation

public enum KeyTaskOutcome: Sendable, Equatable {
    /// Thông điệp ngắn đã làm sạch.
    case success(String)
    case failure(String)
    case cancelled
}

public enum KeyTaskEvent: Sendable, Equatable {
    case authPrompt(PromptKind)
    /// Luôn là event cuối; sau đó stream kết thúc.
    case finished(KeyTaskOutcome)
}

public enum KeyTaskError: Error, Equatable {
    case alreadyStarted
    case spawnFailed(String)
}

/// Một tác vụ khoá (tạo key, cài key) chạy qua PTY: phát prompt lên UI, nhận câu trả lời, báo kết quả.
/// Tổng quát cho mọi tác vụ "khoá" — UI không cần biết đó là ssh-keygen hay ssh-copy-id.
public actor KeyTaskSession {
    public nonisolated let events: AsyncStream<KeyTaskEvent>

    private let continuation: AsyncStream<KeyTaskEvent>.Continuation
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let helper: URL?
    private let autofill: (@Sendable (PromptKind) -> String?)?
    private let refuseOverwrite: Bool
    private let evaluate: @Sendable (ProcessExit, _ lines: [String]) -> KeyTaskOutcome

    private var pty: PTYProcess?
    private var detector = PromptDetector()
    private var started = false
    private var finished = false
    private var userCancelled = false
    private var overwriteRefused = false
    private var fatalReason: String?
    private var output = ""
    private var readerTask: Task<Void, Never>?

    /// - Parameters:
    ///   - autofill: gọi cho mỗi prompt; trả chuỗi thì gửi thẳng (che trong output) và KHÔNG phát lên UI.
    ///   - refuseOverwrite: gặp `Overwrite (y/n)?` thì trả lời `n` và coi là lỗi.
    ///   - evaluate: (exit, các dòng cuối (tối đa 40) của output đã làm sạch) → kết quả; không được gọi khi huỷ.
    init(
        executable: URL, arguments: [String], environment: [String: String], helper: URL?,
        autofill: (@Sendable (PromptKind) -> String?)? = nil, refuseOverwrite: Bool = false,
        evaluate: @escaping @Sendable (ProcessExit, [String]) -> KeyTaskOutcome
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.helper = helper
        self.autofill = autofill
        self.refuseOverwrite = refuseOverwrite
        self.evaluate = evaluate
        let (stream, cont) = AsyncStream<KeyTaskEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        continuation = cont
    }

    func start() throws {
        guard !started else { throw KeyTaskError.alreadyStarted }
        started = true
        let proc: PTYProcess
        do {
            proc = try PTYProcess.start(
                executable: executable, arguments: arguments, environment: environment, helper: helper)
        } catch {
            started = false
            throw KeyTaskError.spawnFailed("\(error)")
        }
        pty = proc
        readerTask = Task { [weak self] in
            for await event in proc.events { await self?.handle(event) }
        }
    }

    /// Trả lời prompt đang chờ. `isSecret`: che chuỗi này nếu tiến trình con in lại.
    public func respond(text: String, isSecret: Bool) {
        guard !finished, !userCancelled else { return }
        pty?.send(text, redact: isSecret)
    }

    /// Huỷ theo process group. Kết quả cuối là `.cancelled`.
    public func cancel() {
        guard !finished, !userCancelled else { return }
        userCancelled = true
        pty?.cancel()
    }

    // MARK: - Nội bộ

    private func handle(_ event: ProcessEvent) {
        switch event {
        case .output(let text):
            output = String((output + text).suffix(4000))
            guard !userCancelled, fatalReason == nil else { return }
            if refuseOverwrite, !overwriteRefused, endsWithOverwritePrompt() {
                overwriteRefused = true
                detector.reset()
                pty?.send("n", redact: false)
                return
            }
            guard let kind = detector.feed(text) else { return }
            if case .hostKeyChanged(let line) = kind {
                fatalReason = "Host key của máy chủ đã thay đổi: \(line)"
                pty?.cancel()
                return
            }
            if let secret = autofill?(kind) {
                pty?.send(secret, redact: true)
                return
            }
            continuation.yield(.authPrompt(kind))
        case .exit(let exit):
            guard !finished else { return }
            finished = true
            let outcome: KeyTaskOutcome
            if let fatalReason {
                outcome = .failure(fatalReason)
            } else if userCancelled {
                outcome = .cancelled
            } else if overwriteRefused {
                outcome = .failure("File đích đã tồn tại — app không ghi đè.")
            } else {
                outcome = evaluate(exit, tailLines())
            }
            continuation.yield(.finished(outcome))
            continuation.finish()
        }
    }

    private func endsWithOverwritePrompt() -> Bool {
        guard !output.hasSuffix("\n") else { return false }
        let last = output.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return last.lowercased().contains("overwrite (y/n)")
    }

    private func tailLines() -> [String] {
        let lines = output.split(whereSeparator: \.isNewline).map {
            PromptDetector.clip(String($0))
        }.filter { !$0.isEmpty }
        return Array(lines.suffix(40))
    }
}

/// Hộp trạng thái "đã tự điền chưa" dùng chung giữa các lần gọi closure autofill.
final class AutofillLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var filled = false
    var isFilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return filled
    }
    func mark() {
        lock.lock()
        filled = true
        lock.unlock()
    }
}
