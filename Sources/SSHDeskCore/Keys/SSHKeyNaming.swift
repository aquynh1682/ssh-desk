import Foundation

public enum SSHKeyError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case invalidComment
    case alreadyExists(String)
    case invalidPublicKey
    case invalidAlias
    case invalidTargetPath
    case directoryNotUsable(String)

    public var description: String {
        switch self {
        case .invalidName(let why): return "Tên file không hợp lệ: \(why)"
        case .invalidComment: return "Comment không được chứa ký tự điều khiển (hoặc quá dài)."
        case .alreadyExists(let p): return "File đã tồn tại, app không ghi đè: \(p)"
        case .invalidPublicKey: return "Public key không hợp lệ (cần file .pub tuyệt đối, tồn tại)."
        case .invalidAlias: return "Alias SSH của máy chủ không hợp lệ."
        case .invalidTargetPath: return "Đường dẫn đích trên máy chủ không hợp lệ."
        case .directoryNotUsable(let p): return "Không dùng được thư mục: \(p)"
        }
    }
}

public enum SSHKeyNaming {
    public static let maxNameLength = 100
    public static let maxCommentLength = 200

    /// Tên file key: chỉ `[A-Za-z0-9._-]`, không bắt đầu bằng `-`, không phải `.`/`..`, không kết thúc `.pub`.
    public static func validateName(_ name: String) throws {
        if name.isEmpty { throw SSHKeyError.invalidName("để trống") }
        if name.count > maxNameLength { throw SSHKeyError.invalidName("quá dài") }
        if name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            throw SSHKeyError.invalidName("chỉ dùng chữ, số, `.`, `_`, `-`")
        }
        if name.hasPrefix("-") { throw SSHKeyError.invalidName("không bắt đầu bằng `-`") }
        if name == "." || name == ".." { throw SSHKeyError.invalidName("tên đặc biệt") }
        if name.hasSuffix(".pub") { throw SSHKeyError.invalidName("không kết thúc bằng `.pub`") }
    }

    /// Comment: không ký tự điều khiển (kể cả newline/DEL).
    public static func validateComment(_ comment: String) throws {
        if comment.count > maxCommentLength { throw SSHKeyError.invalidComment }
        for u in comment.unicodeScalars where u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value) {
            throw SSHKeyError.invalidComment
        }
    }
}
