import Foundation
import Testing

@testable import SSHDeskCore

private final class FakeHandler: WarpURLHandler, @unchecked Sendable {
    var available = true
    var accept = true
    var opened: [URL] = []
    func isWarpAvailable() -> Bool { available }
    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return accept
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warptest-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let hostileStrings = [
    "a b", "$HOME", "`id`", "it's", "say \"hi\"", "Tiếng Việt ü 日本", "-n", "a;b", "a && b",
    "$(touch /tmp/pwned)", "back\\slash", "'", "''", "*?[x]", "~/x", "=ls",
]

// MARK: - Renderer

@Test func rendererExactOutput() {
    let out = WarpTabConfigRenderer.render(displayName: "Web 1", command: "'/usr/bin/ssh' '-F' '/p' 'a'")
    let expected = """
        # Do SSH Desk sinh — không sửa tay
        name = "Web 1"

        [[panes]]
        id = "main"
        type = "terminal"
        shell = "zsh"
        is_focused = true
        commands = ["'/usr/bin/ssh' '-F' '/p' 'a'"]

        """
    #expect(out == expected)
}

@Test func rendererEscapesHostileDisplayName() {
    let name = "a\"b\\c\nd]\r[[panes]]\ncommands = [\"rm -rf /\"]\u{01}\u{7F}\t"
    let out = WarpTabConfigRenderer.render(displayName: name, command: "ssh x")
    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.filter { $0 == "[[panes]]" }.count == 1)
    #expect(lines.filter { $0.hasPrefix("commands") }.count == 1)
    #expect(lines.filter { $0.hasPrefix("name") }.count == 1)
    #expect(lines.first?.hasPrefix(WarpTabConfigRenderer.ownershipMarker) == true)
    #expect(out.contains(#"name = "a\"b\\c\nd]\r[[panes]]\ncommands = [\"rm -rf /\"]\u0001\u007F\t""#))
    #expect(lines.contains(#"commands = ["ssh x"]"#))
    #expect(!out.contains("rm -rf /\"]\n"))
}

@Test func tomlControlEscapes() {
    #expect(WarpTabConfigRenderer.tomlString("\u{08}\t\n\u{0C}\r\u{1F}") == #""\b\t\n\f\r\u001F""#)
}

// MARK: - Quoting

@Test func quoteBasics() throws {
    #expect(try ZshQuoting.quote("") == "''")
    #expect(try ZshQuoting.quote("abc") == "'abc'")
    #expect(try ZshQuoting.quote("it's") == #"'it'\''s'"#)
    #expect(try ZshQuoting.quote("$(x) `y` \"z\" ü -n; &&") == "'$(x) `y` \"z\" ü -n; &&'")
}

@Test func quoteRejectsControlLineBreaks() {
    for bad in ["a\nb", "a\rb", "a\0b", "\n"] {
        #expect(throws: ZshQuotingError.forbiddenCharacter) { try ZshQuoting.quote(bad) }
    }
}

@Test func sshCommandJoinsQuoted() throws {
    let cmd = try ZshQuoting.sshCommand(sshPath: "/usr/bin/ssh", configPath: "/p/my config", alias: "sshdesk-1")
    #expect(cmd == "'/usr/bin/ssh' '-F' '/p/my config' 'sshdesk-1'")
    #expect(throws: ZshQuotingError.self) {
        try ZshQuoting.sshCommand(sshPath: "/usr/bin/ssh", configPath: "/p", alias: "a\nb")
    }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
func realZshEchoesHostileArgumentsVerbatim() throws {
    for s in hostileStrings {
        let cmd = try ZshQuoting.sshCommand(sshPath: "/bin/echo", configPath: s, alias: s + "x")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == "-F \(s) \(s)x\n", "chuỗi: \(s)")
    }
}

// MARK: - Launcher

@Test func prepareWritesOwnedFileAndURI() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    let launcher = WarpLauncher(tabConfigsDirectory: dir, handler: FakeHandler())
    let prep = try launcher.prepare(hostID: id, displayName: "H", sshCommand: "ssh x")
    let stem = "sshdesk_" + id.uuidString.lowercased()
    #expect(prep.fileURL.lastPathComponent == stem + ".toml")
    #expect(prep.uri.absoluteString == "warp://tab_config/\(stem)")
    #expect(prep.copyableCommand == "ssh x")
    let again = try launcher.prepare(hostID: id, displayName: "H", sshCommand: "ssh x", newWindow: true)
    #expect(again.uri.absoluteString == "warp://tab_config/\(stem)?new_window=true")
    let attrs = try FileManager.default.attributesOfItem(atPath: prep.fileURL.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files == [stem + ".toml"])
}

@Test func refusesToOverwriteForeignFileAndRemove() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    let file = dir.appendingPathComponent("sshdesk_" + id.uuidString.lowercased() + ".toml")
    try "name = \"mine\"\n".write(to: file, atomically: true, encoding: .utf8)
    let launcher = WarpLauncher(tabConfigsDirectory: dir, handler: FakeHandler())
    #expect(throws: WarpLauncherError.notOwnedByApp) {
        try launcher.prepare(hostID: id, displayName: "H", sshCommand: "ssh x")
    }
    #expect(throws: WarpLauncherError.notOwnedByApp) { try launcher.removeConfig(hostID: id) }
    #expect(try String(contentsOf: file, encoding: .utf8) == "name = \"mine\"\n")
}

@Test func removeConfigDeletesOwnedOnly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    let other = dir.appendingPathComponent("personal.toml")
    try "x".write(to: other, atomically: true, encoding: .utf8)
    let launcher = WarpLauncher(tabConfigsDirectory: dir, handler: FakeHandler())
    let prep = try launcher.prepare(hostID: id, displayName: "H", sshCommand: "ssh x")
    try launcher.removeConfig(hostID: id)
    #expect(!FileManager.default.fileExists(atPath: prep.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
    try launcher.removeConfig(hostID: id)  // không tồn tại: không lỗi
}

@Test func launchResults() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let handler = FakeHandler()
    let launcher = WarpLauncher(tabConfigsDirectory: dir, handler: handler)
    let id = UUID()
    #expect(await launcher.launch(hostID: id, displayName: "H", sshCommand: "ssh x", newWindow: true) == .requested)
    #expect(handler.opened.count == 1)
    #expect(handler.opened[0].absoluteString.hasSuffix("?new_window=true"))

    handler.accept = false
    if case .failed = await launcher.launch(hostID: id, displayName: "H", sshCommand: "ssh x") {
    } else {
        Issue.record("mong .failed")
    }

    handler.available = false
    handler.opened = []
    #expect(await launcher.launch(hostID: id, displayName: "H", sshCommand: "ssh x") == .warpUnavailable)
    #expect(handler.opened.isEmpty)
}

@Test func launchWithoutWarpWritesNothing() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tabDir = dir.appendingPathComponent("tab_configs")
    let handler = FakeHandler()
    handler.available = false
    let launcher = WarpLauncher(tabConfigsDirectory: tabDir, handler: handler)
    #expect(await launcher.launch(hostID: UUID(), displayName: "H", sshCommand: "ssh x") == .warpUnavailable)
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: tabDir.path)) ?? []
    #expect(contents.isEmpty)
    #expect(handler.opened.isEmpty)
}
