import AppKit
import Foundation

/// Tách phần tương tác hệ thống để test không mở Windows App thật.
public protocol WindowsAppHandler: Sendable {
    /// Đường dẫn Windows App; nil nếu chưa cài.
    func windowsAppURL() -> URL?
    /// Yêu cầu mở file bằng app; true nếu yêu cầu được chấp nhận.
    func open(file: URL, withApplicationAt app: URL) async -> Bool
}

public struct SystemWindowsAppHandler: WindowsAppHandler {
    public static let bundleIdentifier = "com.microsoft.rdc.macos"
    /// Trang tải Windows App trên Mac App Store.
    public static let appStoreURL = URL(string: "macappstore://apps.apple.com/app/id1295203466")!

    public init() {}

    public func windowsAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    public func open(file: URL, withApplicationAt app: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(
                [file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()
            ) { opened, error in
                continuation.resume(returning: opened != nil && error == nil)
            }
        }
    }
}

public enum RDPLaunchResult: Equatable, Sendable {
    /// Chỉ nghĩa là đã yêu cầu mở Windows App, không phải đã kết nối.
    case requested
    case appUnavailable
    case failed(String)
}

public enum WindowsAppLauncherError: Error, Equatable {
    case writeFailed(String)
}

/// Ghi `~/Library/Application Support/SSHDesk/rdp/<uuid>.rdp` (0600, atomically) rồi nhờ Windows App mở.
public struct WindowsAppLauncher: Sendable {
    public let directory: URL
    private let handler: any WindowsAppHandler

    public static var defaultDirectory: URL {
        AppPaths.default.baseDirectory.appendingPathComponent("rdp", isDirectory: true)
    }

    public init(
        directory: URL = WindowsAppLauncher.defaultDirectory,
        handler: any WindowsAppHandler = SystemWindowsAppHandler()
    ) {
        self.directory = directory
        self.handler = handler
    }

    /// Thư mục con riêng của host: `<directory>/<uuid chữ thường>/`.
    public func hostDirectory(hostID: UUID) -> URL {
        directory.appendingPathComponent(hostID.uuidString.lowercased(), isDirectory: true)
    }

    /// Windows App lấy tiêu đề cửa sổ từ TÊN FILE nên tên file = tên hiển thị đã làm sạch.
    public func fileURL(hostID: UUID, displayName: String) -> URL {
        hostDirectory(hostID: hostID).appendingPathComponent(
            Self.sanitizedFileName(displayName) + ".rdp")
    }

    /// Bỏ ký tự điều khiển, thay `/ : \` và ký tự không hợp lệ bằng `-`, trim, tối đa 80 ký tự, rỗng -> "Windows".
    public static func sanitizedFileName(_ name: String) -> String {
        let invalid = Set("/:\\*?\"<>|")
        var out = ""
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                || scalar.value == 0x2028 || scalar.value == 0x2029
            {
                continue
            }
            let ch = Character(scalar)
            out.append(invalid.contains(ch) ? "-" : ch)
        }
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        out = clean(out)
        if out.count > 80 { out = clean(String(out.prefix(80))) }
        return out.isEmpty ? "Windows" : out
    }

    /// Sinh và ghi file (ghi đè; file cũ khác tên trong thư mục con bị xoá). Không mở app.
    @discardableResult
    public func prepare(_ host: HostProfile) throws -> URL {
        try host.validate()
        let content = try RDPFileRenderer.render(host)
        let target = fileURL(hostID: host.id, displayName: host.displayName)
        try atomicWrite(Data(content.utf8), to: target)
        return target
    }

    public func launch(_ host: HostProfile) async -> RDPLaunchResult {
        guard let app = handler.windowsAppURL() else { return .appUnavailable }
        let file: URL
        do { file = try prepare(host) } catch { return .failed("\(error)") }
        return await handler.open(file: file, withApplicationAt: app)
            ? .requested : .failed("Không gửi được yêu cầu mở Windows App.")
    }

    /// Xoá cả thư mục con của host (không lỗi nếu chưa có). Không đi theo symlink: nếu là symlink thì chỉ gỡ liên kết.
    public func removeFile(hostID: UUID) throws {
        let dir = hostDirectory(hostID: hostID)
        guard (try? FileManager.default.attributesOfItem(atPath: dir.path)) != nil else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let hostDir = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // Thư mục con là symlink (hoặc file) -> gỡ đi, không ghi xuyên qua.
            if let attrs = try? fm.attributesOfItem(atPath: hostDir.path),
                (attrs[.type] as? FileAttributeType) != .typeDirectory
            {
                try fm.removeItem(at: hostDir)
            }
            try fm.createDirectory(
                at: hostDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hostDir.path)
            // Đổi tên host: xoá file cũ khác tên.
            for name in (try? fm.contentsOfDirectory(atPath: hostDir.path)) ?? []
            where name != target.lastPathComponent {
                try? fm.removeItem(at: hostDir.appendingPathComponent(name))
            }
            let tmp = hostDir.appendingPathComponent(".sshdesk_tmp_" + UUID().uuidString)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw WindowsAppLauncherError.writeFailed("Không tạo được file tạm.") }
            if rename(tmp.path, target.path) != 0 {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: tmp)
                throw WindowsAppLauncherError.writeFailed(reason)
            }
        } catch let error as WindowsAppLauncherError {
            throw error
        } catch {
            throw WindowsAppLauncherError.writeFailed("\(error)")
        }
    }
}
