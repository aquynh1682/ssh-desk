import AppKit
import Foundation

/// Tách phần tương tác hệ thống để test không mở Warp thật.
public protocol WarpURLHandler: Sendable {
    /// Warp có đăng ký xử lý scheme `warp://` không.
    func isWarpAvailable() -> Bool
    /// Yêu cầu hệ thống mở URL; trả về true nếu yêu cầu được chấp nhận.
    func open(_ url: URL) async -> Bool
}

/// Cài đặt thật dựa trên NSWorkspace.
public struct SystemWarpURLHandler: WarpURLHandler {
    public init() {}

    public func isWarpAvailable() -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "warp://tab_config/x")!) != nil
    }

    public func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}

public enum WarpLauncherError: Error, Equatable {
    /// Tên file không khớp namespace `sshdesk_<uuid>.toml`.
    case outsideNamespace
    /// File cùng tên đã tồn tại nhưng không do SSH Desk sinh.
    case notOwnedByApp
    case writeFailed(String)
}

public struct PreparedLaunch: Equatable, Sendable {
    public let fileURL: URL
    public let fileStem: String
    public let uri: URL
    /// Chính chuỗi lệnh ssh — dùng cho fallback "Copy lệnh SSH".
    public let copyableCommand: String
}

public enum LaunchResult: Equatable, Sendable {
    /// Chỉ nghĩa là đã yêu cầu mở Warp, không phải đã đăng nhập.
    case requested
    case warpUnavailable
    case failed(String)
}

public struct WarpLauncher: Sendable {
    public let tabConfigsDirectory: URL
    private let handler: any WarpURLHandler

    public static var defaultTabConfigsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".warp/tab_configs", isDirectory: true)
    }

    public init(
        tabConfigsDirectory: URL = WarpLauncher.defaultTabConfigsDirectory,
        handler: any WarpURLHandler = SystemWarpURLHandler()
    ) {
        self.tabConfigsDirectory = tabConfigsDirectory
        self.handler = handler
    }

    static func fileStem(for hostID: UUID) -> String { "sshdesk_" + hostID.uuidString.lowercased() }

    static func isOwnedFileName(_ name: String) -> Bool {
        name.range(of: #"^sshdesk_[0-9a-f-]{36}\.toml$"#, options: .regularExpression) != nil
    }

    static func uri(stem: String, newWindow: Bool) -> URL {
        URL(string: "warp://tab_config/\(stem)" + (newWindow ? "?new_window=true" : ""))!
    }

    public func prepare(
        hostID: UUID, displayName: String, sshCommand: String, newWindow: Bool = false
    ) throws -> PreparedLaunch {
        let stem = Self.fileStem(for: hostID)
        let name = stem + ".toml"
        guard Self.isOwnedFileName(name) else { throw WarpLauncherError.outsideNamespace }
        let target = tabConfigsDirectory.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: target.path) {
            guard try Self.isAppOwned(target) else { throw WarpLauncherError.notOwnedByApp }
        }
        let content = WarpTabConfigRenderer.render(displayName: displayName, command: sshCommand)
        try atomicWrite(Data(content.utf8), to: target)
        return PreparedLaunch(
            fileURL: target, fileStem: stem, uri: Self.uri(stem: stem, newWindow: newWindow),
            copyableCommand: sshCommand)
    }

    public func launch(
        hostID: UUID, displayName: String, sshCommand: String, newWindow: Bool = false
    ) async -> LaunchResult {
        guard handler.isWarpAvailable() else { return .warpUnavailable }
        let prepared: PreparedLaunch
        do {
            prepared = try prepare(
                hostID: hostID, displayName: displayName, sshCommand: sshCommand, newWindow: newWindow)
        } catch {
            return .failed("\(error)")
        }
        return await handler.open(prepared.uri) ? .requested : .failed("Không gửi được yêu cầu mở Warp.")
    }

    /// Chỉ xóa file thuộc app. File lạ (không có dấu hiệu) bị từ chối.
    public func removeConfig(hostID: UUID) throws {
        let name = Self.fileStem(for: hostID) + ".toml"
        guard Self.isOwnedFileName(name) else { throw WarpLauncherError.outsideNamespace }
        let target = tabConfigsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard try Self.isAppOwned(target) else { throw WarpLauncherError.notOwnedByApp }
        try FileManager.default.removeItem(at: target)
    }

    private static func isAppOwned(_ url: URL) throws -> Bool {
        guard let data = FileManager.default.contents(atPath: url.path),
            let text = String(data: data, encoding: .utf8)
        else { throw WarpLauncherError.writeFailed("Không đọc được file hiện có.") }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return firstLine.hasPrefix(WarpTabConfigRenderer.ownershipMarker)
    }

    /// Ghi file tạm 0600 cùng thư mục rồi rename.
    private func atomicWrite(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tabConfigsDirectory, withIntermediateDirectories: true)
            let tmp = tabConfigsDirectory.appendingPathComponent(".sshdesk_tmp_" + UUID().uuidString)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw WarpLauncherError.writeFailed("Không tạo được file tạm.")
            }
            if rename(tmp.path, target.path) != 0 {
                let reason = String(cString: strerror(errno))
                try? fm.removeItem(at: tmp)
                throw WarpLauncherError.writeFailed(reason)
            }
        } catch let error as WarpLauncherError {
            throw error
        } catch {
            throw WarpLauncherError.writeFailed("\(error)")
        }
    }
}
