import Foundation

public enum PromptKind: Sendable, Equatable {
    case password(String)
    case passphrase(String)
    case keyboardInteractive(String)
    case hostKeyConfirm(fingerprint: String?, text: String)
    /// Lỗi dừng, KHÔNG phải prompt: không được cho người dùng "tiếp tục".
    case hostKeyChanged(String)
    /// Dòng cuối chưa kết thúc, trông như prompt (kết thúc bằng `:`/`?`) nhưng không nhận ra loại.
    /// UI hiển thị text đã làm sạch (fallback), không tự điền credential.
    case unknown(String)
}

/// Nhận chunk output (đã bỏ ANSI và `\r`), giữ bộ đệm cuối, phát hiện prompt xác thực của OpenSSH.
/// Pure: không I/O. Mỗi prompt chỉ được báo một lần (bộ đệm được xóa sau khi báo).
public struct PromptDetector: Sendable {
    public static let maxPromptLength = 300
    private static let maxBuffer = 4000

    private var buffer = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> PromptKind? {
        // Phòng thủ: dù đầu vào được nói là đã sạch, vẫn bỏ escape/ký tự điều khiển.
        buffer += OutputSanitizer.clean(chunk.replacingOccurrences(of: "\r", with: ""))
        // Dòng quá dài (độc hại) bị rút gọn nhưng giữ đầu và đuôi để vẫn nhận ra prompt.
        buffer = buffer.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.count > 1000 ? String(line.prefix(500)) + "…" + String(line.suffix(400)) : String(line)
        }.joined(separator: "\n")
        if buffer.count > Self.maxBuffer { buffer = String(buffer.suffix(Self.maxBuffer)) }

        if let range = buffer.range(of: "REMOTE HOST IDENTIFICATION HAS CHANGED") {
            let line = Self.lineContaining(range, in: buffer)
            buffer = ""
            return .hostKeyChanged(Self.clip(line))
        }

        // Prompt chỉ có thể nằm ở dòng cuối chưa kết thúc bằng newline.
        guard !buffer.hasSuffix("\n") else { return nil }
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let lastRaw = lines.last else { return nil }
        let last = lastRaw.trimmingCharacters(in: .whitespaces)
        guard !last.isEmpty else { return nil }
        let lower = last.lowercased()

        if lower.hasPrefix("enter passphrase for"), last.hasSuffix(":") {
            buffer = ""
            return .passphrase(Self.clip(last))
        }
        if lower.contains("are you sure you want to continue connecting"), last.hasSuffix("?") {
            let fingerprint = Self.extractFingerprint(lines.dropLast())
            let text = Self.hostKeyText(lines)
            buffer = ""
            return .hostKeyConfirm(fingerprint: fingerprint, text: text)
        }
        guard last.hasSuffix(":") else { return nil }
        if lower.hasSuffix("password:") || lower.hasPrefix("password for")
            || lower.contains("]'s password:") || lower.contains("'s password:")
        {
            buffer = ""
            return .password(Self.clip(last))
        }
        if lower.range(of: #"verification code|otp|token|code"#, options: .regularExpression) != nil {
            buffer = ""
            return .keyboardInteractive(Self.clip(last))
        }
        buffer = ""
        return .unknown(Self.clip(last))
    }

    public mutating func reset() { buffer = "" }

    // MARK: - Helpers

    /// Cắt tối đa 300 ký tự (giữ phần đầu), bỏ ký tự điều khiển.
    static func clip(_ s: String) -> String {
        let cleaned = OutputSanitizer.clean(s).unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        let text = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return String(text.prefix(maxPromptLength))
    }

    private static func lineContaining(_ range: Range<String.Index>, in s: String) -> String {
        let start = s[..<range.lowerBound].lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
        let end = s[range.upperBound...].firstIndex(of: "\n") ?? s.endIndex
        return String(s[start..<end])
    }

    private static func extractFingerprint<S: Sequence>(_ lines: S) -> String? where S.Element == String {
        var found: String?
        for line in lines {
            if let r = line.range(of: #"(SHA256|MD5):[A-Za-z0-9+/=:]+"#, options: .regularExpression) {
                found = String(line[r])
            }
        }
        return found
    }

    /// Khối thông tin host key + câu hỏi; giữ phần cuối nếu dài quá để câu hỏi không bị cắt mất.
    private static func hostKeyText(_ lines: [String]) -> String {
        var start = 0
        if let i = lines.lastIndex(where: { $0.contains("authenticity of host") }) { start = i }
        let block = lines[start...].joined(separator: "\n")
        let cleaned = clipKeepingTail(block)
        return cleaned
    }

    private static func clipKeepingTail(_ s: String) -> String {
        let scalars = OutputSanitizer.clean(s).unicodeScalars.filter {
            $0.value == 0x0A || ($0.value >= 0x20 && $0.value != 0x7F)
        }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= maxPromptLength ? text : "…" + String(text.suffix(maxPromptLength - 1))
    }
}
