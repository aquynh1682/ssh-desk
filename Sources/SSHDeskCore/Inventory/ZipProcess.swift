import Darwin
import Foundation

/// Chạy một công cụ hệ thống (executable + argv, env RỖNG, không shell), đọc stdout theo chunk với trần byte và timeout.
/// Vượt trần/timeout -> terminate tiến trình và ném lỗi. Dùng cho `/usr/bin/unzip` (ADR-026).
enum BoundedProcess {
    struct Result {
        var status: Int32
        var stdout: Data
    }

    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false
        private var _exceeded = false
        func setTimedOut() {
            lock.lock()
            _timedOut = true
            lock.unlock()
        }
        func setExceeded() {
            lock.lock()
            _exceeded = true
            lock.unlock()
        }
        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _timedOut
        }
        var exceeded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _exceeded
        }
    }

    /// - Parameters:
    ///   - maxBytes: trần stdout cho lần chạy này.
    ///   - exceeded: lỗi ném khi vượt `maxBytes`.
    static func run(
        executable: String, arguments: [String], currentDirectory: URL? = nil, maxBytes: Int, timeout: TimeInterval,
        exceeded: SpreadsheetError
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [:]
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw SpreadsheetError.cannotRun(executable) }

        let flags = Flags()
        let pid = process.processIdentifier
        let timer = DispatchWorkItem {
            flags.setTimedOut()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        var data = Data()
        let reader = out.fileHandleForReading
        while true {
            let chunk: Data
            do { chunk = try reader.read(upToCount: 65_536) ?? Data() } catch { break }
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes {
                flags.setExceeded()
                process.terminate()
                if process.isRunning { kill(pid, SIGKILL) }
                break
            }
        }
        try? reader.close()
        process.waitUntilExit()
        timer.cancel()
        if flags.exceeded { throw exceeded }
        if flags.timedOut { throw SpreadsheetError.timeout }
        return Result(status: process.terminationStatus, stdout: data)
    }
}
