import Foundation

/// Làm sạch output của tiến trình con trước khi đưa lên UI/log:
/// bỏ chuỗi ANSI (CSI/OSC/DCS...), ký tự điều khiển, ký tự đảo chiều văn bản (bidi).
/// `\r\n` và `\r` đơn lẻ đều thành `\n` (progress của scp dùng `\r` để vẽ lại dòng).
/// Có trạng thái: chuỗi escape hoặc ký tự UTF-8 bị cắt giữa hai lần đọc vẫn xử lý đúng.
public struct OutputSanitizer: Sendable {
    private enum State { case normal, esc, escIntermediate, csi, string, stringEsc }

    private var state = State.normal
    private var stringLength = 0
    private var lastWasCR = false
    private var pending: [UInt8] = []

    /// Chuỗi escape kiểu OSC/DCS không có điểm kết thúc sẽ không được nuốt vô hạn output.
    private static let maxStringLength = 4096

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = pending
        pending = []
        out.reserveCapacity(out.count + bytes.count)
        for b in bytes { step(b, into: &out) }
        let cut = Self.completePrefixLength(out)
        if cut < out.count {
            pending = Array(out[cut...])
            out.removeLast(out.count - cut)
        }
        return Self.decode(out)
    }

    /// Xả phần byte UTF-8 dở dang còn lại (khi kết thúc luồng).
    public mutating func finish() -> String {
        let rest = pending
        pending = []
        state = .normal
        return Self.decode(rest)
    }

    /// Tiện ích cho chuỗi đã có sẵn.
    public static func clean(_ text: String) -> String {
        var s = OutputSanitizer()
        let a = s.feed(Array(text.utf8))
        return a + s.finish()
    }

    private mutating func step(_ b: UInt8, into out: inout [UInt8]) {
        switch state {
        case .normal:
            switch b {
            case 0x1B:
                state = .esc
                lastWasCR = false
            case 0x0D:
                out.append(0x0A)
                lastWasCR = true
            case 0x0A:
                if !lastWasCR { out.append(0x0A) }
                lastWasCR = false
            case 0x09:
                out.append(b)
                lastWasCR = false
            case 0x00..<0x20, 0x7F:
                lastWasCR = false
            default:
                out.append(b)
                lastWasCR = false
            }
        case .esc:
            switch b {
            case 0x5B: state = .csi
            case 0x5D, 0x50, 0x58, 0x5E, 0x5F:  // ] P X ^ _
                state = .string
                stringLength = 0
            case 0x20...0x2F: state = .escIntermediate
            case 0x1B: state = .esc
            default: state = .normal
            }
        case .escIntermediate:
            if (0x30...0x7E).contains(b) { state = .normal } else if b == 0x1B { state = .esc }
        case .csi:
            if (0x40...0x7E).contains(b) {
                state = .normal
            } else if b == 0x1B {
                state = .esc
            }
        case .string:
            stringLength += 1
            if b == 0x07 {
                state = .normal
            } else if b == 0x1B {
                state = .stringEsc
            } else if stringLength > Self.maxStringLength {
                state = .normal
            }
        case .stringEsc:
            if b == 0x5C {
                state = .normal
            } else {
                state = .esc
                step(b, into: &out)
            }
        }
    }

    /// Độ dài tiền tố không kết thúc giữa một ký tự UTF-8.
    private static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        var i = n - 1
        var back = 0
        while i >= 0, back < 3 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 {
                i -= 1
                back += 1
                continue
            }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            return (n - i) < need ? i : n
        }
        return n
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            let v = u.value
            if (0x80...0x9F).contains(v) { continue }  // C1
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F {
                continue  // bidi
            }
            scalars.append(u)
        }
        return String(scalars)
    }
}
