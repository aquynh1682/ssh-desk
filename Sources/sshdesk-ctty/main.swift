import Darwin

// Helper nhỏ: biến slave pty thành controlling tty rồi exec chương trình đích.
// argv = [tên, ttyPath, executable, args...]. Không đọc env, không nhận input nào khác.
// Mọi lỗi: in ngắn ra stderr và thoát 126.

func fail(_ message: String) -> Never {
    let line = "sshdesk-ctty: " + message + "\n"
    _ = line.withCString { write(2, $0, strlen($0)) }
    _exit(126)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("thiếu tham số") }
let ttyPath = args[1]
let target = args[2]

// PTYProcess đã setsid; chạy trực tiếp thì tự setsid (EPERM nếu đã là leader => bỏ qua).
if getsid(0) != getpid() {
    guard setsid() != -1 else { fail("setsid: errno \(errno)") }
}

let fd = open(ttyPath, O_RDWR)
guard fd >= 0 else { fail("không mở được tty: errno \(errno)") }
if ioctl(fd, UInt(TIOCSCTTY), 0) != 0 {
    // Có thể open() đã gán controlling tty; chỉ chấp nhận nếu /dev/tty mở được.
    let probe = open("/dev/tty", O_RDWR)
    guard probe >= 0 else { fail("TIOCSCTTY: errno \(errno)") }
    close(probe)
}
for target in Int32(0)...2 where dup2(fd, target) < 0 { fail("dup2: errno \(errno)") }
// Đóng mọi fd thừa (giữ 0/1/2).
for extra in 3..<256 { close(Int32(extra)) }

var cArgv: [UnsafeMutablePointer<CChar>?] = args.dropFirst(2).map { strdup($0) }
cArgv.append(nil)
execv(target, &cArgv)
fail("execv \(target): errno \(errno)")
