import Foundation

/// Tìm helper `sshdesk-ctty` (xem `PTYProcess`). Thứ tự:
/// 1. cạnh executable chính (`.app/Contents/MacOS`, `swift run`, `.build/<config>`);
/// 2. cạnh thư mục chứa test bundle (`swift test`: `.build/<triple>/debug/`);
/// 3. `.build/{debug,release}` của package theo `#filePath` (chạy test từ xctest runner).
public enum ControllingTTYHelper {
    public static let name = "sshdesk-ctty"

    public static func defaultURL() -> URL? { HelperLocator.url(named: name) }
}

/// Tìm helper `sshdesk-askpass` (cùng quy tắc tìm như `sshdesk-ctty`).
public enum AskpassHelper {
    public static let name = "sshdesk-askpass"
    public static func defaultURL() -> URL? { HelperLocator.url(named: name) }
}

enum HelperLocator {
    static func url(named name: String) -> URL? {
        let filePath = #filePath
        let fm = FileManager.default
        var dirs: [URL] = []
        if let exe = Bundle.main.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        for b in Bundle.allBundles {
            dirs.append(b.bundleURL.deletingLastPathComponent())
        }
        // .../Sources/SSHDeskCore/Process/<file> -> gốc package
        let root = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for config in ["debug", "release"] {
            dirs.append(root.appendingPathComponent(".build/\(config)"))
        }
        for d in dirs {
            let url = d.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
