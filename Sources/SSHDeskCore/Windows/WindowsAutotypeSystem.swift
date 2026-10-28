import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// ADR-018b: cài đặt thật của `WindowsAutotypeProbe` / `WindowsKeyTyper`. Dùng chuỗi literal cho tên thuộc tính AX và
// khoá tuỳ chọn để không đụng biến toàn cục C (Swift 6 coi là trạng thái chia sẻ không an toàn).

/// Đọc quyền Trợ năng và phần tử đang focus của app đang ở trước. Không đọc giá trị ô (chỉ độ dài).
public struct SystemWindowsAutotypeProbe: WindowsAutotypeProbe {
    public init() {}

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func requestTrust() {
        // "AXTrustedCheckOptionPrompt" = kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func snapshot() -> WindowsUISnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else { return WindowsUISnapshot() }
        var snapshot = WindowsUISnapshot(
            frontmostBundleID: app.bundleIdentifier, frontmostPID: app.processIdentifier)
        guard AXIsProcessTrusted() else { return snapshot }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, "AXFocusedUIElement" as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return snapshot }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        snapshot.focusedSubrole = Self.string(element, "AXSubrole")
        snapshot.fieldLength = Self.integer(element, "AXNumberOfCharacters")
        return snapshot
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func integer(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }
}

/// Gõ bằng sự kiện bàn phím gửi THẲNG tới một pid (`postToPid`), không post toàn hệ thống.
public struct SystemWindowsKeyTyper: WindowsKeyTyper {
    /// Mã phím Return (kVK_Return).
    private static let returnKey: CGKeyCode = 0x24

    public init() {}

    public func type(_ chunk: String, toPID pid: Int32) -> Bool {
        let units = Array(chunk.utf16)
        guard !units.isEmpty, let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                return false
            }
            event.flags = []  // không để modifier người dùng đang giữ lọt vào
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.postToPid(pid)
        }
        return true
    }

    public func pressReturn(toPID pid: Int32) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKey, keyDown: keyDown)
            else { return false }
            event.flags = []
            event.postToPid(pid)
        }
        return true
    }
}
