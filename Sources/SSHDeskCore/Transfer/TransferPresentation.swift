import Foundation

/// Ánh xạ trạng thái job → nhãn tiếng Việt và quy tắc nút. Thuần logic.
public enum TransferPresentation {
    public static func isSkipped(_ job: TransferJob) -> Bool {
        job.state == .completed && job.direction == .download && job.overwritePolicy == .skip
            && job.failureReason == TransferJob.skippedReason
    }

    public static func label(for job: TransferJob) -> String {
        if isSkipped(job) { return "Đã bỏ qua" }
        return label(for: job.state)
    }

    public static func label(for state: TransferState) -> String {
        switch state {
        case .queued: return "Đang chờ"
        case .connecting: return "Đang kết nối"
        case .awaitingUserInput: return "Chờ xác thực"
        case .transferring: return "Đang truyền"
        case .finalizing: return "Đang hoàn tất"
        case .completed: return "Hoàn tất"
        case .failed: return "Lỗi"
        case .cancelling: return "Đang huỷ"
        case .cancelled: return "Đã huỷ"
        case .interrupted: return "Bị gián đoạn"
        }
    }

    /// Huỷ được ở mọi trạng thái chưa kết thúc, trừ `finalizing` (ADR-008) và `cancelling`.
    public static func canCancel(_ state: TransferState) -> Bool {
        switch state {
        case .queued, .connecting, .awaitingUserInput, .transferring: return true
        default: return false
        }
    }

    public static func canRetry(_ state: TransferState) -> Bool {
        state == .failed || state == .cancelled || state == .interrupted
    }

    /// Đường dẫn local để mở trong Finder (download hoàn tất, không bị bỏ qua).
    public static func revealPath(for job: TransferJob) -> String? {
        guard job.direction == .download, job.state == .completed, !isSkipped(job) else {
            return nil
        }
        if case .rename(let name) = job.overwritePolicy {
            return URL(fileURLWithPath: job.destinationPath).deletingLastPathComponent()
                .appendingPathComponent(name).path
        }
        return job.destinationPath
    }

    /// `nil` = không xác định (KHÔNG bịa phần trăm).
    public static func fraction(for job: TransferJob) -> Double? {
        guard job.state == .transferring || job.state == .finalizing else { return nil }
        return job.progress.fraction.map { min(1, max(0, $0)) }
    }

    public static func speedText(for job: TransferJob) -> String? {
        guard job.state == .transferring, let v = job.progress.bytesPerSecond, v > 0 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) + "/s"
    }

    /// Job đang hoạt động (màn Truyền file) so với lịch sử.
    public static func isActive(_ job: TransferJob) -> Bool { !job.state.isTerminal }

    /// Active: cũ trước (thứ tự hàng đợi). History: mới kết thúc trước.
    public static func active(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.filter(isActive).sorted { $0.createdAt < $1.createdAt }
    }

    public static func history(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.filter { !isActive($0) }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }
}

/// Câu hỏi xác thực đang chờ của một job.
public struct PendingPrompt: Sendable, Equatable, Identifiable {
    public var id: UUID { jobID }
    public let jobID: UUID
    public let kind: PromptKind
}

/// Hàng đợi prompt: nhiều job chờ thì xếp hàng, hiển thị lần lượt.
public struct AuthPromptQueue: Sendable, Equatable {
    public private(set) var items: [PendingPrompt] = []

    public init() {}

    public var current: PendingPrompt? { items.first }

    /// Prompt mới của cùng job thay thế prompt cũ (giữ vị trí).
    public mutating func enqueue(jobID: UUID, kind: PromptKind) {
        let p = PendingPrompt(jobID: jobID, kind: kind)
        if let i = items.firstIndex(where: { $0.jobID == jobID }) {
            items[i] = p
        } else {
            items.append(p)
        }
    }

    public mutating func remove(jobID: UUID) { items.removeAll { $0.jobID == jobID } }

    /// Job không còn chờ nhập (đã trả lời, huỷ, lỗi...) thì bỏ prompt của nó.
    public mutating func reconcile(_ job: TransferJob) {
        if job.state != .awaitingUserInput { remove(jobID: job.id) }
    }
}

/// Cách hiển thị một `PromptKind` (không chứa dữ liệu bí mật).
public struct PromptPresentation: Sendable, Equatable {
    public enum Input: Sendable, Equatable {
        /// Ô nhập che ký tự.
        case secret
        /// Hai nút Tin cậy / Huỷ.
        case hostKeyDecision
        /// Chỉ có nút huỷ tác vụ (lỗi dứt khoát).
        case none
    }

    public let title: String
    public let text: String
    public let fingerprint: String?
    public let input: Input
    public let note: String?

    public static let hostKeyTrust = (text: "yes", isSecret: false)
    public static let hostKeyDecline = (text: "no", isSecret: false)

    public init(_ kind: PromptKind) {
        switch kind {
        case .password(let t):
            (title, text, fingerprint, input, note) = ("Cần mật khẩu", t, nil, .secret, nil)
        case .passphrase(let t):
            (title, text, fingerprint, input, note) = ("Cần passphrase", t, nil, .secret, nil)
        case .keyboardInteractive(let t):
            (title, text, fingerprint, input, note) = (
                "Cần mã xác thực", t, nil, .secret, "Mã không được lưu"
            )
        case .hostKeyConfirm(let fp, let t):
            (title, text, fingerprint, input, note) = (
                "Xác nhận host key", t, fp, .hostKeyDecision, nil
            )
        case .hostKeyChanged(let t):
            (title, text, fingerprint, input, note) = ("Host key đã thay đổi", t, nil, .none, nil)
        case .unknown(let t):
            (title, text, fingerprint, input, note) = ("Máy chủ yêu cầu nhập", t, nil, .secret, nil)
        }
    }
}

/// Trình bày khung "Truyền file" ở màn chính.
extension TransferPresentation {
    /// Toàn bộ job đang chạy (cũ trước) rồi tới các job gần nhất để đủ `limit`.
    /// Nếu số job đang chạy đã ≥ `limit` thì không thêm lịch sử.
    public static func panelJobs(_ jobs: [TransferJob], limit: Int = 4) -> [TransferJob] {
        let running = active(jobs)
        let slots = max(0, limit - running.count)
        return running + Array(history(jobs).prefix(slots))
    }

    /// Tên file/thư mục đang truyền (thành phần cuối của nguồn).
    public static func fileName(for job: TransferJob) -> String {
        let name = URL(fileURLWithPath: job.sourcePath).lastPathComponent
        return name.isEmpty || name == "/" ? job.sourcePath : name
    }

    /// "nguồn → đích" ngắn: upload = Máy này → host; download = host → tên thư mục đích.
    public static func route(for job: TransferJob) -> (from: String, to: String) {
        switch job.direction {
        case .upload: return ("Máy này", job.hostDisplayNameSnapshot)
        case .download:
            let dir = URL(fileURLWithPath: job.destinationPath).deletingLastPathComponent()
                .lastPathComponent
            return (job.hostDisplayNameSnapshot, dir.isEmpty ? "Máy này" : dir)
        }
    }

    /// Phần trăm làm tròn (0...100) khi có fraction thật; không có thì nil.
    public static func percentText(for job: TransferJob) -> String? {
        fraction(for: job).map { "\(Int(($0 * 100).rounded()))%" }
    }
}
