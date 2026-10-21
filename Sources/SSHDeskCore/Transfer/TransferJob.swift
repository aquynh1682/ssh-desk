import Foundation

public enum TransferDirection: String, Codable, Sendable, Equatable {
    case upload
    case download
}

public enum TransferItemKind: String, Codable, Sendable, Equatable {
    case file
    case directory
}

/// Chính sách ghi đè mà người dùng ĐÃ xác nhận trước khi tạo job (không bao giờ là mặc định ngầm).
public enum OverwritePolicy: Codable, Sendable, Equatable {
    case overwrite
    /// Đích mới (chỉ tên cuối, không có dấu `/`) do người dùng đặt.
    case rename(String)
    case skip
}

/// Trạng thái cuối của process, tách khỏi `ProcessExit` để có thể Codable/lưu DB.
public enum TransferExitStatus: Codable, Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
    case cancelled

    public init(_ exit: ProcessExit) {
        switch exit {
        case .exited(let c): self = .exited(c)
        case .signaled(let s): self = .signaled(s)
        case .cancelled: self = .cancelled
        }
    }
}

public struct TransferProgress: Codable, Sendable, Equatable {
    /// Mọi giá trị đều có thể chưa biết (indeterminate).
    public var bytes: Int64?
    public var fraction: Double?
    public var bytesPerSecond: Double?

    public init(bytes: Int64? = nil, fraction: Double? = nil, bytesPerSecond: Double? = nil) {
        self.bytes = bytes
        self.fraction = fraction
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum TransferState: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case connecting
    case awaitingUserInput
    case transferring
    case finalizing
    case completed
    case failed
    case cancelling
    case cancelled
    /// "Bị gián đoạn": job đang chạy/đang chờ khi app thoát hoặc crash. Không tự chạy lại.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        default: return false
        }
    }
}

public struct TransferJob: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var hostID: UUID
    public var hostDisplayNameSnapshot: String
    /// Chuỗi hiển thị `user@host:port` tại thời điểm tạo job.
    public var targetSnapshot: String
    public var sshAliasSnapshot: String
    public var configPathSnapshot: String
    public var direction: TransferDirection
    public var sourcePath: String
    public var destinationPath: String
    public var itemKind: TransferItemKind
    public var overwritePolicy: OverwritePolicy
    public var state: TransferState
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var progress: TransferProgress
    public var exitStatus: TransferExitStatus?
    /// Ngắn, đã làm sạch (xem `sanitizeReason`).
    public var failureReason: String?
    public var previousAttemptID: UUID?
    /// File/thư mục `.part` local của download (nil nếu chưa có hoặc là upload).
    public var tempPartialPath: String?

    public init(
        id: UUID = UUID(), hostID: UUID, hostDisplayNameSnapshot: String, targetSnapshot: String,
        sshAliasSnapshot: String, configPathSnapshot: String, direction: TransferDirection,
        sourcePath: String, destinationPath: String, itemKind: TransferItemKind,
        overwritePolicy: OverwritePolicy, state: TransferState = .queued, createdAt: Date = Date(),
        startedAt: Date? = nil, finishedAt: Date? = nil, progress: TransferProgress = .init(),
        exitStatus: TransferExitStatus? = nil, failureReason: String? = nil,
        previousAttemptID: UUID? = nil, tempPartialPath: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.hostDisplayNameSnapshot = hostDisplayNameSnapshot
        self.targetSnapshot = targetSnapshot
        self.sshAliasSnapshot = sshAliasSnapshot
        self.configPathSnapshot = configPathSnapshot
        self.direction = direction
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.itemKind = itemKind
        self.overwritePolicy = overwritePolicy
        self.state = state
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.progress = progress
        self.exitStatus = exitStatus
        self.failureReason = failureReason
        self.previousAttemptID = previousAttemptID
        self.tempPartialPath = tempPartialPath
    }

    /// Lý do ghi kèm khi download bị bỏ qua vì đích đã tồn tại (job vẫn `completed`).
    public static let skippedReason = "Đã bỏ qua vì đích đã tồn tại"

    /// Làm sạch lý do lỗi trước khi lưu: bỏ ký tự điều khiển, gộp khoảng trắng, cắt 200 ký tự.
    public static func sanitizeReason(_ raw: String) -> String {
        let cleaned = String(
            String.UnicodeScalarView(
                raw.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) ? " " : $0
                }))
        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return String(collapsed.prefix(200))
    }
}

public enum TransferStateError: Error, Equatable {
    case invalidTransition(from: TransferState, to: TransferState)
}

/// Máy trạng thái đúng sơ đồ mục 9 (+ `interrupted` chỉ dùng khi recovery).
public enum TransferStateMachine {
    private static let edges: [TransferState: Set<TransferState>] = [
        .queued: [.connecting, .cancelled],
        .connecting: [.awaitingUserInput, .transferring, .failed, .cancelling],
        .awaitingUserInput: [.connecting, .failed, .cancelling],
        .transferring: [.finalizing, .failed, .cancelling],
        .finalizing: [.completed, .failed],
        .cancelling: [.cancelled],
    ]

    /// Mọi trạng thái chưa kết thúc (kể cả `queued`) → `interrupted` khi recovery sau crash.
    public static func isValid(from: TransferState, to: TransferState) -> Bool {
        if to == .interrupted { return !from.isTerminal }
        return edges[from]?.contains(to) ?? false
    }

    public static func transition(from: TransferState, to: TransferState) throws -> TransferState {
        guard isValid(from: from, to: to) else {
            throw TransferStateError.invalidTransition(from: from, to: to)
        }
        return to
    }
}
