import Foundation

/// Một alias `Host` cụ thể tìm thấy trong file SSH config có sẵn.
///
/// Các giá trị (`hostName`, `user`, `port`, `identityFile`, `proxyJump`) là giá trị THÔ,
/// đọc trực tiếp từ khối `Host` đó để hiển thị. Chúng KHÔNG phải cấu hình hiệu lực:
/// `Host *`, `Match` hoặc `Include` đứng sau có thể thay đổi kết quả thật khi OpenSSH
/// xử lý. UI phải nói rõ điều này. Không expand `%` token hay biến môi trường.
public struct ImportCandidate: Sendable, Equatable {
    public let alias: String
    /// File chứa dòng `Host` (có thể là file được `Include`).
    public let sourceFile: URL
    /// Số dòng (từ 1) của dòng `Host`.
    public let line: Int
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var proxyJump: String?
    public var hasProxyCommand: Bool
    /// Khối này nằm sau `Match`, trong file được Include có điều kiện, dùng pattern/negation
    /// cùng dòng, hoặc chứa `Include`/`Match`: cấu hình hiệu lực có thể khác giá trị thô.
    public var hasMatchOrComplexity: Bool

    public init(
        alias: String, sourceFile: URL, line: Int, hostName: String? = nil,
        user: String? = nil, port: Int? = nil, identityFile: String? = nil,
        proxyJump: String? = nil, hasProxyCommand: Bool = false,
        hasMatchOrComplexity: Bool = false
    ) {
        self.alias = alias
        self.sourceFile = sourceFile
        self.line = line
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.hasProxyCommand = hasProxyCommand
        self.hasMatchOrComplexity = hasMatchOrComplexity
    }
}

/// Cảnh báo khi quét; luôn có file và số dòng (0 nếu không gắn với dòng cụ thể).
public struct ScanWarning: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case fileUnreadable
        case fileTooLarge
        case notUTF8
        case tooManyLines
        case includeUnresolved
        case includeDepthExceeded
        case includeCycle
        case tooManyFiles
        case matchNotEvaluated
        case matchExec
        case proxyCommand
        case duplicateAlias
        case invalidAlias
        case invalidValue
        case malformedLine
    }

    public let kind: Kind
    public let file: URL
    public let line: Int
    public let message: String

    public init(kind: Kind, file: URL, line: Int, message: String) {
        self.kind = kind
        self.file = file
        self.line = line
        self.message = message
    }
}

public struct SSHConfigScanResult: Sendable, Equatable {
    public var candidates: [ImportCandidate]
    /// Token `Host` chứa `*`, `?` hoặc `!` (vd `*`, `*.internal`); không phải máy chủ cụ thể.
    public var skippedPatterns: [String]
    public var warnings: [ScanWarning]

    public init(
        candidates: [ImportCandidate] = [], skippedPatterns: [String] = [],
        warnings: [ScanWarning] = []
    ) {
        self.candidates = candidates
        self.skippedPatterns = skippedPatterns
        self.warnings = warnings
    }
}
