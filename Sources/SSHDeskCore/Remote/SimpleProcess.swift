import Foundation

struct SimpleProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

/// Chạy executable + argv (không shell, không PTY), gom stdout/stderr, có timeout.
enum SimpleProcess {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    static func run(
        executable: String, arguments: [String], stdin: String? = nil,
        environment: [String: String], timeout: TimeInterval
    ) async throws -> SimpleProcessOutput {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = environment
                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                p.standardInput = inPipe
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                let timedOut = Flag()
                let pid = p.processIdentifier
                let timer = DispatchWorkItem {
                    timedOut.set()
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { kill(pid, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                let group = DispatchGroup()
                let outBox = Box()
                let errBox = Box()
                group.enter()
                DispatchQueue.global().async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                    try? inPipe.fileHandleForWriting.close()
                    group.leave()
                }
                p.waitUntilExit()
                group.wait()
                timer.cancel()
                cont.resume(
                    returning: SimpleProcessOutput(
                        status: p.terminationStatus,
                        stdout: String(decoding: outBox.data, as: UTF8.self),
                        stderr: String(decoding: errBox.data, as: UTF8.self),
                        timedOut: timedOut.isSet))
            }
        }
    }
}
