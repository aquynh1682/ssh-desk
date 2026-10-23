import Foundation
import SSHDeskCore

// CLI `sshdesk` (ADR-025). Chỉ đọc DB; `open` ghi file yêu cầu rồi nhờ app mở. Không đọc Keychain,
// không ghi SSH config / Tab Config / DB, không chạy ssh.
// Mã thoát: 0 ok, 1 lỗi chạy, 2 sai tham số, 3 không tìm thấy / nhiều máy khớp / máy Windows.

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func fail(_ s: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("sshdesk: " + s + "\n").utf8))
    exit(code)
}

func loadHosts(_ paths: AppPaths) async -> [HostProfile] {
    do {
        let db = try Database.openReadOnly(url: paths.databaseURL)
        return try await HostRepository(database: db).all()
    } catch DatabaseError.notFound(let p) {
        fail("chưa có dữ liệu (\(p)). Hãy mở SSH Desk một lần.", code: 1)
    } catch DatabaseError.schemaMismatch(let found, let expected) {
        fail("schema dữ liệu là \(found), CLI này hiểu \(expected). Dùng CLI cùng phiên bản với app.", code: 1)
    } catch { fail("không đọc được dữ liệu: \(error)", code: 1) }
}

let command: CLICommand
do { command = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst())) } catch {
    fail("\(error)\n\(CLIArguments.usage)", code: 2)
}
let paths = AppPaths.default

switch command {
case .help:
    out(CLIArguments.usage)
case .list(let folder, let json):
    let entries = CLIHostList.entries(await loadHosts(paths), folder: folder)
    do { out(json ? try CLIHostList.json(entries) : CLIHostList.table(entries)) } catch {
        fail("không xuất được JSON: \(error)", code: 1)
    }
case .template(let path):
    // Ghi file Excel mẫu mới (ADR-026): không ghi đè, không đụng DB / SSH config.
    let url = URL(fileURLWithPath: path)
    do {
        try InventoryTemplate.write(to: url)
        out("Đã ghi file mẫu: \(url.standardizedFileURL.path)")
    } catch { fail("\(error)", code: 1) }
case .open(let query):
    let hosts = await loadHosts(paths)
    let host: HostProfile
    do { host = try HostResolver.resolve(query, in: hosts) } catch { fail("\(error)", code: 3) }
    let dir = CLIOpenRequest.directory(in: paths)
    let requestID: UUID
    do { requestID = try CLIOpenRequest.write(hostID: host.id, in: dir) } catch {
        fail("\(error)", code: 1)
    }
    // /usr/bin/open với argv [url] — không qua shell.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["sshdesk://cli?request=\(requestID.uuidString.lowercased())"]
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        CLIOpenRequest.discard(id: requestID, in: dir)
        fail("không chạy được /usr/bin/open: \(error)", code: 1)
    }
    guard proc.terminationStatus == 0 else {
        CLIOpenRequest.discard(id: requestID, in: dir)
        fail("không mở được SSH Desk (đã cài vào /Applications và mở một lần chưa?).", code: 1)
    }
    out("Đã gửi yêu cầu mở “\(HostResolver.printable(host.displayName))” tới SSH Desk.")
}
