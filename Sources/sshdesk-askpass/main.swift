import AskpassKit
import Darwin
import Foundation
import Security

// Helper SSH_ASKPASS của SSH Desk. Chỉ nhận: argv[1] (prompt của ssh) và env
// SSHDESK_HOST_REF / SSH_ASKPASS_PROMPT. Không nhận lệnh nào khác.
// - Trả password Keychain CHỈ khi: cha là /usr/bin/ssh, prompt là password tài khoản, có tham chiếu,
//   và đây là lần đầu cho tiến trình ssh cha này.
// - Mọi trường hợp khác: hỏi người dùng trên /dev/tty. Không mở được tty -> exit 1.
// Không bao giờ ghi password ra stderr/log/file.

// MARK: - Tiện ích POSIX

func writeAll(_ fd: Int32, _ s: String) {
    var bytes = Array(s.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return }
    }
}

func environment(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

func parentExecutablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return n > 0 ? String(cString: buffer) : nil
}

func processStartTime(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
}

func homeDirectory() -> String? {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
    return String(cString: dir)
}

/// `~/Library/Application Support/SSHDesk/askpass`, quyền 0700.
func markerDirectory() -> String? {
    guard let home = homeDirectory() else { return nil }
    var path = home
    for part in ["Library", "Application Support", "SSHDesk", "askpass"] {
        path += "/" + part
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
    }
    chmod(path, 0o700)
    return path
}

func removeOldMarkers(in dir: String) {
    guard let d = opendir(dir) else { return }
    defer { closedir(d) }
    let cutoff = time(nil) - 86_400
    while let entry = readdir(d) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        guard name.hasPrefix("used-") else { continue }
        var st = stat()
        let full = dir + "/" + name
        if lstat(full, &st) == 0, st.st_mtimespec.tv_sec < cutoff { unlink(full) }
    }
}

/// Đánh dấu nguyên tử "đã dùng password cho tiến trình ssh cha này". Lỗi nào cũng coi là đã dùng.
func claimPasswordUse() -> Bool {
    let ppid = getppid()
    guard let dir = markerDirectory(), let started = processStartTime(ppid) else { return false }
    removeOldMarkers(in: dir)
    let fd = open("\(dir)/used-\(ppid)-\(started)", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    close(fd)
    return true
}

func readKeychainPassword(ref: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: CredentialConstants.service,
        kSecAttrAccount as String: ref,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
        let data = out as? Data
    else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - tty

nonisolated(unsafe) var savedTermios = termios()
nonisolated(unsafe) var savedTTY: Int32 = -1

func restoreTerminalAndExit(_ signal: Int32) {
    if savedTTY >= 0 { tcsetattr(savedTTY, TCSAFLUSH, &savedTermios) }
    _exit(128 + signal)
}

func askOnTTY(prompt: String, echo: Bool) -> String? {
    let tty = open("/dev/tty", O_RDWR)
    guard tty >= 0 else { return nil }
    defer { close(tty) }
    writeAll(tty, AskpassDecision.sanitizeForDisplay(prompt))
    if !echo {
        if tcgetattr(tty, &savedTermios) == 0 {
            savedTTY = tty
            signal(SIGINT, restoreTerminalAndExit)
            signal(SIGTERM, restoreTerminalAndExit)
            var t = savedTermios
            t.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(tty, TCSAFLUSH, &t)
        }
    }
    var answer: [UInt8] = []
    var byte: UInt8 = 0
    var sawAny = false
    while answer.count < 4096 {
        let n = read(tty, &byte, 1)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        sawAny = true
        if byte == 10 { break }
        answer.append(byte)
    }
    if savedTTY >= 0 {
        tcsetattr(tty, TCSAFLUSH, &savedTermios)
        savedTTY = -1
    }
    if !echo { writeAll(tty, "\n") }
    if !sawAny { return nil }
    return String(decoding: answer, as: UTF8.self)
}

func showOnTTY(_ text: String) {
    let tty = open("/dev/tty", O_WRONLY)
    guard tty >= 0 else { return }
    writeAll(tty, AskpassDecision.sanitizeForDisplay(text) + "\n")
    close(tty)
}

// MARK: - main

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Password:"
let action = AskpassDecision.decide(
    prompt: prompt, promptType: environment("SSH_ASKPASS_PROMPT"),
    hostRef: environment(CredentialConstants.hostRefEnv),
    parentPath: parentExecutablePath(getppid()), claimUse: claimPasswordUse)

switch action {
case .answerFromKeychain(let ref):
    if let password = readKeychainPassword(ref: ref) {
        writeAll(1, password + "\n")
        exit(0)
    }
    // Không có item / không đọc được: hỏi người dùng như ssh thường.
    guard let answer = askOnTTY(prompt: prompt, echo: false) else { exit(1) }
    writeAll(1, answer + "\n")
case .askTTY(let echo):
    guard let answer = askOnTTY(prompt: prompt, echo: echo) else { exit(1) }
    writeAll(1, answer + "\n")
case .showOnly:
    showOnTTY(prompt)
}
exit(0)
