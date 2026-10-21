import Foundation

@testable import SSHDeskCore

/// Thư mục tạm cho test DB, tự dọn khi `cleanup()`.
struct HostTempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshdesk-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var dbURL: URL { url.appendingPathComponent("data/sshdesk.sqlite") }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

func managedHost(
    _ name: String = "web", hostName: String = "web.example.com", user: String = "deploy",
    project: String = "", tags: [String] = [], jump: UUID? = nil
) -> HostProfile {
    HostProfile(
        displayName: name, project: project, tags: tags, hostName: hostName, user: user,
        jumpHostID: jump)
}

func importedHost(_ name: String = "legacy", alias: String = "web-u") -> HostProfile {
    HostProfile(
        displayName: name, connectionMode: .existingSSHConfigAlias,
        sshConfigPath: "/Users/me/.ssh/config", sshConfigAlias: alias)
}
